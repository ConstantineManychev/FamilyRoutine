mod common;

use axum::http::{Method, StatusCode};
use chrono::{Duration, Utc};
use common::{ai_config, catalog_config, TestApp, TestUser};
use serde_json::{json, Value};
use sqlx::PgPool;

const COFFEE_BARCODE: &str = "4820024700016";

async fn post(a_app: &TestApp, a_user: &TestUser, a_uri: &str, a_body: Value) -> Value
{
    let reply = a_app.call(Method::POST, a_uri, Some(&a_user.token), Some(a_body)).await;
    assert!(reply.status.is_success(), "{a_uri}: {} {}", reply.status, reply.body);
    reply.body
}

async fn item(a_app: &TestApp, a_user: &TestUser, a_body: Value) -> String
{
    post(a_app, a_user, "/api/dicts/items", a_body).await["id"]
        .as_str()
        .unwrap()
        .to_string()
}

async fn shop(a_app: &TestApp, a_user: &TestUser, a_name: &str, a_family: Option<&str>) -> (String, String)
{
    let countries = a_app
        .call(Method::GET, "/api/geo/countries", Some(&a_user.token), None)
        .await;
    let country_id = countries.body[0]["id"].as_str().unwrap().to_string();
    let city = post(
        a_app,
        a_user,
        &format!("/api/geo/countries/{country_id}/cities"),
        json!({ "name": "Київ" }),
    )
    .await;
    let city_id = city["id"].as_str().unwrap().to_string();
    let street = post(
        a_app,
        a_user,
        &format!("/api/geo/cities/{city_id}/streets"),
        json!({ "name": "Хрещатик" }),
    )
    .await;

    let place = post(
        a_app,
        a_user,
        "/api/places",
        json!({
            "name": a_name,
            "family_id": a_family,
            "addrs": [{
                "is_main": true,
                "country_id": country_id,
                "city_id": city_id,
                "street_id": street["id"],
                "house_num": "5",
                "zip": "01001"
            }]
        }),
    )
    .await;

    (
        place["id"].as_str().unwrap().to_string(),
        place["addrs"][0]["id"].as_str().unwrap().to_string(),
    )
}

async fn receipt(a_app: &TestApp, a_user: &TestUser, a_body: Value) -> (StatusCode, Value)
{
    let reply = a_app
        .call(Method::POST, "/api/receipts", Some(&a_user.token), Some(a_body))
        .await;
    (reply.status, reply.body)
}

async fn prices(a_app: &TestApp, a_user: &TestUser, a_item: &str, a_convert: Option<&str>) -> Value
{
    let uri = match a_convert
    {
        Some(code) => format!("/api/dicts/items/{a_item}/prices?convert_to={code}"),
        None => format!("/api/dicts/items/{a_item}/prices"),
    };
    let reply = a_app.call(Method::GET, &uri, Some(&a_user.token), None).await;
    assert_eq!(reply.status, StatusCode::OK, "{}", reply.body);
    reply.body
}

async fn get(a_app: &TestApp, a_user: &TestUser, a_uri: &str) -> Value
{
    let reply = a_app.call(Method::GET, a_uri, Some(&a_user.token), None).await;
    assert_eq!(reply.status, StatusCode::OK, "{a_uri}: {}", reply.body);
    reply.body
}

