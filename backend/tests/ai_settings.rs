mod common;

use axum::http::{Method, StatusCode};
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use chrono::Utc;
use common::bank_mocks::{spawn_ai, AiMock, GEMINI_KEY, OPENAI_KEY};
use common::{ai_config, TestApp, TestUser};
use serde_json::{json, Value};
use sqlx::PgPool;

fn photo() -> String
{
    let mut bytes = vec![0xFF, 0xD8, 0xFF, 0xE0];
    bytes.extend(std::iter::repeat_n(7u8, 400));
    STANDARD.encode(bytes)
}

fn receipt() -> Value
{
    json!({
        "is_receipt": true, "store_name": "Tesco", "country_code": "IRL", "city": "Dublin", "street": "Main Street",
        "house_number": "1", "postal_code": null, "date": Utc::now().date_naive().to_string(), "time": "10:00",
        "currency": "EUR", "total": 3.5,
        "lines": [{
            "text": "MILK 1L", "name": "Milk 1 l", "kind": "food", "unit": "piece", "quantity": 1,
            "unit_price": 3.5, "amount": 3.5, "barcode": null
        }]
    })
}

async fn recognize(a_app: &TestApp, a_user: &TestUser, a_mock: &AiMock) -> (StatusCode, Value)
{
    a_mock.reply_with(receipt());
    let reply = a_app
        .call(
            Method::POST,
            "/api/receipts/recognize",
            Some(&a_user.token),
            Some(json!({ "image": photo(), "media_type": "image/jpeg", "tz_offset_min": 0 })),
        )
        .await;
    (reply.status, reply.body)
}

async fn save_key(a_app: &TestApp, a_user: &TestUser, a_provider: &str, a_body: Value) -> (StatusCode, Value)
{
    let reply = a_app
        .call(
            Method::PUT,
            &format!("/api/settings/ai/keys/{a_provider}"),
            Some(&a_user.token),
            Some(a_body),
        )
        .await;
    (reply.status, reply.body)
}

async fn settings(a_app: &TestApp, a_user: &TestUser) -> Value
{
    a_app
        .call(Method::GET, "/api/settings/ai", Some(&a_user.token), None)
        .await
        .body
}

