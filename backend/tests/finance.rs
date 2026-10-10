mod common;

use axum::http::{Method, StatusCode};
use backend::banking::sync::sync_connection;
use backend::security::crypto::bank_conn_aad;
use chrono::{Duration, Utc};
use common::bank_mocks::{mono_item, spawn_enable_banking, spawn_mono, EB_CODE, EB_SESSION, MONO_TOKEN};
use common::{bank_config, TestApp, TestUser};
use serde_json::{json, Value};
use sqlx::PgPool;
use uuid::Uuid;

fn mono_history() -> Vec<Value>
{
    let mut items: Vec<Value> = (0..520)
        .map(|index| mono_item(&format!("pay-{index}"), 60 + index * 50, -1000 - index, 5411, "Сільпо"))
        .collect();

    items.push(mono_item("atm-1", 30, -50000, 6011, "Банкомат"));
    items.push(mono_item("p2p-1", 40, -20000, 4829, "Переказ Івану"));
    items.push(mono_item("old-1", 45 * 24 * 60, -7000, 5812, "Кафе"));
    items.push(mono_item("old-2", 80 * 24 * 60, -9000, 5541, "WOG"));
    items.push(mono_item("ancient-1", 200 * 24 * 60, -100, 5411, "Сільпо"));
    items
}

async fn connect_mono(a_app: &TestApp, a_user: &TestUser) -> Uuid
{
    let connected = a_app
        .call(
            Method::POST,
            "/api/banks/monobank",
            Some(&a_user.token),
            Some(json!({ "token": MONO_TOKEN })),
        )
        .await;
    assert_eq!(connected.status, StatusCode::CREATED, "{}", connected.body);
    connected.body["id"].as_str().unwrap().parse().unwrap()
}

async fn create_item(a_app: &TestApp, a_user: &TestUser, a_name: &str, a_kind: &str, a_unit: &str) -> String
{
    let reply = a_app
        .call(
            Method::POST,
            "/api/dicts/items",
            Some(&a_user.token),
            Some(json!({ "name": a_name, "kind": a_kind, "unit": a_unit })),
        )
        .await;
    assert_eq!(reply.status, StatusCode::CREATED, "{}", reply.body);
    reply.body["id"].as_str().unwrap().to_string()
}

async fn all_transactions(a_app: &TestApp, a_user: &TestUser, a_extra: &str) -> Vec<Value>
{
    let mut items = Vec::new();
    let mut cursor: Option<String> = None;

    loop
    {
        let uri = match &cursor
        {
            Some(cursor) => format!("/api/transactions?limit=200{a_extra}&cursor={cursor}"),
            None => format!("/api/transactions?limit=200{a_extra}"),
        };
        let page = a_app.call(Method::GET, &uri, Some(&a_user.token), None).await;
        assert_eq!(page.status, StatusCode::OK, "{}", page.body);
        items.extend(page.body["items"].as_array().unwrap().iter().cloned());

        match page.body["next_cursor"].as_str()
        {
            Some(next) => cursor = Some(next.to_string()),
            None => return items,
        }
    }
}

async fn complete(a_app: &TestApp, a_user: &TestUser, a_state: &str) -> common::Reply
{
    a_app
        .call(
            Method::POST,
            "/api/banks/enable-banking/complete",
            Some(&a_user.token),
            Some(json!({ "code": EB_CODE, "state": a_state })),
        )
        .await
}

async fn wallet_by_name(a_app: &TestApp, a_user: &TestUser, a_name: &str) -> Value
{
    let wallets = a_app.call(Method::GET, "/api/wallets", Some(&a_user.token), None).await;
    wallets
        .body
        .as_array()
        .unwrap()
        .iter()
        .find(|wallet| wallet["name"] == a_name)
        .cloned()
        .unwrap()
}

