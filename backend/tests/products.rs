mod common;

use axum::http::{Method, StatusCode};
use chrono::{Duration, Utc};
use common::{TestApp, TestUser};
use serde_json::{json, Value};
use sqlx::PgPool;

const COFFEE_BARCODE: &str = "4820024700016";

async fn post(a_app: &TestApp, a_user: &TestUser, a_uri: &str, a_body: Value) -> Value
{
    let reply = a_app.call(Method::POST, a_uri, Some(&a_user.token), Some(a_body)).await;
    assert!(reply.status.is_success(), "{a_uri}: {} {}", reply.status, reply.body);
    reply.body
}

async fn item(a_app: &TestApp, a_user: &TestUser, a_body: Value) -> String
{
    post(a_app, a_user, "/api/dicts/items", a_body).await["id"]
        .as_str()
        .unwrap()
        .to_string()
}

async fn shop(a_app: &TestApp, a_user: &TestUser, a_name: &str, a_family: Option<&str>) -> (String, String)
{
    let countries = a_app
        .call(Method::GET, "/api/geo/countries", Some(&a_user.token), None)
        .await;
    let country_id = countries.body[0]["id"].as_str().unwrap().to_string();
    let city = post(
        a_app,
        a_user,
        &format!("/api/geo/countries/{country_id}/cities"),
        json!({ "name": "Київ" }),
    )
    .await;
    let city_id = city["id"].as_str().unwrap().to_string();
    let street = post(
        a_app,
        a_user,
        &format!("/api/geo/cities/{city_id}/streets"),
        json!({ "name": "Хрещатик" }),
    )
    .await;

    let place = post(
        a_app,
        a_user,
        "/api/places",
        json!({
            "name": a_name,
            "family_id": a_family,
            "addrs": [{
                "is_main": true,
                "country_id": country_id,
                "city_id": city_id,
                "street_id": street["id"],
                "house_num": "5",
                "zip": "01001"
            }]
        }),
    )
    .await;

    (
        place["id"].as_str().unwrap().to_string(),
        place["addrs"][0]["id"].as_str().unwrap().to_string(),
    )
}

async fn receipt(a_app: &TestApp, a_user: &TestUser, a_body: Value) -> (StatusCode, Value)
{
    let reply = a_app
        .call(Method::POST, "/api/receipts", Some(&a_user.token), Some(a_body))
        .await;
    (reply.status, reply.body)
}

async fn prices(a_app: &TestApp, a_user: &TestUser, a_item: &str, a_convert: Option<&str>) -> Value
{
    let uri = match a_convert
    {
        Some(code) => format!("/api/dicts/items/{a_item}/prices?convert_to={code}"),
        None => format!("/api/dicts/items/{a_item}/prices"),
    };
    let reply = a_app.call(Method::GET, &uri, Some(&a_user.token), None).await;
    assert_eq!(reply.status, StatusCode::OK, "{}", reply.body);
    reply.body
}

async fn set_price_sharing(a_app: &TestApp, a_user: &TestUser, a_family: &str, a_is_shared: bool)
{
    let reply = a_app
        .call(
            Method::PUT,
            &format!("/api/families/{a_family}/price-sharing"),
            Some(&a_user.token),
            Some(json!({ "is_shared": a_is_shared })),
        )
        .await;
    assert_eq!(reply.status, StatusCode::NO_CONTENT);
}

