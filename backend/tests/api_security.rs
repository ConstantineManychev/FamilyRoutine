mod common;

use axum::body::Body;
use axum::http::{header, Method, Request, StatusCode};
use backend::security::crypto::account_token_aad;
use common::{TestApp, PASSWORD};
use serde_json::json;
use sqlx::PgPool;
use uuid::Uuid;

const MONO_TOKEN: &str = "uMonoBankPersonalToken0123456789abcdef";

#[sqlx::test(migrations = "./migrations")]
async fn protected_endpoints_require_a_session(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let nil = Uuid::nil();

    let endpoints = [
        (Method::GET, "/api/user/me".to_string()),
        (
            Method::GET,
            "/api/user/energy-timeline?target_date=2026-01-01".to_string(),
        ),
        (Method::GET, "/api/families".to_string()),
        (Method::GET, "/api/wallets".to_string()),
        (Method::GET, "/api/currencies".to_string()),
        (Method::GET, "/api/places".to_string()),
        (Method::DELETE, format!("/api/places/{nil}")),
        (Method::GET, "/api/geo/countries".to_string()),
        (Method::DELETE, format!("/api/geo/cities/{nil}")),
        (Method::GET, "/api/dicts/exercises".to_string()),
        (Method::POST, "/api/invites/accept".to_string()),
    ];

    for (method, uri) in endpoints
    {
        let reply = app.call(method.clone(), &uri, None, None).await;
        assert_eq!(reply.status, StatusCode::UNAUTHORIZED, "{method} {uri}");
        assert_eq!(reply.body["code"], "UNAUTHENTICATED");
    }

    let forged = app.call(Method::GET, "/api/user/me", Some("forged-token"), None).await;
    assert_eq!(forged.status, StatusCode::UNAUTHORIZED);
}

#[sqlx::test(migrations = "./migrations")]
async fn session_tokens_are_hashed_and_revocable(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let alice = app.user("alice@example.com").await;

    let stored: Vec<u8> = sqlx::query_scalar("SELECT token_hash FROM sessions WHERE user_id = $1")
        .bind(alice.id)
        .fetch_one(&a_db)
        .await
        .unwrap();
    assert_ne!(stored, alice.token.as_bytes());

    let me = app.call(Method::GET, "/api/user/me", Some(&alice.token), None).await;
    assert_eq!(me.status, StatusCode::OK);
    assert_eq!(me.body["id"], alice.id.to_string());
    assert_eq!(me.body["email"], "alice@example.com");

    let logout = app
        .call(Method::POST, "/api/auth/logout", Some(&alice.token), None)
        .await;
    assert_eq!(logout.status, StatusCode::NO_CONTENT);

    let after = app.call(Method::GET, "/api/user/me", Some(&alice.token), None).await;
    assert_eq!(after.status, StatusCode::UNAUTHORIZED);
}

#[sqlx::test(migrations = "./migrations")]
async fn logout_all_revokes_every_session(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let second = app.login("alice@example.com").await.body["token"]
        .as_str()
        .unwrap()
        .to_string();

    let reply = app
        .call(Method::POST, "/api/auth/logout-all", Some(&alice.token), None)
        .await;
    assert_eq!(reply.status, StatusCode::NO_CONTENT);

    assert_eq!(
        app.call(Method::GET, "/api/user/me", Some(&second), None).await.status,
        StatusCode::UNAUTHORIZED
    );
}

#[sqlx::test(migrations = "./migrations")]
async fn passwords_are_peppered_and_login_is_rate_limited(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    app.user("alice@example.com").await;

    let row: (String, bool) = sqlx::query_as("SELECT password_hash, is_pwd_peppered FROM users WHERE email = $1")
        .bind("alice@example.com")
        .fetch_one(&a_db)
        .await
        .unwrap();
    assert!(row.0.starts_with("$argon2id$"));
    assert!(!row.0.contains(PASSWORD));
    assert!(row.1);

    let unknown = app
        .call(
            Method::POST,
            "/api/auth/login",
            None,
            Some(json!({ "email": "nobody@example.com", "password": "x" })),
        )
        .await;
    assert_eq!(unknown.status, StatusCode::UNAUTHORIZED);
    assert_eq!(unknown.body["code"], "INVALID_CREDENTIALS");

    let mut last_status = StatusCode::OK;
    for _ in 0..12
    {
        last_status = app
            .call(
                Method::POST,
                "/api/auth/login",
                None,
                Some(json!({ "email": "alice@example.com", "password": "wrong-password" })),
            )
            .await
            .status;
    }
    assert_eq!(last_status, StatusCode::TOO_MANY_REQUESTS);
}

