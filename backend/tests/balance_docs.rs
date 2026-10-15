mod common;

use axum::http::{Method, StatusCode};
use chrono::{DateTime, Duration, Utc};
use common::{TestApp, TestUser};
use serde_json::{json, Value};
use sqlx::PgPool;

async fn send(
    a_app: &TestApp,
    a_user: &TestUser,
    a_method: Method,
    a_uri: &str,
    a_body: Option<Value>,
) -> (StatusCode, Value)
{
    let reply = a_app.call(a_method, a_uri, Some(&a_user.token), a_body).await;
    (reply.status, reply.body)
}

async fn cash_wallet(a_app: &TestApp, a_user: &TestUser, a_family_id: Option<&str>) -> String
{
    let curr_id = a_app.currency_by_code(&a_user.token, "EUR").await;
    let (status, body) = send(
        a_app,
        a_user,
        Method::POST,
        "/api/wallets",
        Some(json!({ "name": "Наличные", "curr_id": curr_id, "account_type": "cash", "family_id": a_family_id })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    body["id"].as_str().unwrap().to_string()
}

async fn manual_tx(a_app: &TestApp, a_user: &TestUser, a_wallet: &str, a_amount: &str, a_ts: DateTime<Utc>)
{
    let (status, body) = send(
        a_app,
        a_user,
        Method::POST,
        "/api/transactions",
        Some(json!({ "account_id": a_wallet, "amount": a_amount, "tx_ts": a_ts })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}

async fn balance(a_app: &TestApp, a_user: &TestUser, a_wallet: &str) -> String
{
    let (status, body) = send(a_app, a_user, Method::GET, &format!("/api/wallets/{a_wallet}"), None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body["balance"].as_str().unwrap().to_string()
}

async fn add_doc(a_app: &TestApp, a_user: &TestUser, a_wallet: &str, a_ts: DateTime<Utc>, a_amount: &str) -> Value
{
    let (status, body) = send(
        a_app,
        a_user,
        Method::POST,
        &format!("/api/wallets/{a_wallet}/balance-docs"),
        Some(json!({ "balance_ts": a_ts, "amount": a_amount })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    body
}

async fn write_off(a_app: &TestApp, a_user: &TestUser, a_doc: &str, a_body: Value) -> (StatusCode, Value)
{
    send(
        a_app,
        a_user,
        Method::POST,
        &format!("/api/balance-docs/{a_doc}/write-offs"),
        Some(a_body),
    )
    .await
}

fn encode(a_ts: DateTime<Utc>) -> String
{
    a_ts.to_rfc3339().replace('+', "%2B").replace(':', "%3A")
}

#[sqlx::test(migrations = "./migrations")]
async fn balance_follows_the_latest_document(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let anna = app.user("anna@example.com").await;
    let wallet = cash_wallet(&app, &anna, None).await;
    let now = Utc::now();
    let day = Duration::days(1);

    assert_eq!(balance(&app, &anna, &wallet).await, "0");
    manual_tx(&app, &anna, &wallet, "-10", now - day * 5).await;
    manual_tx(&app, &anna, &wallet, "100", now - day * 4).await;
    assert_eq!(balance(&app, &anna, &wallet).await, "90.00");

    let first = add_doc(&app, &anna, &wallet, now - day * 3, "70").await;
    assert_eq!(first["delta"], Value::Null);
    assert_eq!(first["expected"], Value::Null);
    assert_eq!(balance(&app, &anna, &wallet).await, "70.00");

    manual_tx(&app, &anna, &wallet, "-5", now - day).await;
    manual_tx(&app, &anna, &wallet, "-20", now - day * 6).await;
    assert_eq!(balance(&app, &anna, &wallet).await, "65.00");

    let second = add_doc(&app, &anna, &wallet, now - Duration::hours(12), "50").await;
    let second_id = second["id"].as_str().unwrap().to_string();
    assert_eq!(second["expected"], "65.00");
    assert_eq!(second["delta"], "-15.00");
    assert_eq!(balance(&app, &anna, &wallet).await, "50.00");

    let (status, _) = send(
        &app,
        &anna,
        Method::POST,
        &format!("/api/wallets/{wallet}/balance-docs"),
        Some(json!({ "balance_ts": now - day * 3, "amount": "1" })),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);

    let (status, doc) = write_off(
        &app,
        &anna,
        &second_id,
        json!({ "amount": "-10", "category": "groceries", "tx_ts": now - day * 2, "note": "рынок" }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{doc}");
    assert_eq!(doc["delta"], "-5.00");
    assert_eq!(doc["write_offs"].as_array().unwrap().len(), 1);
    assert_eq!(balance(&app, &anna, &wallet).await, "50.00");

    for rejected in [
        json!({ "amount": "-10" }),
        json!({ "amount": "3" }),
        json!({ "amount": "-1", "tx_ts": now - day * 4 }),
        json!({ "amount": "-1", "tx_ts": now - Duration::hours(1) }),
    ]
    {
        let (status, body) = write_off(&app, &anna, &second_id, rejected.clone()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{rejected} {body}");
    }

    let (status, doc) = write_off(&app, &anna, &second_id, json!({ "amount": "-5" })).await;
    assert_eq!(status, StatusCode::CREATED, "{doc}");
    assert_eq!(doc["delta"], "0.00");
    let (status, _) = write_off(&app, &anna, &second_id, json!({ "amount": "-1" })).await;
    assert_eq!(status, StatusCode::CONFLICT);
    let first_id = first["id"].as_str().unwrap();
    let (status, _) = write_off(&app, &anna, first_id, json!({ "amount": "-1" })).await;
    assert_eq!(status, StatusCode::CONFLICT);

    let (_, txs) = send(
        &app,
        &anna,
        Method::GET,
        &format!("/api/transactions?account_id={wallet}"),
        None,
    )
    .await;
    let marked = txs["items"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|tx| tx["balance_doc_id"] == second_id.as_str())
        .count();
    assert_eq!(marked, 2);

    let range = format!("from={}&to={}&account_id={wallet}", encode(now - day * 7), encode(now));
    let (status, stats) = send(
        &app,
        &anna,
        Method::GET,
        &format!("/api/stats/categories?{range}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{stats}");
    let groceries = stats["series"][0]["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["category"] == "groceries")
        .cloned()
        .unwrap();
    assert_eq!(groceries["expense"], "10.00");

    let moved_ts = now - Duration::hours(60);
    let (status, moved) = send(
        &app,
        &anna,
        Method::PUT,
        &format!("/api/balance-docs/{second_id}"),
        Some(json!({ "balance_ts": moved_ts, "amount": "50", "note": "пересчитал" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{moved}");
    for item in moved["write_offs"].as_array().unwrap()
    {
        let ts: DateTime<Utc> = item["tx_ts"].as_str().unwrap().parse().unwrap();
        assert!(ts <= moved_ts && ts > now - day * 3, "{item}");
    }
    assert_eq!(balance(&app, &anna, &wallet).await, "45.00");

    let (status, _) = send(
        &app,
        &anna,
        Method::DELETE,
        &format!("/api/balance-docs/{second_id}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let left: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM transactions WHERE account_id = $1::uuid")
        .bind(&wallet)
        .fetch_one(&a_db)
        .await
        .unwrap();
    assert_eq!(left, 4);
    assert_eq!(balance(&app, &anna, &wallet).await, "65.00");

    let (_, docs) = send(
        &app,
        &anna,
        Method::GET,
        &format!("/api/wallets/{wallet}/balance-docs"),
        None,
    )
    .await;
    assert_eq!(docs.as_array().unwrap().len(), 1);
}

#[sqlx::test(migrations = "./migrations")]
async fn balance_documents_follow_wallet_access(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let anna = app.user("anna@example.com").await;
    let boris = app.user("boris@example.com").await;
    let eve = app.user("eve@example.com").await;
    let home = app.family(&anna, "Home").await;
    app.join(&anna, &boris, &home, "standard").await;
    let now = Utc::now();

    let personal = cash_wallet(&app, &anna, None).await;
    let doc = add_doc(&app, &anna, &personal, now - Duration::days(1), "40").await;
    let doc_id = doc["id"].as_str().unwrap();
    let list_uri = format!("/api/wallets/{personal}/balance-docs");

    assert_eq!(
        send(&app, &boris, Method::GET, &list_uri, None).await.0,
        StatusCode::NOT_FOUND
    );
    let (status, _) = send(
        &app,
        &anna,
        Method::PUT,
        &format!("/api/wallets/{personal}/shares/{home}"),
        Some(json!({ "is_shared": true })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, seen) = send(&app, &boris, Method::GET, &list_uri, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(seen[0]["amount"], "40.00");
    assert_eq!(balance(&app, &boris, &personal).await, "40.00");
    let body = json!({ "balance_ts": now, "amount": "1" });
    assert_eq!(
        send(&app, &boris, Method::POST, &list_uri, Some(body.clone())).await.0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        send(
            &app,
            &boris,
            Method::PUT,
            &format!("/api/balance-docs/{doc_id}"),
            Some(body.clone())
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        send(
            &app,
            &boris,
            Method::DELETE,
            &format!("/api/balance-docs/{doc_id}"),
            None
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        send(&app, &eve, Method::GET, &list_uri, None).await.0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        send(&app, &eve, Method::DELETE, &format!("/api/balance-docs/{doc_id}"), None)
            .await
            .0,
        StatusCode::NOT_FOUND
    );

    let family_wallet = cash_wallet(&app, &anna, Some(&home)).await;
    let family_uri = format!("/api/wallets/{family_wallet}/balance-docs");
    assert_eq!(
        send(&app, &boris, Method::POST, &family_uri, Some(body.clone()))
            .await
            .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        send(&app, &anna, Method::POST, &family_uri, Some(body.clone())).await.0,
        StatusCode::CREATED
    );

    for invalid in [
        json!({ "balance_ts": now + Duration::hours(1), "amount": "1" }),
        json!({ "balance_ts": now, "amount": "1.001" }),
        json!({ "balance_ts": "1999-12-31T00:00:00Z", "amount": "1" }),
        json!({ "balance_ts": now - Duration::hours(3), "amount": "1", "note": "x".repeat(501) }),
    ]
    {
        let (status, reply) = send(&app, &anna, Method::POST, &list_uri, Some(invalid.clone())).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{invalid} {reply}");
    }

    let linked = cash_wallet(&app, &anna, None).await;
    sqlx::query(
        r#"
        WITH conn AS (
            INSERT INTO bank_conns (owner_id, provider) SELECT user_id, 'monobank' FROM accounts WHERE id = $1::uuid
            RETURNING id
        )
        UPDATE accounts SET conn_id = (SELECT id FROM conn), balance = 12.34, balance_ts = NOW() WHERE id = $1::uuid
        "#,
    )
    .bind(&linked)
    .execute(&a_db)
    .await
    .unwrap();
    let (status, _) = send(
        &app,
        &anna,
        Method::POST,
        &format!("/api/wallets/{linked}/balance-docs"),
        Some(body),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(balance(&app, &anna, &linked).await, "12.34");
}