#[sqlx::test(migrations = "./migrations")]
async fn family_catalog_shares_prices_only_with_consent(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let eve = app.user("eve@example.com").await;
    let home = app.family(&alice, "Home").await;
    app.join(&alice, &bob, &home, "standard").await;
    let uah = app.currency_by_code(&alice.token, "UAH").await;

    let milk = item(
        &app,
        &alice,
        json!({ "name": "Молоко", "kind": "product", "unit": "liter", "family_id": home }),
    )
    .await;
    let bob_view = app
        .call(Method::GET, &format!("/api/dicts/items/{milk}"), Some(&bob.token), None)
        .await;
    assert_eq!(bob_view.status, StatusCode::OK);
    assert_eq!(bob_view.body["family_name"], "Home");
    assert_eq!(bob_view.body["is_editable"], false);
    assert_eq!(
        app.call(Method::GET, &format!("/api/dicts/items/{milk}"), Some(&eve.token), None)
            .await
            .status,
        StatusCode::NOT_FOUND
    );

    let eve_family_item = app
        .call(
            Method::POST,
            "/api/dicts/items",
            Some(&eve.token),
            Some(json!({ "name": "Чужое", "kind": "product", "unit": "piece", "family_id": home })),
        )
        .await;
    assert_eq!(eve_family_item.body["field"], "family_id");

    let bob_edit = app
        .call(
            Method::PUT,
            &format!("/api/dicts/items/{milk}"),
            Some(&bob.token),
            Some(json!({ "name": "Молоко!", "kind": "product", "unit": "liter" })),
        )
        .await;
    assert_eq!(bob_edit.status, StatusCode::FORBIDDEN);

    let (atb, atb_branch) = shop(&app, &bob, "АТБ", Some(&home)).await;
    let (_, eve_branch) = shop(&app, &eve, "Eve shop", None).await;

    let (status, bought) = receipt(
        &app,
        &bob,
        json!({
            "receipt_ts": Utc::now() - Duration::days(1),
            "curr_id": uah,
            "place_id": atb,
            "place_addr_id": atb_branch,
            "items": [{ "item_id": milk, "qty": "0.9", "amount": "36" }]
        }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{bought}");
    assert_eq!(bought["branch"], "Київ, Хрещатик 5");

    let (_, wrong_branch) = receipt(
        &app,
        &bob,
        json!({ "receipt_ts": Utc::now(), "curr_id": uah, "place_id": atb, "place_addr_id": eve_branch }),
    )
    .await;
    assert_eq!(wrong_branch["field"], "place_addr_id");
    let (_, eve_place) = receipt(
        &app,
        &eve,
        json!({ "receipt_ts": Utc::now(), "curr_id": uah, "place_id": atb }),
    )
    .await;
    assert_eq!(eve_place["field"], "place_id");
    let (_, eve_item) = receipt(
        &app,
        &eve,
        json!({ "receipt_ts": Utc::now(), "curr_id": uah, "items": [{ "item_id": milk, "amount": "1" }] }),
    )
    .await;
    assert_eq!(eve_item["field"], "item_id");

    assert_eq!(prices(&app, &alice, &milk, None).await["prices"], json!([]));

    set_price_sharing(&app, &bob, &home, true).await;
    let shared = prices(&app, &alice, &milk, None).await;
    assert_eq!(shared["prices"].as_array().unwrap().len(), 1, "{shared}");
    assert_eq!(shared["prices"][0]["store_name"], "АТБ");
    assert_eq!(shared["prices"][0]["branch"], "Київ, Хрещатик 5");
    assert_eq!(shared["prices"][0]["last_price"], "40.00");
    assert_eq!(shared["prices"][0]["is_shared"], true);

    let detail = app
        .call(Method::GET, &format!("/api/families/{home}"), Some(&bob.token), None)
        .await;
    assert_eq!(detail.body["is_prices_shared"], true);
    assert_eq!(
        app.call(
            Method::PUT,
            &format!("/api/families/{home}/price-sharing"),
            Some(&eve.token),
            Some(json!({ "is_shared": true }))
        )
        .await
        .status,
        StatusCode::NOT_FOUND
    );

    let left = app
        .call(
            Method::POST,
            &format!("/api/families/{home}/leave"),
            Some(&bob.token),
            None,
        )
        .await;
    assert!(left.status.is_success());
    assert_eq!(prices(&app, &alice, &milk, None).await["prices"], json!([]));

    let receipt_id = bought["id"].as_str().unwrap();
    let resaved = app
        .call(
            Method::PUT,
            &format!("/api/receipts/{receipt_id}"),
            Some(&bob.token),
            Some(json!({
                "receipt_ts": Utc::now() - Duration::days(1),
                "curr_id": uah,
                "place_id": atb,
                "place_addr_id": atb_branch,
                "items": [{ "item_id": milk, "qty": "0.9", "amount": "36" }]
            })),
        )
        .await;
    assert_eq!(resaved.status, StatusCode::OK, "{}", resaved.body);
    assert_eq!(resaved.body["place_name"], "АТБ");

    let (_, new_with_family_place) = receipt(
        &app,
        &bob,
        json!({ "receipt_ts": Utc::now(), "curr_id": uah, "place_id": atb }),
    )
    .await;
    assert_eq!(new_with_family_place["field"], "place_id");
}

#[sqlx::test(migrations = "./migrations")]
async fn barcodes_merge_products_and_prices_convert_currencies(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let home = app.family(&alice, "Home").await;
    let uah = app.currency_by_code(&alice.token, "UAH").await;
    let eur = app.currency_by_code(&alice.token, "EUR").await;

    let invalid = app
        .call(
            Method::POST,
            "/api/dicts/items",
            Some(&alice.token),
            Some(json!({ "name": "Кава", "kind": "product", "unit": "piece", "barcode": "4820024700017" })),
        )
        .await;
    assert_eq!(invalid.body["field"], "barcode");

    let coffee = item(
        &app,
        &alice,
        json!({ "name": "Кава", "kind": "product", "unit": "piece", "barcode": COFFEE_BARCODE }),
    )
    .await;
    let family_coffee = item(
        &app,
        &alice,
        json!({ "name": "Кава Lavazza", "kind": "product", "unit": "piece", "barcode": COFFEE_BARCODE, "family_id": home }),
    )
    .await;
    let duplicate = app
        .call(
            Method::POST,
            "/api/dicts/items",
            Some(&alice.token),
            Some(json!({ "name": "Інша кава", "kind": "product", "unit": "piece", "barcode": COFFEE_BARCODE })),
        )
        .await;
    assert_eq!(duplicate.status, StatusCode::CONFLICT);

    let search = app
        .call(
            Method::GET,
            &format!("/api/dicts/items?q={COFFEE_BARCODE}"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(search.body.as_array().unwrap().len(), 2, "{}", search.body);
    let exact = app
        .call(
            Method::GET,
            &format!("/api/dicts/items?barcode={COFFEE_BARCODE}"),
            Some(&bob.token),
            None,
        )
        .await;
    assert_eq!(exact.body, json!([]));

    let (status, _) = receipt(
        &app,
        &alice,
        json!({
            "receipt_ts": Utc::now() - Duration::days(2),
            "merchant_name": "АТБ",
            "curr_id": uah,
            "items": [{ "item_id": coffee, "amount": "200" }]
        }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    let manual = post(
        &app,
        &alice,
        &format!("/api/dicts/items/{family_coffee}/manual-prices"),
        json!({ "merchant_name": "Tesco", "curr_id": eur, "qty": "2", "price": "10", "seen_ts": Utc::now() - Duration::days(1) }),
    )
    .await;
    assert_eq!(manual["store_name"], "Tesco");
    let no_store = app
        .call(
            Method::POST,
            &format!("/api/dicts/items/{coffee}/manual-prices"),
            Some(&alice.token),
            Some(json!({ "curr_id": eur, "price": "10" })),
        )
        .await;
    assert_eq!(no_store.body["field"], "place_id");

    let by_currency = prices(&app, &alice, &coffee, None).await;
    assert_eq!(by_currency["matched_items"], 2);
    assert_eq!(by_currency["prices"].as_array().unwrap().len(), 2, "{by_currency}");

    let without_rates = prices(&app, &alice, &coffee, Some("UAH")).await;
    assert_eq!(without_rates["missing_rates"], json!(["EUR"]));
    assert_eq!(without_rates["prices"].as_array().unwrap().len(), 1);

    sqlx::query(
        r#"
        INSERT INTO currency_rates (base_curr_id, target_curr_id, rate, date)
        SELECT u.id, e.id, 45, CURRENT_DATE - 10
        FROM currencies u, currencies e
        WHERE u.code = 'UAH' AND e.code = 'EUR'
        "#,
    )
    .execute(&a_db)
    .await
    .unwrap();

    let converted = prices(&app, &alice, &coffee, Some("uah")).await;
    assert_eq!(converted["missing_rates"], json!([]));
    let rows = converted["prices"].as_array().unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["store_name"], "АТБ");
    assert_eq!(rows[0]["last_price"], "200.00");
    assert_eq!(rows[1]["store_name"], "Tesco");
    assert_eq!(rows[1]["curr_code"], "UAH");
    assert_eq!(rows[1]["last_price"], "225.00");

    let manual_id = manual["id"].as_str().unwrap();
    let manual_uri = format!("/api/dicts/items/{family_coffee}/manual-prices/{manual_id}");
    assert_eq!(
        app.call(Method::DELETE, &manual_uri, Some(&bob.token), None)
            .await
            .status,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        app.call(Method::DELETE, &manual_uri, Some(&alice.token), None)
            .await
            .status,
        StatusCode::NO_CONTENT
    );
}

#[sqlx::test(migrations = "./migrations")]
async fn sharing_merging_and_family_removal_keep_receipts_valid(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let home = app.family(&alice, "Home").await;
    app.join(&alice, &bob, &home, "standard").await;
    let uah = app.currency_by_code(&alice.token, "UAH").await;

    let cheese = item(
        &app,
        &alice,
        json!({ "name": "Сир", "kind": "product", "unit": "kilogram" }),
    )
    .await;
    let hard_cheese = item(
        &app,
        &alice,
        json!({ "name": "Сир твердий", "kind": "product", "unit": "kilogram" }),
    )
    .await;
    let bread = item(
        &app,
        &alice,
        json!({ "name": "Хліб", "kind": "product", "unit": "piece" }),
    )
    .await;
    let (status, bought) = receipt(
        &app,
        &alice,
        json!({
            "receipt_ts": Utc::now(),
            "merchant_name": "Сільпо",
            "curr_id": uah,
            "items": [{ "item_id": hard_cheese, "qty": "0.5", "amount": "150" }]
        }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    let foreign_share = app
        .call(
            Method::PUT,
            &format!("/api/dicts/items/{cheese}/family"),
            Some(&bob.token),
            Some(json!({ "family_id": home })),
        )
        .await;
    assert_eq!(foreign_share.status, StatusCode::NOT_FOUND);

    let shared = app
        .call(
            Method::PUT,
            &format!("/api/dicts/items/{cheese}/family"),
            Some(&alice.token),
            Some(json!({ "family_id": home })),
        )
        .await;
    assert_eq!(shared.status, StatusCode::OK, "{}", shared.body);
    assert_eq!(shared.body["family_name"], "Home");
    assert_eq!(
        app.call(
            Method::GET,
            &format!("/api/dicts/items/{cheese}"),
            Some(&bob.token),
            None
        )
        .await
        .status,
        StatusCode::OK
    );

    let wrong_unit = app
        .call(
            Method::POST,
            &format!("/api/dicts/items/{bread}/merge"),
            Some(&alice.token),
            Some(json!({ "target_id": cheese })),
        )
        .await;
    assert_eq!(wrong_unit.body["field"], "target_id");

    let merged = app
        .call(
            Method::POST,
            &format!("/api/dicts/items/{hard_cheese}/merge"),
            Some(&alice.token),
            Some(json!({ "target_id": cheese })),
        )
        .await;
    assert_eq!(merged.status, StatusCode::OK, "{}", merged.body);
    assert_eq!(
        app.call(
            Method::GET,
            &format!("/api/dicts/items/{hard_cheese}"),
            Some(&alice.token),
            None
        )
        .await
        .status,
        StatusCode::NOT_FOUND
    );
    let receipt_id = bought["id"].as_str().unwrap();
    let reloaded = app
        .call(
            Method::GET,
            &format!("/api/receipts/{receipt_id}"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(reloaded.body["items"][0]["item_id"], cheese.as_str());

    let bob_flour = item(
        &app,
        &bob,
        json!({ "name": "Борошно", "kind": "product", "unit": "kilogram", "family_id": home }),
    )
    .await;
    item(
        &app,
        &alice,
        json!({ "name": "сир", "kind": "product", "unit": "kilogram" }),
    )
    .await;
    let (status, bob_receipt) = receipt(
        &app,
        &bob,
        json!({ "receipt_ts": Utc::now(), "curr_id": uah, "items": [{ "item_id": cheese, "amount": "90" }] }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    let (bob_shop, _) = shop(&app, &bob, "Ринок", Some(&home)).await;
    let alice_places = app.call(Method::GET, "/api/places", Some(&alice.token), None).await;
    assert_eq!(alice_places.body[0]["id"], bob_shop.as_str());
    assert_eq!(alice_places.body[0]["is_editable"], true);

    let deleted = app
        .call(
            Method::DELETE,
            &format!("/api/families/{home}"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(deleted.status, StatusCode::NO_CONTENT, "{}", deleted.body);

    let alice_cheese = app
        .call(
            Method::GET,
            &format!("/api/dicts/items/{cheese}"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(alice_cheese.body["name"], "Сир (Home)");
    assert_eq!(alice_cheese.body["family_id"], Value::Null);
    assert_eq!(alice_cheese.body["is_editable"], true);
    let bob_flour_view = app
        .call(
            Method::GET,
            &format!("/api/dicts/items/{bob_flour}"),
            Some(&bob.token),
            None,
        )
        .await;
    assert_eq!(bob_flour_view.body["is_editable"], true);

    let bob_places = app.call(Method::GET, "/api/places", Some(&bob.token), None).await;
    assert_eq!(bob_places.body[0]["family_id"], Value::Null);
    assert_eq!(bob_places.body[0]["is_editable"], true);
    let alice_places = app.call(Method::GET, "/api/places", Some(&alice.token), None).await;
    assert_eq!(alice_places.body, json!([]));

    let bob_receipt_id = bob_receipt["id"].as_str().unwrap();
    let bob_reloaded = app
        .call(
            Method::GET,
            &format!("/api/receipts/{bob_receipt_id}"),
            Some(&bob.token),
            None,
        )
        .await;
    assert_eq!(bob_reloaded.status, StatusCode::OK);
    assert_eq!(bob_reloaded.body["items"][0]["name"], "Сир (Home)");
}
