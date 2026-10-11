mod common;

use axum::http::{Method, StatusCode};
use chrono::{Duration, Utc};
use common::{TestApp, TestUser, PASSWORD};
use serde_json::{json, Value};
use sqlx::PgPool;

async fn person(a_app: &TestApp, a_viewer: &TestUser, a_person_id: &str) -> (StatusCode, Value)
{
    let reply = a_app
        .call(
            Method::GET,
            &format!("/api/people/{a_person_id}"),
            Some(&a_viewer.token),
            None,
        )
        .await;
    (reply.status, reply.body)
}

async fn add_entry(
    a_app: &TestApp,
    a_actor: &TestUser,
    a_person_id: &str,
    a_days_ago: i64,
    a_values: Value,
) -> (StatusCode, Value)
{
    let reply = a_app
        .call(
            Method::POST,
            &format!("/api/people/{a_person_id}/entries"),
            Some(&a_actor.token),
            Some(json!({ "measured_ts": Utc::now() - Duration::days(a_days_ago), "values": a_values })),
        )
        .await;
    (reply.status, reply.body)
}

fn latest(a_profile: &Value, a_metric: &str) -> Option<Value>
{
    a_profile["latest"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["metric"] == a_metric)
        .cloned()
}

#[sqlx::test(migrations = "./migrations")]
async fn own_profile_can_be_edited_and_password_changed(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let alice_id = alice.id.to_string();

    let (status, profile) = person(&app, &alice, &alice_id).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(profile["is_self"], true);
    assert_eq!(profile["can_edit"], true);
    assert_eq!(profile["email"], "alice@example.com");
    assert_eq!(profile["sex"], Value::Null);
    assert_eq!(profile["visible_groups"], json!(["body", "composition", "measures"]));

    let updated = app
        .call(
            Method::PUT,
            &format!("/api/people/{alice_id}"),
            Some(&alice.token),
            Some(json!({
                "first_name": " Alice ", "last_name": "Smith", "birth_date": "1991-02-03",
                "sex": "female", "activity": "moderate"
            })),
        )
        .await;
    assert_eq!(updated.status, StatusCode::OK, "{}", updated.body);
    assert_eq!(updated.body["first_name"], "Alice");
    assert_eq!(updated.body["sex"], "female");
    assert_eq!(updated.body["activity"], "moderate");
    assert_eq!(updated.body["birth_date"], "1991-02-03");

    let future = app
        .call(
            Method::PUT,
            &format!("/api/people/{alice_id}"),
            Some(&alice.token),
            Some(json!({ "first_name": "A", "last_name": "S", "birth_date": "2999-01-01" })),
        )
        .await;
    assert_eq!(future.status, StatusCode::BAD_REQUEST);

    let second_session = app.login("alice@example.com").await.body["token"]
        .as_str()
        .unwrap()
        .to_string();
    let wrong = app
        .call(
            Method::POST,
            "/api/user/password",
            Some(&alice.token),
            Some(json!({ "current_password": "nope", "new_password": "new-secret" })),
        )
        .await;
    assert_eq!(
        (wrong.status, wrong.body["code"].as_str()),
        (StatusCode::CONFLICT, Some("WRONG_PASSWORD"))
    );

    let changed = app
        .call(
            Method::POST,
            "/api/user/password",
            Some(&alice.token),
            Some(json!({ "current_password": PASSWORD, "new_password": "new-secret" })),
        )
        .await;
    assert_eq!(changed.status, StatusCode::NO_CONTENT);
    assert_eq!(person(&app, &alice, &alice_id).await.0, StatusCode::OK);
    let revoked = app.call(Method::GET, "/api/user/me", Some(&second_session), None).await;
    assert_eq!(revoked.status, StatusCode::UNAUTHORIZED);
    assert_eq!(app.login("alice@example.com").await.status, StatusCode::UNAUTHORIZED);
    let relogin = app
        .call(
            Method::POST,
            "/api/auth/login",
            None,
            Some(json!({ "email": "alice@example.com", "password": "new-secret" })),
        )
        .await;
    assert_eq!(relogin.status, StatusCode::OK);
}

