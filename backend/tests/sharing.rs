mod common;

use axum::http::{Method, StatusCode};
use chrono::Utc;
use common::{TestApp, TestUser};
use serde_json::{json, Value};
use sqlx::PgPool;
use uuid::Uuid;

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

async fn wallet(a_app: &TestApp, a_user: &TestUser, a_name: &str) -> String
{
    let curr_id = a_app.currency_by_code(&a_user.token, "EUR").await;
    let (status, body) = send(
        a_app,
        a_user,
        Method::POST,
        "/api/wallets",
        Some(json!({ "name": a_name, "curr_id": curr_id, "account_type": "card" })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    body["id"].as_str().unwrap().to_string()
}

async fn bank_tx(a_db: &PgPool, a_account: &str, a_amount: &str, a_description: &str) -> String
{
    let id: Uuid = sqlx::query_scalar(
        r#"
        INSERT INTO transactions (user_id, account_id, curr_id, amount, tx_type, tx_ts, ext_id, source, description, rule_key)
        SELECT a.user_id, a.id, a.curr_id, $2::numeric, 'expense', NOW(), gen_random_uuid()::text, 'bank', $3, ''
        FROM accounts a WHERE a.id = $1::uuid
        RETURNING id
        "#,
    )
    .bind(a_account)
    .bind(a_amount)
    .bind(a_description)
    .fetch_one(a_db)
    .await
    .unwrap();
    id.to_string()
}

async fn tx_ids(a_app: &TestApp, a_user: &TestUser, a_query: &str) -> Vec<String>
{
    let (status, body) = send(
        a_app,
        a_user,
        Method::GET,
        &format!("/api/transactions?limit=200{a_query}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tx| tx["id"].as_str().unwrap().to_string())
        .collect()
}

async fn share(
    a_app: &TestApp,
    a_user: &TestUser,
    a_wallet: &str,
    a_family: &str,
    a_is_shared: bool,
) -> (StatusCode, Value)
{
    send(
        a_app,
        a_user,
        Method::PUT,
        &format!("/api/wallets/{a_wallet}/shares/{a_family}"),
        Some(json!({ "is_shared": a_is_shared })),
    )
    .await
}

#[sqlx::test(migrations = "./migrations")]
async fn members_choose_which_wallets_each_group_sees(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let anna = app.user("anna@example.com").await;
    let boris = app.user("boris@example.com").await;
    let eve = app.user("eve@example.com").await;
    let home = app.family(&anna, "Home").await;
    let work = app.family(&boris, "Work").await;
    let outside = app.family(&eve, "Outside").await;
    app.join(&anna, &boris, &home, "standard").await;
    app.join(&boris, &anna, &work, "standard").await;

    let anna_card = wallet(&app, &anna, "Anna card").await;
    let anna_cash = wallet(&app, &anna, "Anna cash").await;
    let boris_card = wallet(&app, &boris, "Boris card").await;
    let anna_lidl = bank_tx(&a_db, &anna_card, "-39.57", "VDC-LIDL 0907 ATHL").await;
    let anna_secret = bank_tx(&a_db, &anna_cash, "-20.00", "Gift").await;
    let boris_tesco = bank_tx(&a_db, &boris_card, "-12.40", "VDP-TESCO STORES").await;

    assert!(tx_ids(&app, &boris, "").await == vec![boris_tesco.clone()]);
    let (_, boris_wallets) = send(&app, &boris, Method::GET, "/api/wallets", None).await;
    assert_eq!(boris_wallets.as_array().unwrap().len(), 1);

    let (status, shared) = share(&app, &anna, &anna_card, &home, true).await;
    assert_eq!(status, StatusCode::OK, "{shared}");
    assert_eq!(shared["shared_family_ids"], json!([home]));
    assert_eq!(shared["is_own"], true);
    assert_eq!(share(&app, &anna, &anna_card, &work, true).await.0, StatusCode::OK);

    let visible = tx_ids(&app, &boris, "").await;
    assert_eq!(visible.len(), 2, "a wallet shared with two groups is listed once");
    assert!(visible.contains(&anna_lidl) && !visible.contains(&anna_secret));

    let (_, boris_wallets) = send(&app, &boris, Method::GET, "/api/wallets", None).await;
    let seen = boris_wallets
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"] == anna_card.as_str())
        .unwrap()
        .clone();
    assert_eq!(seen["is_own"], false);
    assert_eq!(seen["is_editable"], false);
    assert_eq!(seen["shared_family_ids"], json!([]));
    assert!(seen["owner_name"].as_str().is_some());

    let (_, page) = send(&app, &boris, Method::GET, "/api/transactions?limit=200", None).await;
    let lidl = page["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|tx| tx["id"] == anna_lidl.as_str())
        .unwrap()
        .clone();
    assert_eq!(lidl["is_editable"], false);
    assert!(lidl["account_owner_name"].as_str().is_some());
    let mine = page["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|tx| tx["id"] == boris_tesco.as_str())
        .unwrap()
        .clone();
    assert_eq!(mine["account_owner_name"], Value::Null);

    assert_eq!(
        tx_ids(&app, &boris, &format!("&owner_id={}", anna.id)).await,
        vec![anna_lidl.clone()]
    );
    assert_eq!(
        tx_ids(&app, &boris, &format!("&owner_id={}", boris.id)).await,
        vec![boris_tesco.clone()]
    );

    let (edit_status, _) = send(
        &app,
        &boris,
        Method::PUT,
        &format!("/api/transactions/{anna_lidl}"),
        Some(json!({ "note": "mine now", "category": "groceries" })),
    )
    .await;
    assert_eq!(edit_status, StatusCode::FORBIDDEN);
    assert_eq!(
        share(&app, &boris, &anna_card, &home, false).await.0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        share(&app, &anna, &anna_card, &outside, true).await.0,
        StatusCode::BAD_REQUEST
    );
    assert!(tx_ids(&app, &eve, "").await.is_empty());

    let from = (Utc::now() - chrono::Duration::days(1)).to_rfc3339();
    let to = (Utc::now() + chrono::Duration::days(1)).to_rfc3339();
    let cashflow = |a_owner: Uuid| {
        format!(
            "/api/stats/cashflow?bucket=day&from={}&to={}&owner_id={a_owner}",
            urlencoding(&from),
            urlencoding(&to)
        )
    };
    let (status, anna_flow) = send(&app, &boris, Method::GET, &cashflow(anna.id), None).await;
    assert_eq!(status, StatusCode::OK, "{anna_flow}");
    assert_eq!(anna_flow["series"].as_array().unwrap().len(), 1);
    assert_eq!(anna_flow["series"][0]["expense_total"], "39.57");

    let eur = app.currency_by_code(&anna.token, "EUR").await;
    let (status, receipt) = send(
        &app,
        &anna,
        Method::POST,
        "/api/receipts",
        Some(json!({
            "receipt_ts": Utc::now(), "curr_id": eur, "tx_ids": [anna_lidl],
            "items": [{ "new_item": { "name": "Milk", "kind": "food", "unit": "piece" }, "amount": "39.57" }]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{receipt}");
    let receipt_id = receipt["id"].as_str().unwrap().to_string();
    let (_, own_receipt) = send(
        &app,
        &anna,
        Method::POST,
        "/api/receipts",
        Some(json!({
            "receipt_ts": Utc::now(), "curr_id": eur,
            "items": [{ "new_item": { "name": "Cake", "kind": "food", "unit": "piece" }, "amount": "5" }]
        })),
    )
    .await;

    let (_, receipts) = send(&app, &boris, Method::GET, "/api/receipts", None).await;
    let listed: Vec<&str> = receipts
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["id"].as_str().unwrap())
        .collect();
    assert_eq!(listed, vec![receipt_id.as_str()]);
    assert!(receipts[0]["owner_name"].as_str().is_some());

    let (status, seen_receipt) = send(&app, &boris, Method::GET, &format!("/api/receipts/{receipt_id}"), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(seen_receipt["is_editable"], false);
    assert_eq!(seen_receipt["items"][0]["name"], "Milk");
    let (status, _) = send(
        &app,
        &boris,
        Method::GET,
        &format!("/api/receipts/{}", own_receipt["id"].as_str().unwrap()),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = send(
        &app,
        &boris,
        Method::PUT,
        &format!("/api/receipts/{receipt_id}"),
        Some(json!({ "receipt_ts": Utc::now(), "curr_id": eur, "items": [] })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (_, anna_view) = send(&app, &anna, Method::GET, &format!("/api/receipts/{receipt_id}"), None).await;
    assert_eq!(anna_view["is_editable"], true);
    assert_eq!(anna_view["owner_name"], Value::Null);

    let (status, _) = send(&app, &anna, Method::POST, &format!("/api/families/{work}/leave"), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let remaining: Vec<Uuid> = sqlx::query_scalar("SELECT family_id FROM account_shares WHERE account_id = $1::uuid")
        .bind(&anna_card)
        .fetch_all(&a_db)
        .await
        .unwrap();
    assert_eq!(remaining, vec![home.parse::<Uuid>().unwrap()]);

    let (status, _) = send(
        &app,
        &anna,
        Method::DELETE,
        &format!("/api/families/{home}/members/{}", boris.id),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(tx_ids(&app, &boris, "").await, vec![boris_tesco]);
}

fn urlencoding(a_value: &str) -> String
{
    a_value.replace('+', "%2B").replace(':', "%3A")
}

#[sqlx::test(migrations = "./migrations")]
async fn trainings_are_visible_to_the_group(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let anna = app.user("anna@example.com").await;
    let boris = app.user("boris@example.com").await;
    let eve = app.user("eve@example.com").await;
    let home = app.family(&anna, "Home").await;
    app.join(&anna, &boris, &home, "standard").await;

    let (_, exercises) = send(&app, &anna, Method::GET, "/api/dicts/exercises", None).await;
    let bench = exercises
        .as_array()
        .unwrap()
        .iter()
        .find(|exercise| exercise["code"] == "bench_press")
        .unwrap()["id"]
        .clone();
    let (status, program) = send(
        &app,
        &anna,
        Method::POST,
        "/api/training/programs",
        Some(json!({
            "name": "Сплит", "schedule_mode": "queue",
            "days": [{ "name": "A", "exercises": [{ "ex_id": bench, "sets": 3, "reps_min": 8, "reps_max": 10, "weight_kg": "50" }] }]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{program}");
    let day_id = program["days"][0]["id"].clone();
    let (_, session) = send(
        &app,
        &anna,
        Method::POST,
        "/api/training/sessions",
        Some(json!({ "day_id": day_id, "started_ts": Utc::now() - chrono::Duration::hours(1) })),
    )
    .await;
    let session_id = session["id"].as_str().unwrap().to_string();

    let overview_uri = format!("/api/people/{}/training", anna.id);
    let (status, overview) = send(&app, &boris, Method::GET, &overview_uri, None).await;
    assert_eq!(status, StatusCode::OK, "{overview}");
    assert_eq!(overview["program"]["name"], "Сплит");
    assert_eq!(overview["plan"]["active_session_id"], session_id.as_str());
    assert_eq!(overview["sessions"].as_array().unwrap().len(), 1);
    let session_uri = format!("/api/people/{}/training/sessions/{session_id}", anna.id);
    let (status, seen) = send(&app, &boris, Method::GET, &session_uri, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(seen["exercises"][0]["sets"].as_array().unwrap().len(), 3);

    let (status, saved) = send(
        &app,
        &anna,
        Method::PUT,
        &format!("/api/training/sessions/{session_id}"),
        Some(json!({ "exercises": [{
            "ex_id": bench, "reps_min": 8, "reps_max": 10,
            "sets": [{ "reps": 9, "weight_kg": "50", "is_done": true }]
        }] })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{saved}");
    let (status, _) = send(
        &app,
        &anna,
        Method::POST,
        &format!("/api/training/sessions/{session_id}/finish"),
        Some(json!({ "intensity": 5 })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let progress_uri = format!(
        "/api/people/{}/training/exercises/{}/progress",
        anna.id,
        bench.as_str().unwrap()
    );
    let (status, progress) = send(&app, &boris, Method::GET, &progress_uri, None).await;
    assert_eq!(status, StatusCode::OK, "{progress}");
    assert_eq!(progress["points"].as_array().unwrap().len(), 1);
    assert_eq!(progress["points"][0]["top_weight_kg"], "50.00");
    let (_, own_progress) = send(
        &app,
        &boris,
        Method::GET,
        &format!("/api/training/exercises/{}/progress", bench.as_str().unwrap()),
        None,
    )
    .await;
    assert_eq!(own_progress["points"], json!([]));

    assert_eq!(
        send(&app, &eve, Method::GET, &overview_uri, None).await.0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        send(&app, &eve, Method::GET, &progress_uri, None).await.0,
        StatusCode::NOT_FOUND
    );
}