#[sqlx::test(migrations = "./migrations")]
async fn registration_validates_input_and_rejects_duplicates(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    assert_eq!(app.register("alice@example.com").await, StatusCode::CREATED);
    assert_eq!(app.register("ALICE@example.com").await, StatusCode::CONFLICT);

    let weak = app
        .call(
            Method::POST,
            "/api/auth/register",
            None,
            Some(json!({
                "first_name": "Bob", "last_name": "B", "email": "bob@example.com",
                "password": "short", "birth_date": "1990-01-01"
            })),
        )
        .await;
    assert_eq!(weak.status, StatusCode::BAD_REQUEST);
    assert_eq!(weak.body["field"], "password");
}

#[sqlx::test(migrations = "./migrations")]
async fn wallet_sync_token_is_encrypted_and_never_returned(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let alice = app.user("alice@example.com").await;
    let curr_id = app.currency_id(&alice.token).await;

    let created = app
        .call(
            Method::POST,
            "/api/wallets",
            Some(&alice.token),
            Some(json!({
                "name": "Mono", "curr_id": curr_id, "account_type": "card",
                "bank_type": "monobank", "mask": "1234", "sync_token": MONO_TOKEN
            })),
        )
        .await;
    assert_eq!(created.status, StatusCode::CREATED);
    assert_eq!(created.body["is_sync_token_set"], true);
    assert!(!created.body.to_string().contains(MONO_TOKEN));

    let wallet_id: Uuid = created.body["id"].as_str().unwrap().parse().unwrap();

    let listed = app.call(Method::GET, "/api/wallets", Some(&alice.token), None).await;
    assert!(!listed.body.to_string().contains(MONO_TOKEN));

    let sealed: Vec<u8> = sqlx::query_scalar("SELECT sync_secret FROM accounts WHERE id = $1")
        .bind(wallet_id)
        .fetch_one(&a_db)
        .await
        .unwrap();
    assert!(!sealed
        .windows(MONO_TOKEN.len())
        .any(|window| window == MONO_TOKEN.as_bytes()));

    let opened = app
        .state
        .secret_box
        .open(&sealed, &account_token_aad(wallet_id))
        .unwrap();
    assert_eq!(opened, MONO_TOKEN.as_bytes());

    let renamed = app
        .call(
            Method::PUT,
            &format!("/api/wallets/{wallet_id}"),
            Some(&alice.token),
            Some(json!({ "name": "Renamed" })),
        )
        .await;
    assert_eq!(renamed.status, StatusCode::OK);
    assert_eq!(renamed.body["is_sync_token_set"], true);

    let cleared = app
        .call(
            Method::PUT,
            &format!("/api/wallets/{wallet_id}"),
            Some(&alice.token),
            Some(json!({ "name": "Renamed", "is_sync_token_removed": true })),
        )
        .await;
    assert_eq!(cleared.body["is_sync_token_set"], false);

    let full_pan = app
        .call(
            Method::PUT,
            &format!("/api/wallets/{wallet_id}"),
            Some(&alice.token),
            Some(json!({ "name": "Renamed", "mask": "4111111111111111" })),
        )
        .await;
    assert_eq!(full_pan.status, StatusCode::BAD_REQUEST);
}

