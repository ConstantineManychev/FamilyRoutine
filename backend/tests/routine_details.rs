mod common;

use axum::http::{Method, StatusCode};
use chrono::{DateTime, Duration, DurationRound, SecondsFormat, Utc};
use common::{TestApp, TestUser};
use serde_json::{json, Value};
use sqlx::PgPool;

fn iso(a_ts: DateTime<Utc>) -> String
{
    a_ts.to_rfc3339_opts(SecondsFormat::Secs, true)
}

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

async fn mark(
    a_app: &TestApp,
    a_user: &TestUser,
    a_status: &str,
    a_start: DateTime<Utc>,
    a_end: Option<DateTime<Utc>>,
) -> String
{
    let (status, body) = send(
        a_app,
        a_user,
        Method::POST,
        "/api/routine/marks",
        Some(json!({ "status": a_status, "start_ts": iso(a_start), "end_ts": a_end.map(iso) })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    body["id"].as_str().unwrap().to_string()
}

async fn details(a_app: &TestApp, a_user: &TestUser, a_id: &str) -> (StatusCode, Value)
{
    send(a_app, a_user, Method::GET, &format!("/api/routine/marks/{a_id}"), None).await
}

async fn edit(a_app: &TestApp, a_user: &TestUser, a_id: &str, a_body: Value) -> (StatusCode, Value)
{
    send(
        a_app,
        a_user,
        Method::PUT,
        &format!("/api/routine/marks/{a_id}"),
        Some(a_body),
    )
    .await
}

#[sqlx::test(migrations = "./migrations")]
async fn blocks_can_be_retyped_rescheduled_and_opened(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let eve = app.user("eve@example.com").await;
    let home = app.family(&alice, "Home").await;
    app.join(&alice, &bob, &home, "standard").await;
    let base = Utc::now().duration_trunc(Duration::minutes(1)).unwrap() - Duration::hours(10);

    let work = mark(&app, &alice, "work", base, Some(base + Duration::hours(3))).await;
    let meal = mark(
        &app,
        &alice,
        "meal",
        base + Duration::hours(3),
        Some(base + Duration::minutes(210)),
    )
    .await;
    let leisure = mark(
        &app,
        &alice,
        "leisure",
        base + Duration::hours(4),
        Some(base + Duration::hours(5)),
    )
    .await;
    let second_meal = mark(
        &app,
        &alice,
        "meal",
        base + Duration::hours(5),
        Some(base + Duration::minutes(330)),
    )
    .await;
    let current = mark(&app, &alice, "home", Utc::now() - Duration::minutes(10), None).await;
    let (_, now_mark) = send(&app, &alice, Method::GET, "/api/routine/current", None).await;
    assert_eq!(now_mark["id"], current.as_str());
    assert_eq!(now_mark["status"], "home");

    let (status, retyped) = edit(&app, &alice, &work, json!({ "status": "school", "note": "Курс" })).await;
    assert_eq!(status, StatusCode::OK, "{retyped}");
    assert_eq!(retyped["status"], "school");
    assert_eq!(retyped["start_ts"], iso(base).replace("+00:00", "Z"));

    let (status, longer) = edit(
        &app,
        &alice,
        &meal,
        json!({ "status": "meal", "end_ts": iso(base + Duration::minutes(270)) }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{longer}");
    let (_, pushed) = details(&app, &alice, &leisure).await;
    assert_eq!(
        pushed["mark"]["start_ts"].as_str().unwrap(),
        iso(base + Duration::minutes(270)).replace("+00:00", "Z")
    );
    let (status, overlap) = edit(
        &app,
        &alice,
        &meal,
        json!({ "status": "meal", "end_ts": iso(base + Duration::hours(6)) }),
    )
    .await;
    assert_eq!(
        (status, overlap["code"].as_str()),
        (StatusCode::CONFLICT, Some("MARK_OVERLAP"))
    );
    let (status, earlier) = edit(
        &app,
        &alice,
        &meal,
        json!({ "status": "meal", "start_ts": iso(base + Duration::minutes(150)) }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{earlier}");
    let (_, trimmed) = details(&app, &alice, &work).await;
    assert_eq!(
        trimmed["mark"]["end_ts"].as_str().unwrap(),
        iso(base + Duration::minutes(150)).replace("+00:00", "Z")
    );

    let (status, item) = send(
        &app,
        &alice,
        Method::POST,
        "/api/dicts/items",
        Some(json!({ "name": "Гречка", "kind": "food", "unit": "kilogram", "nutrition": { "kcal": "343", "prot": "13" } })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{item}");
    let today = Utc::now().date_naive();
    let (status, linked) = send(
        &app,
        &alice,
        Method::POST,
        "/api/nutrition/entries",
        Some(json!({ "date": today, "item_id": item["id"], "grams": "100", "status_mark_id": meal })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{linked}");
    assert_eq!(linked["status_mark_id"], meal.as_str());
    let (_, loose) = send(
        &app,
        &alice,
        Method::POST,
        "/api/nutrition/entries",
        Some(json!({ "date": today, "quick": { "title": "Кофе", "kcal": "60" }, "status_mark_id": second_meal })),
    )
    .await;
    assert_eq!(
        send(
            &app,
            &alice,
            Method::POST,
            "/api/nutrition/entries",
            Some(json!({ "date": today, "quick": { "kcal": "10" }, "status_mark_id": leisure }))
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );

    let (_, meal_details) = details(&app, &alice, &meal).await;
    assert_eq!(meal_details["is_mine"], true);
    assert_eq!(meal_details["meals"]["entries"].as_array().unwrap().len(), 1);
    assert_eq!(meal_details["meals"]["total"]["kcal"], "343");
    let (status, relinked) = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/routine/marks/{meal}/meal-entries"),
        Some(json!({ "entry_ids": [linked["id"], loose["id"]] })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{relinked}");
    assert_eq!(relinked["meals"]["total"]["kcal"], "403");

    let (_, bob_meal) = details(&app, &bob, &meal).await;
    assert_eq!(bob_meal["is_mine"], false);
    assert_eq!(bob_meal["can_edit"], false);
    assert_eq!(bob_meal["is_details_hidden"], false);
    assert_eq!(bob_meal["meals"]["entries"].as_array().unwrap().len(), 2);
    let (_, bob_work) = details(&app, &bob, &work).await;
    assert_eq!(bob_work["is_details_hidden"], true);
    assert_eq!(bob_work["mark"]["status"], "school");
    assert_eq!(details(&app, &eve, &meal).await.0, StatusCode::NOT_FOUND);
    assert_eq!(
        edit(&app, &bob, &meal, json!({ "status": "work" })).await.0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        send(
            &app,
            &bob,
            Method::PUT,
            &format!("/api/routine/marks/{meal}/meal-entries"),
            Some(json!({ "entry_ids": [] }))
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );

    let (status, _) = edit(&app, &alice, &meal, json!({ "status": "leisure" })).await;
    assert_eq!(status, StatusCode::OK);
    let (_, day) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/nutrition/day?date={today}"),
        None,
    )
    .await;
    let still_linked = day["meals"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|group| group["entries"].as_array().unwrap())
        .filter(|entry| !entry["status_mark_id"].is_null())
        .count();
    assert_eq!(still_linked, 0);
}

#[sqlx::test(migrations = "./migrations")]
async fn workout_blocks_show_the_session_to_allowed_members(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let home = app.family(&alice, "Home").await;
    app.join(&alice, &bob, &home, "standard").await;

    let (_, exercises) = send(&app, &alice, Method::GET, "/api/dicts/exercises", None).await;
    let bench = exercises
        .as_array()
        .unwrap()
        .iter()
        .find(|exercise| exercise["code"] == "bench_press")
        .unwrap()["id"]
        .clone();
    let (_, program) = send(
        &app,
        &alice,
        Method::POST,
        "/api/training/programs",
        Some(json!({
            "name": "Сплит", "schedule_mode": "queue",
            "days": [{ "name": "Грудь", "exercises": [{ "ex_id": bench, "sets": 2, "reps_min": 8, "reps_max": 10, "weight_kg": "50" }] }]
        })),
    )
    .await;
    let (status, session) = send(
        &app,
        &alice,
        Method::POST,
        "/api/training/sessions",
        Some(json!({ "day_id": program["days"][0]["id"], "started_ts": Utc::now() - Duration::minutes(30) })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{session}");
    let (_, gym) = send(&app, &alice, Method::GET, "/api/routine/current", None).await;
    assert_eq!(gym["status"], "gym");
    let gym_id = gym["id"].as_str().unwrap();

    let (_, own) = details(&app, &alice, gym_id).await;
    assert_eq!(own["workout"]["id"], session["id"]);
    assert_eq!(own["workout"]["day_name"], "Грудь");
    assert_eq!(own["workout"]["exercises"][0]["sets"].as_array().unwrap().len(), 2);
    let (_, member) = details(&app, &bob, gym_id).await;
    assert_eq!(member["workout"]["id"], session["id"]);
    assert_eq!(member["owner_name"].as_str().map(|name| name.is_empty()), Some(false));
}
