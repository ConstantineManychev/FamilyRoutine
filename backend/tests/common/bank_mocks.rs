use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use backend::config::EnableBankingConfig;
use chrono::{Duration, Utc};
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Validation};
use rsa::pkcs8::{EncodePrivateKey, EncodePublicKey, LineEnding};
use rsa::RsaPrivateKey;
use serde_json::{json, Value};
use tokio::net::TcpListener;

pub const MONO_TOKEN: &str = "uMonoBankPersonalToken0123456789abcdef";
pub const MONO_ACCOUNT: &str = "acc-uah";
pub const EB_APP_ID: &str = "11111111-2222-3333-4444-555555555555";
pub const EB_CODE: &str = "good-code";
pub const EB_SESSION: &str = "session-secret-1";
pub const EB_ACCOUNT: &str = "uid-1";

#[derive(Clone)]
pub struct MonoMock
{
    pub items: Arc<Vec<Value>>,
    pub calls: Arc<Mutex<Vec<String>>>,
}

pub async fn spawn_mono(a_items: Vec<Value>) -> (String, MonoMock)
{
    let mock = MonoMock {
        items: Arc::new(a_items),
        calls: Arc::new(Mutex::new(Vec::new())),
    };

    let router = Router::new()
        .route("/personal/client-info", get(mono_client_info))
        .route("/personal/statement/:account/:from/:to", get(mono_statement))
        .with_state(mock.clone());

    (serve(router).await, mock)
}

async fn mono_client_info(State(a_mock): State<MonoMock>, a_headers: HeaderMap) -> Response
{
    a_mock.calls.lock().unwrap().push("client-info".into());

    if a_headers.get("X-Token").and_then(|value| value.to_str().ok()) != Some(MONO_TOKEN)
    {
        return (
            StatusCode::FORBIDDEN,
            Json(json!({ "errorDescription": "Unknown 'X-Token'" })),
        )
            .into_response();
    }

    Json(json!({
        "clientId": "c1",
        "name": "Test",
        "accounts": [{
            "id": MONO_ACCOUNT,
            "balance": 150000,
            "creditLimit": 0,
            "type": "black",
            "currencyCode": 980,
            "maskedPan": ["537541******4321"],
            "iban": "UA213223130000026007233566001"
        }]
    }))
    .into_response()
}

async fn mono_statement(
    State(a_mock): State<MonoMock>,
    a_headers: HeaderMap,
    Path((a_account, a_from, a_to)): Path<(String, i64, i64)>,
) -> Response
{
    a_mock.calls.lock().unwrap().push(format!("statement:{a_from}:{a_to}"));

    if a_headers.get("X-Token").and_then(|value| value.to_str().ok()) != Some(MONO_TOKEN)
    {
        return StatusCode::FORBIDDEN.into_response();
    }

    if a_account != MONO_ACCOUNT || a_to - a_from > 31 * 86_400 + 3600
    {
        return StatusCode::BAD_REQUEST.into_response();
    }

    let mut items: Vec<Value> = a_mock
        .items
        .iter()
        .filter(|item| {
            let time = item["time"].as_i64().unwrap();
            time >= a_from && time <= a_to
        })
        .cloned()
        .collect();
    items.sort_by_key(|item| std::cmp::Reverse(item["time"].as_i64().unwrap()));
    items.truncate(500);

    Json(items).into_response()
}

pub fn mono_item(a_id: &str, a_minutes_ago: i64, a_amount: i64, a_mcc: i64, a_description: &str) -> Value
{
    json!({
        "id": a_id,
        "time": (Utc::now() - Duration::minutes(a_minutes_ago)).timestamp(),
        "description": a_description,
        "mcc": a_mcc,
        "originalMcc": a_mcc,
        "hold": false,
        "amount": a_amount,
        "operationAmount": a_amount,
        "currencyCode": 980,
        "commissionRate": 0,
        "cashbackAmount": 0,
        "balance": 100000
    })
}

