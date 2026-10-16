mod common;

use axum::http::{Method, StatusCode};
use chrono::{Duration, Utc};
use common::{ai_config, catalog_config, TestApp, TestUser};
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

async fn tree(a_app: &TestApp, a_user: &TestUser) -> Value
{
    let (status, tree) = send(a_app, a_user, Method::GET, "/api/dicts/product-cats", None).await;
    assert_eq!(status, StatusCode::OK, "{tree}");
    tree
}

fn node<'a>(a_tree: &'a Value, a_key: &str) -> &'a Value
{
    a_tree["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|node| node["code"] == a_key || node["name"] == a_key)
        .unwrap_or_else(|| panic!("no node {a_key}"))
}

fn id(a_value: &Value) -> String
{
    a_value["id"].as_str().unwrap().to_string()
}

async fn add_cat(a_app: &TestApp, a_user: &TestUser, a_name: &str, a_parent: Option<&str>) -> (StatusCode, Value)
{
    send(
        a_app,
        a_user,
        Method::POST,
        "/api/dicts/product-cats",
        Some(json!({ "name": a_name, "parent_id": a_parent })),
    )
    .await
}

async fn add_item(a_app: &TestApp, a_user: &TestUser, a_body: Value) -> String
{
    let (status, item) = send(a_app, a_user, Method::POST, "/api/dicts/items", Some(a_body)).await;
    assert_eq!(status, StatusCode::CREATED, "{item}");
    id(&item)
}

async fn manual_price(a_app: &TestApp, a_user: &TestUser, a_item: &str, a_curr: &str, a_price: &str, a_days_ago: i64)
{
    let (status, body) = send(
        a_app,
        a_user,
        Method::POST,
        &format!("/api/dicts/items/{a_item}/manual-prices"),
        Some(json!({
            "merchant_name": format!("Магазин {a_days_ago}"), "curr_id": a_curr, "qty": "1", "price": a_price,
            "seen_ts": Utc::now() - Duration::days(a_days_ago)
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}

#[sqlx::test(migrations = "./migrations")]
async fn category_tree_is_shared_and_protected(a_db: PgPool)
{
    let app = TestApp::with_catalog(
        a_db,
        catalog_config(&["admin@example.com"], None),
        ai_config("http://127.0.0.1:9", None),
    );
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let admin = app.user("admin@example.com").await;

    let seeded = tree(&app, &alice).await;
    assert_eq!(seeded["max_depth"], 3);
    assert_eq!(seeded["is_admin"], false);
    assert_eq!(tree(&app, &admin).await["is_admin"], true);
    assert!(seeded["nodes"].as_array().unwrap().len() >= 60);
    let cheese = node(&seeded, "dairy_cheese");
    assert_eq!(cheese["depth"], 2);
    assert_eq!(cheese["owner_kind"], "catalog");
    assert_eq!(cheese["is_editable"], false);
    let cheese_id = id(cheese);
    let dairy_id = id(node(&seeded, "dairy"));
    let pork_id = id(node(&seeded, "meat_pork"));
    let household_id = id(node(&seeded, "household"));

    let (status, maasdam) = add_cat(&app, &alice, "Маасдам", Some(&cheese_id)).await;
    assert_eq!(status, StatusCode::CREATED, "{maasdam}");
    assert_eq!(maasdam["depth"], 3);
    assert_eq!(maasdam["owner_kind"], "me");
    let maasdam_id = id(&maasdam);
    let (status, too_deep) = add_cat(&app, &alice, "Маасдам 45%", Some(&maasdam_id)).await;
    assert_eq!(
        (status, too_deep["field"].as_str()),
        (StatusCode::BAD_REQUEST, Some("depth"))
    );
    assert_eq!(
        add_cat(&app, &bob, "маасдам", Some(&cheese_id)).await.1["code"],
        "CAT_EXISTS"
    );
    let (_, bacon) = add_cat(&app, &bob, "Бекон", Some(&pork_id)).await;

    let (_, pets) = add_cat(&app, &alice, "Зоотовары", None).await;
    let pets_id = id(&pets);
    let (_, dry_food) = add_cat(&app, &alice, "Сухой корм", Some(&pets_id)).await;
    let dry_food_id = id(&dry_food);
    let move_uri = format!("/api/dicts/product-cats/{pets_id}");
    let (status, cycle) = send(
        &app,
        &alice,
        Method::PUT,
        &move_uri,
        Some(json!({ "name": "Зоотовары", "parent_id": dry_food_id })),
    )
    .await;
    assert_eq!(
        (status, cycle["field"].as_str()),
        (StatusCode::BAD_REQUEST, Some("cycle"))
    );
    let (status, moved) = send(
        &app,
        &alice,
        Method::PUT,
        &move_uri,
        Some(json!({ "name": "Для животных", "parent_id": household_id })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{moved}");
    assert_eq!(moved["depth"], 2);
    let (status, deep) = send(
        &app,
        &alice,
        Method::PUT,
        &move_uri,
        Some(json!({ "name": "Для животных", "parent_id": maasdam_id })),
    )
    .await;
    assert_eq!(
        (status, deep["field"].as_str()),
        (StatusCode::BAD_REQUEST, Some("depth"))
    );

    let maasdam_uri = format!("/api/dicts/product-cats/{maasdam_id}");
    assert_eq!(
        send(
            &app,
            &bob,
            Method::PUT,
            &maasdam_uri,
            Some(json!({ "name": "Сыр", "parent_id": cheese_id }))
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    let cheese_uri = format!("/api/dicts/product-cats/{cheese_id}");
    assert_eq!(
        send(&app, &alice, Method::DELETE, &cheese_uri, None).await.0,
        StatusCode::FORBIDDEN
    );

    let bob_item = add_item(
        &app,
        &bob,
        json!({ "name": "Маасдам Bob", "kind": "food", "unit": "kilogram", "cat_id": maasdam_id }),
    )
    .await;
    let (status, in_use) = send(
        &app,
        &alice,
        Method::PUT,
        &maasdam_uri,
        Some(json!({ "name": "Маасдамер", "parent_id": cheese_id })),
    )
    .await;
    assert_eq!(
        (status, in_use["code"].as_str()),
        (StatusCode::CONFLICT, Some("CAT_IN_USE"))
    );
    assert_eq!(node(&tree(&app, &alice).await, "Маасдам")["is_in_use"], true);

    let (status, curated) = send(
        &app,
        &admin,
        Method::PUT,
        &maasdam_uri,
        Some(json!({ "name": "Маасдам", "parent_id": cheese_id })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{curated}");

    let (_, duplicate) = add_cat(&app, &bob, "Маасдамский", Some(&cheese_id)).await;
    let duplicate_id = id(&duplicate);
    let dup_item = add_item(
        &app,
        &bob,
        json!({ "name": "Маасдам дубль", "kind": "food", "unit": "kilogram", "cat_id": duplicate_id }),
    )
    .await;
    let merge_uri = format!("/api/dicts/product-cats/{duplicate_id}/merge");
    assert_eq!(
        send(
            &app,
            &bob,
            Method::POST,
            &merge_uri,
            Some(json!({ "target_id": maasdam_id }))
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    let (status, merged) = send(
        &app,
        &admin,
        Method::POST,
        &merge_uri,
        Some(json!({ "target_id": maasdam_id })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{merged}");
    assert_eq!(merged["item_count"], 2);
    let (_, moved_item) = send(&app, &bob, Method::GET, &format!("/api/dicts/items/{dup_item}"), None).await;
    assert_eq!(moved_item["cat_id"], maasdam_id.as_str());
    let (_, inside) = send(
        &app,
        &bob,
        Method::GET,
        &format!("/api/dicts/items?cat_id={dairy_id}"),
        None,
    )
    .await;
    let names: Vec<&str> = inside
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["name"].as_str().unwrap())
        .collect();
    assert!(
        names.contains(&"Маасдам Bob") && names.contains(&"Маасдам дубль"),
        "{names:?}"
    );

    let bacon_uri = format!("/api/dicts/product-cats/{}", id(&bacon));
    let bacon_item = add_item(
        &app,
        &bob,
        json!({ "name": "Бекон сырокопчёный", "kind": "food", "unit": "kilogram", "cat_id": id(&bacon) }),
    )
    .await;
    assert_eq!(
        send(&app, &bob, Method::DELETE, &bacon_uri, None).await.0,
        StatusCode::NO_CONTENT
    );
    let (_, orphan) = send(&app, &bob, Method::GET, &format!("/api/dicts/items/{bacon_item}"), None).await;
    assert_eq!(orphan["cat_id"], pork_id.as_str());
    assert_eq!(
        send(
            &app,
            &admin,
            Method::DELETE,
            &format!("/api/dicts/product-cats/{dairy_id}"),
            None
        )
        .await
        .1["code"],
        "CAT_HAS_CHILDREN"
    );
    assert_eq!(
        send(
            &app,
            &bob,
            Method::DELETE,
            &format!("/api/dicts/items/{bob_item}"),
            None
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
}

#[sqlx::test(migrations = "./migrations")]
async fn branch_prices_rank_items_per_100_grams(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let eve = app.user("eve@example.com").await;
    let home = app.family(&alice, "Home").await;
    app.join(&alice, &bob, &home, "standard").await;
    let uah = app.currency_by_code(&alice.token, "UAH").await;

    let seeded = tree(&app, &alice).await;
    let cheese_id = id(node(&seeded, "dairy_cheese"));
    let dairy_id = id(node(&seeded, "dairy"));
    let energy_id = id(node(&seeded, "drinks_energy"));
    let (_, maasdam) = add_cat(&app, &alice, "Маасдам", Some(&cheese_id)).await;
    let maasdam_id = id(&maasdam);

    let (status, wrong) = send(
        &app,
        &alice,
        Method::POST,
        "/api/dicts/items",
        Some(
            json!({ "name": "Сыр весовой", "kind": "food", "unit": "kilogram", "net_qty": "200", "net_measure": "g" }),
        ),
    )
    .await;
    assert_eq!(
        (status, wrong["field"].as_str()),
        (StatusCode::BAD_REQUEST, Some("net_qty"))
    );
    let (status, _) = send(
        &app,
        &alice,
        Method::POST,
        "/api/dicts/items",
        Some(json!({ "name": "Сыр без единицы", "kind": "food", "unit": "piece", "net_qty": "200" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let pack = add_item(
        &app,
        &alice,
        json!({
            "name": "Маасдам President 200 г", "kind": "food", "unit": "piece",
            "net_qty": "200", "net_measure": "g", "cat_id": maasdam_id
        }),
    )
    .await;
    let (_, pack_item) = send(&app, &alice, Method::GET, &format!("/api/dicts/items/{pack}"), None).await;
    assert_eq!(pack_item["net_qty"], "200");
    assert_eq!(pack_item["net_measure"], "g");
    let bulk = add_item(
        &app,
        &alice,
        json!({ "name": "Маасдам весовой", "kind": "food", "unit": "kilogram", "cat_id": maasdam_id }),
    )
    .await;
    let unmeasured = add_item(
        &app,
        &alice,
        json!({ "name": "Маасдам кусок", "kind": "food", "unit": "piece", "cat_id": maasdam_id }),
    )
    .await;
    let can = add_item(
        &app,
        &alice,
        json!({
            "name": "Red Bull 250 мл", "kind": "food", "unit": "piece",
            "net_qty": "250", "net_measure": "ml", "cat_id": energy_id
        }),
    )
    .await;

    manual_price(&app, &alice, &pack, &uah, "99", 10).await;
    manual_price(&app, &alice, &pack, &uah, "89.90", 40).await;
    manual_price(&app, &bob, &bulk, &uah, "420", 3).await;
    manual_price(&app, &alice, &unmeasured, &uah, "50", 2).await;
    manual_price(&app, &alice, &bulk, &uah, "300", 400).await;
    manual_price(&app, &alice, &can, &uah, "45", 5).await;
    let (status, _) = send(
        &app,
        &alice,
        Method::POST,
        "/api/receipts",
        Some(json!({
            "receipt_ts": Utc::now() - Duration::days(1),
            "merchant_name": "АТБ",
            "curr_id": uah,
            "items": [{ "item_id": pack, "qty": "2", "amount": "170" }]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    let prices_uri = format!("/api/dicts/product-cats/{dairy_id}/prices?convert_to=UAH&days=365");
    let (_, without_bob) = send(&app, &alice, Method::GET, &prices_uri, None).await;
    let rows = without_bob["rows"].as_array().unwrap();
    assert_eq!(rows.len(), 1, "{without_bob}");
    assert_eq!(rows[0]["best_100"], "42.5");
    assert_eq!(rows[0]["best_store"], "АТБ");
    assert_eq!(rows[0]["count"], 3);
    assert_eq!(without_bob["unmeasured"][0]["name"], "Маасдам кусок");

    let (status, _) = send(
        &app,
        &bob,
        Method::PUT,
        &format!("/api/families/{home}/price-sharing"),
        Some(json!({ "is_shared": true })),
    )
    .await;
    assert!(status.is_success());

    let (_, ranked) = send(&app, &alice, Method::GET, &prices_uri, None).await;
    let order: Vec<&str> = ranked["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["item_name"].as_str().unwrap())
        .collect();
    assert_eq!(order, ["Маасдам весовой", "Маасдам President 200 г"], "{ranked}");
    assert_eq!(ranked["rows"][0]["best_100"], "42");
    assert_eq!(ranked["rows"][0]["measure"], "g");
    assert_eq!(ranked["rows"][1]["last_100"], "42.5");

    let (_, all_time) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/dicts/product-cats/{maasdam_id}/prices?convert_to=UAH"),
        None,
    )
    .await;
    assert_eq!(all_time["rows"][0]["best_100"], "30");

    let (_, drinks) = send(
        &app,
        &alice,
        Method::GET,
        &format!("/api/dicts/product-cats/{energy_id}/prices"),
        None,
    )
    .await;
    assert_eq!(drinks["rows"][0]["measure"], "ml");
    assert_eq!(drinks["rows"][0]["best_100"], "18");
    assert_eq!(drinks["rows"][0]["curr_code"], "UAH");

    let (_, stranger) = send(&app, &eve, Method::GET, &prices_uri, None).await;
    assert_eq!(stranger["rows"], json!([]));
    assert_eq!(
        send(
            &app,
            &eve,
            Method::GET,
            "/api/dicts/product-cats/00000000-0000-0000-0000-000000000001/prices",
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
            Method::GET,
            &format!("/api/dicts/product-cats/{dairy_id}/prices?days=0"),
            None
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
}
