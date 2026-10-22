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

#[sqlx::test(migrations = "./migrations")]
async fn meals_rise_over_their_block_and_gym_blocks_burn(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
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

    let day = (Utc::now() - Duration::days(1)).date_naive();
    let midnight = day.and_time(NaiveTime::MIN).and_utc();
    let lunch = midnight + Duration::hours(13);
    let (status, mark) = send(
        &app,
        &alice,
        Method::POST,
        "/api/routine/marks",
        Some(json!({ "status": "meal", "start_ts": ts(lunch), "end_ts": ts(lunch + Duration::minutes(30)) })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{mark}");
    let (status, entry) = send(
        &app,
        &alice,
        Method::POST,
        "/api/nutrition/entries",
        Some(json!({ "date": day, "status_mark_id": mark["id"], "quick": { "title": "Обед", "kcal": "500" } })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{entry}");
    let gym = midnight + Duration::hours(18);
    let (status, mark) = send(
        &app,
        &alice,
        Method::POST,
        "/api/routine/marks",
        Some(json!({ "status": "gym", "start_ts": ts(gym), "end_ts": ts(gym + Duration::hours(1)) })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{mark}");

    let (status, body) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/energy/day?date={day}&tz=UTC"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let mine = me(&body);
    let burn: f64 = mine["daily_burn"].as_str().unwrap().parse().unwrap();
    let points = mine["points"].as_array().unwrap();
    let at = |a_ts: DateTime<Utc>| -> Vec<f64> {
        points
            .iter()
            .filter(|point| point["ts"] == ts(a_ts))
            .map(|point| point["kcal"].as_f64().unwrap())
            .collect()
    };
    let before = at(lunch);
    let after = at(lunch + Duration::minutes(30));
    assert_eq!(before.len(), 1, "{mine}");
    assert_eq!(after.len(), 1, "{mine}");
    assert!((before[0] + burn * 13.0 / 24.0).abs() <= 1.0, "{mine}");
    assert!((after[0] - before[0] - (500.0 - burn / 48.0)).abs() <= 1.0, "{mine}");
    assert_eq!(mine["eaten"], 500);
    assert_eq!(mine["burned_workouts"], 240);
    assert_eq!(at(gym).len(), 1);
    let gym_end = at(gym + Duration::hours(1));
    assert!((at(gym)[0] - gym_end[0] - (240.0 + burn / 24.0)).abs() <= 1.0, "{mine}");

    let late = midnight - Duration::minutes(20);
    let (status, mark) = send(
        &app,
        &alice,
        Method::POST,
        "/api/routine/marks",
        Some(json!({ "status": "meal", "start_ts": ts(late), "end_ts": ts(late + Duration::minutes(40)) })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{mark}");
    send(
        &app,
        &alice,
        Method::POST,
        "/api/nutrition/entries",
        Some(json!({ "date": day, "status_mark_id": mark["id"], "quick": { "title": "Ужин", "kcal": "600" } })),
    )
    .await;
    let (_, one) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/energy/day?date={day}&tz=UTC"),
        None,
    )
    .await;
    let (_, two) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/energy/day?date={day}&tz=UTC&days=2"),
        None,
    )
    .await;
    let (one, two) = (me(&one), me(&two));
    assert_eq!(one["eaten"], 800, "{one}");
    assert_eq!(two["eaten"], 1100, "{two}");
    assert!(
        (one["start_kcal"].as_f64().unwrap() - (300.0 - burn)).abs() <= 1.0,
        "{one}"
    );
    assert!((one["balance"].as_f64().unwrap() - two["balance"].as_f64().unwrap()).abs() <= 1.0);
}