#[derive(Clone)]
pub struct EbMock
{
    pub decoding: Arc<DecodingKey>,
    pub states: Arc<Mutex<Vec<String>>>,
    pub tx_queries: Arc<Mutex<Vec<HashMap<String, String>>>>,
    pub deleted_sessions: Arc<Mutex<Vec<String>>>,
}

pub async fn spawn_enable_banking() -> (EnableBankingConfig, EbMock)
{
    let private = RsaPrivateKey::new(&mut rand::thread_rng(), 2048).unwrap();
    let private_pem = private.to_pkcs8_pem(LineEnding::LF).unwrap();
    let public_pem = private.to_public_key().to_public_key_pem(LineEnding::LF).unwrap();

    let mock = EbMock {
        decoding: Arc::new(DecodingKey::from_rsa_pem(public_pem.as_bytes()).unwrap()),
        states: Arc::new(Mutex::new(Vec::new())),
        tx_queries: Arc::new(Mutex::new(Vec::new())),
        deleted_sessions: Arc::new(Mutex::new(Vec::new())),
    };

    let router = Router::new()
        .route("/aspsps", get(eb_aspsps))
        .route("/auth", post(eb_auth))
        .route("/sessions", post(eb_sessions))
        .route("/sessions/:id", delete(eb_delete_session))
        .route("/accounts/:uid/balances", get(eb_balances))
        .route("/accounts/:uid/transactions", get(eb_transactions))
        .with_state(mock.clone());

    let url = serve(router).await;

    let cfg = EnableBankingConfig {
        api_url: url,
        app_id: EB_APP_ID.to_string(),
        key: EncodingKey::from_rsa_pem(private_pem.as_bytes()).unwrap(),
        redirect_url: "https://app.example/app/bank-callback".to_string(),
        consent_days: 180,
    };

    (cfg, mock)
}

fn is_authorized(a_mock: &EbMock, a_headers: &HeaderMap) -> bool
{
    let Some(token) = a_headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
    else
    {
        return false;
    };

    let mut validation = Validation::new(Algorithm::RS256);
    validation.set_audience(&["api.enablebanking.com"]);
    validation.set_issuer(&["enablebanking.com"]);

    let header_kid = jsonwebtoken::decode_header(token).ok().and_then(|header| header.kid);
    header_kid.as_deref() == Some(EB_APP_ID)
        && jsonwebtoken::decode::<Value>(token, &a_mock.decoding, &validation).is_ok()
}

async fn eb_aspsps(State(a_mock): State<EbMock>, a_headers: HeaderMap) -> Response
{
    if !is_authorized(&a_mock, &a_headers)
    {
        return StatusCode::UNAUTHORIZED.into_response();
    }

    Json(json!({ "aspsps": [{ "name": "AIB", "country": "IE", "maximum_consent_validity": 15_552_000 }] }))
        .into_response()
}

async fn eb_auth(State(a_mock): State<EbMock>, a_headers: HeaderMap, Json(a_body): Json<Value>) -> Response
{
    if !is_authorized(&a_mock, &a_headers)
    {
        return StatusCode::UNAUTHORIZED.into_response();
    }

    if a_body["aspsp"]["name"] != "AIB" || a_body["psu_type"] != "personal" || a_body["access"]["valid_until"].is_null()
    {
        return StatusCode::UNPROCESSABLE_ENTITY.into_response();
    }

    let state = a_body["state"].as_str().unwrap().to_string();
    a_mock.states.lock().unwrap().push(state.clone());

    Json(json!({ "url": format!("https://bank.example/auth?state={state}"), "authorization_id": "a1" })).into_response()
}

