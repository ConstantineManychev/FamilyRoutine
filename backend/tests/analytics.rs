mod common;

use axum::http::{Method, StatusCode};
use backend::banking::store::recategorize_pending;
use backend::banking::{fx, matching};
use chrono::{DateTime, Duration, SecondsFormat, Utc};
use common::bank_mocks::{spawn_nbu, NBU_EUR_RATE};
use common::{bank_config, TestApp, TestUser};
use rust_decimal::Decimal;
use serde_json::{json, Value};
use sqlx::PgPool;
use std::str::FromStr;
use uuid::Uuid;

struct BankTx<'a>
{
    amount: &'a str,
    hours_ago: i64,
    category: &'a str,
    mcc: Option<i16>,
    description: &'a str,
    op: Option<(&'a str, &'a str)>,
}

impl<'a> BankTx<'a>
{
    fn new(a_amount: &'a str, a_hours_ago: i64, a_category: &'a str, a_description: &'a str) -> Self
    {
        Self {
            amount: a_amount,
            hours_ago: a_hours_ago,
            category: a_category,
            mcc: None,
            description: a_description,
            op: None,
        }
    }
}

async fn wallet(a_app: &TestApp, a_user: &TestUser, a_name: &str, a_curr: &str, a_type: &str) -> Uuid
{
    let curr_id = a_app.currency_by_code(&a_user.token, a_curr).await;
    let reply = a_app
        .call(
            Method::POST,
            "/api/wallets",
            Some(&a_user.token),
            Some(json!({ "name": a_name, "curr_id": curr_id, "account_type": a_type })),
        )
        .await;
    assert_eq!(reply.status, StatusCode::CREATED, "{}", reply.body);
    reply.body["id"].as_str().unwrap().parse().unwrap()
}

async fn insert_bank_tx(a_db: &PgPool, a_account: Uuid, a_tx: BankTx<'_>) -> Uuid
{
    let amount = Decimal::from_str(a_tx.amount).unwrap();
    let ts = Utc::now() - Duration::hours(a_tx.hours_ago);
    let (op_amount, op_code) = match a_tx.op
    {
        Some((value, code)) => (Some(Decimal::from_str(value).unwrap()), Some(code)),
        None => (None, None),
    };

    sqlx::query_scalar(
        r#"
        INSERT INTO transactions (
            user_id, account_id, curr_id, amount, tx_type, tx_ts, ext_id, source, description, mcc, category,
            op_amount, op_curr_id, rule_key
        )
        SELECT a.user_id, a.id, a.curr_id, $2,
               CASE WHEN $2 > 0 THEN 'income'::tx_type_t ELSE 'expense'::tx_type_t END,
               $3, gen_random_uuid()::text, 'bank', $4, $5, $6::tx_cat_t, $7,
               (SELECT id FROM currencies WHERE code = $8), ''
        FROM accounts a WHERE a.id = $1
        RETURNING id
        "#,
    )
    .bind(a_account)
    .bind(amount)
    .bind(ts)
    .bind(a_tx.description)
    .bind(a_tx.mcc)
    .bind(a_tx.category)
    .bind(op_amount)
    .bind(op_code)
    .fetch_one(a_db)
    .await
    .unwrap()
}

async fn tx(a_app: &TestApp, a_user: &TestUser, a_id: Uuid) -> Value
{
    let page = a_app
        .call(Method::GET, "/api/transactions?limit=200", Some(&a_user.token), None)
        .await;
    page.body["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"] == a_id.to_string().as_str())
        .cloned()
        .unwrap()
}

fn iso(a_ts: DateTime<Utc>) -> String
{
    a_ts.to_rfc3339_opts(SecondsFormat::Millis, true)
}

async fn stats(a_app: &TestApp, a_user: &TestUser, a_path: &str, a_extra: &str) -> Value
{
    let now = Utc::now();
    let uri = format!(
        "/api/stats/{a_path}?from={}&to={}{a_extra}",
        iso(now - Duration::days(10)),
        iso(now + Duration::hours(1))
    );
    let reply = a_app.call(Method::GET, &uri, Some(&a_user.token), None).await;
    assert_eq!(reply.status, StatusCode::OK, "{}", reply.body);
    reply.body
}

fn series_totals(a_body: &Value) -> Vec<(String, String, String)>
{
    a_body["series"]
        .as_array()
        .unwrap()
        .iter()
        .map(|series| {
            (
                series["curr_code"].as_str().unwrap().to_string(),
                series["income_total"].as_str().unwrap().to_string(),
                series["expense_total"].as_str().unwrap().to_string(),
            )
        })
        .collect()
}

#[sqlx::test(migrations = "./migrations")]
async fn own_transfers_and_cash_are_matched_and_excluded_from_flows(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let alice = app.user("alice@example.com").await;
    let mallory = app.user("mallory@example.com").await;

    let mono_uah = wallet(&app, &alice, "Mono UAH", "UAH", "card").await;
    let mono_eur = wallet(&app, &alice, "Mono EUR", "EUR", "card").await;
    let aib = wallet(&app, &alice, "AIB", "EUR", "bank_acc").await;
    let cash = wallet(&app, &alice, "Кошелёк", "EUR", "cash").await;
    let mallory_eur = wallet(&app, &mallory, "Mallory EUR", "EUR", "card").await;

    let exchange_out = insert_bank_tx(
        &a_db,
        mono_eur,
        BankTx {
            mcc: Some(4829),
            ..BankTx::new("-100.00", 30, "transfer", "Продаж валюти")
        },
    )
    .await;
    let exchange_in = insert_bank_tx(
        &a_db,
        mono_uah,
        BankTx {
            mcc: Some(4829),
            op: Some(("100.00", "EUR")),
            ..BankTx::new("4550.00", 30, "transfer", "З євро-рахунку")
        },
    )
    .await;

    let sepa_out = insert_bank_tx(
        &a_db,
        aib,
        BankTx::new("-200.00", 50, "transfer", "SEPA TRANSFER TO MONOBANK"),
    )
    .await;
    let sepa_in = insert_bank_tx(
        &a_db,
        mono_eur,
        BankTx {
            mcc: Some(4829),
            ..BankTx::new("200.00", 26, "transfer", "Від: AIB")
        },
    )
    .await;

    let groceries = insert_bank_tx(
        &a_db,
        aib,
        BankTx {
            mcc: Some(5411),
            ..BankTx::new("-50.00", 20, "groceries", "TESCO")
        },
    )
    .await;
    let refund = insert_bank_tx(&a_db, mono_eur, BankTx::new("50.00", 19, "income", "Refund")).await;

    let ambiguous_out = insert_bank_tx(&a_db, aib, BankTx::new("-30.00", 10, "transfer", "TRANSFER")).await;
    insert_bank_tx(&a_db, mono_eur, BankTx::new("30.00", 9, "transfer", "Переказ")).await;
    insert_bank_tx(&a_db, mono_eur, BankTx::new("30.00", 8, "transfer", "Переказ")).await;

    let atm = insert_bank_tx(
        &a_db,
        aib,
        BankTx {
            mcc: Some(6011),
            ..BankTx::new("-100.00", 6, "cash", "ATM WITHDRAWAL")
        },
    )
    .await;
    let lodgement = insert_bank_tx(&a_db, aib, BankTx::new("100.00", 2, "cash", "CASH LODGEMENT")).await;
    let salary = insert_bank_tx(&a_db, aib, BankTx::new("3000.00", 40, "income", "SALARY ACME")).await;

    insert_bank_tx(&a_db, mallory_eur, BankTx::new("100.00", 30, "transfer", "Переказ")).await;

    let cash_income = app
        .call(
            Method::POST,
            "/api/transactions",
            Some(&alice.token),
            Some(json!({
                "account_id": cash, "amount": "100.00",
                "tx_ts": iso(Utc::now() - Duration::hours(5)), "category": "cash"
            })),
        )
        .await;
    assert_eq!(cash_income.status, StatusCode::CREATED, "{}", cash_income.body);
    let cash_income_id: Uuid = cash_income.body["id"].as_str().unwrap().parse().unwrap();

    assert_eq!(matching::match_transfers(&a_db, alice.id).await.unwrap(), 0);

    let exchange = tx(&app, &alice, exchange_out).await;
    assert_eq!(exchange["tx_type"], "transfer");
    assert_eq!(exchange["is_auto_transfer"], true);
    assert_eq!(exchange["peer_account_name"], "Mono UAH");
    assert_eq!(exchange["peer_amount"], "4550.00");
    assert_eq!(
        tx(&app, &alice, exchange_in).await["transfer_id"],
        exchange["transfer_id"]
    );

    let sepa = tx(&app, &alice, sepa_out).await;
    assert_eq!(sepa["tx_type"], "transfer");
    assert_eq!(tx(&app, &alice, sepa_in).await["transfer_id"], sepa["transfer_id"]);

    assert_eq!(tx(&app, &alice, groceries).await["transfer_id"], Value::Null);
    assert_eq!(tx(&app, &alice, refund).await["transfer_id"], Value::Null);
    assert_eq!(tx(&app, &alice, ambiguous_out).await["transfer_id"], Value::Null);
    assert_eq!(tx(&app, &alice, salary).await["transfer_id"], Value::Null);

    let atm_tx = tx(&app, &alice, atm).await;
    assert_eq!(atm_tx["tx_type"], "transfer");
    assert_eq!(atm_tx["peer_account_name"], "Кошелёк");
    assert_eq!(
        tx(&app, &alice, cash_income_id).await["transfer_id"],
        atm_tx["transfer_id"]
    );

    let net = stats(&app, &alice, "cashflow", "&bucket=day").await;
    let eur = series_totals(&net)
        .into_iter()
        .find(|(code, _, _)| code == "EUR")
        .unwrap();
    assert_eq!((eur.1.as_str(), eur.2.as_str()), ("3110.00", "80.00"));

    let turnover = stats(&app, &alice, "cashflow", "&bucket=day&mode=turnover").await;
    let eur = series_totals(&turnover)
        .into_iter()
        .find(|(code, _, _)| code == "EUR")
        .unwrap();
    assert_eq!((eur.1.as_str(), eur.2.as_str()), ("3510.00", "480.00"));
    assert!(series_totals(&turnover)
        .iter()
        .any(|(code, income, _)| code == "UAH" && income == "4550.00"));
    assert!(series_totals(&net).iter().all(|(code, _, _)| code != "UAH"));

    let atm_transfer = atm_tx["transfer_id"].as_str().unwrap();
    let unlinked = app
        .call(
            Method::DELETE,
            &format!("/api/transfers/{atm_transfer}"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(unlinked.status, StatusCode::NO_CONTENT);
    matching::match_transfers(&a_db, alice.id).await.unwrap();
    assert_eq!(tx(&app, &alice, atm).await["transfer_id"], Value::Null);
    let kept_income = tx(&app, &alice, cash_income_id).await;
    assert_eq!(kept_income["transfer_id"], Value::Null);
    assert_eq!(kept_income["tx_type"], "income");

    assert_eq!(tx(&app, &alice, lodgement).await["tx_type"], "income");
    let after_unlink = stats(&app, &alice, "cashflow", "&bucket=day").await;
    let eur = series_totals(&after_unlink)
        .into_iter()
        .find(|(code, _, _)| code == "EUR")
        .unwrap();
    assert_eq!((eur.1.as_str(), eur.2.as_str()), ("3210.00", "80.00"));

    let mallory_page = app
        .call(Method::GET, "/api/transactions?limit=200", Some(&mallory.token), None)
        .await;
    assert!(mallory_page.body["items"]
        .as_array()
        .unwrap()
        .iter()
        .all(|item| item["transfer_id"].is_null()));
}

#[sqlx::test(migrations = "./migrations")]
async fn rates_convert_all_currencies_into_one(a_db: PgPool)
{
    let nbu_url = spawn_nbu().await;
    let mut banks = bank_config("http://127.0.0.1:9");
    banks.fx_api_url = Some(nbu_url);
    let app = TestApp::with_banks(a_db.clone(), banks);
    let alice = app.user("alice@example.com").await;

    let uah = wallet(&app, &alice, "UAH", "UAH", "card").await;
    let eur = wallet(&app, &alice, "EUR", "EUR", "card").await;
    insert_bank_tx(&a_db, uah, BankTx::new("-910.00", 30, "groceries", "Сільпо")).await;
    insert_bank_tx(&a_db, eur, BankTx::new("-10.00", 28, "restaurants", "Costa")).await;
    insert_bank_tx(&a_db, eur, BankTx::new("-20.00", 29, "groceries", "Lidl")).await;
    insert_bank_tx(&a_db, eur, BankTx::new("1000.00", 27, "income", "SALARY")).await;

    let missing = stats(&app, &alice, "cashflow", "&bucket=day&convert_to=EUR").await;
    assert_eq!(missing["missing_rates"], json!(["UAH"]));

    let fetched = fx::sync_rates(&app.state).await.unwrap();
    assert!(fetched >= 2, "{fetched}");
    let rate: Decimal = sqlx::query_scalar(
        "SELECT rate FROM currency_rates r JOIN currencies c ON c.id = r.target_curr_id WHERE c.code = 'EUR' LIMIT 1",
    )
    .fetch_one(&a_db)
    .await
    .unwrap();
    assert_eq!(rate, Decimal::from_str(NBU_EUR_RATE).unwrap());
    assert_eq!(fx::sync_rates(&app.state).await.unwrap(), 0);

    let converted = stats(&app, &alice, "cashflow", "&bucket=day&convert_to=eur").await;
    assert_eq!(converted["missing_rates"], json!([]));
    assert_eq!(
        series_totals(&converted),
        vec![("EUR".to_string(), "1000.00".to_string(), "50.00".to_string())]
    );

    let in_uah = stats(&app, &alice, "categories", "&convert_to=UAH").await;
    let series = &in_uah["series"][0];
    assert_eq!(series["curr_code"], "UAH");
    assert_eq!(series["expense_total"], "2275.00");
    assert_eq!(series["items"][0]["category"], "groceries");
    assert_eq!(series["items"][0]["expense"], "1820.00");
    assert_eq!(series["items"][0]["tx_count"], 2);
    assert_eq!(series["items"][1]["category"], "restaurants");
    assert_eq!(series["items"][1]["expense"], "455.00");

    let unknown = app
        .call(
            Method::GET,
            &format!(
                "/api/stats/cashflow?bucket=day&from={}&to={}&convert_to=ZZZ",
                iso(Utc::now() - Duration::days(1)),
                iso(Utc::now())
            ),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(unknown.body["field"], "convert_to");
}

#[sqlx::test(migrations = "./migrations")]
async fn text_rules_and_user_rules_categorize_transactions(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let aib = wallet(&app, &alice, "AIB", "EUR", "bank_acc").await;
    let bob_card = wallet(&app, &bob, "Bob", "EUR", "card").await;

    let insert_raw = |a_account: Uuid, a_amount: &'static str, a_description: &'static str| {
        let db = a_db.clone();
        async move {
            sqlx::query_scalar::<_, Uuid>(
                r#"
                INSERT INTO transactions (user_id, account_id, curr_id, amount, tx_type, tx_ts, ext_id, source, description)
                SELECT a.user_id, a.id, a.curr_id, $2::numeric,
                       CASE WHEN $2::numeric > 0 THEN 'income'::tx_type_t ELSE 'expense'::tx_type_t END,
                       NOW(), gen_random_uuid()::text, 'bank', $3
                FROM accounts a WHERE a.id = $1
                RETURNING id
                "#,
            )
            .bind(a_account)
            .bind(a_amount)
            .bind(a_description)
            .fetch_one(&db)
            .await
            .unwrap()
        }
    };

    let tesco = insert_raw(aib, "-12.40", "VDP-TESCO STORES 3092").await;
    let tesco_other = insert_raw(aib, "-8.10", "VDP-TESCO STORES 1001").await;
    let gym = insert_raw(aib, "-40.00", "VDP-FLYEFIT DUBLIN").await;
    let gym_later = insert_raw(aib, "-40.00", "VDP-FLYEFIT DUBLIN").await;
    let bob_gym = insert_raw(bob_card, "-40.00", "VDP-FLYEFIT DUBLIN").await;

    assert_eq!(recategorize_pending(&a_db).await.unwrap(), 5);
    assert_eq!(recategorize_pending(&a_db).await.unwrap(), 0);

    assert_eq!(tx(&app, &alice, tesco).await["category"], "groceries");
    assert_eq!(tx(&app, &alice, tesco_other).await["category"], "groceries");
    let gym_tx = tx(&app, &alice, gym).await;
    assert_eq!(gym_tx["category"], "other");
    assert_eq!(gym_tx["similar_key"], "flyefit dublin");

    let updated = app
        .call(
            Method::PUT,
            &format!("/api/transactions/{gym}"),
            Some(&alice.token),
            Some(json!({ "category": "health", "is_apply_to_similar": true })),
        )
        .await;
    assert_eq!(updated.status, StatusCode::OK, "{}", updated.body);
    assert_eq!(tx(&app, &alice, gym_later).await["category"], "health");
    assert_eq!(tx(&app, &bob, bob_gym).await["category"], "other");

    let locked = app
        .call(
            Method::PUT,
            &format!("/api/transactions/{tesco_other}"),
            Some(&alice.token),
            Some(json!({ "category": "home" })),
        )
        .await;
    assert_eq!(locked.status, StatusCode::OK);
    let relabel = app
        .call(
            Method::PUT,
            &format!("/api/transactions/{tesco}"),
            Some(&alice.token),
            Some(json!({ "category": "shopping", "is_apply_to_similar": true })),
        )
        .await;
    assert_eq!(relabel.status, StatusCode::OK);
    assert_eq!(tx(&app, &alice, tesco_other).await["category"], "home");

    let no_key = insert_raw(aib, "-1.00", "").await;
    recategorize_pending(&a_db).await.unwrap();
    let rejected = app
        .call(
            Method::PUT,
            &format!("/api/transactions/{no_key}"),
            Some(&alice.token),
            Some(json!({ "category": "fees", "is_apply_to_similar": true })),
        )
        .await;
    assert_eq!(rejected.body["field"], "is_apply_to_similar");

    let filtered = app
        .call(
            Method::GET,
            "/api/transactions?category=health",
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(filtered.body["items"].as_array().unwrap().len(), 2);
}
