mod common;

use axum::http::{Method, StatusCode};
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use chrono::Utc;
use common::bank_mocks::{spawn_anthropic, AiMock};
use common::{TestApp, TestUser};
use serde_json::{json, Value};
use sqlx::PgPool;

const COFFEE_BARCODE: &str = "4820024700016";

fn photo() -> String
{
    let mut bytes = vec![0xFF, 0xD8, 0xFF, 0xE0];
    bytes.extend(std::iter::repeat_n(7u8, 400));
    STANDARD.encode(bytes)
}

fn line(a_text: &str, a_name: &str, a_unit: &str, a_qty: f64, a_amount: f64, a_barcode: Option<&str>) -> Value
{
    json!({
        "text": a_text, "name": a_name, "kind": "food", "unit": a_unit, "quantity": a_qty,
        "unit_price": null, "amount": a_amount, "barcode": a_barcode
    })
}

fn receipt(a_store: &str, a_street: &str, a_house: &str, a_lines: Vec<Value>) -> Value
{
    json!({
        "is_receipt": true,
        "store_name": a_store,
        "country_code": "UKR",
        "city": "Київ",
        "street": a_street,
        "house_number": a_house,
        "postal_code": null,
        "date": Utc::now().date_naive().to_string(),
        "time": "00:15",
        "currency": "UAH",
        "total": 300.5,
        "lines": a_lines
    })
}

async fn recognize(a_app: &TestApp, a_user: &TestUser, a_mock: &AiMock, a_receipt: Value) -> (StatusCode, Value)
{
    a_mock.reply_with(a_receipt);
    let reply = a_app
        .call(
            Method::POST,
            "/api/receipts/recognize",
            Some(&a_user.token),
            Some(json!({ "image": photo(), "media_type": "image/jpeg", "tz_offset_min": 180 })),
        )
        .await;
    (reply.status, reply.body)
}

async fn post(a_app: &TestApp, a_user: &TestUser, a_uri: &str, a_body: Value) -> Value
{
    let reply = a_app.call(Method::POST, a_uri, Some(&a_user.token), Some(a_body)).await;
    assert!(reply.status.is_success(), "{a_uri}: {} {}", reply.status, reply.body);
    reply.body
}

async fn kyiv_shop(a_app: &TestApp, a_user: &TestUser, a_name: &str) -> (String, String)
{
    let countries = a_app
        .call(Method::GET, "/api/geo/countries", Some(&a_user.token), None)
        .await;
    let ukraine = countries
        .body
        .as_array()
        .unwrap()
        .iter()
        .find(|country| country["code"] == "UKR")
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let city = post(
        a_app,
        a_user,
        &format!("/api/geo/countries/{ukraine}/cities"),
        json!({ "name": "Київ" }),
    )
    .await;
    let street = post(
        a_app,
        a_user,
        &format!("/api/geo/cities/{}/streets", city["id"].as_str().unwrap()),
        json!({ "name": "Хрещатик" }),
    )
    .await;
    let place = post(
        a_app,
        a_user,
        "/api/places",
        json!({
            "name": a_name,
            "addrs": [{
                "is_main": true, "country_id": ukraine, "city_id": city["id"], "street_id": street["id"],
                "house_num": "5", "zip": "01001"
            }]
        }),
    )
    .await;
    (
        place["id"].as_str().unwrap().to_string(),
        place["addrs"][0]["id"].as_str().unwrap().to_string(),
    )
}

#[sqlx::test(migrations = "./migrations")]
async fn recognition_is_off_without_a_key(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;

    let features = app.call(Method::GET, "/api/features", Some(&alice.token), None).await;
    assert_eq!(features.body["is_receipt_recognition"], false);
    let reply = app
        .call(
            Method::POST,
            "/api/receipts/recognize",
            Some(&alice.token),
            Some(json!({ "image": photo(), "media_type": "image/jpeg" })),
        )
        .await;
    assert_eq!(reply.body["code"], "RECOGNITION_DISABLED");
    let anonymous = app
        .call(
            Method::POST,
            "/api/receipts/recognize",
            None,
            Some(json!({ "image": photo(), "media_type": "image/jpeg" })),
        )
        .await;
    assert_eq!(anonymous.status, StatusCode::UNAUTHORIZED);
}