#[sqlx::test(migrations = "./migrations")]
async fn group_members_share_catalog_prices(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let eve = app.user("eve@example.com").await;
    let home = app.family(&alice, "Home").await;
    app.join(&alice, &bob, &home, "standard").await;
    let uah = app.currency_by_code(&alice.token, "UAH").await;

    let milk = item(
        &app,
        &alice,
        json!({ "name": "Молоко", "kind": "product", "unit": "liter" }),
    )
    .await;
    let as_member = get(&app, &bob, &format!("/api/dicts/items/{milk}")).await;
    assert_eq!(as_member["owner_kind"], "member");
    assert_eq!(as_member["owner_name"], "Test alice");
    assert_eq!(as_member["is_editable"], false);
    let as_stranger = get(&app, &eve, &format!("/api/dicts/items/{milk}")).await;
    assert_eq!(as_stranger["owner_kind"], "user");
    assert_eq!(as_stranger["owner_name"], Value::Null);
    assert_eq!(as_stranger["is_editable"], false);

    let bob_edit = app
        .call(
            Method::PUT,
            &format!("/api/dicts/items/{milk}"),
            Some(&bob.token),
            Some(json!({ "name": "Молоко!", "kind": "product", "unit": "liter" })),
        )
        .await;
    assert_eq!(bob_edit.status, StatusCode::FORBIDDEN);

    let (atb, atb_branch) = shop(&app, &bob, "АТБ", Some(&home)).await;
    let (_, eve_branch) = shop(&app, &eve, "Eve shop", None).await;

    let (status, bought) = receipt(
        &app,
        &bob,
        json!({
            "receipt_ts": Utc::now() - Duration::days(1),
            "curr_id": uah,
            "place_id": atb,
            "place_addr_id": atb_branch,
            "items": [{ "item_id": milk, "qty": "0.9", "amount": "36" }]
        }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{bought}");
    assert_eq!(bought["branch"], "Київ, Хрещатик 5");

    let (_, wrong_branch) = receipt(
        &app,
        &bob,
        json!({ "receipt_ts": Utc::now(), "curr_id": uah, "place_id": atb, "place_addr_id": eve_branch }),
    )
    .await;
    assert_eq!(wrong_branch["field"], "place_addr_id");
    let (_, eve_place) = receipt(
        &app,
        &eve,
        json!({ "receipt_ts": Utc::now(), "curr_id": uah, "place_id": atb }),
    )
    .await;
    assert_eq!(eve_place["field"], "place_id");
    let (eve_status, _) = receipt(
        &app,
        &eve,
        json!({ "receipt_ts": Utc::now(), "curr_id": uah, "items": [{ "item_id": milk, "amount": "1" }] }),
    )
    .await;
    assert_eq!(eve_status, StatusCode::CREATED);

    let shared = prices(&app, &alice, &milk, None).await;
    assert_eq!(shared["prices"].as_array().unwrap().len(), 1, "{shared}");
    assert_eq!(shared["prices"][0]["store_name"], "АТБ");
    assert_eq!(shared["prices"][0]["branch"], "Київ, Хрещатик 5");
    assert_eq!(shared["prices"][0]["last_price"], "40.00");
    assert_eq!(shared["prices"][0]["is_shared"], true);
    let history = get(&app, &alice, &format!("/api/dicts/items/{milk}/price-history")).await;
    assert_eq!(history.as_array().unwrap().len(), 1, "{history}");
    assert_eq!(history[0]["unit_price"], "40.00");
    assert_eq!(history[0]["is_shared"], true);

    let eve_view = prices(&app, &eve, &milk, None).await;
    assert!(
        eve_view["prices"]
            .as_array()
            .unwrap()
            .iter()
            .all(|price| price["store_name"] != "АТБ"),
        "{eve_view}"
    );
    assert_eq!(
        app.call(
            Method::PUT,
            &format!("/api/families/{home}/price-sharing"),
            Some(&bob.token),
            Some(json!({ "is_shared": false }))
        )
        .await
        .status,
        StatusCode::NOT_FOUND
    );

    let left = app
        .call(
            Method::POST,
            &format!("/api/families/{home}/leave"),
            Some(&bob.token),
            None,
        )
        .await;
    assert!(left.status.is_success());
    assert_eq!(prices(&app, &alice, &milk, None).await["prices"], json!([]));
    assert_eq!(
        get(&app, &bob, &format!("/api/dicts/items/{milk}")).await["owner_kind"],
        "user"
    );

    let receipt_id = bought["id"].as_str().unwrap();
    let resaved = app
        .call(
            Method::PUT,
            &format!("/api/receipts/{receipt_id}"),
            Some(&bob.token),
            Some(json!({
                "receipt_ts": Utc::now() - Duration::days(1),
                "curr_id": uah,
                "place_id": atb,
                "place_addr_id": atb_branch,
                "items": [{ "item_id": milk, "qty": "0.9", "amount": "36" }]
            })),
        )
        .await;
    assert_eq!(resaved.status, StatusCode::OK, "{}", resaved.body);
    assert_eq!(resaved.body["place_name"], "АТБ");

    let (_, new_with_family_place) = receipt(
        &app,
        &bob,
        json!({ "receipt_ts": Utc::now(), "curr_id": uah, "place_id": atb }),
    )
    .await;
    assert_eq!(new_with_family_place["field"], "place_id");
}

#[sqlx::test(migrations = "./migrations")]
async fn barcodes_are_global_and_price_history_follows_receipt_dates(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let carol = app.user("carol@example.com").await;
    let uah = app.currency_by_code(&alice.token, "UAH").await;
    let eur = app.currency_by_code(&alice.token, "EUR").await;
    let pln = app.currency_by_code(&alice.token, "PLN").await;

    let invalid = app
        .call(
            Method::POST,
            "/api/dicts/items",
            Some(&alice.token),
            Some(json!({ "name": "Кава", "kind": "product", "unit": "piece", "barcode": "4820024700017" })),
        )
        .await;
    assert_eq!(invalid.body["field"], "barcode");

    let coffee = item(
        &app,
        &alice,
        json!({ "name": "Кава", "kind": "product", "unit": "piece", "barcode": COFFEE_BARCODE }),
    )
    .await;
    for (user, name) in [(&alice, "Інша кава"), (&carol, "Моя кава")]
    {
        let taken = app
            .call(
                Method::POST,
                "/api/dicts/items",
                Some(&user.token),
                Some(json!({ "name": name, "kind": "product", "unit": "piece", "barcode": COFFEE_BARCODE })),
            )
            .await;
        assert_eq!(taken.status, StatusCode::CONFLICT);
        assert_eq!(taken.body["code"], "BARCODE_TAKEN");
    }
    let tea = item(
        &app,
        &alice,
        json!({ "name": "Чай", "kind": "product", "unit": "piece" }),
    )
    .await;
    let tea_with_coffee_code = app
        .call(
            Method::PUT,
            &format!("/api/dicts/items/{tea}"),
            Some(&alice.token),
            Some(json!({ "name": "Чай", "kind": "product", "unit": "piece", "barcode": COFFEE_BARCODE })),
        )
        .await;
    assert_eq!(tea_with_coffee_code.body["code"], "BARCODE_TAKEN");

    let search = get(&app, &alice, &format!("/api/dicts/items?q={COFFEE_BARCODE}")).await;
    assert_eq!(search.as_array().unwrap().len(), 1, "{search}");
    let exact = get(&app, &carol, &format!("/api/dicts/items?barcode={COFFEE_BARCODE}")).await;
    assert_eq!(exact.as_array().unwrap().len(), 1);
    assert_eq!(exact[0]["name"], "Кава");
    assert_eq!(exact[0]["owner_kind"], "user");

    let (status, _) = receipt(
        &app,
        &alice,
        json!({
            "receipt_ts": Utc::now() - Duration::days(2),
            "merchant_name": "АТБ",
            "curr_id": uah,
            "items": [{ "item_id": coffee, "amount": "200" }]
        }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    let manual = post(
        &app,
        &alice,
        &format!("/api/dicts/items/{coffee}/manual-prices"),
        json!({ "merchant_name": "Tesco", "curr_id": eur, "qty": "2", "price": "10", "seen_ts": Utc::now() - Duration::days(1) }),
    )
    .await;
    assert_eq!(manual["store_name"], "Tesco");
    let no_store = app
        .call(
            Method::POST,
            &format!("/api/dicts/items/{coffee}/manual-prices"),
            Some(&alice.token),
            Some(json!({ "curr_id": eur, "price": "10" })),
        )
        .await;
    assert_eq!(no_store.body["field"], "place_id");

    let (silpo, silpo_branch) = shop(&app, &alice, "Сільпо", None).await;
    let (status, _) = receipt(
        &app,
        &alice,
        json!({
            "receipt_ts": Utc::now() - Duration::days(10),
            "curr_id": uah,
            "place_id": silpo,
            "place_addr_id": silpo_branch,
            "items": [{ "item_id": coffee, "qty": "2", "amount": "360" }]
        }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    let history = get(&app, &alice, &format!("/api/dicts/items/{coffee}/price-history")).await;
    let points = history.as_array().unwrap();
    assert_eq!(points.len(), 3, "{history}");
    assert_eq!(points[0]["store_name"], "Tesco");
    assert_eq!(points[0]["source"], "manual");
    assert_eq!(points[0]["curr_code"], "EUR");
    assert_eq!(points[0]["unit_price"], "5.00");
    assert_eq!(points[1]["store_name"], "АТБ");
    assert_eq!(points[1]["unit_price"], "200.00");
    assert_eq!(points[2]["store_name"], "Сільпо");
    assert_eq!(points[2]["branch"], "Київ, Хрещатик 5");
    assert_eq!(points[2]["unit_price"], "180.00");
    assert_eq!(points[2]["source"], "receipt");

    let latest_uah = get(
        &app,
        &alice,
        &format!("/api/dicts/items/{coffee}/last-price?curr_id={uah}"),
    )
    .await;
    assert_eq!(latest_uah["store_name"], "АТБ");
    let same_shop = get(
        &app,
        &alice,
        &format!("/api/dicts/items/{coffee}/last-price?curr_id={uah}&place_id={silpo}"),
    )
    .await;
    assert_eq!(same_shop["unit_price"], "180.00");
    assert_eq!(
        get(
            &app,
            &alice,
            &format!("/api/dicts/items/{coffee}/last-price?curr_id={pln}")
        )
        .await,
        Value::Null
    );
    assert_eq!(
        get(&app, &carol, &format!("/api/dicts/items/{coffee}/last-price")).await,
        Value::Null
    );

    let by_currency = prices(&app, &alice, &coffee, None).await;
    assert_eq!(by_currency["prices"].as_array().unwrap().len(), 3, "{by_currency}");

    let without_rates = prices(&app, &alice, &coffee, Some("UAH")).await;
    assert_eq!(without_rates["missing_rates"], json!(["EUR"]));
    assert_eq!(without_rates["prices"].as_array().unwrap().len(), 2);

    sqlx::query(
        r#"
        INSERT INTO currency_rates (base_curr_id, target_curr_id, rate, date)
        SELECT u.id, e.id, 45, CURRENT_DATE - 10
        FROM currencies u, currencies e
        WHERE u.code = 'UAH' AND e.code = 'EUR'
        "#,
    )
    .execute(&a_db)
    .await
    .unwrap();

    let converted = prices(&app, &alice, &coffee, Some("uah")).await;
    assert_eq!(converted["missing_rates"], json!([]));
    let rows = converted["prices"].as_array().unwrap();
    assert_eq!(rows.len(), 3);
    assert_eq!(rows[0]["store_name"], "Сільпо");
    assert_eq!(rows[1]["store_name"], "АТБ");
    assert_eq!(rows[1]["last_price"], "200.00");
    assert_eq!(rows[2]["store_name"], "Tesco");
    assert_eq!(rows[2]["curr_code"], "UAH");
    assert_eq!(rows[2]["last_price"], "225.00");

    let manual_id = manual["id"].as_str().unwrap();
    let manual_uri = format!("/api/dicts/items/{coffee}/manual-prices/{manual_id}");
    assert_eq!(
        app.call(Method::DELETE, &manual_uri, Some(&bob.token), None)
            .await
            .status,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        app.call(Method::DELETE, &manual_uri, Some(&alice.token), None)
            .await
            .status,
        StatusCode::NO_CONTENT
    );
}

#[sqlx::test(migrations = "./migrations")]
async fn admins_curate_the_catalog_without_breaking_receipts(a_db: PgPool)
{
    let app = TestApp::with_catalog(
        a_db.clone(),
        catalog_config(&["admin@example.com"], None),
        ai_config("http://127.0.0.1:9", None),
    );
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let admin = app.user("Admin@Example.com").await;
    let home = app.family(&alice, "Home").await;
    app.join(&alice, &bob, &home, "standard").await;
    let uah = app.currency_by_code(&alice.token, "UAH").await;

    let cheese = item(
        &app,
        &alice,
        json!({ "name": "Сир", "kind": "product", "unit": "kilogram" }),
    )
    .await;
    let hard_cheese = item(
        &app,
        &alice,
        json!({ "name": "Сир твердий", "kind": "product", "unit": "kilogram" }),
    )
    .await;
    let bread = item(
        &app,
        &alice,
        json!({ "name": "Хліб", "kind": "product", "unit": "piece" }),
    )
    .await;
    let (status, bought) = receipt(
        &app,
        &alice,
        json!({
            "receipt_ts": Utc::now(),
            "merchant_name": "Сільпо",
            "curr_id": uah,
            "items": [{ "item_id": hard_cheese, "qty": "0.5", "amount": "150" }]
        }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    let wrong_unit = app
        .call(
            Method::POST,
            &format!("/api/dicts/items/{bread}/merge"),
            Some(&alice.token),
            Some(json!({ "target_id": cheese })),
        )
        .await;
    assert_eq!(wrong_unit.body["field"], "target_id");

    let merged = app
        .call(
            Method::POST,
            &format!("/api/dicts/items/{hard_cheese}/merge"),
            Some(&alice.token),
            Some(json!({ "target_id": cheese })),
        )
        .await;
    assert_eq!(merged.status, StatusCode::OK, "{}", merged.body);
    assert_eq!(
        app.call(
            Method::GET,
            &format!("/api/dicts/items/{hard_cheese}"),
            Some(&alice.token),
            None
        )
        .await
        .status,
        StatusCode::NOT_FOUND
    );
    let receipt_id = bought["id"].as_str().unwrap();
    let reloaded = get(&app, &alice, &format!("/api/receipts/{receipt_id}")).await;
    assert_eq!(reloaded["items"][0]["item_id"], cheese.as_str());

    let (status, bob_receipt) = receipt(
        &app,
        &bob,
        json!({ "receipt_ts": Utc::now(), "curr_id": uah, "items": [{ "item_id": cheese, "amount": "90" }] }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(
        get(&app, &alice, &format!("/api/dicts/items/{cheese}")).await["is_in_use"],
        true
    );

    for (method, uri, body) in [
        (Method::DELETE, format!("/api/dicts/items/{cheese}"), None),
        (
            Method::PUT,
            format!("/api/dicts/items/{cheese}"),
            Some(json!({ "name": "Сир кисломолочний", "kind": "product", "unit": "kilogram" })),
        ),
        (
            Method::POST,
            format!("/api/dicts/items/{cheese}/merge"),
            Some(
                json!({ "target_id": item(&app, &alice, json!({ "name": "Бринза", "kind": "food", "unit": "kilogram" })).await }),
            ),
        ),
    ]
    {
        let reply = app.call(method, &uri, Some(&alice.token), body).await;
        assert_eq!(reply.status, StatusCode::CONFLICT, "{uri}");
        assert_eq!(reply.body["code"], "ITEM_IN_USE");
    }

    let admin_view = get(&app, &admin, &format!("/api/dicts/items/{cheese}")).await;
    assert_eq!(admin_view["is_editable"], true);
    assert_eq!(admin_view["is_in_use"], true);
    let renamed = app
        .call(
            Method::PUT,
            &format!("/api/dicts/items/{cheese}"),
            Some(&admin.token),
            Some(json!({ "name": "Сир кисломолочний", "kind": "food", "unit": "kilogram" })),
        )
        .await;
    assert_eq!(renamed.status, StatusCode::OK, "{}", renamed.body);
    let admin_delete = app
        .call(
            Method::DELETE,
            &format!("/api/dicts/items/{cheese}"),
            Some(&admin.token),
            None,
        )
        .await;
    assert_eq!(admin_delete.body["code"], "ITEM_IN_USE");

    let gouda = item(
        &app,
        &admin,
        json!({ "name": "Сир Гауда", "kind": "food", "unit": "kilogram", "barcode": COFFEE_BARCODE }),
    )
    .await;
    assert_eq!(
        get(&app, &alice, &format!("/api/dicts/items/{gouda}")).await["owner_kind"],
        "catalog"
    );
    let curated = app
        .call(
            Method::POST,
            &format!("/api/dicts/items/{cheese}/merge"),
            Some(&admin.token),
            Some(json!({ "target_id": gouda })),
        )
        .await;
    assert_eq!(curated.status, StatusCode::OK, "{}", curated.body);
    let bob_receipt_id = bob_receipt["id"].as_str().unwrap();
    let bob_reloaded = get(&app, &bob, &format!("/api/receipts/{bob_receipt_id}")).await;
    assert_eq!(bob_reloaded["items"][0]["name"], "Сир Гауда");
    assert_eq!(
        get(&app, &alice, &format!("/api/receipts/{receipt_id}")).await["items"][0]["item_id"],
        gouda.as_str()
    );

    let bob_flour = item(
        &app,
        &bob,
        json!({ "name": "Борошно", "kind": "product", "unit": "kilogram" }),
    )
    .await;
    let (bob_shop, _) = shop(&app, &bob, "Ринок", Some(&home)).await;
    let alice_places = get(&app, &alice, "/api/places").await;
    assert_eq!(alice_places[0]["id"], bob_shop.as_str());

    let deleted = app
        .call(
            Method::DELETE,
            &format!("/api/families/{home}"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(deleted.status, StatusCode::NO_CONTENT, "{}", deleted.body);
    assert_eq!(
        get(&app, &bob, &format!("/api/dicts/items/{bob_flour}")).await["is_editable"],
        true
    );
    let bob_places = get(&app, &bob, "/api/places").await;
    assert_eq!(bob_places[0]["family_id"], Value::Null);
    assert_eq!(get(&app, &alice, "/api/places").await, json!([]));

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(bob.id)
        .execute(&a_db)
        .await
        .unwrap();
    let orphan = get(&app, &alice, &format!("/api/dicts/items/{bob_flour}")).await;
    assert_eq!(orphan["owner_kind"], "catalog");
    assert_eq!(orphan["is_editable"], false);
    assert_eq!(
        get(&app, &admin, &format!("/api/dicts/items/{bob_flour}")).await["is_editable"],
        true
    );
}
