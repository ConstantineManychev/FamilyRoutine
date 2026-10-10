mod common;

use axum::http::{Method, StatusCode};
use chrono::{DateTime, Duration, SecondsFormat, Utc};
use common::{TestApp, TestUser};
use serde_json::{json, Value};
use sqlx::PgPool;

fn iso(a_ts: DateTime<Utc>) -> String
{
    a_ts.to_rfc3339_opts(SecondsFormat::Secs, true)
}

async fn mark(a_app: &TestApp, a_user: &TestUser, a_status: &str, a_start: DateTime<Utc>) -> Value
{
    let reply = a_app
        .call(
            Method::POST,
            "/api/routine/marks",
            Some(&a_user.token),
            Some(json!({ "status": a_status, "start_ts": iso(a_start) })),
        )
        .await;
    assert_eq!(reply.status, StatusCode::CREATED, "{}", reply.body);
    reply.body
}

async fn timeline(
    a_app: &TestApp,
    a_user: &TestUser,
    a_family: Option<&str>,
    a_now: DateTime<Utc>,
) -> (StatusCode, Value)
{
    let mut uri = format!(
        "/api/routine/timeline?from={}&to={}",
        iso(a_now - Duration::hours(12)).replace('+', "%2B"),
        iso(a_now + Duration::hours(12)).replace('+', "%2B")
    );
    if let Some(family) = a_family
    {
        uri.push_str(&format!("&family_id={family}"));
    }

    let reply = a_app.call(Method::GET, &uri, Some(&a_user.token), None).await;
    (reply.status, reply.body)
}

fn statuses(a_member: &Value) -> Vec<(String, Option<String>)>
{
    a_member["marks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|mark| {
            (
                mark["status"].as_str().unwrap().to_string(),
                mark["end_ts"].as_str().map(str::to_string),
            )
        })
        .collect()
}

fn member_names(a_timeline: &Value) -> Vec<String>
{
    a_timeline["members"]
        .as_array()
        .unwrap()
        .iter()
        .map(|member| member["last_name"].as_str().unwrap().to_string())
        .collect()
}

#[sqlx::test(migrations = "./migrations")]
async fn marks_split_the_day_without_overlaps(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let anna = app.user("anna@example.com").await;
    let now = Utc::now();

    mark(&app, &anna, "work", now - Duration::hours(6)).await;
    mark(&app, &anna, "meal", now - Duration::hours(2)).await;
    let transit = mark(&app, &anna, "transit", now - Duration::hours(4)).await;
    assert_eq!(transit["end_ts"], iso(now - Duration::hours(2)));

    mark(&app, &anna, "leisure", now - Duration::hours(2)).await;

    let (status, body) = timeline(&app, &anna, None, now).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        statuses(&body["members"][0]),
        vec![
            ("work".to_string(), Some(iso(now - Duration::hours(4)))),
            ("transit".to_string(), Some(iso(now - Duration::hours(2)))),
            ("leisure".to_string(), None),
        ]
    );

    let too_old = app
        .call(
            Method::POST,
            "/api/routine/marks",
            Some(&anna.token),
            Some(json!({ "status": "work", "start_ts": iso(now - Duration::days(40)) })),
        )
        .await;
    assert_eq!(too_old.status, StatusCode::BAD_REQUEST);

    let too_wide = app
        .call(
            Method::GET,
            &format!(
                "/api/routine/timeline?from={}&to={}",
                iso(now - Duration::days(10)),
                iso(now)
            ),
            Some(&anna.token),
            None,
        )
        .await;
    assert_eq!(too_wide.status, StatusCode::BAD_REQUEST);
}