async fn eb_sessions(State(a_mock): State<EbMock>, a_headers: HeaderMap, Json(a_body): Json<Value>) -> Response
{
    if !is_authorized(&a_mock, &a_headers)
    {
        return StatusCode::UNAUTHORIZED.into_response();
    }

    if a_body["code"] != EB_CODE
    {
        return StatusCode::BAD_REQUEST.into_response();
    }

    Json(json!({
        "session_id": EB_SESSION,
        "aspsp": { "name": "AIB", "country": "IE" },
        "psu_type": "personal",
        "access": { "valid_until": (Utc::now() + Duration::days(180)).to_rfc3339() },
        "accounts": [{
            "uid": EB_ACCOUNT,
            "account_id": { "iban": "IE29AIBK93115212345678" },
            "name": "Current",
            "currency": "EUR",
            "cash_account_type": "CACC"
        }]
    }))
    .into_response()
}

async fn eb_delete_session(State(a_mock): State<EbMock>, a_headers: HeaderMap, Path(a_id): Path<String>) -> StatusCode
{
    if !is_authorized(&a_mock, &a_headers)
    {
        return StatusCode::UNAUTHORIZED;
    }

    a_mock.deleted_sessions.lock().unwrap().push(a_id);
    StatusCode::NO_CONTENT
}

async fn eb_balances(State(a_mock): State<EbMock>, a_headers: HeaderMap, Path(a_uid): Path<String>) -> Response
{
    if !is_authorized(&a_mock, &a_headers) || a_uid != EB_ACCOUNT
    {
        return StatusCode::UNAUTHORIZED.into_response();
    }

    Json(json!({ "balances": [
        { "balance_amount": { "currency": "EUR", "amount": "999.00" }, "balance_type": "XPCD" },
        { "balance_amount": { "currency": "EUR", "amount": "1234.56" }, "balance_type": "CLBD" }
    ]}))
    .into_response()
}

async fn eb_transactions(
    State(a_mock): State<EbMock>,
    a_headers: HeaderMap,
    Path(a_uid): Path<String>,
    Query(a_query): Query<HashMap<String, String>>,
) -> Response
{
    if !is_authorized(&a_mock, &a_headers) || a_uid != EB_ACCOUNT
    {
        return StatusCode::UNAUTHORIZED.into_response();
    }

    a_mock.tx_queries.lock().unwrap().push(a_query.clone());

    let today = Utc::now().date_naive();
    let day = |a_days: i64| (today - Duration::days(a_days)).to_string();

    if a_query.get("continuation_key").map(String::as_str) == Some("page-2")
    {
        return Json(json!({ "transactions": [
            { "transaction_amount": { "currency": "EUR", "amount": "3.50" }, "credit_debit_indicator": "DBIT",
              "status": "BOOK", "booking_date": day(2), "remittance_information": ["VDP-COSTA COFFEE"] },
            { "transaction_amount": { "currency": "EUR", "amount": "3.50" }, "credit_debit_indicator": "DBIT",
              "status": "BOOK", "booking_date": day(2), "remittance_information": ["VDP-COSTA COFFEE"] }
        ], "continuation_key": null }))
        .into_response();
    }

    Json(json!({ "transactions": [
        { "entry_reference": "R1", "transaction_amount": { "currency": "EUR", "amount": "2500.00" },
          "credit_debit_indicator": "CRDT", "status": "BOOK", "booking_date": day(20),
          "debtor": { "name": "EMPLOYER LTD" }, "remittance_information": ["SALARY"] },
        { "entry_reference": "R2", "transaction_amount": { "currency": "EUR", "amount": "45.10" },
          "credit_debit_indicator": "DBIT", "status": "BOOK", "booking_date": day(5),
          "creditor": { "name": "TESCO" }, "merchant_category_code": "5411", "remittance_information": ["VDP-TESCO STORES 3092"] },
        { "entry_reference": "R3", "transaction_amount": { "currency": "EUR", "amount": "100.00" },
          "credit_debit_indicator": "DBIT", "status": "BOOK", "booking_date": day(3),
          "merchant_category_code": "6011", "remittance_information": ["ATM WITHDRAWAL"] }
    ], "continuation_key": "page-2" }))
    .into_response()
}

async fn serve(a_router: Router) -> String
{
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, a_router).await.unwrap();
    });
    format!("http://{addr}")
}
