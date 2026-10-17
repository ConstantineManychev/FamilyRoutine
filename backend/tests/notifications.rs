mod common;

use std::sync::{Arc, Mutex};

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, Method, StatusCode};
use axum::routing::post;
use axum::Router;
use backend::notify::web_push::{generate_vapid, VapidKeys};
use backend::notify::{sender, worker};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::{DateTime, Duration, NaiveDate, NaiveTime, Timelike, Utc};
use common::{push_config, TestApp, TestUser};
use ring::rand::{SecureRandom, SystemRandom};
use ring::{aead, agreement, hkdf, signature};
use serde_json::{json, Value};
use sqlx::PgPool;
use tokio::net::TcpListener;
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

async fn item(a_app: &TestApp, a_user: &TestUser, a_name: &str) -> String
{
    let (status, item) = send(
        a_app,
        a_user,
        Method::POST,
        "/api/dicts/items",
        Some(json!({ "name": a_name, "kind": "food", "unit": "kilogram",
                     "nutrition": { "kcal": "300", "prot": "10", "fat": "5", "carb": "50" } })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{item}");
    item["id"].as_str().unwrap().to_string()
}

async fn lot(a_app: &TestApp, a_user: &TestUser, a_body: Value) -> Value
{
    let (status, lot) = send(a_app, a_user, Method::POST, "/api/stock/lots", Some(a_body)).await;
    assert_eq!(status, StatusCode::CREATED, "{lot}");
    lot
}

async fn set_expiry(a_app: &TestApp, a_user: &TestUser, a_lot: &Value, a_date: Option<NaiveDate>)
    -> (StatusCode, Value)
{
    send(
        a_app,
        a_user,
        Method::PATCH,
        &format!("/api/stock/lots/{}", a_lot["id"].as_str().unwrap()),
        Some(json!({ "expires_on": a_date })),
    )
    .await
}

async fn settings(a_app: &TestApp, a_user: &TestUser, a_body: Value) -> Value
{
    let (status, saved) = send(a_app, a_user, Method::PUT, "/api/notifications/settings", Some(a_body)).await;
    assert_eq!(status, StatusCode::OK, "{saved}");
    saved
}

async fn inbox(a_app: &TestApp, a_user: &TestUser) -> Value
{
    let (status, list) = send(a_app, a_user, Method::GET, "/api/notifications", None).await;
    assert_eq!(status, StatusCode::OK, "{list}");
    list
}

async fn meal_mark(a_app: &TestApp, a_user: &TestUser) -> String
{
    let start = Utc::now() - Duration::minutes(30);
    let (status, mark) = send(
        a_app,
        a_user,
        Method::POST,
        "/api/routine/marks",
        Some(json!({ "status": "meal", "start_ts": start, "end_ts": start + Duration::minutes(20) })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{mark}");
    mark["id"].as_str().unwrap().to_string()
}

async fn eat(a_app: &TestApp, a_user: &TestUser, a_mark: &str, a_item: &str, a_grams: &str) -> Value
{
    let (status, entry) = send(
        a_app,
        a_user,
        Method::POST,
        "/api/nutrition/entries",
        Some(json!({ "date": Utc::now().date_naive(), "status_mark_id": a_mark, "item_id": a_item, "grams": a_grams })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{entry}");
    entry
}

async fn stock_lots(a_app: &TestApp, a_user: &TestUser, a_query: &str) -> Vec<Value>
{
    let (status, stock) = send(a_app, a_user, Method::GET, &format!("/api/stock{a_query}"), None).await;
    assert_eq!(status, StatusCode::OK, "{stock}");
    stock["lots"].as_array().unwrap().clone()
}

fn left_of(a_lots: &[Value], a_id: &Value) -> Option<String>
{
    a_lots
        .iter()
        .find(|lot| lot["id"] == *a_id)
        .map(|lot| lot["left_qty"].as_str().unwrap().to_string())
}

fn at(a_date: NaiveDate, a_hour: u32, a_minute: u32) -> DateTime<Utc>
{
    a_date
        .and_time(NaiveTime::from_hms_opt(a_hour, a_minute, 0).unwrap())
        .and_utc()
}

#[sqlx::test(migrations = "./migrations")]
async fn diary_and_cooking_take_lots_that_expire_first(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let today = Utc::now().date_naive();
    let rice = item(&app, &alice, "Рис").await;

    let plain = lot(
        &app,
        &alice,
        json!({ "item_id": rice, "qty": "500", "unit": "g", "acquired_on": today - Duration::days(5) }),
    )
    .await;
    let soon = lot(
        &app,
        &alice,
        json!({ "item_id": rice, "qty": "300", "unit": "g", "acquired_on": today - Duration::days(1),
                "expires_on": today + Duration::days(3) }),
    )
    .await;
    let later = lot(
        &app,
        &alice,
        json!({ "item_id": rice, "qty": "200", "unit": "g", "acquired_on": today - Duration::days(2),
                "expires_on": today + Duration::days(10) }),
    )
    .await;
    let stale = lot(
        &app,
        &alice,
        json!({ "item_id": rice, "qty": "100", "unit": "g", "acquired_on": today - Duration::days(6) }),
    )
    .await;
    assert_eq!(soon["expires_on"], json!(today + Duration::days(3)));
    assert_eq!(soon["is_expired"], false);

    let (status, expired) = set_expiry(&app, &alice, &stale, Some(today - Duration::days(1))).await;
    assert_eq!(status, StatusCode::OK, "{expired}");
    assert_eq!(expired["is_expired"], true);
    let (status, too_early) = set_expiry(&app, &alice, &stale, Some(today - Duration::days(30))).await;
    assert_eq!(
        (status, too_early["field"].as_str()),
        (StatusCode::BAD_REQUEST, Some("expires_on"))
    );
    let (status, past) = send(
        &app,
        &alice,
        Method::POST,
        "/api/stock/lots",
        Some(json!({ "item_id": rice, "qty": "10", "unit": "g", "expires_on": today - Duration::days(1) })),
    )
    .await;
    assert_eq!(
        (status, past["field"].as_str()),
        (StatusCode::BAD_REQUEST, Some("expires_on"))
    );
    let (status, far) = send(
        &app,
        &alice,
        Method::POST,
        "/api/stock/lots",
        Some(json!({ "item_id": rice, "qty": "10", "unit": "g", "expires_on": today + Duration::days(4000) })),
    )
    .await;
    assert_eq!(
        (status, far["field"].as_str()),
        (StatusCode::BAD_REQUEST, Some("expires_on"))
    );

    let mark = meal_mark(&app, &alice).await;
    let entry = eat(&app, &alice, &mark, &rice, "400").await;
    assert!(entry["stock_short"].is_null() || entry["stock_short"] == "0", "{entry}");
    let lots = stock_lots(&app, &alice, "").await;
    assert_eq!(left_of(&lots, &soon["id"]), None);
    assert_eq!(left_of(&lots, &later["id"]).as_deref(), Some("100"));
    assert_eq!(left_of(&lots, &plain["id"]).as_deref(), Some("500"));
    assert_eq!(left_of(&lots, &stale["id"]).as_deref(), Some("100"));

    let (status, dish) = send(
        &app,
        &alice,
        Method::POST,
        "/api/dishes",
        Some(json!({ "name": "Каша", "ingredients": [{ "item_id": rice, "grams": "150" }] })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{dish}");
    let (status, batch) = send(
        &app,
        &alice,
        Method::POST,
        "/api/stock/cook",
        Some(
            json!({ "dish_id": dish["id"], "cooked_g": "300", "expires_on": today + Duration::days(2),
                     "ingredients": [{ "item_id": rice, "grams": "150" }] }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{batch}");
    assert_eq!(batch["expires_on"], json!(today + Duration::days(2)));
    let lots = stock_lots(&app, &alice, "").await;
    assert_eq!(left_of(&lots, &later["id"]), None);
    assert_eq!(left_of(&lots, &plain["id"]).as_deref(), Some("450"));
    let dish_lot = lots.iter().find(|lot| lot["kind"] == "dish").unwrap();
    assert_eq!(dish_lot["expires_on"], json!(today + Duration::days(2)));

    let (status, cleared) = set_expiry(&app, &alice, &stale, None).await;
    assert_eq!(status, StatusCode::OK);
    assert!(cleared["expires_on"].is_null());
    assert_eq!(cleared["is_expired"], false);
}

#[sqlx::test(migrations = "./migrations")]
async fn expired_lots_are_written_off_once_and_announced_to_the_store(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let carol = app.user("carol@example.com").await;
    let fam = app.family(&alice, "Дом").await;
    app.join(&alice, &bob, &fam, "standard").await;
    settings(&app, &alice, json!({ "lang": "ru", "tz": "UTC", "is_expiring": false })).await;
    settings(&app, &bob, json!({ "is_expiring": false })).await;
    settings(&app, &carol, json!({ "is_expired": true })).await;

    let today = Utc::now().date_naive();
    let uah = app.currency_by_code(&alice.token, "UAH").await;
    let milk = item(&app, &alice, "Молоко").await;
    let cheese = item(&app, &alice, "Сыр").await;
    let personal = lot(
        &app,
        &alice,
        json!({ "item_id": milk, "qty": "1000", "unit": "g", "cost": "50", "curr_id": uah, "is_personal": true,
                "acquired_on": today - Duration::days(3), "expires_on": today }),
    )
    .await;
    let shared = lot(
        &app,
        &alice,
        json!({ "item_id": cheese, "qty": "200", "unit": "g", "family_id": fam, "expires_on": today }),
    )
    .await;
    let mark = meal_mark(&app, &alice).await;
    let entry = eat(&app, &alice, &mark, &milk, "400").await;

    let before = at(today, 23, 59);
    assert_eq!(worker::run_tick(&app.state, before).await.unwrap().expired_lots, 0);
    let after = at(today + Duration::days(1), 0, 1);
    let report = worker::run_tick(&app.state, after).await.unwrap();
    assert_eq!(report.expired_lots, 2);
    assert_eq!(worker::run_tick(&app.state, after).await.unwrap().expired_lots, 0);

    let lots = stock_lots(&app, &alice, "?is_personal=true").await;
    assert_eq!(left_of(&lots, &personal["id"]), None);
    let (_, waste) = send(
        &app,
        &alice,
        Method::GET,
        "/api/stock/moves?kind=waste&is_personal=true",
        None,
    )
    .await;
    assert_eq!(waste["waste_g"], "600");
    assert_eq!(waste["waste_costs"], json!([{ "curr_code": "UAH", "amount": "30.00" }]));
    assert_eq!(waste["moves"][0]["reason"], "expired");
    assert!(waste["moves"][0]["actor_name"].is_null());

    let alice_inbox = inbox(&app, &alice).await;
    assert_eq!(alice_inbox["unread"], 2);
    let titles: Vec<&str> = alice_inbox["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|note| note["title"].as_str().unwrap())
        .collect();
    assert_eq!(titles, ["Списано по сроку годности", "Списано по сроку годности"]);
    let bodies: Vec<&str> = alice_inbox["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|note| note["body"].as_str().unwrap())
        .collect();
    assert!(bodies.contains(&"Молоко 600 г"), "{bodies:?}");
    assert!(bodies.contains(&"Дом: Сыр 200 г"), "{bodies:?}");
    assert_eq!(alice_inbox["items"][0]["link"], "/app/stock/history");
    assert_eq!(alice_inbox["items"][0]["kind"], "expired");

    let bob_inbox = inbox(&app, &bob).await;
    assert_eq!(bob_inbox["unread"], 1);
    assert_eq!(bob_inbox["items"][0]["title"], "Written off as expired");
    assert_eq!(bob_inbox["items"][0]["params"]["items"][0]["title"], "Сыр");
    assert_eq!(inbox(&app, &carol).await["unread"], 0);

    let alice_ids: Vec<Value> = alice_inbox["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|note| note["id"].clone())
        .collect();
    let (status, _) = send(
        &app,
        &carol,
        Method::POST,
        "/api/notifications/read",
        Some(json!({ "ids": alice_ids })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(inbox(&app, &alice).await["unread"], 2);
    let (status, _) = send(
        &app,
        &alice,
        Method::POST,
        "/api/notifications/read",
        Some(json!({ "ids": [alice_ids[0]] })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(inbox(&app, &alice).await["unread"], 1);
    let (status, _) = send(
        &app,
        &alice,
        Method::POST,
        "/api/notifications/read",
        Some(json!({ "is_all": true })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(inbox(&app, &alice).await["unread"], 0);
    let (status, _) = send(&app, &alice, Method::POST, "/api/notifications/read", Some(json!({}))).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, _) = send(
        &app,
        &alice,
        Method::DELETE,
        &format!("/api/nutrition/entries/{}", entry["id"].as_str().unwrap()),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(worker::run_tick(&app.state, after).await.unwrap().expired_lots, 1);
    let (_, waste) = send(
        &app,
        &alice,
        Method::GET,
        "/api/stock/moves?kind=waste&is_personal=true",
        None,
    )
    .await;
    assert_eq!(waste["waste_g"], "1000");
    assert_eq!(inbox(&app, &alice).await["items"].as_array().unwrap().len(), 2);
    let _ = shared;
}

#[sqlx::test(migrations = "./migrations")]
async fn expiring_stock_is_announced_once_from_nine_in_the_store_zone(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let fam = app.family(&alice, "Дом").await;
    app.join(&alice, &bob, &fam, "standard").await;
    settings(&app, &alice, json!({ "lang": "ru", "tz": "UTC" })).await;
    settings(&app, &bob, json!({ "is_expiring": false })).await;

    let today = Utc::now().date_naive();
    let tomorrow = today + Duration::days(1);
    let kefir = item(&app, &alice, "Кефир").await;
    let bread = item(&app, &alice, "Хлеб").await;
    lot(
        &app,
        &alice,
        json!({ "item_id": kefir, "qty": "500", "unit": "g", "family_id": fam, "expires_on": tomorrow }),
    )
    .await;
    lot(
        &app,
        &alice,
        json!({ "item_id": bread, "qty": "300", "unit": "g", "family_id": fam, "expires_on": tomorrow }),
    )
    .await;
    lot(
        &app,
        &alice,
        json!({ "item_id": bread, "qty": "100", "unit": "g", "family_id": fam, "expires_on": today + Duration::days(5) }),
    )
    .await;
    lot(
        &app,
        &alice,
        json!({ "item_id": kefir, "qty": "250", "unit": "g", "is_personal": true, "expires_on": today }),
    )
    .await;

    let (status, feed) = send(&app, &alice, Method::GET, "/api/notifications/upcoming?hours=72", None).await;
    assert_eq!(status, StatusCode::OK, "{feed}");
    let kinds: Vec<(&str, &str)> = feed
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| (entry["kind"].as_str().unwrap(), entry["due_ts"].as_str().unwrap()))
        .collect();
    let expected_expired = at(today + Duration::days(2), 0, 0).to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    assert!(kinds.contains(&("expired", expected_expired.as_str())), "{kinds:?}");
    let (_, bob_feed) = send(&app, &bob, Method::GET, "/api/notifications/upcoming", None).await;
    assert!(bob_feed
        .as_array()
        .unwrap()
        .iter()
        .all(|entry| entry["kind"] != "expiring"));

    assert_eq!(
        worker::run_tick(&app.state, at(today, 8, 59))
            .await
            .unwrap()
            .warned_lots,
        1
    );
    assert_eq!(
        worker::run_tick(&app.state, at(today, 9, 1)).await.unwrap().warned_lots,
        2
    );
    assert_eq!(
        worker::run_tick(&app.state, at(today, 9, 2)).await.unwrap().warned_lots,
        0
    );

    let alice_inbox = inbox(&app, &alice).await;
    let notes = alice_inbox["items"].as_array().unwrap();
    assert_eq!(notes.len(), 2);
    let today_note = notes.iter().find(|note| note["params"]["day"] == "today").unwrap();
    assert_eq!(today_note["title"], "Истекает сегодня");
    assert_eq!(today_note["body"], "Кефир 250 г");
    let note = notes.iter().find(|note| note["params"]["day"] == "tomorrow").unwrap();
    assert_eq!(note["kind"], "expiring");
    assert_eq!(note["title"], "Истекает завтра");
    assert_eq!(note["body"], "Дом: Кефир 500 г, Хлеб 300 г");
    assert_eq!(note["params"]["day"], "tomorrow");
    assert_eq!(note["link"], "/app/stock");
    assert_eq!(inbox(&app, &bob).await["items"].as_array().unwrap().len(), 0);
}

async fn plan_event(a_app: &TestApp, a_user: &TestUser, a_body: Value) -> String
{
    let (status, event) = send(a_app, a_user, Method::POST, "/api/plan/events", Some(a_body)).await;
    assert_eq!(status, StatusCode::CREATED, "{event}");
    event["id"].as_str().unwrap().to_string()
}

#[sqlx::test(migrations = "./migrations")]
async fn planner_reminders_fire_once_inside_the_lead_time(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let saved = settings(
        &app,
        &alice,
        json!({ "lang": "ru", "tz": "Europe/Kyiv", "plan_lead_min": 20 }),
    )
    .await;
    assert_eq!(saved["plan_lead_min"], 20);
    assert_eq!(saved["workout_lead_min"], 60);
    assert_eq!(saved["is_web_push"], false);

    let later = Utc::now() + Duration::hours(3);
    let start = later.date_naive().and_hms_opt(later.hour(), 0, 0).unwrap().and_utc();
    plan_event(
        &app,
        &alice,
        json!({ "title": "Созвон", "timing": "fixed", "start_date": start.date_naive(),
                "start_time": start.time(), "duration_min": 30, "tz": "UTC" }),
    )
    .await;

    let (status, feed) = send(&app, &alice, Method::GET, "/api/notifications/upcoming", None).await;
    assert_eq!(status, StatusCode::OK);
    let reminder = feed
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["kind"] == "plan")
        .unwrap();
    assert_eq!(
        reminder["due_ts"].as_str().unwrap(),
        (start - Duration::minutes(20)).to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
    );
    assert_eq!(reminder["title"], "Созвон");

    assert_eq!(
        worker::run_tick(&app.state, start - Duration::minutes(25))
            .await
            .unwrap()
            .reminders,
        0
    );
    assert_eq!(
        worker::run_tick(&app.state, start - Duration::minutes(19))
            .await
            .unwrap()
            .reminders,
        1
    );
    assert_eq!(
        worker::run_tick(&app.state, start - Duration::minutes(18))
            .await
            .unwrap()
            .reminders,
        0
    );
    let notes = inbox(&app, &alice).await;
    assert_eq!(notes["items"].as_array().unwrap().len(), 1);
    assert_eq!(notes["items"][0]["kind"], "plan");
    assert_eq!(notes["items"][0]["link"], "/app/planner");
    let local = start
        .with_timezone(&chrono_tz::Europe::Kyiv)
        .format("%H:%M")
        .to_string();
    assert_eq!(notes["items"][0]["body"], format!("Начало в {local}"));

    settings(&app, &alice, json!({ "is_plan": false })).await;
    plan_event(
        &app,
        &alice,
        json!({ "title": "Обед", "timing": "fixed", "start_date": start.date_naive(),
                "start_time": (start + Duration::minutes(30)).time(), "duration_min": 30, "tz": "UTC" }),
    )
    .await;
    assert_eq!(
        worker::run_tick(&app.state, start + Duration::minutes(15))
            .await
            .unwrap()
            .reminders,
        0
    );

    let (status, _) = send(
        &app,
        &alice,
        Method::PUT,
        "/api/notifications/settings",
        Some(json!({ "tz": "Mars/Base" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    for body in [
        json!({ "lang": "xx" }),
        json!({ "plan_lead_min": 2000 }),
        json!({ "workout_lead_min": -1 }),
    ]
    {
        let (status, _) = send(&app, &alice, Method::PUT, "/api/notifications/settings", Some(body)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
}

#[derive(Clone, Default)]
struct PushMock
{
    calls: Arc<Mutex<Vec<(String, HeaderMap, Bytes)>>>,
}

async fn push_endpoint(
    State(a_mock): State<PushMock>,
    Path((a_mode, a_id)): Path<(String, String)>,
    a_headers: HeaderMap,
    a_body: Bytes,
) -> StatusCode
{
    a_mock
        .calls
        .lock()
        .unwrap()
        .push((format!("{a_mode}/{a_id}"), a_headers, a_body));
    match a_mode.as_str()
    {
        "ok" => StatusCode::CREATED,
        "gone" => StatusCode::GONE,
        _ => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

async fn spawn_push() -> (String, PushMock)
{
    let mock = PushMock::default();
    let router = Router::new()
        .route("/:mode/:id", post(push_endpoint))
        .with_state(mock.clone());
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    (format!("http://{addr}"), mock)
}

struct Len(usize);

impl hkdf::KeyType for Len
{
    fn len(&self) -> usize
    {
        self.0
    }
}

fn hkdf_expand(a_salt: &[u8], a_ikm: &[u8], a_info: &[u8], a_len: usize) -> Vec<u8>
{
    let prk = hkdf::Salt::new(hkdf::HKDF_SHA256, a_salt).extract(a_ikm);
    let info = [a_info];
    let mut out = vec![0u8; a_len];
    prk.expand(&info, Len(a_len)).unwrap().fill(&mut out).unwrap();
    out
}

fn browser_decrypt(a_body: &[u8], a_key: agreement::EphemeralPrivateKey, a_public: &[u8], a_auth: &[u8]) -> Value
{
    let salt = &a_body[..16];
    assert_eq!(u32::from_be_bytes(a_body[16..20].try_into().unwrap()), 4096);
    let key_len = usize::from(a_body[20]);
    let sender_public = &a_body[21..21 + key_len];
    let mut record = a_body[21 + key_len..].to_vec();
    let shared = agreement::agree_ephemeral(
        a_key,
        &agreement::UnparsedPublicKey::new(&agreement::ECDH_P256, sender_public),
        |secret| secret.to_vec(),
    )
    .unwrap();
    let mut info = b"WebPush: info\0".to_vec();
    info.extend_from_slice(a_public);
    info.extend_from_slice(sender_public);
    let ikm = hkdf_expand(a_auth, &shared, &info, 32);
    let cek = hkdf_expand(salt, &ikm, b"Content-Encoding: aes128gcm\0", 16);
    let nonce = hkdf_expand(salt, &ikm, b"Content-Encoding: nonce\0", 12);
    let key = aead::LessSafeKey::new(aead::UnboundKey::new(&aead::AES_128_GCM, &cek).unwrap());
    let plain = key
        .open_in_place(
            aead::Nonce::try_assume_unique_for_key(&nonce).unwrap(),
            aead::Aad::empty(),
            &mut record,
        )
        .unwrap();
    assert_eq!(plain.last(), Some(&2));
    serde_json::from_slice(&plain[..plain.len() - 1]).unwrap()
}

async fn add_notice(a_app: &TestApp, a_user: &TestUser, a_key: &str) -> Uuid
{
    sqlx::query_scalar!(
        r#"
        INSERT INTO notifications (user_id, kind, dedup_key, title, body, link)
        VALUES ($1, 'plan', $2, 'Созвон', 'Начало в 10:00', '/app/planner')
        RETURNING id
        "#,
        a_user.id,
        a_key
    )
    .fetch_one(&a_app.state.db)
    .await
    .unwrap()
}

async fn push_state(a_app: &TestApp, a_id: Uuid) -> String
{
    sqlx::query_scalar!(
        r#"SELECT push_state::text AS "state!" FROM notifications WHERE id = $1"#,
        a_id
    )
    .fetch_one(&a_app.state.db)
    .await
    .unwrap()
}

#[sqlx::test(migrations = "./migrations")]
async fn web_push_is_encrypted_signed_and_sent_once(a_db: PgPool)
{
    let (base, mock) = spawn_push().await;
    let (public, private) = generate_vapid().unwrap();
    let vapid = VapidKeys::from_base64(&public, &private, "mailto:admin@example.com").unwrap();
    let app = TestApp::with_push(a_db, push_config(Some(vapid), &["127.0.0.1"]));
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;

    let (status, key) = send(&app, &alice, Method::GET, "/api/notifications/push-key", None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(key["public_key"], public);

    let rng = SystemRandom::new();
    let browser = agreement::EphemeralPrivateKey::generate(&agreement::ECDH_P256, &rng).unwrap();
    let browser_public = browser.compute_public_key().unwrap().as_ref().to_vec();
    let mut auth = [0u8; 16];
    rng.fill(&mut auth).unwrap();
    let subscription = |a_endpoint: String| {
        json!({ "endpoint": a_endpoint, "p256dh": URL_SAFE_NO_PAD.encode(&browser_public),
                "auth": URL_SAFE_NO_PAD.encode(auth) })
    };
    for (body, field) in [
        (subscription("https://evil.example.com/push/1".into()), "endpoint"),
        (subscription("http://10.0.0.1/push/1".into()), "endpoint"),
        (
            json!({ "endpoint": format!("{base}/ok/1"), "p256dh": "AAAA", "auth": "AAAA" }),
            "keys",
        ),
    ]
    {
        let (status, reply) = send(&app, &alice, Method::POST, "/api/notifications/push-subs", Some(body)).await;
        assert_eq!(
            (status, reply["field"].as_str()),
            (StatusCode::BAD_REQUEST, Some(field))
        );
    }
    for path in ["ok/1", "gone/2"]
    {
        let (status, reply) = send(
            &app,
            &alice,
            Method::POST,
            "/api/notifications/push-subs",
            Some(subscription(format!("{base}/{path}"))),
        )
        .await;
        assert_eq!(status, StatusCode::NO_CONTENT, "{reply}");
    }
    let sealed: Vec<Vec<u8>> = sqlx::query_scalar!("SELECT sealed FROM push_subs")
        .fetch_all(&app.state.db)
        .await
        .unwrap();
    assert!(sealed
        .iter()
        .all(|blob| !String::from_utf8_lossy(blob).contains("127.0.0.1")));

    let first = add_notice(&app, &alice, "plan:first").await;
    assert_eq!(sender::deliver(&app.state, Utc::now()).await.unwrap(), 1);
    assert_eq!(push_state(&app, first).await, "sent");
    let calls = mock.calls.lock().unwrap().clone();
    assert_eq!(calls.len(), 2);
    let (path, headers, body) = calls.iter().find(|(path, _, _)| path == "ok/1").unwrap();
    assert_eq!(path, "ok/1");
    assert_eq!(headers["content-encoding"], "aes128gcm");
    assert_eq!(headers["urgency"], "high");
    assert_eq!(headers["topic"], first.simple().to_string().as_str());
    assert_eq!(headers["ttl"], "3600");
    let authorization = headers["authorization"].to_str().unwrap();
    let (token, key_part) = authorization
        .strip_prefix("vapid t=")
        .unwrap()
        .split_once(", k=")
        .unwrap();
    assert_eq!(key_part, public);
    let (signing_input, signature_b64) = token.rsplit_once('.').unwrap();
    signature::UnparsedPublicKey::new(
        &signature::ECDSA_P256_SHA256_FIXED,
        URL_SAFE_NO_PAD.decode(&public).unwrap(),
    )
    .verify(
        signing_input.as_bytes(),
        &URL_SAFE_NO_PAD.decode(signature_b64).unwrap(),
    )
    .unwrap();
    let claims: Value = serde_json::from_slice(
        &URL_SAFE_NO_PAD
            .decode(signing_input.split('.').nth(1).unwrap())
            .unwrap(),
    )
    .unwrap();
    assert_eq!(claims["aud"], base);
    let payload = browser_decrypt(body, browser, &browser_public, &auth);
    assert_eq!(payload["title"], "Созвон");
    assert_eq!(payload["body"], "Начало в 10:00");
    assert_eq!(payload["link"], "/app/planner");
    assert_eq!(payload["tag"], first.to_string());

    let subs: i64 = sqlx::query_scalar!(r#"SELECT COUNT(*) AS "count!" FROM push_subs"#)
        .fetch_one(&app.state.db)
        .await
        .unwrap();
    assert_eq!(subs, 1);
    assert_eq!(sender::deliver(&app.state, Utc::now()).await.unwrap(), 0);
    assert_eq!(mock.calls.lock().unwrap().len(), 2);

    let stuck = add_notice(&app, &alice, "plan:stuck").await;
    sqlx::query!(
        "UPDATE notifications SET push_state = 'sending', push_ts = NOW() - INTERVAL '10 minutes' WHERE id = $1",
        stuck
    )
    .execute(&app.state.db)
    .await
    .unwrap();
    assert_eq!(sender::deliver(&app.state, Utc::now()).await.unwrap(), 1);
    assert_eq!(push_state(&app, stuck).await, "sent");
    let resent = mock.calls.lock().unwrap().last().unwrap().1["topic"].clone();
    assert_eq!(resent, stuck.simple().to_string().as_str());

    let old = add_notice(&app, &alice, "plan:old").await;
    sqlx::query!(
        "UPDATE notifications SET created_ts = NOW() - INTERVAL '1 day' WHERE id = $1",
        old
    )
    .execute(&app.state.db)
    .await
    .unwrap();
    let calls_before = mock.calls.lock().unwrap().len();
    sender::deliver(&app.state, Utc::now()).await.unwrap();
    assert_eq!(push_state(&app, old).await, "skipped");
    assert_eq!(mock.calls.lock().unwrap().len(), calls_before);

    let (status, _) = send(
        &app,
        &bob,
        Method::POST,
        "/api/notifications/push-subs/remove",
        Some(json!({ "endpoint": format!("{base}/ok/1") })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, alice_settings) = send(&app, &alice, Method::GET, "/api/notifications/settings", None).await;
    assert_eq!(alice_settings["push_subs"], 1);
    assert_eq!(alice_settings["is_web_push"], true);
    let (status, _) = send(
        &app,
        &alice,
        Method::POST,
        "/api/notifications/push-subs/remove",
        Some(json!({ "endpoint": format!("{base}/ok/1") })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _) = send(
        &app,
        &bob,
        Method::POST,
        "/api/notifications/push-subs",
        Some(subscription(format!("{base}/fail/3"))),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let failing = add_notice(&app, &bob, "plan:failing").await;
    for expected in ["pending", "pending", "failed"]
    {
        sender::deliver(&app.state, Utc::now()).await.unwrap();
        assert_eq!(push_state(&app, failing).await, expected);
    }
    let lonely = add_notice(&app, &alice, "plan:lonely").await;
    sender::deliver(&app.state, Utc::now()).await.unwrap();
    assert_eq!(push_state(&app, lonely).await, "skipped");
}

#[sqlx::test(migrations = "./migrations")]
async fn push_subscriptions_need_server_keys(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let (status, key) = send(&app, &alice, Method::GET, "/api/notifications/push-key", None).await;
    assert_eq!(status, StatusCode::OK);
    assert!(key["public_key"].is_null());
    let (status, reply) = send(
        &app,
        &alice,
        Method::POST,
        "/api/notifications/push-subs",
        Some(json!({ "endpoint": "https://fcm.googleapis.com/fcm/send/x", "p256dh": "AAAA", "auth": "AAAA" })),
    )
    .await;
    assert_eq!(
        (status, reply["code"].as_str()),
        (StatusCode::CONFLICT, Some("PUSH_UNAVAILABLE"))
    );
    let note = add_notice(&app, &alice, "plan:quiet").await;
    sender::deliver(&app.state, Utc::now()).await.unwrap();
    assert_eq!(push_state(&app, note).await, "skipped");
    assert_eq!(inbox(&app, &alice).await["unread"], 1);
}