#[sqlx::test(migrations = "./migrations")]
async fn personal_wallets_are_invisible_to_other_users(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let mallory = app.user("mallory@example.com").await;
    let curr_id = app.currency_id(&alice.token).await;

    let created = app
        .call(
            Method::POST,
            "/api/wallets",
            Some(&alice.token),
            Some(json!({ "name": "Cash", "curr_id": curr_id, "account_type": "cash" })),
        )
        .await;
    let wallet_id = created.body["id"].as_str().unwrap();
    let uri = format!("/api/wallets/{wallet_id}");

    assert_eq!(
        app.call(Method::GET, &uri, Some(&mallory.token), None).await.status,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        app.call(Method::PUT, &uri, Some(&mallory.token), Some(json!({ "name": "x" })))
            .await
            .status,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        app.call(Method::DELETE, &uri, Some(&mallory.token), None).await.status,
        StatusCode::NOT_FOUND
    );

    let listed = app.call(Method::GET, "/api/wallets", Some(&mallory.token), None).await;
    assert_eq!(listed.body.as_array().unwrap().len(), 0);
}

#[sqlx::test(migrations = "./migrations")]
async fn family_wallets_follow_membership_and_roles(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let mallory = app.user("mallory@example.com").await;
    let fam_id = app.family(&alice, "Home").await;
    app.join(&alice, &bob, &fam_id, "standard").await;
    let curr_id = app.currency_id(&alice.token).await;

    let intrusion = app
        .call(
            Method::POST,
            "/api/wallets",
            Some(&mallory.token),
            Some(json!({ "name": "x", "curr_id": curr_id, "account_type": "cash", "family_id": fam_id })),
        )
        .await;
    assert_eq!(intrusion.status, StatusCode::NOT_FOUND);

    let family_token = app
        .call(
            Method::POST,
            "/api/wallets",
            Some(&alice.token),
            Some(json!({
                "name": "Shared", "curr_id": curr_id, "account_type": "card",
                "bank_type": "monobank", "family_id": fam_id, "sync_token": MONO_TOKEN
            })),
        )
        .await;
    assert_eq!(family_token.status, StatusCode::BAD_REQUEST);

    let created = app
        .call(
            Method::POST,
            "/api/wallets",
            Some(&alice.token),
            Some(json!({ "name": "Shared", "curr_id": curr_id, "account_type": "cash", "family_id": fam_id })),
        )
        .await;
    assert_eq!(created.status, StatusCode::CREATED);
    let uri = format!("/api/wallets/{}", created.body["id"].as_str().unwrap());

    let seen_by_bob = app.call(Method::GET, &uri, Some(&bob.token), None).await;
    assert_eq!(seen_by_bob.status, StatusCode::OK);
    assert_eq!(seen_by_bob.body["is_editable"], false);
    assert_eq!(
        app.call(Method::DELETE, &uri, Some(&bob.token), None).await.status,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        app.call(Method::GET, &uri, Some(&mallory.token), None).await.status,
        StatusCode::NOT_FOUND
    );
}

