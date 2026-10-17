mod common;

use axum::http::{Method, StatusCode};
use chrono::{DateTime, Duration, SecondsFormat, Utc};
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

fn encoded(a_value: DateTime<Utc>) -> String
{
    ts(a_value).replace('+', "%2B").replace(':', "%3A")
}

struct Family
{
    app: TestApp,
    anna: TestUser,
    boris: TestUser,
    dana: TestUser,
    eve: TestUser,
    home: String,
    kid: String,
}

async fn family(a_db: PgPool) -> Family
{
    let app = TestApp::new(a_db);
    let anna = app.user("anna@example.com").await;
    let boris = app.user("boris@example.com").await;
    let dana = app.user("dana@example.com").await;
    let eve = app.user("eve@example.com").await;
    let home = app.family(&anna, "Home").await;
    app.join(&anna, &boris, &home, "standard").await;
    app.join(&anna, &dana, &home, "admin").await;
    let (status, child) = send(
        &app,
        &anna,
        Method::POST,
        &format!("/api/families/{home}/children"),
        Some(json!({ "first_name": "Kid", "last_name": "Test", "birth_date": "2018-04-02", "sex": "male" })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{child}");
    let kid = child["id"].as_str().unwrap().to_string();
    Family {
        app,
        anna,
        boris,
        dana,
        eve,
        home,
        kid,
    }
}

async fn kid_mark(a_family: &Family, a_actor: &TestUser, a_status: &str, a_start: DateTime<Utc>)
    -> (StatusCode, Value)
{
    send(
        &a_family.app,
        a_actor,
        Method::POST,
        "/api/routine/marks",
        Some(json!({
            "person_id": a_family.kid, "status": a_status, "start_ts": ts(a_start),
            "end_ts": ts(a_start + Duration::minutes(20))
        })),
    )
    .await
}

#[sqlx::test(migrations = "./migrations")]
async fn admins_keep_a_childs_routine_and_members_only_watch(a_db: PgPool)
{
    let fam = family(a_db).await;
    let start = Utc::now() - Duration::hours(2);

    let (status, mark) = kid_mark(&fam, &fam.anna, "school", start).await;
    assert_eq!(status, StatusCode::CREATED, "{mark}");
    assert_eq!(kid_mark(&fam, &fam.boris, "home", start).await.0, StatusCode::FORBIDDEN);
    assert_eq!(kid_mark(&fam, &fam.eve, "home", start).await.0, StatusCode::NOT_FOUND);

    let mark_uri = format!("/api/routine/marks/{}", mark["id"].as_str().unwrap());
    let (status, edited) = send(
        &fam.app,
        &fam.dana,
        Method::PUT,
        &mark_uri,
        Some(json!({ "status": "leisure", "note": "Парк" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{edited}");
    assert_eq!(edited["status"], "leisure");
    assert_eq!(
        send(&fam.app, &fam.boris, Method::DELETE, &mark_uri, None).await.0,
        StatusCode::FORBIDDEN
    );

    let (_, details) = send(&fam.app, &fam.boris, Method::GET, &mark_uri, None).await;
    assert_eq!(details["can_edit"], false);
    assert_eq!(details["owner_name"], "Kid Test");
    let (_, details) = send(&fam.app, &fam.dana, Method::GET, &mark_uri, None).await;
    assert_eq!(details["can_edit"], true);

    let timeline_uri = format!(
        "/api/routine/timeline?family_id={}&from={}&to={}",
        fam.home,
        encoded(Utc::now() - Duration::hours(6)),
        encoded(Utc::now() + Duration::hours(1))
    );
    let editable = |a_body: &Value| -> Vec<String> {
        a_body["members"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|member| member["can_edit"] == true)
            .map(|member| member["user_id"].as_str().unwrap().to_string())
            .collect()
    };
    let (_, seen_by_boris) = send(&fam.app, &fam.boris, Method::GET, &timeline_uri, None).await;
    let kid_row = seen_by_boris["members"]
        .as_array()
        .unwrap()
        .iter()
        .find(|member| member["user_id"] == fam.kid.as_str())
        .unwrap()
        .clone();
    assert_eq!(kid_row["marks"][0]["status"], "leisure");
    assert_eq!(kid_row["is_managed"], true);
    assert_eq!(editable(&seen_by_boris), vec![fam.boris.id.to_string()]);
    let (_, seen_by_anna) = send(&fam.app, &fam.anna, Method::GET, &timeline_uri, None).await;
    let mut anna_rows = editable(&seen_by_anna);
    anna_rows.sort();
    let mut expected = vec![fam.anna.id.to_string(), fam.kid.clone()];
    expected.sort();
    assert_eq!(anna_rows, expected);

    let (_, current) = send(
        &fam.app,
        &fam.anna,
        Method::GET,
        &format!("/api/routine/current?person_id={}", fam.kid),
        None,
    )
    .await;
    assert_eq!(current, Value::Null);
    assert_eq!(
        send(
            &fam.app,
            &fam.boris,
            Method::GET,
            &format!("/api/routine/current?person_id={}", fam.kid),
            None
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
}

#[sqlx::test(migrations = "./migrations")]
async fn a_childs_meals_come_from_the_parents_store(a_db: PgPool)
{
    let fam = family(a_db).await;
    let (status, cheese) = send(
        &fam.app,
        &fam.anna,
        Method::POST,
        "/api/dicts/items",
        Some(json!({ "name": "Сир", "kind": "food", "unit": "kilogram", "nutrition": { "kcal": "350" } })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{cheese}");
    let (status, lot) = send(
        &fam.app,
        &fam.anna,
        Method::POST,
        "/api/stock/lots",
        Some(json!({ "is_personal": true, "item_id": cheese["id"], "qty": "300", "unit": "g" })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{lot}");

    let (_, meal) = kid_mark(&fam, &fam.anna, "meal", Utc::now() - Duration::minutes(40)).await;
    let today = Utc::now().date_naive();
    let entry_body = json!({
        "person_id": fam.kid, "date": today, "status_mark_id": meal["id"], "item_id": cheese["id"], "grams": "50"
    });
    let (status, entry) = send(
        &fam.app,
        &fam.anna,
        Method::POST,
        "/api/nutrition/entries",
        Some(entry_body.clone()),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{entry}");
    assert_eq!(entry["stock_short"], "0");
    assert_eq!(
        send(
            &fam.app,
            &fam.boris,
            Method::POST,
            "/api/nutrition/entries",
            Some(entry_body)
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    let (_, store) = send(&fam.app, &fam.anna, Method::GET, "/api/stock?is_personal=true", None).await;
    assert_eq!(store["lots"][0]["left_qty"], "250");

    let day_uri = format!("/api/nutrition/day?date={today}&person_id={}", fam.kid);
    let (status, by_member) = send(&fam.app, &fam.boris, Method::GET, &day_uri, None).await;
    assert_eq!(status, StatusCode::OK, "{by_member}");
    assert_eq!(by_member["can_edit"], false);
    assert_eq!(by_member["total"]["kcal"], "175");
    let (_, by_admin) = send(&fam.app, &fam.dana, Method::GET, &day_uri, None).await;
    assert_eq!(by_admin["can_edit"], true);
    assert_eq!(by_admin["person_id"], fam.kid.as_str());
    assert_eq!(
        send(&fam.app, &fam.eve, Method::GET, &day_uri, None).await.0,
        StatusCode::NOT_FOUND
    );
    let (_, own) = send(
        &fam.app,
        &fam.anna,
        Method::GET,
        &format!("/api/nutrition/day?date={today}"),
        None,
    )
    .await;
    assert_eq!(own["total"]["kcal"], "0");

    let entry_uri = format!("/api/nutrition/entries/{}", entry["id"].as_str().unwrap());
    let (status, changed) = send(
        &fam.app,
        &fam.dana,
        Method::PUT,
        &entry_uri,
        Some(json!({ "date": today, "grams": "80" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{changed}");
    assert_eq!(changed["total"]["kcal"], "280");
    assert_eq!(
        send(&fam.app, &fam.boris, Method::DELETE, &entry_uri, None).await.0,
        StatusCode::FORBIDDEN
    );
    let (_, store) = send(&fam.app, &fam.anna, Method::GET, "/api/stock?is_personal=true", None).await;
    assert_eq!(store["lots"][0]["left_qty"], "220");
    assert_eq!(
        send(&fam.app, &fam.anna, Method::DELETE, &entry_uri, None).await.0,
        StatusCode::NO_CONTENT
    );

    let (status, goal) = send(
        &fam.app,
        &fam.anna,
        Method::GET,
        &format!("/api/nutrition/goal?person_id={}", fam.kid),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{goal}");
    assert_eq!(goal["is_child"], true);
    assert_eq!(
        send(
            &fam.app,
            &fam.boris,
            Method::GET,
            &format!("/api/nutrition/goal?person_id={}", fam.kid),
            None
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
}

#[sqlx::test(migrations = "./migrations")]
async fn admins_train_and_plan_for_a_child(a_db: PgPool)
{
    let fam = family(a_db.clone()).await;
    let (_, exercises) = send(&fam.app, &fam.anna, Method::GET, "/api/dicts/exercises", None).await;
    let squat = exercises
        .as_array()
        .unwrap()
        .iter()
        .find(|exercise| exercise["code"] == "back_squat")
        .unwrap()["id"]
        .clone();
    let program_body = json!({
        "person_id": fam.kid, "name": "Зарядка", "schedule_mode": "queue",
        "days": [{ "name": "Ноги", "exercises": [{ "ex_id": squat, "sets": 2, "reps_min": 10, "reps_max": 15 }] }]
    });
    let (status, program) = send(
        &fam.app,
        &fam.anna,
        Method::POST,
        "/api/training/programs",
        Some(program_body.clone()),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{program}");
    assert_eq!(
        send(
            &fam.app,
            &fam.boris,
            Method::POST,
            "/api/training/programs",
            Some(program_body)
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    let (_, own_programs) = send(&fam.app, &fam.anna, Method::GET, "/api/training/programs", None).await;
    assert_eq!(own_programs, json!([]));
    let (_, kid_programs) = send(
        &fam.app,
        &fam.dana,
        Method::GET,
        &format!("/api/training/programs?person_id={}", fam.kid),
        None,
    )
    .await;
    assert_eq!(kid_programs[0]["name"], "Зарядка");
    assert_eq!(kid_programs[0]["is_active"], true);

    let (status, session) = send(
        &fam.app,
        &fam.dana,
        Method::POST,
        "/api/training/sessions",
        Some(json!({
            "person_id": fam.kid, "day_id": program["days"][0]["id"],
            "started_ts": ts(Utc::now() - Duration::minutes(30))
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{session}");
    let (_, current) = send(
        &fam.app,
        &fam.anna,
        Method::GET,
        &format!("/api/routine/current?person_id={}", fam.kid),
        None,
    )
    .await;
    assert_eq!(current["status"], "gym");
    let session_uri = format!("/api/training/sessions/{}", session["id"].as_str().unwrap());
    assert_eq!(
        send(
            &fam.app,
            &fam.boris,
            Method::POST,
            &format!("{session_uri}/finish"),
            Some(json!({ "intensity": 5 }))
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    let (status, finished) = send(
        &fam.app,
        &fam.anna,
        Method::POST,
        &format!("{session_uri}/finish"),
        Some(json!({ "intensity": 5 })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{finished}");
    let (status, overview) = send(
        &fam.app,
        &fam.boris,
        Method::GET,
        &format!("/api/people/{}/training", fam.kid),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{overview}");
    assert_eq!(overview["sessions"].as_array().unwrap().len(), 1);

    let event_body = json!({
        "person_id": fam.kid, "title": "Бассейн", "timing": "fixed",
        "start_date": (Utc::now() + Duration::days(1)).date_naive(), "start_time": "17:00:00",
        "duration_min": 45, "tz": "Europe/Kyiv"
    });
    let (status, event) = send(
        &fam.app,
        &fam.anna,
        Method::POST,
        "/api/plan/events",
        Some(event_body.clone()),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{event}");
    assert_eq!(
        send(&fam.app, &fam.boris, Method::POST, "/api/plan/events", Some(event_body))
            .await
            .0,
        StatusCode::FORBIDDEN
    );
    let (_, kid_events) = send(
        &fam.app,
        &fam.dana,
        Method::GET,
        &format!("/api/plan/events?person_id={}", fam.kid),
        None,
    )
    .await;
    assert_eq!(kid_events[0]["title"], "Бассейн");
    let (_, anna_events) = send(&fam.app, &fam.anna, Method::GET, "/api/plan/events", None).await;
    assert_eq!(anna_events, json!([]));
    let event_uri = format!("/api/plan/events/{}", event["id"].as_str().unwrap());
    assert_eq!(
        send(&fam.app, &fam.boris, Method::DELETE, &event_uri, None).await.0,
        StatusCode::FORBIDDEN
    );

    let reminders: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM plan_remind_due WHERE user_id = $1::uuid")
        .bind(&fam.kid)
        .fetch_one(&a_db)
        .await
        .unwrap();
    assert_eq!(reminders, 0);
    assert_eq!(
        send(&fam.app, &fam.dana, Method::DELETE, &event_uri, None).await.0,
        StatusCode::NO_CONTENT
    );
}

#[sqlx::test(migrations = "./migrations")]
async fn energy_day_draws_every_group_member_including_children(a_db: PgPool)
{
    let fam = family(a_db).await;
    let today = Utc::now().date_naive();
    let lunch = Utc::now() - Duration::hours(1);
    let (status, own_meal) = send(
        &fam.app,
        &fam.anna,
        Method::POST,
        "/api/routine/marks",
        Some(json!({ "status": "meal", "start_ts": ts(lunch), "end_ts": ts(lunch + Duration::minutes(20)) })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{own_meal}");
    let (status, kid_meal) = kid_mark(&fam, &fam.anna, "meal", lunch).await;
    assert_eq!(status, StatusCode::CREATED, "{kid_meal}");
    let quick = |a_kcal: &str, a_mark: &Value, a_person: Option<&str>| {
        json!({
            "date": today, "person_id": a_person, "status_mark_id": a_mark["id"],
            "quick": { "title": "Перекус", "kcal": a_kcal }
        })
    };
    let (status, own) = send(
        &fam.app,
        &fam.anna,
        Method::POST,
        "/api/nutrition/entries",
        Some(quick("500", &own_meal, None)),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{own}");
    let (status, kids) = send(
        &fam.app,
        &fam.anna,
        Method::POST,
        "/api/nutrition/entries",
        Some(quick("300", &kid_meal, Some(&fam.kid))),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{kids}");

    let uri = format!("/api/energy/day?date={today}&tz=UTC");
    let (status, seen_by_boris) = send(&fam.app, &fam.boris, Method::GET, &uri, None).await;
    assert_eq!(status, StatusCode::OK, "{seen_by_boris}");
    let people = seen_by_boris["people"].as_array().unwrap();
    assert_eq!(people.len(), 4);
    assert_eq!(people[0]["person_id"], fam.boris.id.to_string());
    assert_eq!(people[0]["is_me"], true);
    assert_eq!(people[0]["can_edit"], true);
    let row = |a_id: &str| {
        people
            .iter()
            .find(|person| person["person_id"] == a_id)
            .cloned()
            .unwrap()
    };
    let anna = row(&fam.anna.id.to_string());
    assert_eq!(anna["eaten"], 500);
    assert_eq!(anna["can_edit"], false);
    let jump = anna["points"]
        .as_array()
        .unwrap()
        .windows(2)
        .find(|pair| pair[0]["ts"] == pair[1]["ts"])
        .map(|pair| {
            (
                pair[0]["ts"].clone(),
                pair[1]["kcal"].as_f64().unwrap() - pair[0]["kcal"].as_f64().unwrap(),
            )
        })
        .unwrap();
    assert_eq!(jump.0, ts(lunch).replace("+00:00", "Z"));
    assert!((jump.1 - 500.0).abs() < 0.2);
    let kid = row(&fam.kid);
    assert_eq!(kid["eaten"], 300);
    assert_eq!(kid["is_managed"], true);
    assert_eq!(kid["can_edit"], false);
    assert_eq!(people.last().unwrap()["person_id"], fam.kid.as_str());

    let (_, seen_by_dana) = send(&fam.app, &fam.dana, Method::GET, &uri, None).await;
    let kid_for_dana = seen_by_dana["people"]
        .as_array()
        .unwrap()
        .iter()
        .find(|person| person["person_id"] == fam.kid.as_str())
        .cloned()
        .unwrap();
    assert_eq!(kid_for_dana["can_edit"], true);

    let (_, people_for_boris) = send(&fam.app, &fam.boris, Method::GET, "/api/people", None).await;
    let refs = people_for_boris.as_array().unwrap();
    assert_eq!(refs.len(), 4);
    assert_eq!(refs[0]["id"], fam.boris.id.to_string());
    assert_eq!(refs[0]["is_me"], true);
    assert_eq!(refs[3]["id"], fam.kid.as_str());
    assert_eq!(refs[3]["can_edit"], false);
    let (_, people_for_dana) = send(&fam.app, &fam.dana, Method::GET, "/api/people", None).await;
    assert_eq!(people_for_dana[3]["can_edit"], true);

    let (_, seen_by_eve) = send(&fam.app, &fam.eve, Method::GET, &uri, None).await;
    assert_eq!(seen_by_eve["people"].as_array().unwrap().len(), 1);
    assert_eq!(
        send(
            &fam.app,
            &fam.boris,
            Method::GET,
            &format!("/api/energy/day?date={today}&tz=Mars%2FBase"),
            None
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        send(
            &fam.app,
            &fam.boris,
            Method::GET,
            &format!("/api/energy/day?date={}&tz=UTC", today + Duration::days(5)),
            None
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
}
