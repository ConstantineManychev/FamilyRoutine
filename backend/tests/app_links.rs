mod common;

use axum::http::{header, Method, StatusCode};
use backend::config::parse_android_links;
use common::TestApp;
use serde_json::json;
use sqlx::PgPool;

#[sqlx::test(migrations = "./migrations")]
async fn asset_links_publish_the_configured_app_without_auth(a_db: PgPool)
{
    let fingerprint = "a1".repeat(32);
    let links = parse_android_links(Some("org.example.family"), &fingerprint).unwrap();
    let app = TestApp::with_android_links(a_db, links);

    let reply = app.call(Method::GET, "/.well-known/assetlinks.json", None, None).await;
    assert_eq!(reply.status, StatusCode::OK);
    assert!(reply.headers[header::CONTENT_TYPE]
        .to_str()
        .unwrap()
        .starts_with("application/json"));
    assert_eq!(
        reply.body,
        json!([{
            "relation": ["delegate_permission/common.handle_all_urls"],
            "target": {
                "namespace": "android_app",
                "package_name": "org.example.family",
                "sha256_cert_fingerprints": ["A1:".repeat(31) + "A1"]
            }
        }])
    );

    let wrong_method = app.call(Method::POST, "/.well-known/assetlinks.json", None, None).await;
    assert_eq!(wrong_method.status, StatusCode::METHOD_NOT_ALLOWED);
}

#[sqlx::test(migrations = "./migrations")]
async fn asset_links_are_absent_until_a_certificate_is_configured(a_db: PgPool)
{
    let app = TestApp::with_android_links(a_db, None);
    let reply = app.call(Method::GET, "/.well-known/assetlinks.json", None, None).await;
    assert_eq!(reply.status, StatusCode::NOT_FOUND);
}