#[sqlx::test(migrations = "./migrations")]
async fn family_timeline_respects_membership_and_sharing(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let anna = app.user("anna@example.com").await;
    let boris = app.user("boris@example.com").await;
    let vera = app.user("vera@example.com").await;
    let eve = app.user("eve@example.com").await;
    let fam_id = app.family(&anna, "Home").await;
    app.join(&anna, &boris, &fam_id, "standard").await;
    app.join(&anna, &vera, &fam_id, "standard").await;

    let now = Utc::now();
    mark(&app, &anna, "work", now - Duration::hours(1)).await;
    let boris_mark = mark(&app, &boris, "gym", now - Duration::hours(1)).await;
    mark(&app, &eve, "home", now - Duration::hours(1)).await;

    let (status, body) = timeline(&app, &boris, Some(&fam_id), now).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(member_names(&body), vec!["boris", "anna", "vera"]);
    assert_eq!(body["members"][0]["is_me"], true);
    assert_eq!(statuses(&body["members"][1]), vec![("work".to_string(), None)]);

    let (status, _) = timeline(&app, &eve, Some(&fam_id), now).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let hidden = app
        .call(
            Method::PUT,
            &format!("/api/families/{fam_id}/routine-sharing"),
            Some(&anna.token),
            Some(json!({ "is_shared": false })),
        )
        .await;
    assert_eq!(hidden.status, StatusCode::NO_CONTENT);

    let (_, body) = timeline(&app, &boris, Some(&fam_id), now).await;
    assert_eq!(member_names(&body), vec!["boris", "vera"]);
    let (_, body) = timeline(&app, &anna, Some(&fam_id), now).await;
    assert_eq!(member_names(&body), vec!["anna", "boris", "vera"]);

    let detail = app
        .call(Method::GET, &format!("/api/families/{fam_id}"), Some(&anna.token), None)
        .await;
    assert_eq!(detail.body["is_routine_shared"], false);

    let outsider_sharing = app
        .call(
            Method::PUT,
            &format!("/api/families/{fam_id}/routine-sharing"),
            Some(&eve.token),
            Some(json!({ "is_shared": true })),
        )
        .await;
    assert_eq!(outsider_sharing.status, StatusCode::NOT_FOUND);

    let mark_uri = format!("/api/routine/marks/{}", boris_mark["id"].as_str().unwrap());
    let foreign_update = app
        .call(
            Method::PUT,
            &mark_uri,
            Some(&anna.token),
            Some(json!({ "status": "work" })),
        )
        .await;
    assert_eq!(foreign_update.status, StatusCode::NOT_FOUND);
    let foreign_delete = app.call(Method::DELETE, &mark_uri, Some(&anna.token), None).await;
    assert_eq!(foreign_delete.status, StatusCode::NOT_FOUND);

    let own_update = app
        .call(
            Method::PUT,
            &mark_uri,
            Some(&boris.token),
            Some(json!({ "status": "school", "note": "  exam  " })),
        )
        .await;
    assert_eq!(own_update.status, StatusCode::OK);
    assert_eq!(own_update.body["status"], "school");
    assert_eq!(own_update.body["note"], "exam");
}

