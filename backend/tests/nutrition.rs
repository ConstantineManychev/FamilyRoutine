mod common;

use axum::http::{Method, StatusCode};
use chrono::{Datelike, Duration, NaiveDate, Utc};
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

async fn food(a_app: &TestApp, a_user: &TestUser, a_name: &str, a_unit: &str, a_nutrition: Value) -> String
{
    let (status, item) = send(
        a_app,
        a_user,
        Method::POST,
        "/api/dicts/items",
        Some(json!({ "name": a_name, "kind": "food", "unit": a_unit, "nutrition": a_nutrition })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{item}");
    item["id"].as_str().unwrap().to_string()
}

async fn add(a_app: &TestApp, a_user: &TestUser, a_body: Value) -> (StatusCode, Value)
{
    send(a_app, a_user, Method::POST, "/api/nutrition/entries", Some(a_body)).await
}

async fn day(a_app: &TestApp, a_user: &TestUser, a_date: NaiveDate) -> Value
{
    let (status, day) = send(
        a_app,
        a_user,
        Method::GET,
        &format!("/api/nutrition/day?date={a_date}&tz_offset_min=180"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{day}");
    day
}

fn meal<'a>(a_day: &'a Value, a_meal: &str) -> &'a Value
{
    a_day["meals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|group| group["meal"] == a_meal)
        .unwrap()
}

fn age_today(a_birth: NaiveDate) -> i32
{
    let today = Utc::now().date_naive();
    let mut age = today.year() - a_birth.year();
    if (today.month(), today.day()) < (a_birth.month(), a_birth.day())
    {
        age -= 1;
    }
    age
}

#[sqlx::test(migrations = "./migrations")]
async fn dishes_account_for_cooking_and_diary_keeps_snapshots(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let today = Utc::now().date_naive();

    let buckwheat = food(
        &app,
        &alice,
        "Гречка",
        "kilogram",
        json!({ "kcal": "343", "prot": "13.3", "fat": "3.4", "carb": "62.1" }),
    )
    .await;
    let egg = food(
        &app,
        &alice,
        "Яйцо",
        "piece",
        json!({ "kcal": "157", "prot": "12.7", "fat": "11.5", "carb": "0.7", "piece_g": "55" }),
    )
    .await;
    let salt = food(&app, &alice, "Соль", "kilogram", json!({})).await;
    let milk = food(&app, &alice, "Молоко", "liter", json!({ "kcal": "52" })).await;
    let (_, item) = send(&app, &alice, Method::GET, &format!("/api/dicts/items/{egg}"), None).await;
    assert_eq!(item["nutrition"]["piece_g"], "55");
    let (_, service) = send(
        &app,
        &alice,
        Method::POST,
        "/api/dicts/items",
        Some(json!({ "name": "Доставка", "kind": "service", "unit": "piece" })),
    )
    .await;
    let service = service["id"].as_str().unwrap().to_string();
    let (_, foods) = send(
        &app,
        &alice,
        Method::GET,
        "/api/dicts/items?kind=food&q=%D0%93%D1%80%D0%B5",
        None,
    )
    .await;
    assert_eq!(foods.as_array().unwrap().len(), 1);

    let (status, dish) = send(
        &app,
        &alice,
        Method::POST,
        "/api/dishes",
        Some(json!({
            "name": "Гречка варёная", "cooked_g": "600", "servings": 3,
            "ingredients": [{ "item_id": buckwheat, "grams": "200" }, { "item_id": salt, "grams": "4" }]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{dish}");
    let dish_id = dish["id"].as_str().unwrap().to_string();
    assert_eq!(dish["raw_g"], "204");
    assert_eq!(dish["cooked_g"], "600");
    assert_eq!(dish["is_cooked_set"], true);
    assert_eq!(dish["portion_g"], "200");
    assert_eq!(dish["missing_count"], 1);
    assert_eq!(
        dish["per_100"],
        json!({ "kcal": "114.33", "prot": "4.43", "fat": "1.13", "carb": "20.7" })
    );
    assert_eq!(dish["ingredients"][0]["total"]["kcal"], "686");

    let (status, _) = send(
        &app,
        &alice,
        Method::POST,
        "/api/dishes",
        Some(json!({ "name": "Ошибка", "ingredients": [{ "item_id": service, "grams": "100" }] })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = send(
        &app,
        &alice,
        Method::POST,
        "/api/dishes",
        Some(json!({ "name": "Сушка", "cooked_g": "10", "ingredients": [{ "item_id": buckwheat, "grams": "200" }] })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, by_portion) = add(
        &app,
        &alice,
        json!({ "date": today, "meal": "lunch", "dish_id": dish_id, "portions": "1.5" }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{by_portion}");
    assert_eq!(by_portion["grams"], "300");
    assert_eq!(by_portion["portions"], "1.5");
    assert_eq!(by_portion["total"]["kcal"], "343");
    let (_, by_pieces) = add(
        &app,
        &alice,
        json!({ "date": today, "meal": "breakfast", "item_id": egg, "portions": "2" }),
    )
    .await;
    assert_eq!(by_pieces["grams"], "110");
    assert_eq!(
        by_pieces["total"],
        json!({ "kcal": "172.7", "prot": "14", "fat": "12.7", "carb": "0.8" })
    );
    let (_, glass) = add(
        &app,
        &alice,
        json!({ "date": today, "meal": "breakfast", "item_id": milk, "grams": "250" }),
    )
    .await;
    assert_eq!(glass["is_ml"], true);
    assert_eq!(glass["total"]["kcal"], "130");
    let (status, quick) = add(
        &app,
        &alice,
        json!({ "date": today, "meal": "snack", "quick": { "title": "Кофе с собой", "kcal": "120", "fat": "6" } }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{quick}");
    assert_eq!(
        quick["total"],
        json!({ "kcal": "120", "prot": "0", "fat": "6", "carb": "0" })
    );

    for body in [
        json!({ "date": today, "meal": "lunch", "item_id": salt, "grams": "5" }),
        json!({ "date": today, "meal": "lunch", "item_id": service, "grams": "5" }),
        json!({ "date": today, "meal": "lunch", "item_id": milk, "portions": "1" }),
        json!({ "date": today, "meal": "lunch", "item_id": egg }),
        json!({ "date": today, "meal": "lunch", "item_id": egg, "dish_id": dish_id, "grams": "5" }),
        json!({ "date": today + Duration::days(30), "meal": "lunch", "item_id": egg, "grams": "5" }),
    ]
    {
        assert_eq!(
            add(&app, &alice, body.clone()).await.0,
            StatusCode::BAD_REQUEST,
            "{body}"
        );
    }

    let (status, _) = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/dishes/{dish_id}"),
        Some(json!({
            "name": "Гречка варёная", "cooked_g": "400", "serving_g": "250",
            "ingredients": [{ "item_id": buckwheat, "grams": "200" }]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, egg_item) = send(&app, &alice, Method::GET, &format!("/api/dicts/items/{egg}"), None).await;
    let (status, _) = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/dicts/items/{egg}"),
        Some(json!({
            "name": egg_item["name"], "kind": "food", "unit": "piece",
            "nutrition": { "kcal": "200", "piece_g": "60" }
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let summary = day(&app, &alice, today).await;
    let lunch = meal(&summary, "lunch");
    assert_eq!(lunch["entries"][0]["total"]["kcal"], "343");
    assert_eq!(lunch["entries"][0]["per_100"]["kcal"], "114.33");
    assert_eq!(meal(&summary, "breakfast")["total"]["kcal"], "302.7");
    assert_eq!(meal(&summary, "dinner")["entries"], json!([]));
    assert_eq!(summary["total"]["kcal"], "765.7");
    assert_eq!(summary["norm"], Value::Null);
    assert_eq!(summary["norm_gaps"], json!(["weight", "height", "sex", "activity"]));

    let entry_id = by_portion["id"].as_str().unwrap();
    let (status, moved) = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/nutrition/entries/{entry_id}"),
        Some(json!({ "date": today, "meal": "dinner", "portions": "1" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{moved}");
    assert_eq!(moved["meal"], "dinner");
    assert_eq!(moved["grams"], "200");
    assert_eq!(moved["total"]["kcal"], "228.7");
    let quick_id = quick["id"].as_str().unwrap();
    let (status, _) = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/nutrition/entries/{quick_id}"),
        Some(json!({ "date": today, "meal": "snack", "grams": "100" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (_, fresh) = add(
        &app,
        &alice,
        json!({ "date": today, "meal": "dinner", "dish_id": dish_id, "portions": "1" }),
    )
    .await;
    assert_eq!(fresh["grams"], "250");
    assert_eq!(fresh["total"]["kcal"], "428.8");

    let (status, profile) = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/people/{}", alice.id),
        Some(json!({
            "first_name": "Alice", "last_name": "Test", "birth_date": "1990-05-17",
            "sex": "female", "activity": "light"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{profile}");
    let (status, _) = send(
        &app,
        &alice,
        Method::POST,
        &format!("/api/people/{}/entries", alice.id),
        Some(json!({
            "measured_ts": Utc::now() - Duration::days(1),
            "values": [{ "metric": "weight", "value": "60" }, { "metric": "height", "value": "165" }]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let summary = day(&app, &alice, today).await;
    let age = age_today(NaiveDate::from_ymd_opt(1990, 5, 17).unwrap());
    let bmr = 600.0 + 1031.25 - 5.0 * f64::from(age) - 161.0;
    assert_eq!(summary["norm"]["bmr"], format!("{}", bmr.round()));
    assert_eq!(summary["norm"]["target"]["kcal"], format!("{}", (bmr * 1.375).round()));
    assert_eq!(summary["norm"]["target"]["prot"], "96");
    assert_eq!(summary["norm"]["weight_kg"], "60");
    assert_eq!(summary["norm_gaps"], json!([]));

    let tomorrow = today + Duration::days(1);
    let (status, copied) = send(
        &app,
        &alice,
        Method::POST,
        "/api/nutrition/copy",
        Some(json!({ "from": today, "to": tomorrow, "meal": "breakfast" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{copied}");
    assert_eq!(copied["copied"], 2);
    let next = day(&app, &alice, tomorrow).await;
    assert_eq!(meal(&next, "breakfast")["total"]["kcal"], "302.7");
    assert_eq!(meal(&next, "breakfast")["entries"][0]["title"], "Яйцо");

    let (_, recent) = send(&app, &alice, Method::GET, "/api/nutrition/recent", None).await;
    let recent = recent.as_array().unwrap();
    assert_eq!(recent.len(), 3);
    assert!(recent
        .iter()
        .any(|food| food["dish_id"] == dish_id.as_str() && food["portions"] == "1"));

    let (status, _) = send(
        &app,
        &alice,
        Method::DELETE,
        &format!("/api/dicts/items/{buckwheat}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    let (status, _) = send(&app, &alice, Method::DELETE, &format!("/api/dishes/{dish_id}"), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let summary = day(&app, &alice, today).await;
    assert_eq!(meal(&summary, "dinner")["entries"][0]["total"]["kcal"], "228.7");
    assert_eq!(meal(&summary, "dinner")["entries"][0]["dish_id"], Value::Null);
    assert_eq!(meal(&summary, "dinner")["entries"][0]["title"], "Гречка варёная");

    let alice_entry = glass["id"].as_str().unwrap();
    assert_eq!(
        send(
            &app,
            &bob,
            Method::PUT,
            &format!("/api/nutrition/entries/{alice_entry}"),
            Some(json!({ "date": today, "meal": "lunch", "grams": "100" }))
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
            &format!("/api/nutrition/entries/{alice_entry}"),
            None
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(day(&app, &bob, today).await["total"]["kcal"], "0");
}

#[sqlx::test(migrations = "./migrations")]
async fn dishes_are_private_until_shared_with_the_group(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let anna = app.user("anna@example.com").await;
    let boris = app.user("boris@example.com").await;
    let eve = app.user("eve@example.com").await;
    let home = app.family(&anna, "Home").await;
    app.join(&anna, &boris, &home, "standard").await;
    let today = Utc::now().date_naive();

    let rice = food(
        &app,
        &anna,
        "Рис",
        "kilogram",
        json!({ "kcal": "360", "prot": "7", "fat": "1", "carb": "79" }),
    )
    .await;
    let dish_body = |a_is_shared: bool| {
        json!({
            "name": "Плов", "serving_g": "300", "is_shared": a_is_shared,
            "ingredients": [{ "item_id": rice, "grams": "500" }]
        })
    };
    let (_, dish) = send(&app, &anna, Method::POST, "/api/dishes", Some(dish_body(false))).await;
    let dish_id = dish["id"].as_str().unwrap().to_string();
    let dish_uri = format!("/api/dishes/{dish_id}");

    assert_eq!(
        send(&app, &boris, Method::GET, &dish_uri, None).await.0,
        StatusCode::NOT_FOUND
    );
    let (_, listed) = send(&app, &boris, Method::GET, "/api/dishes", None).await;
    assert_eq!(listed, json!([]));
    assert_eq!(
        add(
            &app,
            &boris,
            json!({ "date": today, "meal": "lunch", "dish_id": dish_id, "grams": "100" })
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );

    let (status, _) = send(&app, &anna, Method::PUT, &dish_uri, Some(dish_body(true))).await;
    assert_eq!(status, StatusCode::OK);
    let (status, seen) = send(&app, &boris, Method::GET, &dish_uri, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(seen["is_editable"], false);
    assert_eq!(seen["owner_name"].as_str().map(|name| name.is_empty()), Some(false));
    let (_, listed) = send(
        &app,
        &boris,
        Method::GET,
        "/api/dishes?q=%D0%9F%D0%BB%D0%BE%D0%B2",
        None,
    )
    .await;
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["ingredients"], json!([]));
    let (status, eaten) = add(
        &app,
        &boris,
        json!({ "date": today, "meal": "lunch", "dish_id": dish_id, "portions": "1" }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{eaten}");
    assert_eq!(eaten["total"]["kcal"], "1080");

    assert_eq!(
        send(&app, &boris, Method::PUT, &dish_uri, Some(dish_body(true)))
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        send(&app, &boris, Method::DELETE, &dish_uri, None).await.0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        send(&app, &eve, Method::GET, &dish_uri, None).await.0,
        StatusCode::NOT_FOUND
    );

    let (status, _) = send(&app, &anna, Method::DELETE, &format!("/api/dicts/items/{rice}"), None).await;
    assert_eq!(status, StatusCode::CONFLICT);
    let (_, boris_dish) = send(
        &app,
        &boris,
        Method::POST,
        "/api/dishes",
        Some(json!({ "name": "Рис", "ingredients": [{ "item_id": rice, "grams": "100" }] })),
    )
    .await;
    assert_eq!(boris_dish["cooked_g"], "100");
    let (_, item) = send(&app, &anna, Method::GET, &format!("/api/dicts/items/{rice}"), None).await;
    assert_eq!(item["is_in_use"], true);
}