#[sqlx::test(migrations = "./migrations")]
async fn own_openai_key_is_sealed_hidden_and_used(a_db: PgPool)
{
    let (ai_url, mock) = spawn_ai().await;
    let app = TestApp::with_ai(a_db.clone(), ai_config(&ai_url, None));
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;

    let initial = settings(&app, &alice).await;
    assert_eq!(initial["source"], "off");
    assert_eq!(initial["server"], Value::Null);
    let features = app.call(Method::GET, "/api/features", Some(&alice.token), None).await;
    assert_eq!(features.body["is_receipt_recognition"], false);

    let (status, rejected) = save_key(
        &app,
        &alice,
        "openai",
        json!({ "api_key": "sk-wrong-key-0123456789abcdef" }),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(rejected["code"], "AI_KEY_REJECTED");
    let (status, _) = save_key(&app, &alice, "openai", json!({ "api_key": "short" })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, saved) = save_key(
        &app,
        &alice,
        "openai",
        json!({ "api_key": format!("  {OPENAI_KEY}\n") }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{saved}");
    assert_eq!(saved["key"]["key_hint"], "cdef");
    assert_eq!(saved["key"]["model"], "gpt-5.5");
    let models: Vec<&str> = saved["models"]
        .as_array()
        .unwrap()
        .iter()
        .map(|model| model["id"].as_str().unwrap())
        .collect();
    assert_eq!(models, ["gpt-5.5-mini", "gpt-5.5"]);
    assert!(!saved.to_string().contains(OPENAI_KEY));

    let sealed: Vec<u8> = sqlx::query_scalar("SELECT sealed_key FROM user_ai_keys WHERE user_id = $1")
        .bind(alice.id)
        .fetch_one(&a_db)
        .await
        .unwrap();
    assert!(!sealed.windows(12).any(|window| window == &OPENAI_KEY.as_bytes()[..12]));

    let current = settings(&app, &alice).await;
    assert_eq!(current["source"], "openai");
    assert_eq!(current["effective_daily_limit"], 30);
    assert!(!current.to_string().contains(OPENAI_KEY));
    assert_eq!(settings(&app, &bob).await["keys"], json!([]));

    let features = app.call(Method::GET, "/api/features", Some(&alice.token), None).await;
    assert_eq!(features.body["recognition_provider"], "openai");
    let bob_features = app.call(Method::GET, "/api/features", Some(&bob.token), None).await;
    assert_eq!(bob_features.body["is_receipt_recognition"], false);
    let (status, _) = recognize(&app, &bob, &mock).await;
    assert_eq!(status, StatusCode::CONFLICT);

    let model = app
        .call(
            Method::PATCH,
            "/api/settings/ai/keys/openai",
            Some(&alice.token),
            Some(json!({ "model": "gpt-realtime" })),
        )
        .await;
    assert_eq!(model.status, StatusCode::BAD_REQUEST);
    let model = app
        .call(
            Method::PATCH,
            "/api/settings/ai/keys/openai",
            Some(&alice.token),
            Some(json!({ "model": "gpt-5.5-mini" })),
        )
        .await;
    assert_eq!(model.body["model"], "gpt-5.5-mini");

    let (status, draft) = recognize(&app, &alice, &mock).await;
    assert_eq!(status, StatusCode::OK, "{draft}");
    assert_eq!(draft["store_name"], "Tesco");
    assert_eq!(draft["lines"][0]["amount"], "3.50");
    assert_eq!(mock.calls().last().unwrap(), "openai:gpt-5.5-mini");

    let usage = settings(&app, &alice).await["usage"].clone();
    assert_eq!(
        usage,
        json!([{
            "is_own_key": true, "today_count": 1, "month_count": 1, "month_input_tokens": 1100, "month_output_tokens": 350
        }])
    );

    let deleted = app
        .call(Method::DELETE, "/api/settings/ai/keys/openai", Some(&alice.token), None)
        .await;
    assert_eq!(deleted.status, StatusCode::NO_CONTENT);
    assert_eq!(settings(&app, &alice).await["source"], "off");
    let (status, _) = recognize(&app, &alice, &mock).await;
    assert_eq!(status, StatusCode::CONFLICT);
}

#[sqlx::test(migrations = "./migrations")]
async fn gemini_key_and_limits(a_db: PgPool)
{
    let (ai_url, mock) = spawn_ai().await;
    let app = TestApp::with_ai(a_db, ai_config(&ai_url, None));
    let alice = app.user("alice@example.com").await;

    let (status, rejected) = save_key(
        &app,
        &alice,
        "gemini",
        json!({ "api_key": "AIza-wrong-gemini-0123456789" }),
    )
    .await;
    assert_eq!(
        (status, rejected["code"].as_str()),
        (StatusCode::CONFLICT, Some("AI_KEY_REJECTED"))
    );

    let (status, saved) = save_key(
        &app,
        &alice,
        "gemini",
        json!({ "api_key": GEMINI_KEY, "model": "gemini-3.1-pro-preview" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{saved}");
    assert_eq!(saved["key"]["model"], "gemini-3.1-pro-preview");
    let (status, _) = save_key(
        &app,
        &alice,
        "gemini",
        json!({ "api_key": GEMINI_KEY, "model": "gemini-embedding-001" }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let invalid_limit = app
        .call(
            Method::PUT,
            "/api/settings/ai",
            Some(&alice.token),
            Some(json!({ "source": "gemini", "daily_limit": 0 })),
        )
        .await;
    assert_eq!(invalid_limit.status, StatusCode::BAD_REQUEST);
    let no_server = app
        .call(
            Method::PUT,
            "/api/settings/ai",
            Some(&alice.token),
            Some(json!({ "source": "server" })),
        )
        .await;
    assert_eq!(no_server.body["code"], "AI_SERVER_UNAVAILABLE");
    let no_key = app
        .call(
            Method::PUT,
            "/api/settings/ai",
            Some(&alice.token),
            Some(json!({ "source": "anthropic" })),
        )
        .await;
    assert_eq!(no_key.body["code"], "AI_KEY_MISSING");

    let limited = app
        .call(
            Method::PUT,
            "/api/settings/ai",
            Some(&alice.token),
            Some(json!({ "source": "gemini", "daily_limit": 1, "monthly_limit": 50 })),
        )
        .await;
    assert_eq!(limited.body["effective_daily_limit"], 1);
    assert_eq!(limited.body["effective_monthly_limit"], 50);

    let (status, draft) = recognize(&app, &alice, &mock).await;
    assert_eq!(status, StatusCode::OK, "{draft}");
    assert_eq!(
        mock.calls().last().unwrap(),
        "gemini:gemini-3.1-pro-preview:generateContent"
    );
    let (status, _) = recognize(&app, &alice, &mock).await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);

    let usage = &settings(&app, &alice).await["usage"][0];
    assert_eq!(usage["today_count"], 1);
    assert_eq!(usage["month_output_tokens"], 420);
}

#[sqlx::test(migrations = "./migrations")]
async fn server_key_limits_cap_user_limits_and_rejected_keys_are_refunded(a_db: PgPool)
{
    let (ai_url, mock) = spawn_ai().await;
    let app = TestApp::with_receipt_ai(a_db.clone(), &ai_url, 5);
    let alice = app.user("alice@example.com").await;

    let current = settings(&app, &alice).await;
    assert_eq!(current["source"], "server");
    assert_eq!(current["server"]["model"], "claude-opus-5-5");
    assert_eq!(current["effective_daily_limit"], 5);

    let raised = app
        .call(
            Method::PUT,
            "/api/settings/ai",
            Some(&alice.token),
            Some(json!({ "source": "server", "daily_limit": 500 })),
        )
        .await;
    assert_eq!(raised.body["effective_daily_limit"], 5);

    let (status, _) = save_key(&app, &alice, "openai", json!({ "api_key": OPENAI_KEY })).await;
    assert_eq!(status, StatusCode::OK);
    sqlx::query("UPDATE user_ai_keys SET sealed_key = $2 WHERE user_id = $1")
        .bind(alice.id)
        .bind(
            app.state
                .secret_box
                .seal(
                    b"sk-revoked-0123456789abcdef",
                    &backend::security::crypto::ai_key_aad(alice.id, "openai"),
                )
                .unwrap(),
        )
        .execute(&a_db)
        .await
        .unwrap();

    let (status, body) = recognize(&app, &alice, &mock).await;
    assert_eq!(
        (status, body["code"].as_str()),
        (StatusCode::CONFLICT, Some("AI_KEY_REJECTED"))
    );
    let usage = settings(&app, &alice).await["usage"].clone();
    assert_eq!(usage[0]["today_count"], 0);

    let back = app
        .call(
            Method::PUT,
            "/api/settings/ai",
            Some(&alice.token),
            Some(json!({ "source": "server", "daily_limit": 500 })),
        )
        .await;
    assert_eq!(back.body["source"], "server");
    let (status, _) = recognize(&app, &alice, &mock).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(mock.calls().last().unwrap(), "anthropic:claude-opus-5-5");
}
