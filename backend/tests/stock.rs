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

async fn item(a_app: &TestApp, a_user: &TestUser, a_body: Value) -> String
{
    let (status, item) = send(a_app, a_user, Method::POST, "/api/dicts/items", Some(a_body)).await;
    assert_eq!(status, StatusCode::CREATED, "{item}");
    item["id"].as_str().unwrap().to_string()
}

fn ts(a_value: DateTime<Utc>) -> String
{
    a_value.to_rfc3339_opts(SecondsFormat::Secs, true)
}

async fn meal_block(a_app: &TestApp, a_user: &TestUser) -> String
{
    let start = Utc::now() - Duration::minutes(30);
    let (status, mark) = send(
        a_app,
        a_user,
        Method::POST,
        "/api/routine/marks",
        Some(json!({ "status": "meal", "start_ts": ts(start), "end_ts": ts(start + Duration::minutes(20)) })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{mark}");
    mark["id"].as_str().unwrap().to_string()
}

async fn eat(a_app: &TestApp, a_user: &TestUser, a_mark: &str, a_source: Value) -> Value
{
    let mut body = json!({ "date": Utc::now().date_naive(), "status_mark_id": a_mark });
    for (key, value) in a_source.as_object().unwrap()
    {
        body[key] = value.clone();
    }
    let (status, entry) = send(a_app, a_user, Method::POST, "/api/nutrition/entries", Some(body)).await;
    assert_eq!(status, StatusCode::CREATED, "{entry}");
    entry
}

async fn stock(a_app: &TestApp, a_user: &TestUser, a_query: &str) -> Value
{
    let (status, stock) = send(a_app, a_user, Method::GET, &format!("/api/stock{a_query}"), None).await;
    assert_eq!(status, StatusCode::OK, "{stock}");
    stock
}

fn left_of(a_stock: &Value, a_title: &str) -> Vec<String>
{
    a_stock["lots"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|lot| lot["title"] == a_title)
        .map(|lot| lot["left_qty"].as_str().unwrap().to_string())
        .collect()
}

async fn receipt(a_app: &TestApp, a_user: &TestUser, a_id: Option<&str>, a_body: Value) -> Value
{
    let (method, uri) = match a_id
    {
        Some(id) => (Method::PUT, format!("/api/receipts/{id}")),
        None => (Method::POST, "/api/receipts".to_string()),
    };
    let (status, receipt) = send(a_app, a_user, method, &uri, Some(a_body)).await;
    assert!(status.is_success(), "{receipt}");
    receipt
}

#[sqlx::test(migrations = "./migrations")]
async fn receipts_fill_the_store_and_the_diary_takes_oldest_lots_first(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let uah = app.currency_by_code(&alice.token, "UAH").await;
    let milk = item(
        &app,
        &alice,
        json!({ "name": "Молоко", "kind": "food", "unit": "piece", "net_qty": "930", "net_measure": "ml",
                "nutrition": { "kcal": "52", "prot": "2.9", "fat": "2.5", "carb": "4.7" } }),
    )
    .await;
    let buckwheat = item(
        &app,
        &alice,
        json!({ "name": "Гречка", "kind": "food", "unit": "kilogram",
                "nutrition": { "kcal": "343", "prot": "13.3", "fat": "3.4", "carb": "62.1" } }),
    )
    .await;
    let candle = item(
        &app,
        &alice,
        json!({ "name": "Свеча", "kind": "product", "unit": "piece" }),
    )
    .await;
    let haircut = item(
        &app,
        &alice,
        json!({ "name": "Стрижка", "kind": "service", "unit": "piece" }),
    )
    .await;

    let first_body = json!({
        "receipt_ts": ts(Utc::now() - Duration::days(3)), "curr_id": uah, "discount": "37",
        "items": [
            { "item_id": milk, "qty": "2", "amount": "80" },
            { "item_id": buckwheat, "qty": "1", "amount": "60" },
            { "item_id": candle, "qty": "3", "amount": "30" },
            { "item_id": haircut, "qty": "1", "amount": "200" }
        ]
    });
    let first = receipt(&app, &alice, None, first_body.clone()).await;
    assert_eq!(first["is_stocked"], true);
    assert_eq!(first["stocked_count"], 3);
    let second_body = json!({
        "receipt_ts": ts(Utc::now() - Duration::days(1)), "curr_id": uah,
        "items": [{ "item_id": buckwheat, "qty": "0.5", "amount": "40" }]
    });
    let second = receipt(&app, &alice, None, second_body).await;
    let second_id = second["id"].as_str().unwrap().to_string();

    let store = stock(&app, &alice, "").await;
    assert_eq!(store["is_active"], true);
    assert!(store["family_id"].is_null());
    let lots = store["lots"].as_array().unwrap();
    let milk_lot = lots.iter().find(|lot| lot["title"] == "Молоко").unwrap();
    assert_eq!(milk_lot["measure"], "ml");
    assert_eq!(milk_lot["qty"], "1860");
    assert_eq!(milk_lot["cost"], "72.00");
    assert_eq!(milk_lot["curr_code"], "UAH");
    assert_eq!(milk_lot["source"], "receipt");
    let candle_lot = lots.iter().find(|lot| lot["title"] == "Свеча").unwrap();
    assert_eq!(
        (candle_lot["measure"].as_str(), candle_lot["qty"].as_str()),
        (Some("pcs"), Some("3"))
    );
    assert!(lots.iter().all(|lot| lot["title"] != "Стрижка"));
    assert_eq!(left_of(&store, "Гречка"), vec!["1000", "500"]);

    let mark = meal_block(&app, &alice).await;
    let big = eat(&app, &alice, &mark, json!({ "item_id": buckwheat, "grams": "1200" })).await;
    assert_eq!(big["stock_short"], "0");
    assert_eq!(left_of(&stock(&app, &alice, "").await, "Гречка"), vec!["300"]);
    let more = eat(&app, &alice, &mark, json!({ "item_id": buckwheat, "grams": "500" })).await;
    assert_eq!(more["stock_short"], "200");
    assert!(left_of(&stock(&app, &alice, "").await, "Гречка").is_empty());

    let big_id = big["id"].as_str().unwrap();
    let (status, edited) = send(
        &app,
        &alice,
        Method::PUT,
        &format!("/api/nutrition/entries/{big_id}"),
        Some(json!({ "date": Utc::now().date_naive(), "grams": "1000" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{edited}");
    assert_eq!(edited["stock_short"], "0");
    assert_eq!(left_of(&stock(&app, &alice, "").await, "Гречка"), vec!["200"]);

    let more_id = more["id"].as_str().unwrap();
    let (status, _) = send(
        &app,
        &alice,
        Method::DELETE,
        &format!("/api/nutrition/entries/{more_id}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(left_of(&stock(&app, &alice, "").await, "Гречка"), vec!["500"]);

    let quick = eat(&app, &alice, &mark, json!({ "quick": { "kcal": "120" } })).await;
    assert!(quick["stock_short"].is_null());

    receipt(
        &app,
        &alice,
        Some(&second_id),
        json!({
            "receipt_ts": second["receipt_ts"], "curr_id": uah,
            "items": [{ "item_id": buckwheat, "qty": "0.7", "amount": "56" }]
        }),
    )
    .await;
    assert_eq!(left_of(&stock(&app, &alice, "").await, "Гречка"), vec!["700"]);

    let mut unstocked = first_body;
    unstocked["is_stocked"] = json!(false);
    let first_id = first["id"].as_str().unwrap();
    let kept = receipt(&app, &alice, Some(first_id), unstocked).await;
    assert_eq!(kept["is_stocked"], false);
    assert_eq!(kept["stocked_count"], 1);
    let after = stock(&app, &alice, "").await;
    assert!(left_of(&after, "Молоко").is_empty());
    assert!(left_of(&after, "Свеча").is_empty());

    let (status, _) = send(
        &app,
        &alice,
        Method::DELETE,
        &format!("/api/receipts/{second_id}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(left_of(&stock(&app, &alice, "").await, "Гречка").is_empty());
}

#[sqlx::test(migrations = "./migrations")]
async fn cooking_turns_ingredients_into_a_batch_the_diary_can_eat(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let uah = app.currency_by_code(&alice.token, "UAH").await;
    let rice = item(
        &app,
        &alice,
        json!({ "name": "Рис", "kind": "food", "unit": "kilogram",
                "nutrition": { "kcal": "360", "prot": "7", "fat": "1", "carb": "79" } }),
    )
    .await;
    let chicken = item(
        &app,
        &alice,
        json!({ "name": "Курица", "kind": "food", "unit": "kilogram",
                "nutrition": { "kcal": "200", "prot": "20", "fat": "12", "carb": "0" } }),
    )
    .await;
    let eggs = item(
        &app,
        &alice,
        json!({ "name": "Яйца", "kind": "food", "unit": "piece",
                "nutrition": { "kcal": "157", "prot": "12.7", "fat": "11.5", "carb": "0.7", "piece_g": "60" } }),
    )
    .await;
    for (item_id, qty, cost) in [(&rice, "500", "40"), (&chicken, "300", "90")]
    {
        let (status, lot) = send(
            &app,
            &alice,
            Method::POST,
            "/api/stock/lots",
            Some(json!({ "item_id": item_id, "qty": qty, "unit": "g", "cost": cost, "curr_id": uah })),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED, "{lot}");
    }
    let (status, egg_lot) = send(
        &app,
        &alice,
        Method::POST,
        "/api/stock/lots",
        Some(json!({ "item_id": eggs, "qty": "10", "unit": "pcs" })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{egg_lot}");
    assert_eq!(
        (egg_lot["measure"].as_str(), egg_lot["qty"].as_str()),
        (Some("g"), Some("600"))
    );
    let (status, wrong_unit) = send(
        &app,
        &alice,
        Method::POST,
        "/api/stock/lots",
        Some(json!({ "item_id": rice, "qty": "2", "unit": "pcs" })),
    )
    .await;
    assert_eq!(
        (status, wrong_unit["field"].as_str()),
        (StatusCode::BAD_REQUEST, Some("qty"))
    );

    let (status, dish) = send(
        &app,
        &alice,
        Method::POST,
        "/api/dishes",
        Some(json!({ "name": "Плов", "ingredients": [
            { "item_id": rice, "grams": "200" }, { "item_id": chicken, "grams": "300" }
        ] })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{dish}");
    let dish_id = dish["id"].as_str().unwrap().to_string();

    let cook = |a_rice: &'static str, a_chicken: &'static str, a_cooked: &'static str| {
        json!({ "dish_id": dish_id, "cooked_g": a_cooked, "ingredients": [
            { "item_id": rice, "grams": a_rice }, { "item_id": chicken, "grams": a_chicken }
        ] })
    };
    let (status, batch) = send(
        &app,
        &alice,
        Method::POST,
        "/api/stock/cook",
        Some(cook("250", "300", "800")),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{batch}");
    assert_eq!(batch["title"], "Плов");
    assert_eq!(batch["raw_g"], "550");
    assert_eq!(batch["left_g"], "800");
    assert_eq!(batch["per_100"]["kcal"], "187.5");
    assert_eq!(batch["cost"], "110.00");
    assert_eq!(batch["ingredients"][1]["short_g"], "0");
    let batch_id = batch["id"].as_str().unwrap().to_string();

    let store = stock(&app, &alice, "").await;
    assert_eq!(left_of(&store, "Рис"), vec!["250"]);
    assert!(left_of(&store, "Курица").is_empty());
    assert_eq!(left_of(&store, "Плов"), vec!["800"]);

    let (status, short_batch) = send(
        &app,
        &alice,
        Method::POST,
        "/api/stock/cook",
        Some(cook("100", "100", "180")),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{short_batch}");
    assert_eq!(short_batch["ingredients"][1]["short_g"], "100");
    assert_eq!(short_batch["cost"], "8.00");

    let (status, batches) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/stock/batches?dish_id={dish_id}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(batches.as_array().unwrap().len(), 2);
    assert_eq!(batches[0]["id"], batch_id.as_str());

    let mark = meal_block(&app, &alice).await;
    let plate = eat(
        &app,
        &alice,
        &mark,
        json!({ "dish_id": dish_id, "batch_id": batch_id, "grams": "300" }),
    )
    .await;
    assert_eq!(plate["batch_id"], batch_id.as_str());
    assert_eq!(plate["total"]["kcal"], "562.5");
    assert_eq!(plate["stock_short"], "0");
    let seconds = eat(
        &app,
        &alice,
        &mark,
        json!({ "dish_id": dish_id, "batch_id": batch_id, "grams": "600" }),
    )
    .await;
    assert_eq!(seconds["stock_short"], "100");
    let recipe = eat(&app, &alice, &mark, json!({ "dish_id": dish_id, "grams": "100" })).await;
    assert!(recipe["stock_short"].is_null());
    assert!(recipe["batch_id"].is_null());

    let short_lot = short_batch["lot_id"].as_str().unwrap();
    let (status, wasted) = send(
        &app,
        &alice,
        Method::POST,
        &format!("/api/stock/lots/{short_lot}/waste"),
        Some(json!({ "qty": "90", "reason": "leftovers", "note": "Не доели" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{wasted}");
    assert_eq!(wasted["left_qty"], "90");
    let (status, too_much) = send(
        &app,
        &alice,
        Method::POST,
        &format!("/api/stock/lots/{short_lot}/waste"),
        Some(json!({ "qty": "91", "reason": "spoiled" })),
    )
    .await;
    assert_eq!(
        (status, too_much["field"].as_str()),
        (StatusCode::BAD_REQUEST, Some("qty"))
    );

    let (status, report) = send(&app, &alice, Method::GET, "/api/stock/moves?kind=waste", None).await;
    assert_eq!(status, StatusCode::OK, "{report}");
    assert_eq!(report["waste_g"], "90");
    assert_eq!(report["waste_costs"], json!([{ "curr_code": "UAH", "amount": "4.00" }]));
    assert_eq!(report["moves"][0]["reason"], "leftovers");
    assert_eq!(report["moves"][0]["note"], "Не доели");
    let (_, history) = send(&app, &alice, Method::GET, "/api/stock/moves", None).await;
    assert!(history["moves"]
        .as_array()
        .unwrap()
        .iter()
        .any(|move_| move_["kind"] == "eaten" && move_["actor_name"].is_null()));

    let (status, used) = send(
        &app,
        &alice,
        Method::DELETE,
        &format!("/api/stock/lots/{short_lot}"),
        None,
    )
    .await;
    assert_eq!(
        (status, used["code"].as_str()),
        (StatusCode::CONFLICT, Some("STOCK_LOT_USED"))
    );

    let (status, undo) = send(
        &app,
        &alice,
        Method::POST,
        "/api/stock/cook",
        Some(cook("50", "10", "60")),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{undo}");
    assert_eq!(left_of(&stock(&app, &alice, "").await, "Рис"), vec!["100"]);
    let undo_lot = undo["lot_id"].as_str().unwrap();
    let (status, _) = send(
        &app,
        &alice,
        Method::DELETE,
        &format!("/api/stock/lots/{undo_lot}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(left_of(&stock(&app, &alice, "").await, "Рис"), vec!["150"]);

    let egg_id = egg_lot["id"].as_str().unwrap();
    let (status, _) = send(&app, &alice, Method::DELETE, &format!("/api/stock/lots/{egg_id}"), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

#[sqlx::test(migrations = "./migrations")]
async fn group_store_is_shared_with_members_only(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let carol = app.user("carol@example.com").await;
    let fam = app.family(&alice, "Дом").await;
    app.join(&alice, &bob, &fam, "standard").await;
    let uah = app.currency_by_code(&alice.token, "UAH").await;
    let cheese = item(
        &app,
        &alice,
        json!({ "name": "Сыр", "kind": "food", "unit": "kilogram",
                "nutrition": { "kcal": "350", "prot": "25", "fat": "27", "carb": "0" } }),
    )
    .await;

    let (status, settings) = send(
        &app,
        &alice,
        Method::PUT,
        "/api/stock/settings",
        Some(json!({ "family_id": fam })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{settings}");
    assert_eq!(settings["active_family_id"], fam.as_str());
    let stores = settings["stores"].as_array().unwrap();
    assert_eq!(stores.len(), 2);
    assert!(stores[0]["family_id"].is_null());
    assert_eq!(stores[1]["family_name"], "Дом");
    assert_eq!(stores[1]["is_active"], true);

    receipt(
        &app,
        &alice,
        None,
        json!({ "receipt_ts": ts(Utc::now()), "curr_id": uah, "items": [{ "item_id": cheese, "qty": "0.4", "amount": "160" }] }),
    )
    .await;
    assert!(stock(&app, &alice, "?is_personal=true").await["lots"]
        .as_array()
        .unwrap()
        .is_empty());
    let group = stock(&app, &bob, &format!("?family_id={fam}")).await;
    assert_eq!(group["family_name"], "Дом");
    assert_eq!(group["is_active"], false);
    assert_eq!(left_of(&group, "Сыр"), vec!["400"]);

    let bob_mark = meal_block(&app, &bob).await;
    let personal = eat(&app, &bob, &bob_mark, json!({ "item_id": cheese, "grams": "50" })).await;
    assert_eq!(personal["stock_short"], "50");
    send(
        &app,
        &bob,
        Method::PUT,
        "/api/stock/settings",
        Some(json!({ "family_id": fam })),
    )
    .await;
    let shared = eat(&app, &bob, &bob_mark, json!({ "item_id": cheese, "grams": "100" })).await;
    assert_eq!(shared["stock_short"], "0");
    assert_eq!(left_of(&stock(&app, &alice, "").await, "Сыр"), vec!["300"]);

    let lot_id = group["lots"][0]["id"].as_str().unwrap().to_string();
    let (status, _) = send(
        &app,
        &bob,
        Method::POST,
        &format!("/api/stock/lots/{lot_id}/waste"),
        Some(json!({ "qty": "20", "reason": "spoiled" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, moves) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/stock/moves?family_id={fam}"),
        None,
    )
    .await;
    let moves = moves["moves"].as_array().unwrap();
    assert!(moves
        .iter()
        .any(|move_| move_["kind"] == "waste" && move_["actor_name"].is_string()));
    assert!(moves
        .iter()
        .any(|move_| move_["kind"] == "eaten" && move_["actor_name"].is_null()));

    let (status, _) = send(&app, &carol, Method::GET, &format!("/api/stock?family_id={fam}"), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = send(
        &app,
        &carol,
        Method::PUT,
        "/api/stock/settings",
        Some(json!({ "family_id": fam })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = send(
        &app,
        &carol,
        Method::POST,
        &format!("/api/stock/lots/{lot_id}/waste"),
        Some(json!({ "qty": "1", "reason": "other" })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = send(&app, &carol, Method::DELETE, &format!("/api/stock/lots/{lot_id}"), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = send(
        &app,
        &carol,
        Method::GET,
        &format!("/api/stock/moves?family_id={fam}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = send(
        &app,
        &carol,
        Method::POST,
        "/api/stock/lots",
        Some(json!({ "family_id": fam, "item_id": cheese, "qty": "100", "unit": "g" })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let (status, _) = send(&app, &bob, Method::POST, &format!("/api/families/{fam}/leave"), None).await;
    assert!(status.is_success());
    let (_, after) = send(&app, &bob, Method::GET, "/api/stock/settings", None).await;
    assert!(after["active_family_id"].is_null());
    assert_eq!(after["stores"].as_array().unwrap().len(), 1);
    let (status, _) = send(&app, &bob, Method::GET, &format!("/api/stock?family_id={fam}"), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}
