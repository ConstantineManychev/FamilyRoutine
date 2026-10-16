mod common;

use axum::http::{Method, StatusCode};
use chrono::{DateTime, Duration, Utc};
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

async fn exercise_id(a_app: &TestApp, a_user: &TestUser, a_code: &str) -> String
{
    let (_, list) = send(a_app, a_user, Method::GET, "/api/dicts/exercises", None).await;
    list.as_array()
        .unwrap()
        .iter()
        .find(|exercise| exercise["code"] == a_code)
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string()
}

async fn start(a_app: &TestApp, a_user: &TestUser, a_day_id: &str, a_started: DateTime<Utc>) -> Value
{
    let (status, session) = send(
        a_app,
        a_user,
        Method::POST,
        "/api/training/sessions",
        Some(json!({ "day_id": a_day_id, "started_ts": a_started })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{session}");
    session
}

fn exercise<'a>(a_session: &'a Value, a_ex_id: &str) -> &'a Value
{
    a_session["exercises"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exercise| exercise["ex_id"] == a_ex_id)
        .unwrap()
}

fn with_sets(a_session: &Value, a_results: &[(&str, Value)]) -> Value
{
    let exercises: Vec<Value> = a_session["exercises"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| {
            let sets = a_results
                .iter()
                .find(|(ex_id, _)| item["ex_id"] == *ex_id)
                .map(|(_, sets)| sets.clone())
                .unwrap_or_else(|| item["sets"].clone());
            json!({
                "ex_id": item["ex_id"], "reps_min": item["reps_min"], "reps_max": item["reps_max"],
                "duration_sec": item["duration_sec"], "target_weight": item["target_weight"],
                "rest_sec": item["rest_sec"], "sets": sets
            })
        })
        .collect();
    json!({ "exercises": exercises })
}

async fn finish(
    a_app: &TestApp,
    a_user: &TestUser,
    a_session: &Value,
    a_results: &[(&str, Value)],
    a_started: DateTime<Utc>,
)
{
    let id = a_session["id"].as_str().unwrap();
    let (status, saved) = send(
        a_app,
        a_user,
        Method::PUT,
        &format!("/api/training/sessions/{id}"),
        Some(with_sets(a_session, a_results)),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{saved}");
    let (status, finished) = send(
        a_app,
        a_user,
        Method::POST,
        &format!("/api/training/sessions/{id}/finish"),
        Some(json!({ "intensity": 6, "finished_ts": a_started + Duration::minutes(50) })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{finished}");
}

fn weighted(a_reps: &[i32], a_weight: &str) -> Value
{
    Value::Array(
        a_reps
            .iter()
            .map(|reps| json!({ "reps": reps, "weight_kg": a_weight, "is_done": true }))
            .collect(),
    )
}

fn reps(a_reps: &[i32]) -> Value
{
    Value::Array(
        a_reps
            .iter()
            .map(|reps| json!({ "reps": reps, "is_done": true }))
            .collect(),
    )
}

fn timed(a_seconds: &[i32]) -> Value
{
    Value::Array(
        a_seconds
            .iter()
            .map(|seconds| json!({ "duration_sec": seconds, "is_done": true }))
            .collect(),
    )
}

#[sqlx::test(migrations = "./migrations")]
async fn sessions_suggest_double_progression_and_deload(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let bench = exercise_id(&app, &alice, "bench_press").await;
    let squat = exercise_id(&app, &alice, "back_squat").await;
    let pull_up = exercise_id(&app, &alice, "pull_up").await;
    let plank = exercise_id(&app, &alice, "plank").await;

    let (status, program) = send(
        &app,
        &alice,
        Method::POST,
        "/api/training/programs",
        Some(json!({
            "name": "Фулбоди",
            "schedule_mode": "queue",
            "days": [{ "name": "A", "exercises": [
                { "ex_id": bench, "sets": 3, "reps_min": 8, "reps_max": 10, "weight_kg": "60" },
                { "ex_id": squat, "sets": 3, "reps_min": 5, "reps_max": 8, "weight_kg": "100" },
                { "ex_id": pull_up, "sets": 3, "reps_min": 6, "reps_max": 10 },
                { "ex_id": plank, "sets": 2, "duration_sec": 60 }
            ]}]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{program}");
    let day = program["days"][0]["id"].as_str().unwrap().to_string();
    let base = Utc::now() - Duration::days(5);

    let first = start(&app, &alice, &day, base).await;
    assert_eq!(exercise(&first, &bench)["advice"], Value::Null);
    assert_eq!(exercise(&first, &bench)["sets"][0]["reps"], 10);
    finish(
        &app,
        &alice,
        &first,
        &[
            (&bench, weighted(&[10, 10, 11], "60")),
            (&squat, weighted(&[8, 8, 8], "100")),
            (&pull_up, reps(&[10, 10, 10])),
            (&plank, timed(&[60, 62])),
        ],
        base,
    )
    .await;

    let second_ts = base + Duration::days(1);
    let second = start(&app, &alice, &day, second_ts).await;
    assert_eq!(
        exercise(&second, &bench)["advice"],
        json!({ "kind": "increase_weight", "from": "60.00", "to": "62.50" })
    );
    assert_eq!(
        exercise(&second, &bench)["sets"][2],
        json!({ "reps": 8, "weight_kg": "62.50", "duration_sec": null, "is_done": false })
    );
    assert_eq!(exercise(&second, &squat)["advice"]["to"], "105.00");
    assert_eq!(exercise(&second, &squat)["sets"][0]["reps"], 5);
    assert_eq!(exercise(&second, &pull_up)["advice"]["kind"], "bodyweight_top");
    assert_eq!(
        exercise(&second, &plank)["advice"],
        json!({ "kind": "add_time", "from": "60.00", "to": "70.00" })
    );
    assert_eq!(exercise(&second, &plank)["sets"][1]["duration_sec"], 70);

    let second_id = second["id"].as_str().unwrap();
    let (_, autosaved) = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/training/sessions/{second_id}"),
        Some(with_sets(
            &second,
            &[(&bench, json!([{ "reps": 7, "weight_kg": "62.5", "is_done": true }]))],
        )),
    )
    .await;
    assert_eq!(exercise(&autosaved, &bench)["advice"]["kind"], "increase_weight");
    assert_eq!(exercise(&autosaved, &plank)["advice"]["kind"], "add_time");

    finish(
        &app,
        &alice,
        &second,
        &[(&bench, weighted(&[7, 6, 6], "62.5"))],
        second_ts,
    )
    .await;

    let third_ts = base + Duration::days(2);
    let third = start(&app, &alice, &day, third_ts).await;
    assert_eq!(exercise(&third, &bench)["advice"]["kind"], "add_reps");
    let third_reps: Vec<i64> = exercise(&third, &bench)["sets"]
        .as_array()
        .unwrap()
        .iter()
        .map(|set| set["reps"].as_i64().unwrap())
        .collect();
    assert_eq!(third_reps, [8, 7, 7]);
    finish(
        &app,
        &alice,
        &third,
        &[(&bench, weighted(&[7, 6, 5], "62.5"))],
        third_ts,
    )
    .await;

    let fourth = start(&app, &alice, &day, base + Duration::days(3)).await;
    assert_eq!(
        exercise(&fourth, &bench)["advice"],
        json!({ "kind": "deload", "from": "62.50", "to": "56.00" })
    );
    assert_eq!(exercise(&fourth, &bench)["sets"][0]["weight_kg"], "56.00");
    assert_eq!(exercise(&fourth, &bench)["sets"][0]["reps"], 8);

    let (status, progress) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/training/exercises/{bench}/progress"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{progress}");
    assert_eq!(progress["measure"], "weight");
    let points = progress["points"].as_array().unwrap();
    assert_eq!(points.len(), 3);
    assert_eq!(points[0]["e1rm_kg"], "82.0");
    assert_eq!(points[0]["top_weight_kg"], "60.00");
    assert_eq!(points[0]["top_reps"], 11);
    assert_eq!(points[0]["total_reps"], 31);
    assert_eq!(points[1]["top_weight_kg"], "62.50");
    assert!(points[0]["started_ts"].as_str() < points[2]["started_ts"].as_str());

    let (_, pull_progress) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/training/exercises/{pull_up}/progress"),
        None,
    )
    .await;
    assert_eq!(pull_progress["measure"], "reps");
    let (_, plank_progress) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/training/exercises/{plank}/progress"),
        None,
    )
    .await;
    assert_eq!(plank_progress["measure"], "duration");
    assert_eq!(plank_progress["points"][0]["best_duration_sec"], 62);

    let (_, foreign) = send(
        &app,
        &bob,
        Method::GET,
        &format!("/api/training/exercises/{bench}/progress"),
        None,
    )
    .await;
    assert_eq!(foreign["points"], json!([]));

    let (status, custom) = send(
        &app,
        &alice,
        Method::POST,
        "/api/dicts/exercises",
        Some(json!({
            "name": "Жим лёжа узким хватом", "ex_type": "strength", "met_val": 5.0, "weight_type": "external",
            "musc_grps": [{ "grp": "arms", "pct": 100 }]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{custom}");
    let custom_id = custom["id"].as_str().unwrap();
    assert_eq!(
        send(
            &app,
            &bob,
            Method::GET,
            &format!("/api/training/exercises/{custom_id}/progress"),
            None
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
}