#[sqlx::test(migrations = "./migrations")]
async fn invites_are_single_use_codes_managed_by_admins(a_db: PgPool)
{
    let app = TestApp::new(a_db.clone());
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let carol = app.user("carol@example.com").await;
    let fam_id = app.family(&alice, "Home").await;

    assert_eq!(
        app.call(Method::GET, &format!("/api/families/{fam_id}"), Some(&bob.token), None)
            .await
            .status,
        StatusCode::NOT_FOUND
    );

    let invite = app
        .call(
            Method::POST,
            &format!("/api/families/{fam_id}/invites"),
            Some(&alice.token),
            Some(json!({ "role": "standard", "label": "for Bob" })),
        )
        .await;
    let code = invite.body["code"].as_str().unwrap().to_string();

    let stored: Vec<u8> = sqlx::query_scalar("SELECT code_hash FROM family_invites")
        .fetch_one(&a_db)
        .await
        .unwrap();
    assert_ne!(stored, code.as_bytes());

    let pending = app
        .call(
            Method::GET,
            &format!("/api/families/{fam_id}/invites"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(pending.body.as_array().unwrap().len(), 1);
    assert!(!pending.body.to_string().contains(&code));

    let accepted = app
        .call(
            Method::POST,
            "/api/invites/accept",
            Some(&bob.token),
            Some(json!({ "code": code.to_lowercase() })),
        )
        .await;
    assert_eq!(accepted.status, StatusCode::OK);
    assert_eq!(accepted.body["family_id"], fam_id);

    let reused = app
        .call(
            Method::POST,
            "/api/invites/accept",
            Some(&carol.token),
            Some(json!({ "code": code })),
        )
        .await;
    assert_eq!(reused.status, StatusCode::NOT_FOUND);

    let by_member = app
        .call(
            Method::POST,
            &format!("/api/families/{fam_id}/invites"),
            Some(&bob.token),
            Some(json!({ "role": "admin" })),
        )
        .await;
    assert_eq!(by_member.status, StatusCode::FORBIDDEN);

    let detail = app
        .call(Method::GET, &format!("/api/families/{fam_id}"), Some(&bob.token), None)
        .await;
    assert_eq!(detail.body["my_role"], "standard");
    assert_eq!(detail.body["members"].as_array().unwrap().len(), 2);
    assert!(!detail.body.to_string().contains("alice@example.com"));
}

#[sqlx::test(migrations = "./migrations")]
async fn last_admin_is_protected(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let fam_id = app.family(&alice, "Home").await;
    app.join(&alice, &bob, &fam_id, "standard").await;

    let leave = app
        .call(
            Method::POST,
            &format!("/api/families/{fam_id}/leave"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(leave.status, StatusCode::CONFLICT);
    assert_eq!(leave.body["code"], "LAST_ADMIN");

    let demote = app
        .call(
            Method::PUT,
            &format!("/api/families/{fam_id}/members/{}", alice.id),
            Some(&alice.token),
            Some(json!({ "role": "standard" })),
        )
        .await;
    assert_eq!(demote.body["code"], "LAST_ADMIN");

    let bad_role = app
        .call(
            Method::PUT,
            &format!("/api/families/{fam_id}/members/{}", bob.id),
            Some(&alice.token),
            Some(json!({ "role": "owner" })),
        )
        .await;
    assert_eq!(bad_role.status, StatusCode::BAD_REQUEST);

    let by_member = app
        .call(
            Method::PUT,
            &format!("/api/families/{fam_id}/members/{}", alice.id),
            Some(&bob.token),
            Some(json!({ "role": "standard" })),
        )
        .await;
    assert_eq!(by_member.status, StatusCode::FORBIDDEN);

    let promote = app
        .call(
            Method::PUT,
            &format!("/api/families/{fam_id}/members/{}", bob.id),
            Some(&alice.token),
            Some(json!({ "role": "admin" })),
        )
        .await;
    assert_eq!(promote.status, StatusCode::NO_CONTENT);

    let leave_again = app
        .call(
            Method::POST,
            &format!("/api/families/{fam_id}/leave"),
            Some(&alice.token),
            None,
        )
        .await;
    assert_eq!(leave_again.status, StatusCode::NO_CONTENT);
}

#[sqlx::test(migrations = "./migrations")]
async fn places_and_custom_exercises_are_private(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let mallory = app.user("mallory@example.com").await;

    let place = app
        .call(
            Method::POST,
            "/api/places",
            Some(&alice.token),
            Some(json!({ "name": "Home", "addrs": [] })),
        )
        .await;
    assert_eq!(place.status, StatusCode::CREATED);
    let place_uri = format!("/api/places/{}", place.body["id"].as_str().unwrap());

    assert_eq!(
        app.call(Method::GET, "/api/places", Some(&mallory.token), None)
            .await
            .body,
        json!([])
    );
    assert_eq!(
        app.call(Method::GET, &place_uri, Some(&mallory.token), None)
            .await
            .status,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        app.call(Method::DELETE, &place_uri, Some(&mallory.token), None)
            .await
            .status,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        app.call(Method::GET, &place_uri, Some(&alice.token), None).await.status,
        StatusCode::OK
    );

    let exercise = app
        .call(
            Method::POST,
            "/api/dicts/exercises",
            Some(&alice.token),
            Some(json!({
                "name": "Secret squat", "ex_type": "strength", "met_val": 5.0,
                "weight_type": "hybrid", "bw_pct": 60.0,
                "musc_grps": [{ "grp": "legs", "pct": 100.0 }]
            })),
        )
        .await;
    assert_eq!(exercise.status, StatusCode::CREATED);
    assert_eq!(exercise.body["weight_type"], "hybrid");
    assert_eq!(exercise.body["bw_pct"], 60.0);
    let ex_uri = format!("/api/dicts/exercises/{}", exercise.body["id"].as_str().unwrap());

    let foreign_list = app
        .call(Method::GET, "/api/dicts/exercises", Some(&mallory.token), None)
        .await;
    assert!(!foreign_list.body.to_string().contains("Secret squat"));
    assert_eq!(
        app.call(Method::GET, &ex_uri, Some(&mallory.token), None).await.status,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        app.call(Method::DELETE, &ex_uri, Some(&mallory.token), None)
            .await
            .status,
        StatusCode::NOT_FOUND
    );
}

#[sqlx::test(migrations = "./migrations")]
async fn shared_geo_entries_are_protected_from_other_users(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let mallory = app.user("mallory@example.com").await;

    let countries = app
        .call(Method::GET, "/api/geo/countries", Some(&alice.token), None)
        .await;
    let country_id = countries.body[0]["id"].as_str().unwrap().to_string();

    let city = app
        .call(
            Method::POST,
            &format!("/api/geo/countries/{country_id}/cities"),
            Some(&alice.token),
            Some(json!({ "name": "Dublin" })),
        )
        .await;
    assert_eq!(city.body["is_editable"], true);
    let city_id = city.body["id"].as_str().unwrap();

    let same_city = app
        .call(
            Method::POST,
            &format!("/api/geo/countries/{country_id}/cities"),
            Some(&mallory.token),
            Some(json!({ "name": "Dublin" })),
        )
        .await;
    assert_eq!(same_city.body["id"], city_id);
    assert_eq!(same_city.body["is_editable"], false);

    let rename = app
        .call(
            Method::PUT,
            &format!("/api/geo/cities/{city_id}"),
            Some(&mallory.token),
            Some(json!({ "name": "X" })),
        )
        .await;
    assert_eq!(rename.status, StatusCode::FORBIDDEN);
    assert_eq!(
        app.call(
            Method::DELETE,
            &format!("/api/geo/cities/{city_id}"),
            Some(&mallory.token),
            None
        )
        .await
        .status,
        StatusCode::FORBIDDEN
    );
}

#[sqlx::test(migrations = "./migrations")]
async fn cookie_sessions_require_csrf_header_for_mutations(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    app.register("alice@example.com").await;

    let login = app
        .call(
            Method::POST,
            "/api/auth/login",
            None,
            Some(json!({ "email": "alice@example.com", "password": PASSWORD, "is_cookie_mode": true })),
        )
        .await;
    assert_eq!(login.status, StatusCode::OK);
    assert!(login.body.get("token").is_none());

    let set_cookie = login
        .headers
        .get(header::SET_COOKIE)
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(set_cookie.contains("HttpOnly"));
    assert!(set_cookie.contains("SameSite=Strict"));
    let cookie = set_cookie.split(';').next().unwrap().to_string();

    let read = Request::builder()
        .method(Method::GET)
        .uri("/api/user/me")
        .header(header::COOKIE, &cookie)
        .body(Body::empty())
        .unwrap();
    assert_eq!(app.send(read).await.status, StatusCode::OK);

    let forged = Request::builder()
        .method(Method::POST)
        .uri("/api/families")
        .header(header::COOKIE, &cookie)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "name": "Forged" }).to_string()))
        .unwrap();
    assert_eq!(app.send(forged).await.status, StatusCode::FORBIDDEN);

    let legit = Request::builder()
        .method(Method::POST)
        .uri("/api/families")
        .header(header::COOKIE, &cookie)
        .header("x-requested-with", "FamilyRoutine")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({ "name": "Legit" }).to_string()))
        .unwrap();
    assert_eq!(app.send(legit).await.status, StatusCode::CREATED);
}

#[sqlx::test(migrations = "./migrations")]
async fn responses_carry_security_headers(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let reply = app.call(Method::GET, "/api/user/me", None, None).await;

    assert_eq!(reply.headers.get("x-content-type-options").unwrap(), "nosniff");
    assert_eq!(reply.headers.get("cache-control").unwrap(), "no-store");
    assert_eq!(reply.headers.get("x-frame-options").unwrap(), "DENY");
}
