mod common;

use axum::http::{Method, StatusCode};
use chrono::{DateTime, Duration, DurationRound, NaiveDate, SecondsFormat, Utc};
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

async fn task(a_app: &TestApp, a_user: &TestUser, a_kind: &str, a_title: &str, a_date: NaiveDate) -> String
{
    let (status, body) = send(
        a_app,
        a_user,
        Method::POST,
        "/api/work/tasks",
        Some(json!({ "kind": a_kind, "title": a_title, "date": a_date })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["events"][0]["kind"], "created");
    body["task"]["id"].as_str().unwrap().to_string()
}

async fn day(a_app: &TestApp, a_user: &TestUser, a_date: NaiveDate) -> Value
{
    let (status, body) = send(
        a_app,
        a_user,
        Method::GET,
        &format!("/api/work/day?date={a_date}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body
}

async fn log(a_app: &TestApp, a_user: &TestUser, a_id: &str, a_body: Value) -> (StatusCode, Value)
{
    send(
        a_app,
        a_user,
        Method::POST,
        &format!("/api/work/tasks/{a_id}/log"),
        Some(a_body),
    )
    .await
}

async fn mark(a_app: &TestApp, a_user: &TestUser, a_status: &str, a_start: DateTime<Utc>) -> String
{
    let (status, body) = send(
        a_app,
        a_user,
        Method::POST,
        "/api/routine/marks",
        Some(json!({ "status": a_status, "start_ts": iso(a_start), "end_ts": iso(a_start + Duration::minutes(50)) })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    body["id"].as_str().unwrap().to_string()
}

fn titles(a_list: &Value) -> Vec<String>
{
    a_list
        .as_array()
        .unwrap()
        .iter()
        .map(|task| task["title"].as_str().unwrap().to_string())
        .collect()
}

#[sqlx::test(migrations = "./migrations")]
async fn general_tasks_carry_over_until_done_and_day_tasks_stay(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let today = Utc::now().date_naive();
    let first = today - Duration::days(2);
    let second = today - Duration::days(1);

    let report = task(&app, &alice, "general", "Квартальный отчёт", first).await;
    task(&app, &alice, "day", "Позвонить клиенту", first).await;
    task(&app, &alice, "day", "Стендап", second).await;

    let start = day(&app, &alice, first).await;
    assert_eq!(titles(&start["general"]), vec!["Квартальный отчёт"]);
    assert_eq!(titles(&start["day"]), vec!["Позвонить клиенту"]);
    let next = day(&app, &alice, second).await;
    assert_eq!(titles(&next["general"]), vec!["Квартальный отчёт"]);
    assert_eq!(titles(&next["day"]), vec!["Стендап"]);
    assert_eq!(
        titles(&day(&app, &alice, today).await["general"]),
        vec!["Квартальный отчёт"]
    );

    assert_eq!(
        log(&app, &alice, &report, json!({ "action": "progress", "date": second }))
            .await
            .0,
        StatusCode::BAD_REQUEST
    );
    let (status, progress) = log(
        &app,
        &alice,
        &report,
        json!({ "action": "progress", "date": second, "report": "Собрал цифры за квартал" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{progress}");
    assert_eq!(progress["task"]["done_on"], Value::Null);
    assert_eq!(progress["task"]["last_report"], "Собрал цифры за квартал");
    assert_eq!(
        log(
            &app,
            &alice,
            &report,
            json!({ "action": "done", "date": first - Duration::days(1) })
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    let (status, done) = log(
        &app,
        &alice,
        &report,
        json!({ "action": "done", "date": second, "report": "Отправил руководителю" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{done}");
    assert_eq!(done["task"]["done_on"], second.to_string());
    assert_eq!(done["task"]["report_count"], 2);
    assert_eq!(
        log(&app, &alice, &report, json!({ "action": "done", "date": second }))
            .await
            .1["code"],
        "TASK_DONE"
    );

    assert_eq!(day(&app, &alice, today).await["general"], json!([]));
    assert_eq!(
        day(&app, &alice, second).await["general"][0]["done_on"],
        second.to_string()
    );
    assert_eq!(
        day(&app, &alice, first).await["general"][0]["done_on"],
        second.to_string()
    );

    let (status, reopened) = log(
        &app,
        &alice,
        &report,
        json!({ "action": "reopen", "date": today, "report": "Попросили доработать" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{reopened}");
    assert_eq!(
        titles(&day(&app, &alice, today).await["general"]),
        vec!["Квартальный отчёт"]
    );
    let kinds: Vec<&str> = reopened["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|event| event["kind"].as_str().unwrap())
        .collect();
    assert_eq!(kinds, vec!["created", "progress", "done", "reopened"]);
    assert_eq!(reopened["events"][2]["report"], "Отправил руководителю");
    assert_eq!(reopened["events"][2]["event_on"], second.to_string());
}

#[sqlx::test(migrations = "./migrations")]
async fn edits_keep_before_and_after_and_the_log_cannot_be_rewritten(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let today = Utc::now().date_naive();
    let id = task(&app, &alice, "day", "Черновик договора", today).await;
    let uri = format!("/api/work/tasks/{id}");

    for body in [
        json!({ "kind": "day", "title": "  ", "date": today }),
        json!({ "kind": "day", "title": "Х", "date": today + Duration::days(400) }),
        json!({ "kind": "weekly", "title": "Х", "date": today }),
    ]
    {
        let status = send(&app, &alice, Method::POST, "/api/work/tasks", Some(body.clone()))
            .await
            .0;
        assert!(status.is_client_error(), "{body}");
    }

    let (status, edited) = send(
        &app,
        &alice,
        Method::PUT,
        &uri,
        Some(json!({
            "kind": "general", "title": "Договор с поставщиком", "note": "Согласовать сроки",
            "date": today - Duration::days(1)
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{edited}");
    let edits: Vec<(String, Value, Value)> = edited["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|event| event["kind"] == "edited")
        .map(|event| {
            (
                event["field"].as_str().unwrap().to_string(),
                event["old_value"].clone(),
                event["new_value"].clone(),
            )
        })
        .collect();
    assert_eq!(
        edits,
        vec![
            (
                "title".to_string(),
                json!("Черновик договора"),
                json!("Договор с поставщиком")
            ),
            ("note".to_string(), Value::Null, json!("Согласовать сроки")),
            ("kind".to_string(), json!("day"), json!("general")),
            (
                "date".to_string(),
                json!(today.to_string()),
                json!((today - Duration::days(1)).to_string())
            ),
        ]
    );
    let (_, same) = send(
        &app,
        &alice,
        Method::PUT,
        &uri,
        Some(json!({
            "kind": "general", "title": "Договор с поставщиком", "note": "Согласовать сроки",
            "date": today - Duration::days(1)
        })),
    )
    .await;
    assert_eq!(same["events"].as_array().unwrap().len(), 5);

    let pool = &app.state.db;
    assert!(sqlx::query("UPDATE work_task_events SET report = 'подмена'")
        .execute(pool)
        .await
        .is_err());
    assert!(sqlx::query("DELETE FROM work_task_events").execute(pool).await.is_err());
    assert!(sqlx::query("DELETE FROM work_tasks").execute(pool).await.is_err());

    for (method, path, body) in [
        (Method::GET, uri.clone(), None),
        (
            Method::PUT,
            uri.clone(),
            Some(json!({ "kind": "day", "title": "Чужое", "date": today })),
        ),
        (Method::DELETE, uri.clone(), None),
        (
            Method::POST,
            format!("{uri}/log"),
            Some(json!({ "action": "done", "date": today })),
        ),
    ]
    {
        assert_eq!(send(&app, &bob, method, &path, body).await.0, StatusCode::NOT_FOUND);
    }
    assert_eq!(day(&app, &bob, today).await["general"], json!([]));

    assert_eq!(
        send(&app, &alice, Method::DELETE, &uri, None).await.0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(day(&app, &alice, today).await["general"], json!([]));
    let (status, archived) = send(&app, &alice, Method::GET, &uri, None).await;
    assert_eq!(status, StatusCode::OK);
    assert!(!archived["task"]["deleted_ts"].is_null());
    assert_eq!(
        archived["events"].as_array().unwrap().last().unwrap()["kind"],
        "deleted"
    );
    let (status, body) = send(
        &app,
        &alice,
        Method::PUT,
        &uri,
        Some(json!({ "kind": "day", "title": "Воскресить", "date": today })),
    )
    .await;
    assert_eq!(
        (status, body["code"].as_str()),
        (StatusCode::CONFLICT, Some("TASK_ARCHIVED"))
    );
}

#[sqlx::test(migrations = "./migrations")]
async fn work_block_lists_tasks_and_records_what_was_done(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let home = app.family(&alice, "Home").await;
    app.join(&alice, &bob, &home, "standard").await;

    let start = Utc::now().duration_trunc(Duration::minutes(1)).unwrap() - Duration::hours(3);
    let work = mark(&app, &alice, "work", start).await;
    let lunch = mark(&app, &alice, "meal", start + Duration::hours(1)).await;
    let bob_work = mark(&app, &bob, "work", start).await;
    let block_day = start.date_naive();

    let report = task(&app, &alice, "general", "Ревью кода", block_day - Duration::days(3)).await;
    task(&app, &alice, "day", "Планёрка", block_day).await;
    task(&app, &alice, "day", "Вчерашнее", block_day - Duration::days(1)).await;

    let details_uri = format!("/api/routine/marks/{work}?tz_offset_min=0");
    let (status, details) = send(&app, &alice, Method::GET, &details_uri, None).await;
    assert_eq!(status, StatusCode::OK, "{details}");
    assert_eq!(details["work"]["date"], block_day.to_string());
    assert_eq!(titles(&details["work"]["general"]), vec!["Ревью кода"]);
    assert_eq!(titles(&details["work"]["day"]), vec!["Планёрка"]);
    assert_eq!(details["work"]["logged"], json!([]));

    for mark_id in [&lunch, &bob_work]
    {
        assert_eq!(
            log(
                &app,
                &alice,
                &report,
                json!({ "action": "progress", "date": block_day, "report": "x", "status_mark_id": mark_id })
            )
            .await
            .0,
            StatusCode::BAD_REQUEST
        );
    }
    let (status, _) = log(
        &app,
        &alice,
        &report,
        json!({ "action": "progress", "date": block_day, "report": "Разобрал два PR", "status_mark_id": work }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, details) = send(&app, &alice, Method::GET, &details_uri, None).await;
    assert_eq!(details["work"]["logged"][0]["task_title"], "Ревью кода");
    assert_eq!(details["work"]["logged"][0]["report"], "Разобрал два PR");
    assert_eq!(details["work"]["logged"][0]["kind"], "progress");

    let (_, member) = send(&app, &bob, Method::GET, &details_uri, None).await;
    assert_eq!(member["is_details_hidden"], true);
    assert_eq!(member["work"], Value::Null);
}
