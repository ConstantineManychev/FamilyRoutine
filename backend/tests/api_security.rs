mod common;

use axum::body::Body;
use axum::http::{header, Method, Request, StatusCode};
use common::{TestApp, TestUser, PASSWORD};
use serde_json::json;
use sqlx::PgPool;
use uuid::Uuid;

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
        (Method::POST, "/api/routine/marks".to_string()),
        (Method::DELETE, format!("/api/routine/marks/{nil}")),
        (
            Method::GET,
            "/api/routine/timeline?from=2026-01-01T00:00:00Z&to=2026-01-02T00:00:00Z".to_string(),
        ),
        (Method::PUT, format!("/api/families/{nil}/routine-sharing")),
        (Method::GET, "/api/dashboards".to_string()),
        (Method::DELETE, format!("/api/dashboards/{nil}")),
        (Method::POST, format!("/api/dashboards/{nil}/widgets")),
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
                "password": "", "birth_date": "1990-01-01"
            })),
        )
        .await;
    assert_eq!(weak.status, StatusCode::BAD_REQUEST);
    assert_eq!(weak.body["field"], "password");

    let single_char = app
        .call(
            Method::POST,
            "/api/auth/register",
            None,
            Some(json!({
                "first_name": "Bob", "last_name": "B", "email": "bob@example.com",
                "password": "1", "birth_date": "1990-01-01"
            })),
        )
        .await;
    assert_eq!(single_char.status, StatusCode::CREATED);
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
async fn only_owner_manages_admins(a_db: PgPool)
{
    let app = TestApp::new(a_db);
    let alice = app.user("alice@example.com").await;
    let bob = app.user("bob@example.com").await;
    let carol = app.user("carol@example.com").await;
    let dave = app.user("dave@example.com").await;
    let fam_id = app.family(&alice, "Home").await;
    app.join(&alice, &bob, &fam_id, "admin").await;
    app.join(&bob, &carol, &fam_id, "standard").await;
    app.join(&alice, &dave, &fam_id, "admin").await;

    let fam_uri = format!("/api/families/{fam_id}");
    let member_uri = |a_user: &TestUser| format!("{fam_uri}/members/{}", a_user.id);
    let as_admin = json!({ "role": "admin" });
    let as_standard = json!({ "role": "standard" });

    let detail = app.call(Method::GET, &fam_uri, Some(&alice.token), None).await;
    assert_eq!(detail.body["is_owner"], true);
    assert_eq!(detail.body["members"][0]["id"], alice.id.to_string());
    assert_eq!(detail.body["members"][0]["is_owner"], true);

    let admin_invite_by_admin = app
        .call(
            Method::POST,
            &format!("{fam_uri}/invites"),
            Some(&bob.token),
            Some(as_admin.clone()),
        )
        .await;
    assert_eq!(admin_invite_by_admin.status, StatusCode::FORBIDDEN);

    for (target, body) in [(&carol, &as_admin), (&dave, &as_standard), (&alice, &as_standard)]
    {
        let reply = app
            .call(Method::PUT, &member_uri(target), Some(&bob.token), Some(body.clone()))
            .await;
        assert_eq!(reply.status, StatusCode::FORBIDDEN);
    }

    let demote_owner = app
        .call(
            Method::PUT,
            &member_uri(&alice),
            Some(&alice.token),
            Some(as_standard.clone()),
        )
        .await;
    assert_eq!(demote_owner.status, StatusCode::CONFLICT);
    assert_eq!(demote_owner.body["code"], "OWNER_PROTECTED");

    let remove_owner = app
        .call(Method::DELETE, &member_uri(&alice), Some(&bob.token), None)
        .await;
    assert_eq!(remove_owner.body["code"], "OWNER_PROTECTED");

    let remove_admin_by_admin = app
        .call(Method::DELETE, &member_uri(&dave), Some(&bob.token), None)
        .await;
    assert_eq!(remove_admin_by_admin.status, StatusCode::FORBIDDEN);

    let bad_role = app
        .call(
            Method::PUT,
            &member_uri(&bob),
            Some(&alice.token),
            Some(json!({ "role": "owner" })),
        )
        .await;
    assert_eq!(bad_role.status, StatusCode::BAD_REQUEST);

    let delete_by_admin = app.call(Method::DELETE, &fam_uri, Some(&bob.token), None).await;
    assert_eq!(delete_by_admin.status, StatusCode::FORBIDDEN);

    let owner_leave = app
        .call(Method::POST, &format!("{fam_uri}/leave"), Some(&alice.token), None)
        .await;
    assert_eq!(owner_leave.status, StatusCode::CONFLICT);
    assert_eq!(owner_leave.body["code"], "OWNER_MUST_TRANSFER");

    let remove_standard_by_admin = app
        .call(Method::DELETE, &member_uri(&carol), Some(&bob.token), None)
        .await;
    assert_eq!(remove_standard_by_admin.status, StatusCode::NO_CONTENT);

    let dave_invite = app
        .call(
            Method::POST,
            &format!("{fam_uri}/invites"),
            Some(&dave.token),
            Some(as_standard.clone()),
        )
        .await;
    assert_eq!(dave_invite.status, StatusCode::CREATED);

    let pending_admin_invite = app
        .call(
            Method::POST,
            &format!("{fam_uri}/invites"),
            Some(&alice.token),
            Some(as_admin.clone()),
        )
        .await;
    assert_eq!(pending_admin_invite.status, StatusCode::CREATED);

    let demote_admin = app
        .call(
            Method::PUT,
            &member_uri(&dave),
            Some(&alice.token),
            Some(as_standard.clone()),
        )
        .await;
    assert_eq!(demote_admin.status, StatusCode::NO_CONTENT);

    let accept_revoked = app
        .call(
            Method::POST,
            "/api/invites/accept",
            Some(&carol.token),
            Some(json!({ "code": dave_invite.body["code"] })),
        )
        .await;
    assert_eq!(accept_revoked.status, StatusCode::NOT_FOUND);

    let transfer_uri = format!("{fam_uri}/transfer");
    let transfer_by_admin = app
        .call(
            Method::POST,
            &transfer_uri,
            Some(&bob.token),
            Some(json!({ "user_id": bob.id })),
        )
        .await;
    assert_eq!(transfer_by_admin.status, StatusCode::FORBIDDEN);

    let transfer_to_stranger = app
        .call(
            Method::POST,
            &transfer_uri,
            Some(&alice.token),
            Some(json!({ "user_id": carol.id })),
        )
        .await;
    assert_eq!(transfer_to_stranger.status, StatusCode::BAD_REQUEST);

    let transfer = app
        .call(
            Method::POST,
            &transfer_uri,
            Some(&alice.token),
            Some(json!({ "user_id": dave.id })),
        )
        .await;
    assert_eq!(transfer.status, StatusCode::NO_CONTENT);

    let accept_old_admin_invite = app
        .call(
            Method::POST,
            "/api/invites/accept",
            Some(&carol.token),
            Some(json!({ "code": pending_admin_invite.body["code"] })),
        )
        .await;
    assert_eq!(accept_old_admin_invite.status, StatusCode::NOT_FOUND);

    let dave_view = app.call(Method::GET, &fam_uri, Some(&dave.token), None).await;
    assert_eq!(dave_view.body["is_owner"], true);
    assert_eq!(dave_view.body["my_role"], "admin");

    let alice_view = app.call(Method::GET, &fam_uri, Some(&alice.token), None).await;
    assert_eq!(alice_view.body["is_owner"], false);
    assert_eq!(alice_view.body["my_role"], "admin");

    let old_owner_demotes = app
        .call(
            Method::PUT,
            &member_uri(&bob),
            Some(&alice.token),
            Some(as_standard.clone()),
        )
        .await;
    assert_eq!(old_owner_demotes.status, StatusCode::FORBIDDEN);

    let new_owner_removes_admin = app
        .call(Method::DELETE, &member_uri(&alice), Some(&dave.token), None)
        .await;
    assert_eq!(new_owner_removes_admin.status, StatusCode::NO_CONTENT);

    let bob_leaves = app
        .call(Method::POST, &format!("{fam_uri}/leave"), Some(&bob.token), None)
        .await;
    assert_eq!(bob_leaves.status, StatusCode::NO_CONTENT);

    let last_owner_leaves = app
        .call(Method::POST, &format!("{fam_uri}/leave"), Some(&dave.token), None)
        .await;
    assert_eq!(last_owner_leaves.status, StatusCode::NO_CONTENT);
    assert_eq!(
        app.call(Method::GET, &fam_uri, Some(&dave.token), None).await.status,
        StatusCode::NOT_FOUND
    );
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