#[sqlx::test(migrations = "./migrations")]
async fn photo_becomes_a_draft_matched_to_the_catalog(a_db: PgPool)
{
    let (ai_url, mock) = spawn_anthropic().await;
    let app = TestApp::with_receipt_ai(a_db, &ai_url, 3);
    let alice = app.user("alice@example.com").await;
    let uah = app.currency_by_code(&alice.token, "UAH").await;

    let features = app.call(Method::GET, "/api/features", Some(&alice.token), None).await;
    assert_eq!(features.body["is_receipt_recognition"], true);

    let (atb, atb_branch) = kyiv_shop(&app, &alice, "АТБ").await;
    let milk = post(
        &app,
        &alice,
        "/api/dicts/items",
        json!({ "name": "Молоко Галичина 2,5%", "kind": "food", "unit": "piece" }),
    )
    .await["id"]
        .as_str()
        .unwrap()
        .to_string();
    let coffee = post(
        &app,
        &alice,
        "/api/dicts/items",
        json!({ "name": "Кава Lavazza", "kind": "food", "unit": "piece", "barcode": COFFEE_BARCODE }),
    )
    .await["id"]
        .as_str()
        .unwrap()
        .to_string();

    let lines = || {
        vec![
            line(
                "МОЛОКО ГАЛИЧ 2.5% 900Г",
                "Молоко Галичина 2,5%",
                "piece",
                1.0,
                41.5,
                None,
            ),
            line("КАВА ЛАВАЦА", "Кава Лавацца", "piece", 1.0, 195.3, Some(COFFEE_BARCODE)),
            line("БАНАНИ ВАГ", "Банани", "kilogram", 1.2349, 61.2, None),
            line("ПАКЕТ", "Пакет", "piece", 1.0, 2.5, None),
        ]
    };

    let invalid = app
        .call(
            Method::POST,
            "/api/receipts/recognize",
            Some(&alice.token),
            Some(json!({ "image": STANDARD.encode(b"definitely not a jpeg image"), "media_type": "image/jpeg" })),
        )
        .await;
    assert_eq!(invalid.body["field"], "image");
    let wrong_type = app
        .call(
            Method::POST,
            "/api/receipts/recognize",
            Some(&alice.token),
            Some(json!({ "image": photo(), "media_type": "image/gif" })),
        )
        .await;
    assert_eq!(wrong_type.body["field"], "media_type");

    let (status, draft) = recognize(&app, &alice, &mock, receipt("АТБ-Маркет", "Хрещатик", "5", lines())).await;
    assert_eq!(status, StatusCode::OK, "{draft}");
    assert_eq!(draft["place_id"], atb.as_str());
    assert_eq!(draft["place_addr_id"], atb_branch.as_str());
    assert_eq!(draft["new_place"], Value::Null);
    assert_eq!(draft["curr_id"], uah.as_str());
    assert_eq!(draft["total"], "300.50");
    assert_eq!(draft["lines_total"], "300.50");
    assert!(draft["receipt_ts"].as_str().unwrap().contains("T21:15:00"));
    let kinds: Vec<&str> = draft["lines"]
        .as_array()
        .unwrap()
        .iter()
        .map(|line| line["match_kind"].as_str().unwrap())
        .collect();
    assert_eq!(kinds, vec!["name", "barcode", "new", "new"]);
    assert_eq!(draft["lines"][0]["item_id"], milk.as_str());
    assert_eq!(draft["lines"][1]["item_id"], coffee.as_str());
    assert_eq!(draft["lines"][2]["qty"], "1.235");
    assert_eq!(draft["lines"][2]["unit"], "kilogram");

    let request = mock.requests.lock().unwrap().last().cloned().unwrap();
    assert_eq!(request["model"], "claude-opus-5-5");
    assert_eq!(
        request["messages"][0]["content"][0]["source"]["media_type"],
        "image/jpeg"
    );

    let items: Vec<Value> = draft["lines"]
        .as_array()
        .unwrap()
        .iter()
        .map(|line| match line["item_id"].as_str()
        {
            Some(id) =>
            {
                json!({ "item_id": id, "source_text": line["text"], "qty": line["qty"], "amount": line["amount"] })
            }
            None => json!({
                "new_item": { "name": line["name"], "kind": line["kind"], "unit": line["unit"] },
                "source_text": line["text"], "qty": line["qty"], "amount": line["amount"]
            }),
        })
        .collect();
    let saved = post(
        &app,
        &alice,
        "/api/receipts",
        json!({
            "receipt_ts": draft["receipt_ts"], "curr_id": uah, "place_id": atb, "place_addr_id": atb_branch,
            "items": items
        }),
    )
    .await;
    assert_eq!(saved["items_total"], "300.50");
    assert_eq!(saved["items"][2]["name"], "Банани");
    assert_eq!(saved["items"][2]["unit"], "kilogram");
    let bananas = saved["items"][2]["item_id"].as_str().unwrap().to_string();

    let (_, again) = recognize(
        &app,
        &alice,
        &mock,
        receipt(
            "АТБ",
            "Хрещатик",
            "5",
            vec![line("БАНАНИ ВАГ", "Банани жовті", "kilogram", 0.9, 44.0, None)],
        ),
    )
    .await;
    assert_eq!(again["lines"][0]["match_kind"], "alias");
    assert_eq!(again["lines"][0]["item_id"], bananas.as_str());

    let (_, other_branch) = recognize(
        &app,
        &alice,
        &mock,
        receipt(
            "АТБ",
            "Хрещатик",
            "10",
            vec![line("ПАКЕТ", "Пакет", "piece", 1.0, 2.5, None)],
        ),
    )
    .await;
    assert_eq!(other_branch["place_id"], atb.as_str());
    assert_eq!(other_branch["place_addr_id"], Value::Null);
    assert_eq!(other_branch["new_place"]["place_id"], atb.as_str());
    assert_eq!(other_branch["lines"][0]["match_kind"], "alias");
    let with_branch = post(
        &app,
        &alice,
        "/api/receipts",
        json!({
            "receipt_ts": Utc::now(), "curr_id": uah, "place_id": atb, "new_place": other_branch["new_place"],
            "items": [{ "item_id": other_branch["lines"][0]["item_id"], "amount": "2.5" }]
        }),
    )
    .await;
    assert_eq!(with_branch["branch"], "Київ, Хрещатик 10");
    let place = app
        .call(Method::GET, &format!("/api/places/{atb}"), Some(&alice.token), None)
        .await;
    assert_eq!(place.body["addrs"].as_array().unwrap().len(), 2);

    let (status, limited) = recognize(&app, &alice, &mock, receipt("АТБ", "Хрещатик", "5", lines())).await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS, "{limited}");
}

