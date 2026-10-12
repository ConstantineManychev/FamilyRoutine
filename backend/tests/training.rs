mod common;

use axum::http::{Method, StatusCode};
use chrono::{Datelike, Duration, Utc};
use common::{TestApp, TestUser};
use serde_json::{json, Value};
use sqlx::PgPool;

async fn exercise_id(a_app: &TestApp, a_user: &TestUser, a_code: &str) -> String
{
    let list = a_app
        .call(Method::GET, "/api/dicts/exercises", Some(&a_user.token), None)
        .await;
    list.body
        .as_array()
        .unwrap()
        .iter()
        .find(|exercise| exercise["code"] == a_code)
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string()
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

async fn four_day_program(a_app: &TestApp, a_user: &TestUser) -> Value
{
    let bench = exercise_id(a_app, a_user, "bench_press").await;
    let squat = exercise_id(a_app, a_user, "back_squat").await;
    let row = exercise_id(a_app, a_user, "barbell_row").await;
    let plank = exercise_id(a_app, a_user, "plank").await;
    let day = |a_name: &str, a_rest: i32, a_exercises: Value| json!({ "name": a_name, "rest_days_after": a_rest, "exercises": a_exercises });

    let (status, program) = send(
        a_app,
        a_user,
        Method::POST,
        "/api/training/programs",
        Some(json!({
            "name": "Сплит",
            "schedule_mode": "intervals",
            "days": [
                day("A", 1, json!([
                    { "ex_id": bench, "sets": 3, "reps_min": 8, "reps_max": 12, "weight_kg": "60", "rest_sec": 120, "weight_step": "2.5" },
                    { "ex_id": plank, "sets": 2, "duration_sec": 60 }
                ])),
                day("B", 2, json!([{ "ex_id": squat, "sets": 4, "reps_min": 6, "reps_max": 8, "weight_kg": 80 }])),
                day("C", 1, json!([{ "ex_id": row, "sets": 3, "reps_min": 8, "reps_max": 10 }])),
                day("D", 2, json!([]))
            ]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{program}");
    program
}

#[sqlx::test(migrations = "./migrations")]
async fn programs_are_validated_and_one_is_active(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;

    let exercises = app
        .call(Method::GET, "/api/dicts/exercises", Some(&alice.token), None)
        .await;
    assert!(exercises.body.as_array().unwrap().len() >= 40);
    let custom = app
        .call(
            Method::POST,
            "/api/dicts/exercises",
            Some(&bob.token),
            Some(json!({ "name": "Bob move", "ex_type": "strength", "met_val": 4, "weight_type": "external", "musc_grps": [{ "grp": "arms", "pct": 100 }] })),
        )
        .await;
    let bob_exercise = custom.body["id"].as_str().unwrap().to_string();

    let invalid = [
        json!({ "name": "X", "schedule_mode": "queue", "days": [] }),
        json!({ "name": "X", "schedule_mode": "weekdays", "days": [{ "name": "A", "weekdays": [8] }] }),
        json!({ "name": "X", "schedule_mode": "weekdays", "days": [{ "name": "A", "weekdays": [1] }, { "name": "B", "weekdays": [1, 3] }] }),
        json!({ "name": "X", "schedule_mode": "weekdays", "days": [{ "name": "A" }] }),
        json!({ "name": "X", "schedule_mode": "intervals", "days": [{ "name": "A", "rest_days_after": 20 }] }),
        json!({ "name": "X", "schedule_mode": "queue", "days": [{ "name": "A", "exercises": [{ "ex_id": bob_exercise, "sets": 3 }] }] }),
    ];
    for body in invalid
    {
        let (status, _) = send(&app, &alice, Method::POST, "/api/training/programs", Some(body)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }

    let first = four_day_program(&app, &alice).await;
    assert_eq!(first["is_active"], true);
    assert_eq!(first["days"][0]["exercises"][0]["weight_step"], "2.50");
    let (_, second) = send(
        &app,
        &alice,
        Method::POST,
        "/api/training/programs",
        Some(json!({ "name": "Пн/Ср/Пт", "schedule_mode": "weekdays", "days": [{ "name": "Full", "weekdays": [1, 3, 5] }] })),
    )
    .await;
    assert_eq!(second["is_active"], false);
    assert_eq!(second["days"][0]["weekdays"], json!([1, 3, 5]));

    let second_id = second["id"].as_str().unwrap();
    let (status, _) = send(
        &app,
        &alice,
        Method::POST,
        &format!("/api/training/programs/{second_id}/activate"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, list) = send(&app, &alice, Method::GET, "/api/training/programs", None).await;
    assert_eq!(list[0]["id"], second["id"]);
    assert_eq!(list[1]["is_active"], false);

    let first_id = first["id"].as_str().unwrap();
    let mut days = first["days"].clone();
    days.as_array_mut().unwrap().swap(0, 1);
    days.as_array_mut().unwrap().pop();
    let (status, updated) = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/training/programs/{first_id}"),
        Some(json!({ "name": "Сплит 2", "schedule_mode": "intervals", "days": days })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{updated}");
    assert_eq!(updated["days"].as_array().unwrap().len(), 3);
    assert_eq!(updated["days"][0]["id"], first["days"][1]["id"]);
    assert_eq!(updated["days"][1]["exercises"][0]["sets"], 3);

    assert_eq!(
        send(
            &app,
            &bob,
            Method::GET,
            &format!("/api/training/programs/{first_id}"),
            None
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        send(
            &app,
            &bob,
            Method::DELETE,
            &format!("/api/training/programs/{first_id}"),
            None
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        send(
            &app,
            &alice,
            Method::DELETE,
            &format!("/api/training/programs/{first_id}"),
            None
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
}

#[sqlx::test(migrations = "./migrations")]
async fn plan_sessions_and_previous_results(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let program = four_day_program(&app, &alice).await;
    let day_id = |a_index: usize| program["days"][a_index]["id"].as_str().unwrap().to_string();
    let today = Utc::now().date_naive();

    let (_, plan) = send(
        &app,
        &alice,
        Method::GET,
        "/api/training/plan?tz_offset_min=0&days=10",
        None,
    )
    .await;
    assert_eq!(plan["program"]["name"], "Сплит");
    assert_eq!(plan["upcoming"][0]["day_name"], "A");
    assert_eq!(plan["upcoming"][0]["date"], today.to_string());
    assert_eq!(plan["upcoming"][1]["day_name"], "B");
    assert_eq!(plan["upcoming"][1]["date"], (today + Duration::days(2)).to_string());
    assert_eq!(plan["upcoming"][2]["date"], (today + Duration::days(5)).to_string());

    let started = Utc::now() - Duration::hours(2);
    let (status, session) = send(
        &app,
        &alice,
        Method::POST,
        "/api/training/sessions",
        Some(json!({ "day_id": day_id(0), "started_ts": started })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{session}");
    assert_eq!(session["day_name"], "A");
    assert_eq!(session["exercises"][0]["ex_code"], "bench_press");
    assert_eq!(session["exercises"][0]["sets"].as_array().unwrap().len(), 3);
    assert_eq!(
        session["exercises"][0]["sets"][0],
        json!({ "reps": 12, "weight_kg": "60.00", "duration_sec": null, "is_done": false })
    );
    assert_eq!(session["exercises"][1]["sets"][0]["duration_sec"], 60);
    assert_eq!(session["exercises"][0]["previous"], json!([]));

    let (status, conflict) = send(&app, &alice, Method::POST, "/api/training/sessions", Some(json!({}))).await;
    assert_eq!(
        (status, conflict["code"].as_str()),
        (StatusCode::CONFLICT, Some("SESSION_ACTIVE"))
    );
    let session_id = session["id"].as_str().unwrap().to_string();
    let open_mark: (String, Option<chrono::DateTime<Utc>>) = sqlx::query_as(
        "SELECT status::text, end_ts FROM status_marks WHERE user_id = $1 ORDER BY start_ts DESC LIMIT 1",
    )
    .bind(alice.id)
    .fetch_one(&a_db)
    .await
    .unwrap();
    assert_eq!(open_mark, ("gym".to_string(), None));

    let bench = session["exercises"][0]["ex_id"].clone();
    let plank = session["exercises"][1]["ex_id"].clone();
    let (status, saved) = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/training/sessions/{session_id}"),
        Some(json!({
            "note": "тяжело",
            "exercises": [
                { "ex_id": bench, "reps_min": 8, "reps_max": 12, "target_weight": 60, "sets": [
                    { "reps": 12, "weight_kg": 60, "is_done": true },
                    { "reps": 10, "weight_kg": "62.5", "is_done": true },
                    { "reps": 8, "weight_kg": "62.5", "is_done": false }
                ]},
                { "ex_id": plank, "sets": [{ "duration_sec": 70, "is_done": true }] }
            ]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{saved}");
    assert_eq!(saved["note"], "тяжело");
    assert_eq!(saved["exercises"][0]["sets"][1]["weight_kg"], "62.50");

    let (status, _) = send(
        &app,
        &alice,
        Method::POST,
        &format!("/api/training/sessions/{session_id}/finish"),
        Some(json!({ "intensity": 11 })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, finished) = send(
        &app,
        &alice,
        Method::POST,
        &format!("/api/training/sessions/{session_id}/finish"),
        Some(json!({ "intensity": 7, "finished_ts": started + Duration::minutes(60) })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{finished}");
    assert_eq!(finished["kcal"], Value::Null);
    let (status, _) = send(
        &app,
        &alice,
        Method::POST,
        &format!("/api/training/sessions/{session_id}/finish"),
        Some(json!({ "intensity": 7 })),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);

    let closed_mark: Option<chrono::DateTime<Utc>> =
        sqlx::query_scalar("SELECT end_ts FROM status_marks WHERE user_id = $1 AND status = 'gym'")
            .bind(alice.id)
            .fetch_one(&a_db)
            .await
            .unwrap();
    assert_eq!(
        closed_mark.unwrap().timestamp(),
        (started + Duration::minutes(60)).timestamp()
    );

    app.call(
        Method::POST,
        &format!("/api/people/{}/entries", alice.id),
        Some(&alice.token),
        Some(json!({ "measured_ts": started - Duration::days(1), "values": [{ "metric": "weight", "value": 80 }] })),
    )
    .await;
    let (_, resaved) = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/training/sessions/{session_id}"),
        Some(json!({ "note": "тяжело", "exercises": saved_exercises(&saved) })),
    )
    .await;
    let kcal: f64 = resaved["kcal"].as_str().unwrap().parse().unwrap();
    let factor = 0.6 + 0.08 * 7.0;
    let met = (5.0 * 2.0 + 3.8) / 3.0;
    let expected = ((met * factor - 1.0) * 80.0 * 1.0 * 10.0_f64).round() / 10.0;
    assert!((kcal - expected).abs() < 0.11, "{kcal} vs {expected}");

    let (_, plan) = send(
        &app,
        &alice,
        Method::GET,
        "/api/training/plan?tz_offset_min=0&days=6",
        None,
    )
    .await;
    assert_eq!(plan["upcoming"][0]["day_name"], "B");
    assert_eq!(
        plan["upcoming"][0]["date"],
        (started.date_naive() + Duration::days(2)).to_string()
    );
    assert_eq!(plan["active_session_id"], Value::Null);
    assert_eq!(plan["last_session"]["done_sets"], 3);
    assert_eq!(plan["last_session"]["volume_kg"], "1345.00");

    let (status, _) = send(
        &app,
        &alice,
        Method::PUT,
        "/api/training/today",
        Some(json!({ "day_id": day_id(2), "date": today })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, plan) = send(
        &app,
        &alice,
        Method::GET,
        "/api/training/plan?tz_offset_min=0&days=6",
        None,
    )
    .await;
    assert_eq!(plan["upcoming"][0]["day_name"], "C");
    assert_eq!(plan["upcoming"][0]["date"], today.to_string());
    assert_eq!(plan["upcoming"][1]["day_name"], "D");
    assert_eq!(
        send(
            &app,
            &bob,
            Method::PUT,
            "/api/training/today",
            Some(json!({ "day_id": day_id(2), "date": today }))
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );

    let (_, second) = send(
        &app,
        &alice,
        Method::POST,
        "/api/training/sessions",
        Some(json!({ "day_id": day_id(0) })),
    )
    .await;
    assert_eq!(second["exercises"][0]["previous"].as_array().unwrap().len(), 2);
    assert_eq!(second["exercises"][0]["previous"][1]["weight_kg"], "62.50");
    assert_eq!(second["exercises"][0]["sets"][1]["weight_kg"], "62.50");
    assert_eq!(second["exercises"][0]["sets"][2]["weight_kg"], "62.50");
    assert_eq!(second["exercises"][1]["sets"][0]["duration_sec"], 70);

    let second_id = second["id"].as_str().unwrap();
    assert_eq!(
        send(
            &app,
            &bob,
            Method::GET,
            &format!("/api/training/sessions/{second_id}"),
            None
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        send(
            &app,
            &alice,
            Method::DELETE,
            &format!("/api/training/sessions/{second_id}"),
            None
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
    let marks: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM status_marks WHERE user_id = $1")
        .bind(alice.id)
        .fetch_one(&a_db)
        .await
        .unwrap();
    assert_eq!(marks, 1);

    let (_, sessions) = send(&app, &alice, Method::GET, "/api/training/sessions", None).await;
    assert_eq!(sessions.as_array().unwrap().len(), 1);

    let timeline = app
        .call(
            Method::GET,
            &format!("/api/user/energy-timeline?target_date={}", started.date_naive()),
            Some(&alice.token),
            None,
        )
        .await;
    assert!(timeline
        .body
        .as_array()
        .unwrap()
        .iter()
        .any(|node| node["event_type"] == "workout" && (node["val"].as_f64().unwrap() + kcal).abs() < 0.11));

    let free = send(&app, &alice, Method::POST, "/api/training/sessions", Some(json!({}))).await;
    assert_eq!(free.0, StatusCode::CREATED);
    assert_eq!(free.1["exercises"], json!([]));
    assert_eq!(free.1["day_name"], Value::Null);
}

fn saved_exercises(a_session: &Value) -> Value
{
    Value::Array(
        a_session["exercises"]
            .as_array()
            .unwrap()
            .iter()
            .map(|exercise| {
                json!({
                    "ex_id": exercise["ex_id"], "reps_min": exercise["reps_min"], "reps_max": exercise["reps_max"],
                    "duration_sec": exercise["duration_sec"], "target_weight": exercise["target_weight"],
                    "rest_sec": exercise["rest_sec"], "sets": exercise["sets"]
                })
            })
            .collect(),
    )
}

#[sqlx::test(migrations = "./migrations")]
async fn weekday_programs_follow_the_calendar(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let (_, program) = send(
        &app,
        &alice,
        Method::POST,
        "/api/training/programs",
        Some(json!({ "name": "Неделя", "schedule_mode": "weekdays", "days": [
            { "name": "Верх", "weekdays": [1, 4] },
            { "name": "Низ", "weekdays": [2, 6] }
        ] })),
    )
    .await;
    assert_eq!(program["is_active"], true);

    let (_, plan) = send(
        &app,
        &alice,
        Method::GET,
        "/api/training/plan?tz_offset_min=0&days=13",
        None,
    )
    .await;
    let upcoming = plan["upcoming"].as_array().unwrap();
    assert!(upcoming.len() >= 7);
    for item in upcoming
    {
        let date: chrono::NaiveDate = item["date"].as_str().unwrap().parse().unwrap();
        let weekday = date.weekday().number_from_monday();
        let expected = if [1, 4].contains(&weekday)
        {
            "Верх"
        }
        else
        {
            "Низ"
        };
        assert!([1, 2, 4, 6].contains(&weekday));
        assert_eq!(item["day_name"], expected);
    }
}