#[sqlx::test(migrations = "./migrations")]
async fn monobank_token_is_sealed_and_history_is_imported_once(a_db: PgPool)
{
    let (mono_url, mono) = spawn_mono(mono_history()).await;
    let app = TestApp::with_banks(a_db.clone(), bank_config(&mono_url));
    let alice = app.user("alice@example.com").await;
    let mallory = app.user("mallory@example.com").await;

    let bad_token = app
        .call(
            Method::POST,
            "/api/banks/monobank",
            Some(&alice.token),
            Some(json!({ "token": "wrong-token-0123456789" })),
        )
        .await;
    assert_eq!(bad_token.status, StatusCode::BAD_REQUEST);
    assert_eq!(bad_token.body["field"], "token");

    let conn_id = connect_mono(&app, &alice).await;

    let stored = sqlx::query!("SELECT secret FROM bank_conns WHERE id = $1", conn_id)
        .fetch_one(&a_db)
        .await
        .unwrap();
    let sealed = stored.secret.unwrap();
    assert!(!sealed
        .windows(MONO_TOKEN.len())
        .any(|window| window == MONO_TOKEN.as_bytes()));
    assert_eq!(
        app.state.secret_box.open(&sealed, &bank_conn_aad(conn_id)).unwrap(),
        MONO_TOKEN.as_bytes()
    );

    let duplicate = app
        .call(
            Method::POST,
            "/api/banks/monobank",
            Some(&alice.token),
            Some(json!({ "token": MONO_TOKEN })),
        )
        .await;
    assert_eq!(duplicate.body["code"], "ALREADY_CONNECTED");

    let wallet = wallet_by_name(&app, &alice, "Monobank Black UAH").await;
    assert_eq!(wallet["provider"], "monobank");
    assert_eq!(wallet["mask"], "4321");
    assert_eq!(wallet["balance"], "1500.00");
    assert!(!wallet.to_string().contains(MONO_TOKEN));

    sync_connection(&app.state, conn_id).await;
    let first = all_transactions(&app, &alice, "").await;
    assert_eq!(first.len(), 524);

    let grocery = first.iter().find(|tx| tx["amount"] == "-10.00").unwrap();
    assert_eq!(grocery["category"], "groceries");
    assert_eq!(grocery["merchant_name"], "Сільпо");

    let atm = first.iter().find(|tx| tx["amount"] == "-500.00").unwrap();
    assert_eq!(atm["category"], "cash");
    assert!(atm["merchant_id"].is_null());

    let p2p = first.iter().find(|tx| tx["amount"] == "-200.00").unwrap();
    assert_eq!(p2p["category"], "transfer");
    assert!(p2p["merchant_id"].is_null());

    let calls_before = mono.calls.lock().unwrap().len();
    sync_connection(&app.state, conn_id).await;
    assert!(mono.calls.lock().unwrap().len() > calls_before);
    assert_eq!(all_transactions(&app, &alice, "").await.len(), 524);

    let conns = app
        .call(Method::GET, "/api/banks/connections", Some(&alice.token), None)
        .await;
    assert_eq!(conns.body[0]["status"], "active");
    assert!(conns.body[0]["last_error"].is_null());
    assert!(!conns.body[0]["last_sync_ts"].is_null());

    assert!(all_transactions(&app, &mallory, "").await.is_empty());
    let merchants = app
        .call(Method::GET, "/api/merchants", Some(&mallory.token), None)
        .await;
    assert_eq!(merchants.body, json!([]));
    let alice_merchants = app
        .call(Method::GET, "/api/merchants?q=сіл", Some(&alice.token), None)
        .await;
    assert_eq!(alice_merchants.body.as_array().unwrap().len(), 1);

    let foreign_delete = app
        .call(
            Method::DELETE,
            &format!("/api/banks/connections/{conn_id}"),
            Some(&mallory.token),
            None,
        )
        .await;
    assert_eq!(foreign_delete.status, StatusCode::NOT_FOUND);

    let removed = app
        .call(
            Method::DELETE,
            &format!("/api/banks/connections/{conn_id}"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(removed.status, StatusCode::NO_CONTENT);
    let kept = wallet_by_name(&app, &alice, "Monobank Black UAH").await;
    assert!(kept["conn_id"].is_null());
    assert_eq!(all_transactions(&app, &alice, "").await.len(), 524);
}

#[sqlx::test(migrations = "./migrations")]
async fn enable_banking_consent_flow_imports_full_history(a_db: PgPool)
{
    let (eb_cfg, eb) = spawn_enable_banking().await;
    let mut banks = bank_config("http://127.0.0.1:9");
    banks.enable_banking = Some(eb_cfg);
    let app = TestApp::with_banks(a_db.clone(), banks);
    let alice = app.user("alice@example.com").await;
    let mallory = app.user("mallory@example.com").await;

    let aspsps = app
        .call(
            Method::GET,
            "/api/banks/enable-banking/aspsps?country=ie",
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(aspsps.body[0]["name"], "AIB");

    let started = app
        .call(
            Method::POST,
            "/api/banks/enable-banking/start",
            Some(&alice.token),
            Some(json!({ "aspsp_name": "aib", "aspsp_country": "ie" })),
        )
        .await;
    assert_eq!(started.status, StatusCode::OK, "{}", started.body);
    let state = eb.states.lock().unwrap().last().cloned().unwrap();
    assert!(started.body["url"].as_str().unwrap().contains(&state));

    assert_eq!(complete(&app, &mallory, &state).await.status, StatusCode::NOT_FOUND);
    assert_eq!(
        complete(&app, &alice, "forged-state").await.status,
        StatusCode::NOT_FOUND
    );

    let completed = complete(&app, &alice, &state).await;
    assert_eq!(completed.status, StatusCode::CREATED, "{}", completed.body);
    assert_eq!(completed.body["account_count"], 1);
    let conn_id: Uuid = completed.body["id"].as_str().unwrap().parse().unwrap();

    assert_eq!(complete(&app, &alice, &state).await.status, StatusCode::NOT_FOUND);

    let wallet = wallet_by_name(&app, &alice, "AIB Current EUR").await;
    assert_eq!(wallet["bank_type"], "aib");
    assert_eq!(wallet["mask"], "5678");

    sync_connection(&app.state, conn_id).await;
    let first = all_transactions(&app, &alice, "").await;
    assert_eq!(first.len(), 5);
    assert_eq!(
        wallet_by_name(&app, &alice, "AIB Current EUR").await["balance"],
        "1234.56"
    );

    let first_query = eb.tx_queries.lock().unwrap()[0].clone();
    assert_eq!(first_query.get("strategy").map(String::as_str), Some("longest"));
    assert!(!first_query.contains_key("date_from"));

    let salary = first.iter().find(|tx| tx["amount"] == "2500.00").unwrap();
    assert_eq!(salary["category"], "income");
    assert_eq!(salary["counterparty"], "EMPLOYER LTD");
    let tesco = first.iter().find(|tx| tx["amount"] == "-45.10").unwrap();
    assert_eq!(tesco["merchant_name"], "TESCO");

    sync_connection(&app.state, conn_id).await;
    assert_eq!(all_transactions(&app, &alice, "").await.len(), 5);
    let later_query = eb.tx_queries.lock().unwrap().last().cloned().unwrap();
    assert!(later_query.contains_key("date_from") || later_query.contains_key("continuation_key"));

    let conn = sqlx::query!("SELECT next_sync_ts FROM bank_conns WHERE id = $1", conn_id)
        .fetch_one(&a_db)
        .await
        .unwrap();
    let next = conn.next_sync_ts.unwrap();
    assert!(next > Utc::now() && next <= Utc::now() + Duration::hours(6) + Duration::minutes(1));

    let removed = app
        .call(
            Method::DELETE,
            &format!("/api/banks/connections/{conn_id}"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(removed.status, StatusCode::NO_CONTENT);
    assert_eq!(eb.deleted_sessions.lock().unwrap().as_slice(), [EB_SESSION]);
}

#[sqlx::test(migrations = "./migrations")]
async fn cash_transfers_receipts_and_cashflow(a_db: PgPool)
{
    let (mono_url, _mono) = spawn_mono(mono_history()).await;
    let app = TestApp::with_banks(a_db.clone(), bank_config(&mono_url));
    let alice = app.user("alice@example.com").await;
    let mallory = app.user("mallory@example.com").await;
    let uah = app.currency_by_code(&alice.token, "UAH").await;

    let conn_id = connect_mono(&app, &alice).await;
    sync_connection(&app.state, conn_id).await;
    let mono_wallet = wallet_by_name(&app, &alice, "Monobank Black UAH").await;
    let mono_id = mono_wallet["id"].as_str().unwrap().to_string();

    let cash = app
        .call(
            Method::POST,
            "/api/wallets",
            Some(&alice.token),
            Some(json!({ "name": "Кошелёк", "curr_id": uah, "account_type": "cash" })),
        )
        .await;
    let cash_id = cash.body["id"].as_str().unwrap().to_string();

    let income = app
        .call(
            Method::POST,
            "/api/transactions",
            Some(&alice.token),
            Some(json!({ "account_id": cash_id, "amount": "1000", "tx_ts": Utc::now() - Duration::hours(2) })),
        )
        .await;
    assert_eq!(income.status, StatusCode::CREATED, "{}", income.body);
    assert_eq!(income.body["tx_type"], "income");
    assert_eq!(income.body["amount"], "1000.00");
    assert_eq!(income.body["category"], "income");

    let synced_manual = app
        .call(
            Method::POST,
            "/api/transactions",
            Some(&alice.token),
            Some(json!({ "account_id": mono_id, "amount": "-5", "tx_ts": Utc::now() })),
        )
        .await;
    assert_eq!(synced_manual.body["field"], "account_id");

    let txs = all_transactions(&app, &alice, &format!("&account_id={mono_id}")).await;
    let atm = txs.iter().find(|tx| tx["amount"] == "-500.00").unwrap().clone();

    let without_link = app
        .call(
            Method::POST,
            "/api/transfers",
            Some(&alice.token),
            Some(json!({ "from_account_id": mono_id, "to_account_id": cash_id, "amount": "500", "tx_ts": Utc::now() })),
        )
        .await;
    assert_eq!(without_link.body["field"], "from_tx_id");

    let transfer = app
        .call(
            Method::POST,
            "/api/transfers",
            Some(&alice.token),
            Some(json!({
                "from_account_id": mono_id, "to_account_id": cash_id, "from_tx_id": atm["id"], "tx_ts": atm["tx_ts"]
            })),
        )
        .await;
    assert_eq!(transfer.status, StatusCode::CREATED, "{}", transfer.body);
    let legs = transfer.body["txs"].as_array().unwrap();
    assert_eq!(legs.len(), 2);
    assert!(legs.iter().all(|leg| leg["tx_type"] == "transfer"));
    assert!(legs
        .iter()
        .any(|leg| leg["amount"] == "500.00" && leg["account_id"] == cash_id.as_str()));

    let now = Utc::now();
    let stats = app
        .call(
            Method::GET,
            &format!(
                "/api/stats/cashflow?bucket=day&tz_offset_min=180&from={}&to={}",
                (now - Duration::days(30)).timestamp_millis_rfc3339(),
                (now + Duration::hours(1)).timestamp_millis_rfc3339()
            ),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(stats.status, StatusCode::OK, "{}", stats.body);
    let series = stats.body["series"].as_array().unwrap();
    assert_eq!(series.len(), 1);
    assert_eq!(series[0]["curr_code"], "UAH");
    assert_eq!(series[0]["income_total"], "1000.00");
    let expense_total: f64 = series[0]["expense_total"].as_str().unwrap().parse().unwrap();
    let expected_expense: f64 = 200.0
        + (0..520)
            .filter(|index| 60 + index * 50 < 30 * 24 * 60)
            .map(|index| (1000 + index) as f64 / 100.0)
            .sum::<f64>();
    assert!(
        (expense_total - expected_expense).abs() < 0.01,
        "{expense_total} vs {expected_expense}"
    );
    assert!(series[0]["points"].as_array().unwrap().len() >= 30);

    let mallory_stats = app
        .call(
            Method::GET,
            &format!(
                "/api/stats/cashflow?bucket=hour&from={}&to={}",
                (now - Duration::days(1)).timestamp_millis_rfc3339(),
                now.timestamp_millis_rfc3339()
            ),
            Some(&mallory.token),
            None,
        )
        .await;
    assert_eq!(mallory_stats.body["series"], json!([]));

    let unlinked = all_transactions(&app, &alice, "&is_unlinked=true").await;
    let grocery = unlinked.iter().find(|tx| tx["amount"] == "-10.00").unwrap().clone();
    let second = unlinked.iter().find(|tx| tx["amount"] == "-10.01").unwrap().clone();

    let bread = create_item(&app, &alice, "Хліб", "product", "piece").await;
    let apples = create_item(&app, &alice, "Яблоки", "product", "kilogram").await;
    let honey = create_item(&app, &alice, "Мёд", "food", "piece").await;

    let receipt = app
        .call(
            Method::POST,
            "/api/receipts",
            Some(&alice.token),
            Some(json!({
                "receipt_ts": grocery["tx_ts"], "merchant_name": "Сільпо", "curr_id": uah,
                "items": [{ "item_id": bread, "qty": "1", "unit_price": "4", "amount": "4" }],
                "tx_ids": [grocery["id"]]
            })),
        )
        .await;
    assert_eq!(receipt.status, StatusCode::CREATED, "{}", receipt.body);
    assert_eq!(receipt.body["items_total"], "4.00");
    assert_eq!(receipt.body["paid_total"], "10.00");
    assert_eq!(receipt.body["rest_amount"], "6.00");
    assert_eq!(receipt.body["cash_amount"], "0.00");
    assert_eq!(receipt.body["items"][0]["name"], "Хліб");
    assert_eq!(receipt.body["items"][0]["unit"], "piece");
    let receipt_id = receipt.body["id"].as_str().unwrap().to_string();

    let double_link = app
        .call(
            Method::POST,
            "/api/receipts",
            Some(&alice.token),
            Some(json!({ "receipt_ts": now, "curr_id": uah, "tx_ids": [grocery["id"]] })),
        )
        .await;
    assert_eq!(double_link.body["field"], "tx_ids");

    let stolen = app
        .call(
            Method::POST,
            "/api/receipts",
            Some(&mallory.token),
            Some(json!({ "receipt_ts": now, "curr_id": uah, "tx_ids": [second["id"]] })),
        )
        .await;
    assert_eq!(stolen.body["field"], "tx_ids");
    assert_eq!(
        app.call(
            Method::GET,
            &format!("/api/receipts/{receipt_id}"),
            Some(&mallory.token),
            None
        )
        .await
        .status,
        StatusCode::NOT_FOUND
    );

    let market = app
        .call(
            Method::POST,
            "/api/receipts",
            Some(&alice.token),
            Some(json!({
                "receipt_ts": now, "merchant_name": "Рынок", "curr_id": uah, "cash_account_id": cash_id,
                "items": [
                    { "item_id": apples, "qty": "2.5", "unit_price": "40", "amount": "100" },
                    { "item_id": honey, "amount": "200" }
                ]
            })),
        )
        .await;
    assert_eq!(market.status, StatusCode::CREATED, "{}", market.body);
    assert_eq!(market.body["cash_amount"], "300.00");
    let market_id = market.body["id"].as_str().unwrap().to_string();

    let cash_txs = all_transactions(&app, &alice, &format!("&account_id={cash_id}")).await;
    let auto_cash = cash_txs.iter().find(|tx| tx["source"] == "receipt_cash").unwrap();
    assert_eq!(auto_cash["amount"], "-300.00");
    assert_eq!(auto_cash["receipt_id"], market_id.as_str());

    let cannot_delete = app
        .call(
            Method::DELETE,
            &format!("/api/transactions/{}", auto_cash["id"].as_str().unwrap()),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(cannot_delete.body["field"], "source");

    let paid_by_card = app
        .call(
            Method::PUT,
            &format!("/api/receipts/{market_id}"),
            Some(&alice.token),
            Some(json!({
                "receipt_ts": now, "merchant_name": "Рынок", "curr_id": uah, "cash_account_id": cash_id,
                "items": [{ "item_id": apples, "amount": "8" }],
                "tx_ids": [second["id"]]
            })),
        )
        .await;
    assert_eq!(paid_by_card.status, StatusCode::OK, "{}", paid_by_card.body);
    assert_eq!(paid_by_card.body["cash_amount"], "0.00");
    assert_eq!(paid_by_card.body["rest_amount"], "2.01");
    let cash_after = all_transactions(&app, &alice, &format!("&account_id={cash_id}")).await;
    assert!(cash_after.iter().all(|tx| tx["source"] != "receipt_cash"));

    let deleted = app
        .call(
            Method::DELETE,
            &format!("/api/receipts/{receipt_id}"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(deleted.status, StatusCode::NO_CONTENT);
    let relinked = all_transactions(&app, &alice, "&is_unlinked=true").await;
    assert!(relinked.iter().any(|tx| tx["id"] == grocery["id"]));

    let transfer_id = transfer.body["transfer_id"].as_str().unwrap();
    let dissolved = app
        .call(
            Method::DELETE,
            &format!("/api/transfers/{transfer_id}"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(dissolved.status, StatusCode::NO_CONTENT);
    let after = all_transactions(&app, &alice, &format!("&account_id={mono_id}")).await;
    let restored = after.iter().find(|tx| tx["id"] == atm["id"]).unwrap();
    assert_eq!(restored["tx_type"], "expense");
    assert!(restored["transfer_id"].is_null());
    let cash_final = all_transactions(&app, &alice, &format!("&account_id={cash_id}")).await;
    assert_eq!(cash_final.len(), 1);
}

trait Rfc3339Query
{
    fn timestamp_millis_rfc3339(&self) -> String;
}

impl Rfc3339Query for chrono::DateTime<Utc>
{
    fn timestamp_millis_rfc3339(&self) -> String
    {
        self.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
    }
}

async fn buy(
    a_app: &TestApp,
    a_user: &TestUser,
    a_curr: &str,
    a_merchant: &str,
    a_days_ago: i64,
    a_items: Value,
) -> Value
{
    let reply = a_app
        .call(
            Method::POST,
            "/api/receipts",
            Some(&a_user.token),
            Some(json!({
                "receipt_ts": Utc::now() - Duration::days(a_days_ago),
                "merchant_name": a_merchant,
                "curr_id": a_curr,
                "items": a_items
            })),
        )
        .await;
    assert_eq!(reply.status, StatusCode::CREATED, "{}", reply.body);
    reply.body
}

#[sqlx::test(migrations = "./migrations")]
async fn items_dictionary_is_private_and_compares_prices(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let uah = app.currency_by_code(&alice.token, "UAH").await;

    let milk = create_item(&app, &alice, "Молоко 2.5%", "product", "piece").await;
    let duplicate = app
        .call(
            Method::POST,
            "/api/dicts/items",
            Some(&alice.token),
            Some(json!({ "name": "  молоко 2.5% ", "kind": "product", "unit": "piece" })),
        )
        .await;
    assert_eq!(duplicate.status, StatusCode::CONFLICT);

    let system_id: Uuid = sqlx::query_scalar("INSERT INTO items (name, type) VALUES ('Хліб', 'product') RETURNING id")
        .fetch_one(&a_db)
        .await
        .unwrap();
    let bob_milk = create_item(&app, &bob, "Молоко 2.5%", "product", "piece").await;

    let bob_list = app.call(Method::GET, "/api/dicts/items", Some(&bob.token), None).await;
    let bob_ids: Vec<&str> = bob_list
        .body
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["id"].as_str().unwrap())
        .collect();
    assert!(bob_ids.contains(&bob_milk.as_str()));
    assert!(bob_ids.contains(&system_id.to_string().as_str()));
    assert!(!bob_ids.contains(&milk.as_str()));

    for (method, uri) in [
        (Method::GET, format!("/api/dicts/items/{milk}")),
        (Method::GET, format!("/api/dicts/items/{milk}/prices")),
        (Method::DELETE, format!("/api/dicts/items/{milk}")),
    ]
    {
        assert_eq!(
            app.call(method, &uri, Some(&bob.token), None).await.status,
            StatusCode::NOT_FOUND
        );
    }

    let foreign_item = app
        .call(
            Method::POST,
            "/api/receipts",
            Some(&bob.token),
            Some(json!({ "receipt_ts": Utc::now(), "curr_id": uah, "items": [{ "item_id": milk, "amount": "1" }] })),
        )
        .await;
    assert_eq!(foreign_item.body["field"], "item_id");

    let system_edit = app
        .call(
            Method::PUT,
            &format!("/api/dicts/items/{system_id}"),
            Some(&alice.token),
            Some(json!({ "name": "Хлеб", "kind": "product", "unit": "piece" })),
        )
        .await;
    assert_eq!(system_edit.status, StatusCode::FORBIDDEN);

    buy(
        &app,
        &alice,
        &uah,
        "Сільпо",
        9,
        json!([{ "item_id": milk, "qty": "2", "amount": "60" }]),
    )
    .await;
    buy(
        &app,
        &alice,
        &uah,
        "АТБ",
        5,
        json!([{ "item_id": milk, "amount": "28" }, { "item_id": system_id, "amount": "20" }]),
    )
    .await;
    buy(
        &app,
        &alice,
        &uah,
        "сільпо",
        1,
        json!([{ "item_id": milk, "qty": "1", "unit_price": "32", "amount": "32" }]),
    )
    .await;
    buy(
        &app,
        &bob,
        &uah,
        "Сільпо",
        1,
        json!([{ "item_id": bob_milk, "amount": "1" }]),
    )
    .await;

    let prices = app
        .call(
            Method::GET,
            &format!("/api/dicts/items/{milk}/prices"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(prices.status, StatusCode::OK, "{}", prices.body);
    let rows = prices.body.as_array().unwrap();
    assert_eq!(rows.len(), 2, "{}", prices.body);
    assert_eq!(rows[0]["merchant_name"], "АТБ");
    assert_eq!(rows[0]["last_price"], "28.00");
    assert_eq!(rows[1]["merchant_name"], "сільпо");
    assert_eq!(rows[1]["last_price"], "32.00");
    assert_eq!(rows[1]["min_price"], "30.00");
    assert_eq!(rows[1]["avg_price"], "31.00");
    assert_eq!(rows[1]["purchase_count"], 2);

    let search = app
        .call(
            Method::GET,
            "/api/dicts/items?q=%D0%BC%D0%BE%D0%BB",
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(search.body.as_array().unwrap().len(), 1);
    assert_eq!(search.body[0]["id"], milk.as_str());

    let in_use = app
        .call(
            Method::DELETE,
            &format!("/api/dicts/items/{milk}"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(in_use.status, StatusCode::CONFLICT);
    let unused = create_item(&app, &alice, "Пакет", "product", "piece").await;
    let removed = app
        .call(
            Method::DELETE,
            &format!("/api/dicts/items/{unused}"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(removed.status, StatusCode::NO_CONTENT);
}
