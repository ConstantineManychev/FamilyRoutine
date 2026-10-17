mod common;

use axum::http::{Method, StatusCode};
use chrono::{DateTime, Datelike, Duration, DurationRound, NaiveDate, SecondsFormat, Utc};
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
    a_note: Option<&str>,
) -> String
{
    let (status, body) = send(
        a_app,
        a_user,
        Method::POST,
        "/api/routine/marks",
        Some(json!({ "status": a_status, "start_ts": iso(a_start), "end_ts": a_end.map(iso), "note": a_note })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    body["id"].as_str().unwrap().to_string()
}

async fn profile(a_app: &TestApp, a_actor: &TestUser, a_person_id: &str, a_body: Value, a_weight: &str, a_height: &str)
{
    let (status, body) = send(
        a_app,
        a_actor,
        Method::PUT,
        &format!("/api/people/{a_person_id}"),
        Some(a_body),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let (status, body) = send(
        a_app,
        a_actor,
        Method::POST,
        &format!("/api/people/{a_person_id}/entries"),
        Some(json!({
            "measured_ts": Utc::now() - Duration::days(1),
            "values": [{ "metric": "weight", "value": a_weight }, { "metric": "height", "value": a_height }]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}

fn norm_uri(a_person_id: &str) -> String
{
    format!(
        "/api/people/{a_person_id}/nutrition/norm?date={}&tz_offset_min=0",
        Utc::now().date_naive()
    )
}

#[sqlx::test(migrations = "./migrations")]
async fn group_members_see_each_others_norms(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let anna = app.user("anna@example.com").await;
    let boris = app.user("boris@example.com").await;
    let eve = app.user("eve@example.com").await;
    let home = app.family(&anna, "Home").await;
    app.join(&anna, &boris, &home, "standard").await;
    let anna_id = anna.id.to_string();

    profile(
        &app,
        &anna,
        &anna_id,
        json!({ "first_name": "Anna", "last_name": "Test", "birth_date": "1990-01-01", "sex": "female", "activity": "moderate" }),
        "64",
        "168",
    )
    .await;
    let (status, _) = send(
        &app,
        &anna,
        Method::PUT,
        "/api/nutrition/goal",
        Some(json!({ "mode": "gain", "pace_kg": "0.3", "target_kg": "68" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, own) = send(&app, &anna, Method::GET, &norm_uri(&anna_id), None).await;
    assert_eq!(status, StatusCode::OK, "{own}");
    assert_eq!(own["norm"]["mode"], "gain");
    assert_eq!(own["norm"]["delta_kcal"], "330");
    assert_eq!(own["norm"]["weight_kg"], "64");
    assert_eq!(own["norm"]["weeks_to_target"], 14);

    let (status, member) = send(&app, &boris, Method::GET, &norm_uri(&anna_id), None).await;
    assert_eq!(status, StatusCode::OK, "{member}");
    assert_eq!(member["norm"]["target"], own["norm"]["target"]);
    assert_eq!(member["norm"]["weight_kg"], "64");
    assert_eq!(
        send(&app, &eve, Method::GET, &norm_uri(&anna_id), None).await.0,
        StatusCode::NOT_FOUND
    );

    let start = Utc::now().duration_trunc(Duration::minutes(1)).unwrap() - Duration::hours(2);
    let lunch = mark(&app, &anna, "meal", start, Some(start + Duration::minutes(30)), None).await;
    let (status, entry) = send(
        &app,
        &anna,
        Method::POST,
        "/api/nutrition/entries",
        Some(
            json!({ "date": start.date_naive(), "status_mark_id": lunch, "quick": { "title": "Суп", "kcal": "250" } }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{entry}");
    let (_, details) = send(&app, &boris, Method::GET, &format!("/api/routine/marks/{lunch}"), None).await;
    assert_eq!(details["meals"]["total"]["kcal"], "250");
    assert_eq!(details["meals"]["day_norm"], own["norm"]["target"]);
    let (_, member) = send(&app, &boris, Method::GET, &norm_uri(&anna_id), None).await;
    if start.date_naive() == Utc::now().date_naive()
    {
        assert_eq!(member["eaten"]["kcal"], "250");
    }
}

#[sqlx::test(migrations = "./migrations")]
async fn minors_get_age_norms_and_cannot_diet(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let parent = app.user("parent@example.com").await;
    let teen = app.user("teen@example.com").await;
    let home = app.family(&parent, "Home").await;
    let today = Utc::now().date_naive();
    let teen_birth = NaiveDate::from_ymd_opt(today.year() - 15, 1, 1).unwrap();
    let teen_id = teen.id.to_string();

    profile(
        &app,
        &teen,
        &teen_id,
        json!({ "first_name": "Teen", "last_name": "Test", "birth_date": teen_birth, "sex": "female", "activity": "light" }),
        "52",
        "163",
    )
    .await;
    let (_, goal) = send(&app, &teen, Method::GET, "/api/nutrition/goal", None).await;
    assert_eq!(goal["is_child"], true);
    assert_eq!(goal["norm"]["kind"], "child");
    assert_eq!(goal["norm"]["age"], 15);
    assert_eq!(goal["norm"]["bmr"], Value::Null);
    let expected = (135.3 - 30.8 * 15.0 + 1.16 * (10.0 * 52.0 + 934.0 * 1.63) + 25.0_f64).round();
    assert_eq!(goal["norm"]["target"]["kcal"], format!("{expected}"));
    assert_eq!(
        goal["norm"]["target"]["fat"],
        format!("{}", (0.3 * expected / 9.0).round())
    );
    for body in [
        json!({ "mode": "lose", "pace_kg": "0.5" }),
        json!({ "mode": "gain", "pace_kg": "0.3" }),
        json!({ "mode": "maintain", "is_custom": true, "custom": { "kcal": "1500", "prot": "80", "fat": "50", "carb": "180" } }),
    ]
    {
        assert_eq!(
            send(&app, &teen, Method::PUT, "/api/nutrition/goal", Some(body.clone()))
                .await
                .0,
            StatusCode::BAD_REQUEST,
            "{body}"
        );
    }
    let (status, _) = send(
        &app,
        &teen,
        Method::PUT,
        "/api/nutrition/goal",
        Some(json!({ "mode": "maintain" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, child) = send(
        &app,
        &parent,
        Method::POST,
        &format!("/api/families/{home}/children"),
        Some(json!({
            "first_name": "Kid", "last_name": "Test", "sex": "male",
            "birth_date": NaiveDate::from_ymd_opt(today.year() - 2, 1, 1).unwrap()
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{child}");
    let child_id = child["id"].as_str().unwrap().to_string();
    let (status, _) = send(
        &app,
        &parent,
        Method::POST,
        &format!("/api/people/{child_id}/entries"),
        Some(
            json!({ "measured_ts": Utc::now() - Duration::days(1), "values": [{ "metric": "weight", "value": "12" }] }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let (status, kid) = send(&app, &parent, Method::GET, &norm_uri(&child_id), None).await;
    assert_eq!(status, StatusCode::OK, "{kid}");
    assert_eq!(kid["is_child"], true);
    assert_eq!(kid["norm"]["kind"], "child");
    assert_eq!(kid["norm"]["target"]["kcal"], "988");
    assert_eq!(kid["norm"]["weight_kg"], "12");
}

#[sqlx::test(migrations = "./migrations")]
async fn closed_meal_inside_a_block_resumes_it(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let anna = app.user("anna@example.com").await;
    let base = Utc::now().duration_trunc(Duration::minutes(1)).unwrap() - Duration::hours(5);

    let work = mark(&app, &anna, "work", base, None, Some("Офис")).await;
    let lunch = mark(
        &app,
        &anna,
        "meal",
        base + Duration::hours(2),
        Some(base + Duration::minutes(150)),
        None,
    )
    .await;
    let (_, timeline) = send(
        &app,
        &anna,
        Method::GET,
        &format!(
            "/api/routine/timeline?from={}&to={}",
            iso(base - Duration::hours(1)),
            iso(Utc::now() + Duration::hours(1))
        ),
        None,
    )
    .await;
    let marks = timeline["members"][0]["marks"].as_array().unwrap().clone();
    assert_eq!(marks.len(), 3, "{marks:?}");
    assert_eq!(marks[0]["id"], work.as_str());
    assert_eq!(
        marks[0]["end_ts"],
        iso(base + Duration::hours(2)).replace("+00:00", "Z")
    );
    assert_eq!(marks[1]["id"], lunch.as_str());
    assert_eq!(marks[2]["status"], "work");
    assert_eq!(marks[2]["note"], "Офис");
    assert_eq!(
        marks[2]["start_ts"],
        iso(base + Duration::minutes(150)).replace("+00:00", "Z")
    );
    assert_eq!(marks[2]["end_ts"], Value::Null);

    mark(&app, &anna, "home", base + Duration::hours(4), None, None).await;
    mark(
        &app,
        &anna,
        "meal",
        base + Duration::hours(3),
        Some(base + Duration::minutes(200)),
        None,
    )
    .await;
    let (_, current) = send(&app, &anna, Method::GET, "/api/routine/current", None).await;
    assert_eq!(current["status"], "home");
}