#[sqlx::test(migrations = "./migrations")]
async fn dashboards_are_private_and_track_family_access(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let anna = app.user("anna@example.com").await;
    let boris = app.user("boris@example.com").await;
    let home = app.family(&anna, "Home").await;
    let work = app.family(&boris, "Work").await;
    app.join(&anna, &boris, &home, "standard").await;

    let created = app
        .call(
            Method::POST,
            "/api/dashboards",
            Some(&boris.token),
            Some(json!({ "name": "Main", "is_prefilled": true })),
        )
        .await;
    assert_eq!(created.status, StatusCode::CREATED, "{}", created.body);
    let dash_id = created.body["id"].as_str().unwrap().to_string();
    let kinds: Vec<(String, Value)> = created.body["widgets"]
        .as_array()
        .unwrap()
        .iter()
        .map(|widget| {
            (
                widget["kind"].as_str().unwrap().to_string(),
                widget["family_name"].clone(),
            )
        })
        .collect();
    assert_eq!(
        kinds,
        vec![
            ("my_status".to_string(), Value::Null),
            ("family_timeline".to_string(), json!("Work")),
            ("family_timeline".to_string(), json!("Home")),
            ("cashflow".to_string(), Value::Null),
        ]
    );

    let dash_uri = format!("/api/dashboards/{dash_id}");
    let foreign_rename = app
        .call(
            Method::PUT,
            &dash_uri,
            Some(&anna.token),
            Some(json!({ "name": "Mine" })),
        )
        .await;
    assert_eq!(foreign_rename.status, StatusCode::NOT_FOUND);
    let foreign_widget = app
        .call(
            Method::POST,
            &format!("{dash_uri}/widgets"),
            Some(&anna.token),
            Some(json!({ "kind": "my_status" })),
        )
        .await;
    assert_eq!(foreign_widget.status, StatusCode::NOT_FOUND);
    let anna_list = app.call(Method::GET, "/api/dashboards", Some(&anna.token), None).await;
    assert_eq!(anna_list.body, json!([]));

    let anna_dash = app
        .call(
            Method::POST,
            "/api/dashboards",
            Some(&anna.token),
            Some(json!({ "name": "Anna" })),
        )
        .await;
    let anna_dash_id = anna_dash.body["id"].as_str().unwrap();
    let not_member = app
        .call(
            Method::POST,
            &format!("/api/dashboards/{anna_dash_id}/widgets"),
            Some(&anna.token),
            Some(json!({ "kind": "family_timeline", "family_id": work })),
        )
        .await;
    assert_eq!(not_member.status, StatusCode::BAD_REQUEST);
    let missing_family = app
        .call(
            Method::POST,
            &format!("/api/dashboards/{anna_dash_id}/widgets"),
            Some(&anna.token),
            Some(json!({ "kind": "family_timeline" })),
        )
        .await;
    assert_eq!(missing_family.status, StatusCode::BAD_REQUEST);

    let widget_ids: Vec<String> = created.body["widgets"]
        .as_array()
        .unwrap()
        .iter()
        .map(|widget| widget["id"].as_str().unwrap().to_string())
        .collect();
    let reversed: Vec<&String> = widget_ids.iter().rev().collect();
    let reordered = app
        .call(
            Method::PUT,
            &format!("{dash_uri}/widgets/order"),
            Some(&boris.token),
            Some(json!({ "widget_ids": reversed })),
        )
        .await;
    assert_eq!(reordered.status, StatusCode::OK);
    assert_eq!(reordered.body["widgets"][0]["kind"], "cashflow");

    let partial = app
        .call(
            Method::PUT,
            &format!("{dash_uri}/widgets/order"),
            Some(&boris.token),
            Some(json!({ "widget_ids": [widget_ids[0]] })),
        )
        .await;
    assert_eq!(partial.status, StatusCode::BAD_REQUEST);

    let left = app
        .call(
            Method::POST,
            &format!("/api/families/{home}/leave"),
            Some(&boris.token),
            None,
        )
        .await;
    assert!(left.status.is_success(), "{}", left.body);

    let list = app.call(Method::GET, "/api/dashboards", Some(&boris.token), None).await;
    let home_widget = list.body[0]["widgets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|widget| widget["family_id"] == json!(home))
        .unwrap()
        .clone();
    assert_eq!(home_widget["is_available"], false);
    assert_eq!(home_widget["family_name"], Value::Null);

    let removed = app
        .call(
            Method::DELETE,
            &format!("{dash_uri}/widgets/{}", home_widget["id"].as_str().unwrap()),
            Some(&boris.token),
            None,
        )
        .await;
    assert_eq!(removed.status, StatusCode::NO_CONTENT);

    let foreign_delete = app.call(Method::DELETE, &dash_uri, Some(&anna.token), None).await;
    assert_eq!(foreign_delete.status, StatusCode::NOT_FOUND);
    let deleted = app.call(Method::DELETE, &dash_uri, Some(&boris.token), None).await;
    assert_eq!(deleted.status, StatusCode::NO_CONTENT);
}
