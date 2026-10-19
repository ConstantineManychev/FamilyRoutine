mod common;

use axum::http::{Method, StatusCode};
use chrono::{DateTime, Duration, NaiveTime, SecondsFormat, Utc};
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

fn ts(a_value: DateTime<Utc>) -> String
{
    a_value.to_rfc3339_opts(SecondsFormat::Secs, true)
}

async fn meal(a_app: &TestApp, a_user: &TestUser, a_start: DateTime<Utc>, a_kcal: &str)
{
    let (status, mark) = send(
        a_app,
        a_user,
        Method::POST,
        "/api/routine/marks",
        Some(json!({ "status": "meal", "start_ts": ts(a_start), "end_ts": ts(a_start + Duration::minutes(20)) })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{mark}");
    let (status, entry) = send(
        a_app,
        a_user,
        Method::POST,
        "/api/nutrition/entries",
        Some(json!({
            "date": a_start.date_naive(), "status_mark_id": mark["id"],
            "quick": { "title": "Обед", "kcal": a_kcal }
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{entry}");
}

fn me(a_day: &Value) -> Value
{
    a_day["people"]
        .as_array()
        .unwrap()
        .iter()
        .find(|person| person["is_me"] == true)
        .cloned()
        .unwrap()
}

#[sqlx::test(migrations = "./migrations")]
async fn balance_carries_over_midnight_and_corrections_reset_it(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let eve = app.user("eve@example.com").await;
    let home = app.family(&alice, "Дом").await;
    app.join(&alice, &bob, &home, "standard").await;
    let id = alice.id.to_string();
    let (status, profile) = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/people/{id}"),
        Some(
            json!({ "first_name": "Alice", "last_name": "Smith", "birth_date": "1990-05-17",
                     "sex": "female", "activity": "light" }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{profile}");
    let (status, entry) = send(
        &app,
        &alice,
        Method::POST,
        &format!("/api/people/{id}/entries"),
        Some(json!({ "measured_ts": ts(Utc::now() - Duration::days(3)),
                     "values": [{ "metric": "weight", "value": "60" }, { "metric": "height", "value": "168" }] })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{entry}");

    let today = Utc::now().date_naive();
    let today_start = today.and_time(NaiveTime::MIN).and_utc();
    meal(&app, &alice, today_start - Duration::hours(12), "1000").await;

    let (status, one_day) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/energy/day?date={today}&tz=UTC"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{one_day}");
    let mine = me(&one_day);
    let burn: f64 = mine["daily_burn"].as_str().unwrap().parse().unwrap();
    assert!(burn > 1000.0);
    let carried = 1000.0 - burn;
    assert!((mine["start_kcal"].as_f64().unwrap() - carried).abs() <= 1.0, "{mine}");
    assert!(
        (mine["points"][0]["kcal"].as_f64().unwrap() - carried).abs() <= 1.0,
        "{mine}"
    );
    assert_eq!(mine["points"][0]["ts"], ts(today_start));
    assert_eq!(mine["eaten"], 0);

    let (status, two_days) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/energy/day?date={today}&tz=UTC&days=2"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{two_days}");
    assert_eq!(two_days["days"], 2);
    let both = me(&two_days);
    assert_eq!(both["start_kcal"], 0);
    assert_eq!(both["eaten"], 1000);
    assert_eq!(both["points"][0]["ts"], ts(today_start - Duration::days(1)));
    assert!((both["balance"].as_f64().unwrap() - mine["balance"].as_f64().unwrap()).abs() <= 1.0);

    let mark_ts = Utc::now() - Duration::hours(1);
    let (status, mark) = send(
        &app,
        &alice,
        Method::POST,
        "/api/energy/marks",
        Some(json!({ "ts": ts(mark_ts), "kcal": "200" })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{mark}");
    assert_eq!(mark["kcal"], 200.0);
    let (_, corrected) = send(
        &app,
        &bob,
        Method::GET,
        &format!("/api/energy/day?date={today}&tz=UTC"),
        None,
    )
    .await;
    let alice_row = corrected["people"]
        .as_array()
        .unwrap()
        .iter()
        .find(|person| person["person_id"] == id.as_str())
        .cloned()
        .unwrap();
    assert_eq!(alice_row["marks"].as_array().unwrap().len(), 1);
    assert!(alice_row["points"]
        .as_array()
        .unwrap()
        .iter()
        .any(|point| point["kcal"] == 200.0));
    let expected = 200.0 - burn / 24.0;
    assert!(
        (alice_row["balance"].as_f64().unwrap() - expected).abs() <= 3.0,
        "{alice_row}"
    );

    let (status, _) = send(
        &app,
        &bob,
        Method::POST,
        "/api/energy/marks",
        Some(json!({ "person_id": id, "ts": ts(mark_ts), "kcal": "0" })),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = send(
        &app,
        &eve,
        Method::POST,
        "/api/energy/marks",
        Some(json!({ "person_id": id, "ts": ts(mark_ts), "kcal": "0" })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = send(
        &app,
        &alice,
        Method::POST,
        "/api/energy/marks",
        Some(json!({ "ts": ts(Utc::now() + Duration::days(1)), "kcal": "0" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let mark_id = mark["id"].as_str().unwrap();
    let (status, _) = send(
        &app,
        &bob,
        Method::DELETE,
        &format!("/api/energy/marks/{mark_id}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = send(
        &app,
        &alice,
        Method::DELETE,
        &format!("/api/energy/marks/{mark_id}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, restored) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/energy/day?date={today}&tz=UTC"),
        None,
    )
    .await;
    assert!(me(&restored)["marks"].as_array().unwrap().is_empty());

    let (status, _) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/energy/day?date={today}&tz=UTC&days=32"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}
