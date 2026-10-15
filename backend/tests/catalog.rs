mod common;

use axum::http::{Method, StatusCode};
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use common::bank_mocks::{spawn_anthropic, spawn_off, AI_KEY, OFF_BROKEN, OFF_MISSING, OFF_PRODUCT};
use common::{ai_config, catalog_config, TestApp};
use serde_json::{json, Value};
use shared_schema::AiProvider;
use sqlx::PgPool;

use backend::config::ServerAiConfig;

fn photo(a_size: usize) -> String
{
    let mut bytes = vec![0xFF, 0xD8, 0xFF, 0xE0];
    bytes.extend(std::iter::repeat_n(7u8, a_size));
    STANDARD.encode(bytes)
}

fn label(a_is_label: bool) -> Value
{
    json!({
        "is_label": a_is_label,
        "name": "Йогурт питний полуниця 2,5%",
        "brand": "Галичина",
        "quantity": "500 г",
        "barcode": OFF_MISSING,
        "kind": "food",
        "kcal": 78.4,
        "protein": 2.9,
        "fat": 2.5,
        "carbohydrates": 11.2
    })
}

#[sqlx::test(migrations = "./migrations")]
async fn product_lookup_asks_open_food_facts_politely_and_caches(a_db: PgPool)
{
    let (off_url, off) = spawn_off().await;
    let app = TestApp::with_catalog(
        a_db,
        catalog_config(&[], Some(&off_url)),
        ai_config("http://127.0.0.1:9", None),
    );
    let alice = app.user("alice@example.com").await;
    let lookup = |a_code: &str, a_lang: &str| {
        let uri = format!("/api/dicts/products/lookup/{a_code}?lang={a_lang}");
        let token = alice.token.clone();
        let app = &app;
        async move { app.call(Method::GET, &uri, Some(&token), None).await }
    };

    let found = lookup(OFF_PRODUCT, "uk").await;
    assert_eq!(found.status, StatusCode::OK, "{}", found.body);
    assert_eq!(found.body["status"], "found");
    let product = &found.body["product"];
    assert_eq!(product["name"], "Кава мелена");
    assert_eq!(product["brand"], "Jacobs");
    assert_eq!(product["suggested_name"], "Кава мелена Jacobs 250 г");
    assert_eq!(product["barcode"], OFF_PRODUCT);
    assert_eq!(product["kind"], "food");
    assert_eq!(product["nutrition"]["kcal"], "2");
    assert_eq!(product["nutrition"]["fat"], "0.1");

    let cached = lookup(OFF_PRODUCT, "en").await;
    assert_eq!(cached.body["product"]["name"], "Ground coffee");
    assert_eq!(off.calls(), vec![OFF_PRODUCT.to_string()]);

    for _ in 0..2
    {
        let missing = lookup(OFF_MISSING, "uk").await;
        assert_eq!(missing.status, StatusCode::OK);
        assert_eq!(missing.body["status"], "not_found");
        assert_eq!(missing.body["product"], Value::Null);
    }
    for _ in 0..2
    {
        let broken = lookup(OFF_BROKEN, "uk").await;
        assert_eq!(broken.body["status"], "unavailable");
    }
    assert_eq!(
        off.calls(),
        [OFF_PRODUCT, OFF_MISSING, OFF_BROKEN, OFF_BROKEN]
            .map(str::to_string)
            .to_vec()
    );

    let invalid = lookup("4820024700017", "uk").await;
    assert_eq!(invalid.status, StatusCode::BAD_REQUEST);
    assert_eq!(invalid.body["field"], "barcode");
    let odd_lang = lookup(OFF_PRODUCT, "../x").await;
    assert_eq!(odd_lang.body["product"]["name"], "Кава мелена");

    let disabled = TestApp::with_catalog(
        app.state.db.clone(),
        catalog_config(&[], None),
        ai_config("http://127.0.0.1:9", None),
    );
    let bob = disabled.user("bob@example.com").await;
    let offline = disabled
        .call(
            Method::GET,
            &format!("/api/dicts/products/lookup/{OFF_BROKEN}"),
            Some(&bob.token),
            None,
        )
        .await;
    assert_eq!(offline.body["status"], "unavailable");
}

#[sqlx::test(migrations = "./migrations")]
async fn label_photo_is_read_within_the_scan_quota(a_db: PgPool)
{
    let (ai_url, mock) = spawn_anthropic().await;
    let server = ServerAiConfig {
        provider: AiProvider::Anthropic,
        api_key: AI_KEY.to_string(),
        model: "claude-opus-5-5".to_string(),
        daily_limit: 2,
        monthly_limit: 300,
    };
    let app = TestApp::with_catalog(a_db, catalog_config(&[], None), ai_config(&ai_url, Some(server)));
    let alice = app.user("alice@example.com").await;
    let read = |a_image: String| {
        let token = alice.token.clone();
        let app = &app;
        async move {
            app.call(
                Method::POST,
                "/api/dicts/products/label",
                Some(&token),
                Some(json!({ "media_type": "image/jpeg", "image": a_image })),
            )
            .await
        }
    };

    let oversized = read(photo(2 * 1024 * 1024 + 1)).await;
    assert_eq!(oversized.status, StatusCode::BAD_REQUEST);
    assert_eq!(oversized.body["field"], "image");
    assert!(mock.calls().is_empty());

    mock.reply_with(label(true));
    let info = read(photo(400)).await;
    assert_eq!(info.status, StatusCode::OK, "{}", info.body);
    assert_eq!(
        info.body["suggested_name"],
        "Йогурт питний полуниця 2,5% Галичина 500 г"
    );
    assert_eq!(info.body["barcode"], OFF_MISSING);
    assert_eq!(info.body["kind"], "food");
    assert_eq!(info.body["nutrition"]["kcal"], "78.4");
    assert_eq!(info.body["nutrition"]["carb"], "11.2");
    let request = mock.requests.lock().unwrap().last().cloned().unwrap();
    assert!(request["system"].as_str().unwrap().contains("product packaging"));
    assert!(request["output_config"]["format"]["schema"]["properties"]["is_label"].is_object());

    mock.reply_with(label(false));
    let not_label = read(photo(400)).await;
    assert_eq!(not_label.status, StatusCode::CONFLICT);
    assert_eq!(not_label.body["code"], "NOT_A_LABEL");

    let limited = read(photo(400)).await;
    assert_eq!(limited.status, StatusCode::TOO_MANY_REQUESTS);
}