#[sqlx::test(migrations = "./migrations")]
async fn unknown_shop_is_created_from_the_receipt(a_db: PgPool)
{
    let (ai_url, mock) = spawn_anthropic().await;
    let app = TestApp::with_receipt_ai(a_db, &ai_url, 10);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let uah = app.currency_by_code(&alice.token, "UAH").await;
    kyiv_shop(&app, &alice, "АТБ").await;

    let (_, draft) = recognize(
        &app,
        &alice,
        &mock,
        receipt(
            "Новус",
            "Велика Васильківська",
            "72",
            vec![line("ХЛІБ", "Хліб", "piece", 1.0, 30.0, None)],
        ),
    )
    .await;
    assert_eq!(draft["place_id"], Value::Null);
    assert_eq!(draft["new_place"]["name"], "Новус");
    assert_eq!(draft["new_place"]["street"], "Велика Васильківська");

    let saved = post(
        &app,
        &alice,
        "/api/receipts",
        json!({
            "receipt_ts": Utc::now(), "curr_id": uah, "new_place": draft["new_place"],
            "items": [{ "new_item": { "name": "Хліб", "kind": "food", "unit": "piece" }, "amount": "30" }]
        }),
    )
    .await;
    assert_eq!(saved["place_name"], "Новус");
    assert_eq!(saved["branch"], "Київ, Велика Васильківська 72");

    let places = app.call(Method::GET, "/api/places", Some(&alice.token), None).await;
    assert_eq!(places.body.as_array().unwrap().len(), 2);
    let cities = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM cities WHERE name = 'Київ'")
        .fetch_one(&app.state.db)
        .await
        .unwrap();
    assert_eq!(cities, 1);

    let (_, not_receipt) = {
        mock.reply_with(json!({
            "is_receipt": false, "store_name": null, "country_code": null, "city": null, "street": null,
            "house_number": null, "postal_code": null, "date": null, "time": null, "currency": null,
            "total": null, "lines": []
        }));
        let reply = app
            .call(
                Method::POST,
                "/api/receipts/recognize",
                Some(&bob.token),
                Some(json!({ "image": photo(), "media_type": "image/jpeg" })),
            )
            .await;
        (reply.status, reply.body)
    };
    assert_eq!(not_receipt["code"], "NOT_A_RECEIPT");

    let unavailable = app
        .call(
            Method::POST,
            "/api/receipts/recognize",
            Some(&bob.token),
            Some(json!({ "image": photo(), "media_type": "image/jpeg" })),
        )
        .await;
    assert_eq!(unavailable.status, StatusCode::BAD_GATEWAY);
    assert_eq!(unavailable.body["code"], "RECOGNITION_UNAVAILABLE");

    let (_, bob_draft) = recognize(
        &app,
        &bob,
        &mock,
        receipt(
            "АТБ",
            "Хрещатик",
            "5",
            vec![line("ХЛІБ", "Хліб", "piece", 1.0, 30.0, None)],
        ),
    )
    .await;
    assert_eq!(bob_draft["place_id"], Value::Null);
    assert_eq!(bob_draft["lines"][0]["match_kind"], "new");
}
