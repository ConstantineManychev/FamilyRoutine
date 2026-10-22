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

async fn event(a_app: &TestApp, a_user: &TestUser, a_body: Value) -> String
{
    let (status, body) = send(a_app, a_user, Method::POST, "/api/plan/events", Some(a_body)).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    body["id"].as_str().unwrap().to_string()
}

async fn agenda(a_app: &TestApp, a_user: &TestUser, a_from: &str, a_to: &str, a_tz: &str) -> Vec<Value>
{
    let (status, body) = send(
        a_app,
        a_user,
        Method::GET,
        &format!("/api/plan?from={a_from}&to={a_to}&tz={a_tz}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body["occurrences"].as_array().unwrap().clone()
}

fn iso(a_ts: DateTime<Utc>) -> String
{
    a_ts.to_rfc3339_opts(SecondsFormat::Secs, true)
}

async fn day_row(a_app: &TestApp, a_user: &TestUser, a_family: Option<&str>, a_day: DateTime<Utc>) -> Value
{
    let mut uri = format!(
        "/api/routine/timeline?from={}&to={}",
        iso(a_day),
        iso(a_day + Duration::days(1))
    );
    if let Some(family) = a_family
    {
        uri.push_str(&format!("&family_id={family}"));
    }
    let (status, body) = send(a_app, a_user, Method::GET, &uri, None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body["members"]
        .as_array()
        .unwrap()
        .iter()
        .find(|member| member["user_id"] == a_user.id.to_string())
        .cloned()
        .unwrap_or_else(|| body["members"][0].clone())
}

fn blocks(a_row: &Value) -> Vec<(String, String, Option<String>)>
{
    a_row["marks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|mark| {
            (
                mark["status"].as_str().unwrap().to_string(),
                mark["start_ts"].as_str().unwrap().to_string(),
                mark["end_ts"].as_str().map(str::to_string),
            )
        })
        .collect()
}

fn find<'a>(a_items: &'a [Value], a_title: &str, a_date: &str) -> &'a Value
{
    a_items
        .iter()
        .find(|item| item["title"] == a_title && item["date"] == a_date)
        .unwrap_or_else(|| panic!("{a_title} on {a_date} not found"))
}

#[sqlx::test(migrations = "./migrations")]
async fn repeats_keep_local_time_and_collisions_are_reported(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let dublin = "Europe/Dublin";

    let yoga = event(
        &app,
        &alice,
        json!({
            "title": "Йога", "category": "gym", "timing": "fixed", "start_date": "2026-10-19", "start_time": "09:00:00",
            "duration_min": 60, "tz": dublin, "repeat": "weekly", "weekday_mask": 1
        }),
    )
    .await;
    event(
        &app,
        &alice,
        json!({
            "title": "Созвон", "timing": "fixed", "start_date": "2026-10-19", "start_time": "09:30:00",
            "duration_min": 30, "tz": dublin
        }),
    )
    .await;
    let run = event(
        &app,
        &alice,
        json!({
            "title": "Пробежка", "timing": "window", "start_date": "2026-10-19", "start_time": "12:00:00",
            "window_min": 120, "duration_min": 40, "tz": dublin, "repeat": "daily"
        }),
    )
    .await;
    for (title, time, minutes) in [("Обед", "12:30:00", 60), ("Встреча", "13:00:00", 45)]
    {
        event(
            &app,
            &alice,
            json!({
                "title": title, "timing": "fixed", "start_date": "2026-10-19", "start_time": time,
                "duration_min": minutes, "tz": dublin
            }),
        )
        .await;
    }

    let week = agenda(&app, &alice, "2026-10-19", "2026-10-26", dublin).await;
    let first_yoga = find(&week, "Йога", "2026-10-19");
    let second_yoga = find(&week, "Йога", "2026-10-26");
    assert_eq!(first_yoga["start_ts"], "2026-10-19T08:00:00Z");
    assert_eq!(second_yoga["start_ts"], "2026-10-26T09:00:00Z");
    assert_eq!(first_yoga["conflicts"][0]["title"], "Созвон");
    assert_eq!(
        find(&week, "Созвон", "2026-10-19")["conflicts"][0]["event_id"],
        yoga.as_str()
    );
    assert_eq!(second_yoga["conflicts"], json!([]));
    assert_eq!(find(&week, "Пробежка", "2026-10-19")["overload"], Value::Null);
    assert_eq!(find(&week, "Пробежка", "2026-10-19")["end_ts"], "2026-10-19T13:00:00Z");
    assert_eq!(week.iter().filter(|item| item["title"] == "Пробежка").count(), 8);

    event(
        &app,
        &alice,
        json!({
            "title": "Почта", "timing": "window", "start_date": "2026-10-19", "start_time": "12:15:00",
            "window_min": 60, "duration_min": 30, "tz": dublin
        }),
    )
    .await;
    let day = agenda(&app, &alice, "2026-10-19", "2026-10-20", dublin).await;
    assert_eq!(
        find(&day, "Пробежка", "2026-10-19")["overload"],
        json!({ "window_min": 120, "busy_min": 145 })
    );
    assert_eq!(find(&day, "Пробежка", "2026-10-20")["overload"], Value::Null);

    let kyiv = agenda(&app, &alice, "2026-10-19", "2026-10-19", "Europe/Kyiv").await;
    assert!(kyiv.iter().any(|item| item["title"] == "Йога"));
    assert!(agenda(&app, &bob, "2026-10-19", "2026-10-26", dublin).await.is_empty());

    let invalid = [
        json!({ "title": "X", "timing": "window", "start_date": "2026-10-19", "start_time": "12:00:00", "window_min": 30, "duration_min": 40, "tz": dublin }),
        json!({ "title": "X", "timing": "fixed", "start_date": "2026-10-19", "start_time": "12:00:00", "duration_min": 40, "tz": "Mars/Base" }),
        json!({ "title": "X", "timing": "fixed", "start_date": "2026-10-19", "start_time": "12:00:00", "duration_min": 2, "tz": dublin }),
        json!({ "title": "X", "timing": "fixed", "start_date": "2026-10-19", "start_time": "12:00:00", "duration_min": 30, "tz": dublin, "repeat": "daily", "until_date": "2026-10-01" }),
    ];
    for (body, field) in invalid
        .into_iter()
        .zip(["window_min", "tz", "duration_min", "until_date"])
    {
        let (status, reply) = send(&app, &alice, Method::POST, "/api/plan/events", Some(body)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(reply["field"], field);
    }
    let (status, _) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/plan?from=2026-01-01&to=2026-12-31&tz={dublin}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    for (method, uri) in [
        (Method::GET, format!("/api/plan/events/{run}")),
        (Method::DELETE, format!("/api/plan/events/{run}")),
        (Method::PUT, format!("/api/plan/events/{run}/occurrences/2026-10-19")),
    ]
    {
        let body = (method == Method::PUT).then(|| json!({ "state": "done" }));
        let (status, _) = send(&app, &bob, method, &uri, body).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }
}

#[sqlx::test(migrations = "./migrations")]
async fn single_occurrences_are_moved_skipped_and_completed(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let alice = app.user("alice@example.com").await;
    let id = event(
        &app,
        &alice,
        json!({
            "title": "Растяжка", "timing": "fixed", "start_date": "2026-11-02", "start_time": "07:00:00",
            "duration_min": 20, "tz": "UTC", "repeat": "daily", "repeat_every": 2
        }),
    )
    .await;
    let occurrence = |a_date: &str| format!("/api/plan/events/{id}/occurrences/{a_date}");

    let (status, _) = send(
        &app,
        &alice,
        Method::PUT,
        &occurrence("2026-11-03"),
        Some(json!({ "state": "done" })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    for (date, body) in [
        ("2026-11-04", json!({ "state": "skipped" })),
        (
            "2026-11-06",
            json!({ "state": "planned", "moved_date": "2026-11-07", "moved_time": "18:30:00" }),
        ),
        ("2026-11-08", json!({ "state": "done" })),
        (
            "2026-11-12",
            json!({ "state": "planned", "moved_start": "2026-11-12T20:15:42Z" }),
        ),
    ]
    {
        let (status, reply) = send(&app, &alice, Method::PUT, &occurrence(date), Some(body)).await;
        assert_eq!(status, StatusCode::NO_CONTENT, "{reply}");
    }

    let items = agenda(&app, &alice, "2026-11-02", "2026-11-09", "UTC").await;
    let dates: Vec<&str> = items.iter().map(|item| item["date"].as_str().unwrap()).collect();
    assert_eq!(dates, ["2026-11-02", "2026-11-04", "2026-11-07", "2026-11-08"]);
    assert_eq!(items[1]["state"], "skipped");
    assert_eq!(items[2]["occ_date"], "2026-11-06");
    assert_eq!(items[2]["is_moved"], true);
    assert_eq!(items[2]["start_ts"], "2026-11-07T18:30:00Z");
    assert_eq!(items[3]["state"], "done");
    let late = agenda(&app, &alice, "2026-11-12", "2026-11-12", "UTC").await;
    assert_eq!(late[0]["start_ts"], "2026-11-12T20:15:00Z");

    let (status, _) = send(
        &app,
        &alice,
        Method::PUT,
        &occurrence("2026-11-06"),
        Some(json!({ "state": "planned", "moved_date": "2026-11-06", "moved_time": "07:00:00" })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    send(
        &app,
        &alice,
        Method::PUT,
        &occurrence("2026-11-08"),
        Some(json!({ "state": "planned" })),
    )
    .await;
    let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM plan_instances")
        .fetch_one(&a_db)
        .await
        .unwrap();
    assert_eq!(rows, 2);
    let items = agenda(&app, &alice, "2026-11-06", "2026-11-06", "UTC").await;
    assert_eq!(items[0]["is_moved"], false);

    let (status, _) = send(&app, &alice, Method::DELETE, &format!("/api/plan/events/{id}"), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(agenda(&app, &alice, "2026-11-02", "2026-11-09", "UTC").await.is_empty());
}

#[sqlx::test(migrations = "./migrations")]
async fn training_slots_start_workouts_and_are_completed_by_them(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let (_, exercises) = send(&app, &alice, Method::GET, "/api/dicts/exercises", None).await;
    let bench = exercises
        .as_array()
        .unwrap()
        .iter()
        .find(|exercise| exercise["code"] == "bench_press")
        .unwrap()["id"]
        .clone();
    let (status, program) = send(
        &app,
        &alice,
        Method::POST,
        "/api/training/programs",
        Some(json!({
            "name": "Сплит",
            "schedule_mode": "queue",
            "days": [
                { "name": "A", "exercises": [{ "ex_id": bench, "sets": 3, "reps_min": 8, "reps_max": 10 }] },
                { "name": "B", "exercises": [{ "ex_id": bench, "sets": 2, "reps_min": 5, "reps_max": 5 }] }
            ]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{program}");
    let program_id = program["id"].as_str().unwrap();
    let day_b = program["days"][1]["id"].as_str().unwrap();

    let today = Utc::now().date_naive();
    let tomorrow = today + Duration::days(1);
    let morning = event(
        &app,
        &alice,
        json!({
            "title": "Зал", "category": "work", "timing": "window", "start_date": today, "start_time": "00:00:00",
            "window_min": 1440, "duration_min": 60, "tz": "UTC", "repeat": "daily", "program_id": program_id
        }),
    )
    .await;
    let (_, saved) = send(&app, &alice, Method::GET, &format!("/api/plan/events/{morning}"), None).await;
    assert_eq!(saved["category"], "gym");
    assert_eq!(saved["program_name"], "Сплит");

    let (status, foreign_day) = send(
        &app,
        &alice,
        Method::POST,
        "/api/plan/events",
        Some(json!({
            "title": "X", "timing": "fixed", "start_date": today, "start_time": "10:00:00", "duration_min": 30,
            "tz": "UTC", "day_id": day_b
        })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(foreign_day["field"], "day_id");

    let (_, plan) = send(&app, &alice, Method::GET, "/api/training/plan?tz=UTC", None).await;
    assert_eq!(plan["next_slot"]["event_id"], morning.as_str());
    assert_eq!(plan["next_slot"]["occ_date"], today.to_string());
    assert_eq!(plan["next_slot"]["day_name"], "A");

    let (status, session) = send(
        &app,
        &alice,
        Method::POST,
        &format!("/api/plan/events/{morning}/occurrences/{today}/start"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{session}");
    assert_eq!(session["day_name"], "A");
    let session_id = session["id"].as_str().unwrap();
    let items = agenda(&app, &alice, &today.to_string(), &today.to_string(), "UTC").await;
    assert_eq!(items[0]["session_id"], session_id);
    assert_eq!(items[0]["is_session_active"], true);
    let (_, status_now) = send(&app, &alice, Method::GET, "/api/training/plan?tz=UTC", None).await;
    assert_eq!(status_now["next_slot"]["occ_date"], today.to_string());

    let (status, _) = send(
        &app,
        &alice,
        Method::POST,
        &format!("/api/training/sessions/{session_id}/finish"),
        Some(json!({ "intensity": 7 })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let items = agenda(&app, &alice, &today.to_string(), &today.to_string(), "UTC").await;
    assert_eq!(items[0]["state"], "done");
    assert_eq!(items[0]["is_session_active"], false);
    let (_, plan) = send(&app, &alice, Method::GET, "/api/training/plan?tz=UTC", None).await;
    assert_eq!(plan["next_slot"]["occ_date"], tomorrow.to_string());
    assert_eq!(plan["next_slot"]["day_name"], "B");

    let evening = event(
        &app,
        &alice,
        json!({
            "title": "Доп. тренировка", "timing": "window", "start_date": today, "start_time": "00:00:00",
            "window_min": 1440, "duration_min": 30, "tz": "UTC", "program_id": program_id, "day_id": day_b
        }),
    )
    .await;
    let (_, direct) = send(
        &app,
        &alice,
        Method::POST,
        "/api/training/sessions",
        Some(json!({ "day_id": day_b })),
    )
    .await;
    let direct_id = direct["id"].as_str().unwrap();
    send(
        &app,
        &alice,
        Method::POST,
        &format!("/api/training/sessions/{direct_id}/finish"),
        Some(json!({ "intensity": 5 })),
    )
    .await;
    let items = agenda(&app, &alice, &today.to_string(), &today.to_string(), "UTC").await;
    let extra = items.iter().find(|item| item["event_id"] == evening.as_str()).unwrap();
    assert_eq!(extra["state"], "done");
    assert_eq!(extra["session_id"], direct_id);

    let (status, _) = send(
        &app,
        &alice,
        Method::DELETE,
        &format!("/api/training/sessions/{direct_id}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let items = agenda(&app, &alice, &today.to_string(), &today.to_string(), "UTC").await;
    let extra = items.iter().find(|item| item["event_id"] == evening.as_str()).unwrap();
    assert_eq!(extra["state"], "planned");

    let (status, not_training) = send(
        &app,
        &alice,
        Method::POST,
        &format!(
            "/api/plan/events/{}/occurrences/{today}/start",
            event(
                &app,
                &alice,
                json!({ "title": "Чтение", "timing": "fixed", "start_date": today, "start_time": "21:00:00", "duration_min": 30, "tz": "UTC" })
            )
            .await
        ),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(not_training["field"], "program_id");
}

#[sqlx::test(migrations = "./migrations")]
async fn accepted_plans_become_routine_blocks(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let home = app.family(&alice, "Дом").await;
    app.join(&alice, &bob, &home, "standard").await;

    let day = (Utc::now() - Duration::days(1)).date_naive();
    let midnight = day.and_time(NaiveTime::MIN).and_utc();
    let at = |a_hours: i64, a_minutes: i64| midnight + Duration::hours(a_hours) + Duration::minutes(a_minutes);
    let (status, mark) = send(
        &app,
        &alice,
        Method::POST,
        "/api/routine/marks",
        Some(json!({ "status": "home", "start_ts": iso(at(8, 0)) })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{mark}");
    let id = event(
        &app,
        &alice,
        json!({
            "title": "Обед", "category": "meal", "timing": "fixed", "start_date": day, "start_time": "13:00:00",
            "duration_min": 30, "tz": "UTC"
        }),
    )
    .await;
    let occurrence = format!("/api/plan/events/{id}/occurrences/{day}");

    let row = day_row(&app, &alice, None, midnight).await;
    assert_eq!(row["plans"].as_array().unwrap().len(), 1);
    assert_eq!(row["plans"][0]["title"], "Обед");
    assert_eq!(row["plans"][0]["start_ts"], iso(at(13, 0)));
    assert_eq!(blocks(&row).len(), 1);
    let (status, bob_view) = send(
        &app,
        &bob,
        Method::GET,
        &format!(
            "/api/routine/timeline?from={}&to={}&family_id={home}",
            iso(midnight),
            iso(midnight + Duration::days(1))
        ),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{bob_view}");
    let alice_for_bob = bob_view["members"]
        .as_array()
        .unwrap()
        .iter()
        .find(|member| member["user_id"] == alice.id.to_string())
        .cloned()
        .unwrap();
    assert_eq!(alice_for_bob["plans"], json!([]));
    assert_eq!(alice_for_bob["marks"].as_array().unwrap().len(), 1);
    let shared = day_row(&app, &alice, Some(&home), midnight).await;
    assert_eq!(shared["plans"].as_array().unwrap().len(), 1);

    let (status, reply) = send(&app, &alice, Method::PUT, &occurrence, Some(json!({ "state": "done" }))).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{reply}");
    let row = day_row(&app, &alice, None, midnight).await;
    assert_eq!(row["plans"], json!([]));
    assert_eq!(
        blocks(&row),
        vec![
            ("home".to_string(), iso(at(8, 0)), Some(iso(at(13, 0)))),
            ("meal".to_string(), iso(at(13, 0)), Some(iso(at(13, 30)))),
            ("home".to_string(), iso(at(13, 30)), None),
        ]
    );
    assert_eq!(row["marks"][1]["note"], "Обед");

    let (status, _) = send(
        &app,
        &alice,
        Method::PUT,
        &occurrence,
        Some(json!({ "state": "done", "moved_start": iso(at(14, 0)) })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let row = day_row(&app, &alice, None, midnight).await;
    assert_eq!(
        blocks(&row),
        vec![
            ("home".to_string(), iso(at(8, 0)), Some(iso(at(14, 0)))),
            ("meal".to_string(), iso(at(14, 0)), Some(iso(at(14, 30)))),
            ("home".to_string(), iso(at(14, 30)), None),
        ]
    );

    let (status, _) = send(
        &app,
        &alice,
        Method::PUT,
        &occurrence,
        Some(json!({ "state": "planned", "moved_start": iso(at(14, 0)) })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let row = day_row(&app, &alice, None, midnight).await;
    assert_eq!(blocks(&row), vec![("home".to_string(), iso(at(8, 0)), None)]);
    assert_eq!(row["plans"][0]["start_ts"], iso(at(14, 0)));

    send(
        &app,
        &alice,
        Method::PUT,
        &occurrence,
        Some(json!({ "state": "done", "moved_start": iso(at(14, 0)) })),
    )
    .await;
    let row = day_row(&app, &alice, None, midnight).await;
    let meal_id = row["marks"][1]["id"].as_str().unwrap().to_string();
    let (status, entry) = send(
        &app,
        &alice,
        Method::POST,
        "/api/nutrition/entries",
        Some(json!({ "date": day, "status_mark_id": meal_id, "quick": { "title": "Суп", "kcal": "300" } })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{entry}");
    send(
        &app,
        &alice,
        Method::PUT,
        &occurrence,
        Some(json!({ "state": "planned", "moved_start": iso(at(14, 0)) })),
    )
    .await;
    let row = day_row(&app, &alice, None, midnight).await;
    assert_eq!(row["marks"][1]["id"], meal_id.as_str());
    assert_eq!(row["plans"].as_array().unwrap().len(), 1);

    send(
        &app,
        &alice,
        Method::PUT,
        &occurrence,
        Some(json!({ "state": "done", "moved_start": iso(at(14, 0)) })),
    )
    .await;
    let row = day_row(&app, &alice, None, midnight).await;
    assert_eq!(row["marks"][1]["id"], meal_id.as_str());
    assert_eq!(row["plans"], json!([]));
    let (status, details) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/routine/marks/{meal_id}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{details}");
    assert_eq!(details["meals"]["entries"].as_array().unwrap().len(), 1, "{details}");

    let (status, _) = send(
        &app,
        &alice,
        Method::DELETE,
        &format!("/api/routine/marks/{meal_id}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let items = agenda(&app, &alice, &day.to_string(), &day.to_string(), "UTC").await;
    assert_eq!(items[0]["state"], "planned");
    assert_eq!(items[0]["start_ts"], iso(at(14, 0)));
    let row = day_row(&app, &alice, None, midnight).await;
    assert_eq!(row["plans"].as_array().unwrap().len(), 1);

    send(
        &app,
        &alice,
        Method::PUT,
        &occurrence,
        Some(json!({ "state": "done", "moved_start": iso(at(14, 0)) })),
    )
    .await;
    let row = day_row(&app, &alice, None, midnight).await;
    let renamed_id = row["marks"][1]["id"].as_str().unwrap().to_string();
    let (status, renamed) = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/routine/marks/{renamed_id}"),
        Some(json!({ "status": "meal", "note": "Обед с коллегами", "start_ts": iso(at(14, 0)), "end_ts": iso(at(14, 30)) })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{renamed}");
    send(
        &app,
        &alice,
        Method::PUT,
        &occurrence,
        Some(json!({ "state": "done", "moved_start": iso(at(15, 0)) })),
    )
    .await;
    let row = day_row(&app, &alice, None, midnight).await;
    assert_eq!(row["marks"][1]["start_ts"], iso(at(15, 0)));
    assert_eq!(row["marks"][1]["note"], "Обед с коллегами");
    send(
        &app,
        &alice,
        Method::PUT,
        &occurrence,
        Some(json!({ "state": "planned", "moved_start": iso(at(15, 0)) })),
    )
    .await;
    let row = day_row(&app, &alice, None, midnight).await;
    assert_eq!(row["marks"][1]["note"], "Обед с коллегами");
    assert_eq!(row["plans"][0]["start_ts"], iso(at(15, 0)));
}
