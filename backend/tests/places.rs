mod common;

use axum::http::{Method, StatusCode};
use backend::banking::store::recategorize_pending;
use chrono::Utc;
use common::{TestApp, TestUser};
use serde_json::{json, Value};
use sqlx::PgPool;
use uuid::Uuid;

async fn post(a_app: &TestApp, a_user: &TestUser, a_uri: &str, a_body: Value) -> Value
{
    let reply = a_app.call(Method::POST, a_uri, Some(&a_user.token), Some(a_body)).await;
    assert_eq!(reply.status, StatusCode::CREATED, "{a_uri}: {}", reply.body);
    reply.body
}

async fn city(a_app: &TestApp, a_user: &TestUser, a_name: &str) -> (String, String)
{
    let countries = a_app
        .call(Method::GET, "/api/geo/countries", Some(&a_user.token), None)
        .await;
    let country_id = countries.body[0]["id"].as_str().unwrap().to_string();
    let city = post(
        a_app,
        a_user,
        &format!("/api/geo/countries/{country_id}/cities"),
        json!({ "name": a_name }),
    )
    .await;
    (country_id, city["id"].as_str().unwrap().to_string())
}

async fn wallet(a_app: &TestApp, a_user: &TestUser, a_name: &str) -> Uuid
{
    let curr_id = a_app.currency_by_code(&a_user.token, "EUR").await;
    let wallet = post(
        a_app,
        a_user,
        "/api/wallets",
        json!({ "name": a_name, "curr_id": curr_id, "account_type": "card" }),
    )
    .await;
    wallet["id"].as_str().unwrap().parse().unwrap()
}

async fn bank_tx(a_db: &PgPool, a_account: Uuid, a_amount: &str, a_description: &str, a_mcc: Option<i16>) -> Uuid
{
    sqlx::query_scalar(
        r#"
        INSERT INTO transactions (user_id, account_id, curr_id, amount, tx_type, tx_ts, ext_id, source, description, mcc)
        SELECT a.user_id, a.id, a.curr_id, $2::numeric, 'expense', NOW(), gen_random_uuid()::text, 'bank', $3, $4
        FROM accounts a WHERE a.id = $1
        RETURNING id
        "#,
    )
    .bind(a_account)
    .bind(a_amount)
    .bind(a_description)
    .bind(a_mcc)
    .fetch_one(a_db)
    .await
    .unwrap()
}

async fn tx(a_app: &TestApp, a_user: &TestUser, a_id: Uuid) -> Value
{
    let page = a_app
        .call(Method::GET, "/api/transactions?limit=200", Some(&a_user.token), None)
        .await;
    assert_eq!(page.status, StatusCode::OK, "{}", page.body);
    page.body["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"] == a_id.to_string().as_str())
        .cloned()
        .unwrap()
}

async fn get_place(a_app: &TestApp, a_user: &TestUser, a_id: &str) -> Value
{
    let reply = a_app
        .call(Method::GET, &format!("/api/places/{a_id}"), Some(&a_user.token), None)
        .await;
    assert_eq!(reply.status, StatusCode::OK, "{}", reply.body);
    reply.body
}

async fn link(a_app: &TestApp, a_user: &TestUser, a_merchant: &Value, a_body: Value) -> StatusCode
{
    let uri = format!("/api/merchants/{}/place", a_merchant.as_str().unwrap());
    a_app
        .call(Method::PUT, &uri, Some(&a_user.token), Some(a_body))
        .await
        .status
}

