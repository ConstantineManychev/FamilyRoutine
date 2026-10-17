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

fn body(a_title: &str, a_parent: Option<&str>, a_unit: &str, a_target: &str, a_done: &str) -> Value
{
    json!({ "parent_id": a_parent, "title": a_title, "unit": a_unit, "target": a_target, "done": a_done })
}

async fn topic(a_app: &TestApp, a_user: &TestUser, a_body: Value) -> String
{
    let (status, created) = send(a_app, a_user, Method::POST, "/api/study/topics", Some(a_body)).await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    created["id"].as_str().unwrap().to_string()
}

async fn tree(a_app: &TestApp, a_user: &TestUser) -> Value
{
    let (status, tree) = send(a_app, a_user, Method::GET, "/api/study/topics", None).await;
    assert_eq!(status, StatusCode::OK, "{tree}");
    tree
}

fn find<'a>(a_tree: &'a Value, a_id: &str) -> &'a Value
{
    a_tree["topics"]
        .as_array()
        .unwrap()
        .iter()
        .find(|topic| topic["id"] == a_id)
        .unwrap()
}

fn code(a_reply: &(StatusCode, Value)) -> (StatusCode, Option<&str>)
{
    (a_reply.0, a_reply.1["code"].as_str())
}

#[sqlx::test(migrations = "./migrations")]
async fn topics_form_a_tree_with_cycle_and_depth_guards(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;

    let mut chain = vec![topic(&app, &alice, body("Уровень 1", None, "percent", "100", "0")).await];
    for level in 2..=5
    {
        let parent = chain.last().unwrap().clone();
        chain.push(
            topic(
                &app,
                &alice,
                body(&format!("Уровень {level}"), Some(&parent), "percent", "100", "0"),
            )
            .await,
        );
    }
    let listed = tree(&app, &alice).await;
    assert_eq!(listed["max_depth"], 5);
    assert_eq!(find(&listed, &chain[4])["depth"], 5);
    assert_eq!(find(&listed, &chain[0])["child_count"], 1);

    let too_deep = send(
        &app,
        &alice,
        Method::POST,
        "/api/study/topics",
        Some(body("Уровень 6", Some(&chain[4]), "percent", "100", "0")),
    )
    .await;
    assert_eq!(code(&too_deep), (StatusCode::CONFLICT, Some("TOPIC_TOO_DEEP")));
    let cycle = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/study/topics/{}", chain[1]),
        Some(body("Уровень 2", Some(&chain[3]), "percent", "100", "0")),
    )
    .await;
    assert_eq!(code(&cycle), (StatusCode::CONFLICT, Some("TOPIC_CYCLE")));

    let other = topic(&app, &alice, body("Другая ветка", None, "percent", "100", "0")).await;
    let other_child = topic(&app, &alice, body("Подтема", Some(&other), "percent", "100", "0")).await;
    let other_grandchild = topic(
        &app,
        &alice,
        body("Под-подтема", Some(&other_child), "percent", "100", "0"),
    )
    .await;
    let moved_deep = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/study/topics/{}", chain[2]),
        Some(body("Уровень 3", Some(&other_grandchild), "percent", "100", "0")),
    )
    .await;
    assert_eq!(code(&moved_deep), (StatusCode::CONFLICT, Some("TOPIC_TOO_DEEP")));
    let (status, moved) = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/study/topics/{}", chain[2]),
        Some(body("Уровень 3", Some(&other), "percent", "100", "0")),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{moved}");
    assert_eq!(moved["depth"], 2);
    assert_eq!(find(&tree(&app, &alice).await, &chain[4])["depth"], 4);

    let shallow = TestApp::with_study_depth(a_db, 2);
    let still = tree(&shallow, &alice).await;
    assert_eq!(still["max_depth"], 2);
    assert_eq!(find(&still, &chain[4])["depth"], 4);
    let (status, _) = send(
        &shallow,
        &alice,
        Method::PUT,
        &format!("/api/study/topics/{}", chain[4]),
        Some(body("Уровень 5 — переименован", Some(&chain[3]), "pages", "40", "10")),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let blocked = send(
        &shallow,
        &alice,
        Method::POST,
        "/api/study/topics",
        Some(body("Ещё глубже", Some(&chain[1]), "percent", "100", "0")),
    )
    .await;
    assert_eq!(code(&blocked), (StatusCode::CONFLICT, Some("TOPIC_TOO_DEEP")));
    topic(
        &shallow,
        &alice,
        body("Второй уровень", Some(&chain[0]), "percent", "100", "0"),
    )
    .await;

    assert_eq!(tree(&app, &bob).await["topics"], json!([]));
    assert_eq!(
        send(
            &app,
            &bob,
            Method::PUT,
            &format!("/api/study/topics/{}", chain[0]),
            Some(body("Чужая", None, "percent", "100", "0"))
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        send(
            &app,
            &bob,
            Method::POST,
            "/api/study/topics",
            Some(body("Внутрь чужой", Some(&chain[0]), "percent", "100", "0"))
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        send(
            &app,
            &bob,
            Method::GET,
            &format!("/api/study/topics/{}/notes", chain[0]),
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
            &format!("/api/study/topics/{}", chain[4]),
            None
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );

    let has_children = send(
        &app,
        &alice,
        Method::DELETE,
        &format!("/api/study/topics/{}", chain[0]),
        None,
    )
    .await;
    assert_eq!(code(&has_children), (StatusCode::CONFLICT, Some("TOPIC_HAS_CHILDREN")));
    assert_eq!(
        send(
            &app,
            &alice,
            Method::DELETE,
            &format!("/api/study/topics/{}", chain[4]),
            None
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
}

#[sqlx::test(migrations = "./migrations")]
async fn progress_rolls_up_and_branch_notes_name_their_source(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;

    for invalid in [
        body("Проценты", None, "percent", "100", "150"),
        body("Страницы", None, "pages", "0", "0"),
        body("  ", None, "pages", "10", "0"),
    ]
    {
        assert_eq!(
            send(&app, &alice, Method::POST, "/api/study/topics", Some(invalid.clone()))
                .await
                .0,
            StatusCode::BAD_REQUEST,
            "{invalid}"
        );
    }

    let course = topic(&app, &alice, body("Курс Rust", None, "percent", "100", "90")).await;
    let first = topic(&app, &alice, body("Глава 1", Some(&course), "pages", "100", "100")).await;
    let second = topic(&app, &alice, body("Глава 2", Some(&course), "pages", "300", "60")).await;
    let listed = tree(&app, &alice).await;
    let parent = &find(&listed, &course)["progress"];
    assert_eq!(parent["is_aggregated"], true);
    assert_eq!(parent["done"], "160");
    assert_eq!(parent["target"], "400");
    assert_eq!(parent["unit"], "pages");
    assert_eq!(parent["percent"], "40");
    assert_eq!(find(&listed, &second)["progress"]["percent"], "20");

    let section = topic(&app, &alice, body("Раздел 2.1", Some(&second), "tasks", "10", "5")).await;
    let practice = topic(&app, &alice, body("Практика", Some(&course), "tasks", "10", "5")).await;
    let listed = tree(&app, &alice).await;
    assert_eq!(find(&listed, &second)["progress"]["percent"], "50");
    assert_eq!(find(&listed, &course)["progress"]["unit"], Value::Null);
    assert_eq!(find(&listed, &course)["progress"]["percent"], "66.7");

    let now = Utc::now().duration_trunc(Duration::minutes(1)).unwrap();
    let notes = [
        (&course, "Общий план курса", now - Duration::days(3)),
        (&first, "Дочитал первую главу", now - Duration::days(2)),
        (&section, "Разобрал задачи 2.1", now - Duration::days(1)),
        (&practice, "Сдал практику", now),
    ];
    let mut note_ids = Vec::new();
    for (topic_id, text, ts) in notes
    {
        let (status, note) = send(
            &app,
            &alice,
            Method::POST,
            &format!("/api/study/topics/{topic_id}/notes"),
            Some(json!({ "body": text, "note_ts": iso(ts) })),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED, "{note}");
        note_ids.push(note["id"].as_str().unwrap().to_string());
    }
    assert_eq!(
        send(
            &app,
            &alice,
            Method::POST,
            &format!("/api/study/topics/{course}/notes"),
            Some(json!({ "body": "Из будущего", "note_ts": iso(now + Duration::days(5)) }))
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );

    let (_, own) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/study/topics/{course}/notes"),
        None,
    )
    .await;
    assert_eq!(own.as_array().unwrap().len(), 1);
    assert_eq!(own[0]["topic_path"], json!(["Курс Rust"]));
    let (_, branch) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/study/topics/{course}/notes?is_branch=true"),
        None,
    )
    .await;
    let bodies: Vec<&str> = branch
        .as_array()
        .unwrap()
        .iter()
        .map(|note| note["body"].as_str().unwrap())
        .collect();
    assert_eq!(
        bodies,
        vec![
            "Сдал практику",
            "Разобрал задачи 2.1",
            "Дочитал первую главу",
            "Общий план курса"
        ]
    );
    assert_eq!(branch[1]["topic_path"], json!(["Курс Rust", "Глава 2", "Раздел 2.1"]));
    let (_, second_branch) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/study/topics/{second}/notes?is_branch=true"),
        None,
    )
    .await;
    assert_eq!(second_branch.as_array().unwrap().len(), 1);

    let (status, edited) = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/study/notes/{}", note_ids[0]),
        Some(json!({ "body": "План курса обновлён", "note_ts": iso(now - Duration::days(4)) })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{edited}");
    assert_eq!(edited["body"], "План курса обновлён");
    assert_eq!(
        send(
            &app,
            &alice,
            Method::DELETE,
            &format!("/api/study/notes/{}", note_ids[1]),
            None
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(find(&tree(&app, &alice).await, &first)["note_count"], 0);
    assert_eq!(
        send(
            &app,
            &alice,
            Method::DELETE,
            &format!("/api/study/topics/{section}"),
            None
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
    let (_, branch) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/study/topics/{course}/notes?is_branch=true"),
        None,
    )
    .await;
    assert_eq!(branch.as_array().unwrap().len(), 2);
}

#[sqlx::test(migrations = "./migrations")]
async fn school_block_shows_topics_and_notes_made_during_it(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let home = app.family(&alice, "Home").await;
    app.join(&alice, &bob, &home, "standard").await;

    let start = Utc::now().duration_trunc(Duration::minutes(1)).unwrap() - Duration::hours(3);
    let (status, school) = send(
        &app,
        &alice,
        Method::POST,
        "/api/routine/marks",
        Some(json!({ "status": "school", "start_ts": iso(start), "end_ts": iso(start + Duration::hours(1)) })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{school}");
    let school_id = school["id"].as_str().unwrap();

    let english = topic(&app, &alice, body("Английский", None, "lessons", "20", "8")).await;
    topic(&app, &alice, body("Грамматика", Some(&english), "lessons", "10", "4")).await;
    for (text, ts) in [
        ("На уроке: Present Perfect", start + Duration::minutes(20)),
        ("Вечером повторил слова", start + Duration::hours(2)),
    ]
    {
        let (status, _) = send(
            &app,
            &alice,
            Method::POST,
            &format!("/api/study/topics/{english}/notes"),
            Some(json!({ "body": text, "note_ts": iso(ts) })),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED);
    }

    let (status, details) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/routine/marks/{school_id}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{details}");
    assert_eq!(details["study"]["topics"].as_array().unwrap().len(), 1);
    assert_eq!(details["study"]["topics"][0]["progress"]["percent"], "40");
    assert_eq!(details["study"]["notes"].as_array().unwrap().len(), 1);
    assert_eq!(details["study"]["notes"][0]["body"], "На уроке: Present Perfect");

    let (_, member) = send(
        &app,
        &bob,
        Method::GET,
        &format!("/api/routine/marks/{school_id}"),
        None,
    )
    .await;
    assert_eq!(member["is_details_hidden"], true);
    assert_eq!(member["study"], Value::Null);
}