#[sqlx::test(migrations = "./migrations")]
async fn body_entries_keep_history_and_latest_values(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let id = alice.id.to_string();

    let (status, first) = add_entry(
        &app,
        &alice,
        &id,
        10,
        json!([{ "metric": "weight", "value": "82.4" }, { "metric": "height", "value": 180 }, { "metric": "waist", "value": 90 }]),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{first}");
    assert_eq!(first["values"].as_array().unwrap().len(), 3);
    let (status, second) = add_entry(
        &app,
        &alice,
        &id,
        1,
        json!([{ "metric": "weight", "value": 81.256 }, { "metric": "body_fat", "value": "21.5" }]),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    for invalid in [
        json!([]),
        json!([{ "metric": "weight", "value": 0 }]),
        json!([{ "metric": "body_fat", "value": 90 }]),
    ]
    {
        assert_eq!(
            add_entry(&app, &alice, &id, 0, invalid).await.0,
            StatusCode::BAD_REQUEST
        );
    }
    assert_eq!(
        add_entry(&app, &alice, &id, -3, json!([{ "metric": "weight", "value": 80 }]))
            .await
            .0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        add_entry(
            &app,
            &alice,
            &id,
            365 * 60,
            json!([{ "metric": "weight", "value": 80 }])
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );

    let (_, profile) = person(&app, &alice, &id).await;
    let weight = latest(&profile, "weight").unwrap();
    assert_eq!(weight["value"], "81.26");
    assert_eq!(weight["prev_value"], "82.40");
    assert_eq!(latest(&profile, "height").unwrap()["value"], "180.00");
    assert_eq!(latest(&profile, "waist").unwrap()["prev_value"], Value::Null);

    let history = app
        .call(
            Method::GET,
            &format!("/api/people/{id}/metrics/weight"),
            Some(&alice.token),
            None,
        )
        .await;
    let values: Vec<&str> = history
        .body
        .as_array()
        .unwrap()
        .iter()
        .map(|point| point["value"].as_str().unwrap())
        .collect();
    assert_eq!(values, ["82.40", "81.26"]);

    let second_id = second["id"].as_str().unwrap();
    let edited = app
        .call(
            Method::PUT,
            &format!("/api/people/{id}/entries/{second_id}"),
            Some(&alice.token),
            Some(json!({ "measured_ts": Utc::now() - Duration::days(2), "note": "после отпуска", "values": [{ "metric": "weight", "value": 80 }] })),
        )
        .await;
    assert_eq!(edited.status, StatusCode::OK);
    assert_eq!(edited.body["values"], json!([{ "metric": "weight", "value": "80.00" }]));
    assert_eq!(edited.body["note"], "после отпуска");
    let (_, profile) = person(&app, &alice, &id).await;
    assert!(latest(&profile, "body_fat").is_none());

    let entries = app
        .call(
            Method::GET,
            &format!("/api/people/{id}/entries"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(entries.body.as_array().unwrap().len(), 2);
    let deleted = app
        .call(
            Method::DELETE,
            &format!("/api/people/{id}/entries/{second_id}"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(deleted.status, StatusCode::NO_CONTENT);
    let (_, profile) = person(&app, &alice, &id).await;
    assert_eq!(latest(&profile, "weight").unwrap()["value"], "82.40");

    let timeline = app
        .call(
            Method::GET,
            &format!("/api/user/energy-timeline?target_date={}", Utc::now().date_naive()),
            Some(&alice.token),
            None,
        )
        .await;
    let bmr_per_hour = -timeline.body[0]["val"].as_f64().unwrap();
    let age = f64::from(timeline_age());
    let expected = (10.0 * 82.4 + 6.25 * 180.0 - 5.0 * age + 5.0) / 24.0;
    assert!((bmr_per_hour - expected).abs() < 0.01, "{bmr_per_hour} vs {expected}");
}

fn timeline_age() -> i32
{
    let today = Utc::now().date_naive();
    let birth = chrono::NaiveDate::from_ymd_opt(1990, 5, 17).unwrap();
    backend::api::user_handlers::age_on(birth, today)
}

#[sqlx::test(migrations = "./migrations")]
async fn family_sees_shared_sections_only(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let carol = app.user("carol@example.com").await;
    let fam = app.family(&alice, "Home").await;
    app.join(&alice, &bob, &fam, "standard").await;
    let id = alice.id.to_string();

    add_entry(
        &app,
        &alice,
        &id,
        1,
        json!([{ "metric": "weight", "value": 60 }, { "metric": "body_fat", "value": 24 }, { "metric": "hips", "value": 96 }]),
    )
    .await;

    let (status, seen) = person(&app, &bob, &id).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(seen["can_edit"], false);
    assert_eq!(seen["email"], Value::Null);
    assert_eq!(seen["birth_date"], Value::Null);
    assert!(seen["age"].as_i64().unwrap() > 30);
    assert_eq!(seen["latest"].as_array().unwrap().len(), 3);
    assert_eq!(seen["sharing"], json!([]));
    assert_eq!(person(&app, &carol, &id).await.0, StatusCode::NOT_FOUND);
    assert_eq!(
        add_entry(&app, &bob, &id, 0, json!([{ "metric": "weight", "value": 1 }]))
            .await
            .0,
        StatusCode::FORBIDDEN
    );

    let (_, own) = person(&app, &alice, &id).await;
    assert_eq!(own["sharing"][0]["family_name"], "Home");
    assert_eq!(own["sharing"][0]["is_composition_shared"], true);
    let hidden = app
        .call(
            Method::PUT,
            &format!("/api/people/{id}/sharing/{fam}"),
            Some(&alice.token),
            Some(json!({ "is_body_shared": false, "is_composition_shared": false, "is_measures_shared": true })),
        )
        .await;
    assert_eq!(hidden.status, StatusCode::NO_CONTENT);

    let (_, seen) = person(&app, &bob, &id).await;
    assert_eq!(seen["visible_groups"], json!(["measures"]));
    assert_eq!(seen["age"], Value::Null);
    let metrics: Vec<&str> = seen["latest"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value["metric"].as_str().unwrap())
        .collect();
    assert_eq!(metrics, ["hips"]);
    let history = app
        .call(
            Method::GET,
            &format!("/api/people/{id}/metrics/body_fat"),
            Some(&bob.token),
            None,
        )
        .await;
    assert_eq!(history.status, StatusCode::NOT_FOUND);
    let entries = app
        .call(
            Method::GET,
            &format!("/api/people/{id}/entries"),
            Some(&bob.token),
            None,
        )
        .await;
    assert_eq!(
        entries.body[0]["values"],
        json!([{ "metric": "hips", "value": "96.00" }])
    );
    let foreign = app
        .call(
            Method::PUT,
            &format!("/api/people/{id}/sharing/{fam}"),
            Some(&bob.token),
            Some(json!({ "is_body_shared": true, "is_composition_shared": true, "is_measures_shared": true })),
        )
        .await;
    assert_eq!(foreign.status, StatusCode::FORBIDDEN);
}

#[sqlx::test(migrations = "./migrations")]
async fn child_profiles_are_managed_by_admins(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let fam = app.family(&alice, "Home").await;
    app.join(&alice, &bob, &fam, "standard").await;

    let child_body = json!({ "first_name": "Миша", "last_name": "Smith", "birth_date": "2022-03-01", "sex": "male" });
    let denied = app
        .call(
            Method::POST,
            &format!("/api/families/{fam}/children"),
            Some(&bob.token),
            Some(child_body.clone()),
        )
        .await;
    assert_eq!(denied.status, StatusCode::FORBIDDEN);
    let created = app
        .call(
            Method::POST,
            &format!("/api/families/{fam}/children"),
            Some(&alice.token),
            Some(child_body),
        )
        .await;
    assert_eq!(created.status, StatusCode::CREATED, "{}", created.body);
    assert_eq!(created.body["is_managed"], true);
    assert_eq!(created.body["can_edit"], true);
    let child = created.body["id"].as_str().unwrap().to_string();

    let (status, _) = add_entry(
        &app,
        &alice,
        &child,
        1,
        json!([{ "metric": "height", "value": 96 }, { "metric": "weight", "value": 14.2 }]),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let (_, seen) = person(&app, &bob, &child).await;
    assert_eq!(seen["can_edit"], false);
    assert_eq!(seen["latest"].as_array().unwrap().len(), 2);
    assert_eq!(
        add_entry(&app, &bob, &child, 0, json!([{ "metric": "weight", "value": 14 }]))
            .await
            .0,
        StatusCode::FORBIDDEN
    );

    let detail = app
        .call(Method::GET, &format!("/api/families/{fam}"), Some(&bob.token), None)
        .await;
    let child_member = detail.body["members"]
        .as_array()
        .unwrap()
        .iter()
        .find(|member| member["id"] == child.as_str())
        .unwrap()
        .clone();
    assert_eq!(child_member["is_managed"], true);

    let promote = app
        .call(
            Method::PUT,
            &format!("/api/families/{fam}/members/{child}"),
            Some(&alice.token),
            Some(json!({ "role": "admin" })),
        )
        .await;
    assert_eq!(promote.body["code"], "CHILD_PROFILE");
    let transfer = app
        .call(
            Method::POST,
            &format!("/api/families/{fam}/transfer"),
            Some(&alice.token),
            Some(json!({ "user_id": child })),
        )
        .await;
    assert_eq!(transfer.body["code"], "CHILD_PROFILE");

    let from = (Utc::now() - Duration::hours(12)).to_rfc3339();
    let to = (Utc::now() + Duration::hours(12)).to_rfc3339();
    let timeline = app
        .call(
            Method::GET,
            &format!(
                "/api/routine/timeline?family_id={fam}&from={}&to={}",
                urlencode(&from),
                urlencode(&to)
            ),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(timeline.status, StatusCode::OK, "{}", timeline.body);
    assert!(!timeline.body.to_string().contains(&child));

    let no_login: Option<String> = sqlx::query_scalar("SELECT email FROM users WHERE id = $1::uuid")
        .bind(&child)
        .fetch_one(&a_db)
        .await
        .unwrap();
    assert!(no_login.is_none());

    let removed = app
        .call(
            Method::DELETE,
            &format!("/api/families/{fam}/members/{child}"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(removed.status, StatusCode::NO_CONTENT);
    assert_eq!(person(&app, &alice, &child).await.0, StatusCode::NOT_FOUND);
    let left: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM body_entries WHERE user_id = $1::uuid")
        .bind(&child)
        .fetch_one(&a_db)
        .await
        .unwrap();
    assert_eq!(left, 0);
}

#[sqlx::test(migrations = "./migrations")]
async fn last_adult_leaving_removes_the_family_and_its_children(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let fam = app.family(&alice, "Home").await;
    let created = app
        .call(
            Method::POST,
            &format!("/api/families/{fam}/children"),
            Some(&alice.token),
            Some(json!({ "first_name": "Ann", "last_name": "Smith", "birth_date": "2020-01-01", "sex": "female" })),
        )
        .await;
    let child = created.body["id"].as_str().unwrap().to_string();

    let left = app
        .call(
            Method::POST,
            &format!("/api/families/{fam}/leave"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(left.status, StatusCode::NO_CONTENT);
    assert_eq!(person(&app, &alice, &child).await.0, StatusCode::NOT_FOUND);
}

fn urlencode(a_value: &str) -> String
{
    a_value.replace('+', "%2B").replace(':', "%3A")
}