#[sqlx::test(migrations = "./migrations")]
async fn addresses_need_only_a_city(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let (country_id, city_id) = city(&app, &alice, "Athlone").await;
    let (_, other_city) = city(&app, &alice, "Galway").await;
    let street = post(
        &app,
        &alice,
        &format!("/api/geo/cities/{other_city}/streets"),
        json!({ "name": "Shop St" }),
    )
    .await;

    let place = post(
        &app,
        &alice,
        "/api/places",
        json!({
            "name": "Lidl",
            "addrs": [
                { "is_main": true, "country_id": country_id, "city_id": city_id },
                { "is_main": false, "country_id": country_id, "city_id": city_id, "zip": "N37 F6D7" },
                { "is_main": false, "country_id": country_id, "city_id": city_id, "house_num": "12" }
            ]
        }),
    )
    .await;
    let mut labels: Vec<&str> = place["addrs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|addr| addr["label"].as_str().unwrap())
        .collect();
    labels.sort_unstable();
    assert_eq!(labels, vec!["Athlone", "Athlone, 12", "Athlone, N37 F6D7"]);
    assert_eq!(place["addrs"][0]["street_id"], Value::Null);
    assert_eq!(place["addrs"][0]["house_num"], Value::Null);

    let wrong_street = app
        .call(
            Method::POST,
            "/api/places",
            Some(&alice.token),
            Some(json!({
                "name": "Aldi",
                "addrs": [{ "is_main": true, "country_id": country_id, "city_id": city_id, "street_id": street["id"] }]
            })),
        )
        .await;
    assert_eq!(wrong_street.status, StatusCode::BAD_REQUEST);
    assert_eq!(wrong_street.body["field"], "addrs.geo");
}

#[sqlx::test(migrations = "./migrations")]
async fn bank_merchants_link_to_places_privately(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let home = app.family(&alice, "Home").await;
    app.join(&alice, &bob, &home, "standard").await;

    let aib = wallet(&app, &alice, "AIB").await;
    let mono = wallet(&app, &alice, "Mono").await;
    let aib_tx = bank_tx(&a_db, aib, "-39.57", "VDC-LIDL 0907 ATHL; Purchase", None).await;
    let mono_tx = bank_tx(&a_db, mono, "-31.57", "Lidl", Some(5411)).await;
    let atm_tx = bank_tx(&a_db, aib, "-50.00", "ATM WITHDRAWAL", Some(6011)).await;
    assert_eq!(recategorize_pending(&a_db).await.unwrap(), 3);

    let aib_before = tx(&app, &alice, aib_tx).await;
    assert_eq!(aib_before["merchant_name"], "LIDL 0907 ATHL");
    assert_eq!(aib_before["place_id"], Value::Null);
    assert_eq!(aib_before["is_merchant_linked"], false);
    let mono_before = tx(&app, &alice, mono_tx).await;
    assert_eq!(mono_before["merchant_name"], "Lidl");
    assert_eq!(tx(&app, &alice, atm_tx).await["merchant_id"], Value::Null);

    let (country_id, city_id) = city(&app, &alice, "Athlone").await;
    let place = post(
        &app,
        &alice,
        "/api/places",
        json!({
            "name": "Lidl", "family_id": home,
            "addrs": [{ "is_main": true, "country_id": country_id, "city_id": city_id }]
        }),
    )
    .await;
    let place_id = place["id"].as_str().unwrap().to_string();
    let branch_id = place["addrs"][0]["id"].clone();

    assert_eq!(
        link(
            &app,
            &alice,
            &aib_before["merchant_id"],
            json!({ "place_id": place_id, "place_addr_id": branch_id })
        )
        .await,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        link(
            &app,
            &alice,
            &mono_before["merchant_id"],
            json!({ "place_id": place_id })
        )
        .await,
        StatusCode::NO_CONTENT
    );

    let aib_after = tx(&app, &alice, aib_tx).await;
    assert_eq!(aib_after["place_name"], "Lidl");
    assert_eq!(aib_after["branch"], "Athlone");
    assert_eq!(aib_after["is_merchant_linked"], true);
    let mono_after = tx(&app, &alice, mono_tx).await;
    assert_eq!(mono_after["place_name"], "Lidl");
    assert_eq!(mono_after["branch"], Value::Null);

    let found = app
        .call(Method::GET, "/api/transactions?q=lidl", Some(&alice.token), None)
        .await;
    assert_eq!(found.body["items"].as_array().unwrap().len(), 2);

    let own_view = get_place(&app, &alice, &place_id).await;
    let names: Vec<&str> = own_view["merchants"]
        .as_array()
        .unwrap()
        .iter()
        .map(|merchant| merchant["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, vec!["LIDL 0907 ATHL", "Lidl"]);
    assert_eq!(get_place(&app, &bob, &place_id).await["merchants"], json!([]));
    assert_eq!(
        link(&app, &bob, &aib_before["merchant_id"], json!({ "place_id": place_id })).await,
        StatusCode::NOT_FOUND
    );

    let bob_place = post(&app, &bob, "/api/places", json!({ "name": "Bob's" })).await;
    assert_eq!(
        link(
            &app,
            &alice,
            &mono_before["merchant_id"],
            json!({ "place_id": bob_place["id"] })
        )
        .await,
        StatusCode::BAD_REQUEST
    );
    let other_place = post(&app, &alice, "/api/places", json!({ "name": "Aldi" })).await;
    assert_eq!(
        link(
            &app,
            &alice,
            &mono_before["merchant_id"],
            json!({ "place_id": other_place["id"], "place_addr_id": branch_id })
        )
        .await,
        StatusCode::BAD_REQUEST
    );

    let unlink_uri = format!("/api/merchants/{}/place", mono_before["merchant_id"].as_str().unwrap());
    let unlinked = app.call(Method::DELETE, &unlink_uri, Some(&alice.token), None).await;
    assert_eq!(unlinked.status, StatusCode::NO_CONTENT);
    assert_eq!(tx(&app, &alice, mono_tx).await["place_id"], Value::Null);
    let again = app.call(Method::DELETE, &unlink_uri, Some(&alice.token), None).await;
    assert_eq!(again.status, StatusCode::NOT_FOUND);

    let left = app
        .call(
            Method::DELETE,
            &format!("/api/places/{place_id}"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(left.status, StatusCode::NO_CONTENT);
    let after_delete = tx(&app, &alice, aib_tx).await;
    assert_eq!(after_delete["place_id"], Value::Null);
    assert_eq!(after_delete["is_merchant_linked"], false);
}

#[sqlx::test(migrations = "./migrations")]
async fn receipts_teach_places_and_new_items_join_the_catalog(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let eve = app.user("eve@example.com").await;
    let home = app.family(&alice, "Home").await;
    app.join(&alice, &bob, &home, "standard").await;

    let card = wallet(&app, &alice, "Card").await;
    let paid = bank_tx(&a_db, card, "-12.40", "VDP-TESCO STORES 3092", None).await;
    recategorize_pending(&a_db).await.unwrap();
    let eur = app.currency_by_code(&alice.token, "EUR").await;
    let place = post(&app, &alice, "/api/places", json!({ "name": "Tesco" })).await;

    let saved = post(
        &app,
        &alice,
        "/api/receipts",
        json!({
            "receipt_ts": Utc::now(), "curr_id": eur, "place_id": place["id"], "tx_ids": [paid],
            "items": [{ "new_item": { "name": "Milk", "kind": "food", "unit": "piece" }, "amount": "12.40" }]
        }),
    )
    .await;

    let linked = tx(&app, &alice, paid).await;
    assert_eq!(linked["place_name"], "Tesco");
    assert_eq!(linked["is_merchant_linked"], true);

    let item_id = saved["items"][0]["item_id"].as_str().unwrap();
    for (viewer, owner_kind, is_editable) in [(&alice, "me", true), (&bob, "member", false), (&eve, "user", false)]
    {
        let milk = app
            .call(
                Method::GET,
                &format!("/api/dicts/items/{item_id}"),
                Some(&viewer.token),
                None,
            )
            .await;
        assert_eq!(milk.status, StatusCode::OK, "{}", milk.body);
        assert_eq!(milk.body["owner_kind"], owner_kind);
        assert_eq!(milk.body["is_editable"], is_editable);
        let owner_name = if owner_kind == "member"
        {
            json!("Test alice")
        }
        else
        {
            Value::Null
        };
        assert_eq!(milk.body["owner_name"], owner_name);
    }

    let later = bank_tx(&a_db, card, "-3.10", "VDP-TESCO STORES 3092", None).await;
    recategorize_pending(&a_db).await.unwrap();
    assert_eq!(tx(&app, &alice, later).await["place_name"], "Tesco");
}
