#![allow(dead_code)]

pub mod bank_mocks;

use axum::body::Body;
use axum::http::{header, HeaderMap, Method, Request, StatusCode};
use axum::Router;
use axum_extra::extract::cookie::SameSite;
use std::time::Duration;

use backend::config::{
    AiEndpoints, AndroidLinks, AppConfig, BankConfig, CatalogConfig, ReceiptAiConfig, ServerAiConfig,
};
use backend::{build_router, AppState};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use shared_schema::AiProvider;
use sqlx::PgPool;
use tower::ServiceExt;
use uuid::Uuid;

pub const PASSWORD: &str = "correct-horse-battery";

pub fn bank_config(a_mono_url: &str) -> BankConfig
{
    BankConfig {
        mono_api_url: a_mono_url.to_string(),
        mono_poll_interval: Duration::from_secs(3600),
        mono_call_gap: Duration::ZERO,
        mono_history_months: 3,
        enable_banking: None,
        sync_timezone: "Europe/Dublin".parse().unwrap(),
        eb_sync_hours: vec![0, 6, 12, 18],
        fx_api_url: None,
    }
}

pub fn ai_config(a_api_url: &str, a_server: Option<ServerAiConfig>) -> ReceiptAiConfig
{
    ReceiptAiConfig {
        endpoints: AiEndpoints {
            anthropic: a_api_url.to_string(),
            openai: a_api_url.to_string(),
            gemini: a_api_url.to_string(),
        },
        server: a_server,
        is_own_keys_allowed: true,
    }
}

pub fn catalog_config(a_admins: &[&str], a_off_url: Option<&str>) -> CatalogConfig
{
    CatalogConfig {
        admin_emails: a_admins.iter().map(|email| email.to_string()).collect(),
        off_api_url: a_off_url.map(str::to_string),
        cat_max_depth: 3,
    }
}

pub struct TestApp
{
    pub router: Router,
    pub state: AppState,
}

pub struct Reply
{
    pub status: StatusCode,
    pub headers: HeaderMap,
    pub body: Value,
}

pub struct TestUser
{
    pub id: Uuid,
    pub token: String,
}

impl TestApp
{
    pub fn new(a_db: PgPool) -> Self
    {
        Self::with_banks(a_db, bank_config("http://127.0.0.1:9"))
    }

    pub fn with_banks(a_db: PgPool, a_banks: BankConfig) -> Self
    {
        Self::build(
            a_db,
            a_banks,
            ai_config("http://127.0.0.1:9", None),
            catalog_config(&[], None),
            None,
        )
    }

    pub fn with_android_links(a_db: PgPool, a_links: Option<AndroidLinks>) -> Self
    {
        Self::build(
            a_db,
            bank_config("http://127.0.0.1:9"),
            ai_config("http://127.0.0.1:9", None),
            catalog_config(&[], None),
            a_links,
        )
    }

    pub fn with_catalog(a_db: PgPool, a_catalog: CatalogConfig, a_receipt_ai: ReceiptAiConfig) -> Self
    {
        Self::build(a_db, bank_config("http://127.0.0.1:9"), a_receipt_ai, a_catalog, None)
    }

    pub fn with_receipt_ai(a_db: PgPool, a_api_url: &str, a_daily_limit: i32) -> Self
    {
        let server = ServerAiConfig {
            provider: AiProvider::Anthropic,
            api_key: bank_mocks::AI_KEY.to_string(),
            model: "claude-opus-5-5".to_string(),
            daily_limit: a_daily_limit,
            monthly_limit: 300,
        };
        Self::with_ai(a_db, ai_config(a_api_url, Some(server)))
    }

    pub fn with_ai(a_db: PgPool, a_receipt_ai: ReceiptAiConfig) -> Self
    {
        Self::build(
            a_db,
            bank_config("http://127.0.0.1:9"),
            a_receipt_ai,
            catalog_config(&[], None),
            None,
        )
    }

    fn build(
        a_db: PgPool,
        a_banks: BankConfig,
        a_receipt_ai: ReceiptAiConfig,
        a_catalog: CatalogConfig,
        a_android_links: Option<AndroidLinks>,
    ) -> Self
    {
        let cfg = AppConfig {
            database_url: String::new(),
            bind_addr: "127.0.0.1:0".parse().unwrap(),
            allowed_origins: Vec::new(),
            is_cookie_secure: false,
            cookie_same_site: SameSite::Strict,
            is_proxy_trusted: false,
            data_key: [9u8; 32],
            password_pepper: vec![3u8; 32],
            banks: a_banks,
            receipt_ai: a_receipt_ai,
            catalog: a_catalog,
            android_links: a_android_links,
        };

        let state = AppState::new(a_db, cfg).unwrap();

        Self {
            router: build_router(state.clone()),
            state,
        }
    }

    pub async fn send(&self, a_request: Request<Body>) -> Reply
    {
        let response = self.router.clone().oneshot(a_request).await.unwrap();
        let status = response.status();
        let headers = response.headers().clone();
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let body = if bytes.is_empty()
        {
            Value::Null
        }
        else
        {
            serde_json::from_slice(&bytes).unwrap_or(Value::Null)
        };

        Reply { status, headers, body }
    }

    pub async fn call(&self, a_method: Method, a_uri: &str, a_token: Option<&str>, a_body: Option<Value>) -> Reply
    {
        let mut builder = Request::builder().method(a_method).uri(a_uri);

        if let Some(token) = a_token
        {
            builder = builder.header(header::AUTHORIZATION, format!("Bearer {token}"));
        }

        let request = match a_body
        {
            Some(body) => builder
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
            None => builder.body(Body::empty()).unwrap(),
        };

        self.send(request).await
    }

    pub async fn register(&self, a_email: &str) -> StatusCode
    {
        let body = json!({
            "first_name": "Test",
            "last_name": a_email.split('@').next().unwrap(),
            "email": a_email,
            "password": PASSWORD,
            "birth_date": "1990-05-17"
        });

        self.call(Method::POST, "/api/auth/register", None, Some(body))
            .await
            .status
    }

    pub async fn login(&self, a_email: &str) -> Reply
    {
        let body = json!({ "email": a_email, "password": PASSWORD });
        self.call(Method::POST, "/api/auth/login", None, Some(body)).await
    }

    pub async fn user(&self, a_email: &str) -> TestUser
    {
        assert_eq!(self.register(a_email).await, StatusCode::CREATED);
        let reply = self.login(a_email).await;
        assert_eq!(reply.status, StatusCode::OK);

        TestUser {
            id: reply.body["user"]["id"].as_str().unwrap().parse().unwrap(),
            token: reply.body["token"].as_str().unwrap().to_string(),
        }
    }

    pub async fn family(&self, a_owner: &TestUser, a_name: &str) -> String
    {
        let reply = self
            .call(
                Method::POST,
                "/api/families",
                Some(&a_owner.token),
                Some(json!({ "name": a_name })),
            )
            .await;
        assert_eq!(reply.status, StatusCode::CREATED);
        reply.body["id"].as_str().unwrap().to_string()
    }

    pub async fn join(&self, a_admin: &TestUser, a_member: &TestUser, a_fam_id: &str, a_role: &str)
    {
        let invite = self
            .call(
                Method::POST,
                &format!("/api/families/{a_fam_id}/invites"),
                Some(&a_admin.token),
                Some(json!({ "role": a_role })),
            )
            .await;
        assert_eq!(invite.status, StatusCode::CREATED);

        let code = invite.body["code"].as_str().unwrap();
        let accepted = self
            .call(
                Method::POST,
                "/api/invites/accept",
                Some(&a_member.token),
                Some(json!({ "code": code })),
            )
            .await;
        assert_eq!(accepted.status, StatusCode::OK);
    }

    pub async fn currency_id(&self, a_token: &str) -> String
    {
        let reply = self.call(Method::GET, "/api/currencies", Some(a_token), None).await;
        reply.body.as_array().unwrap()[0]["id"].as_str().unwrap().to_string()
    }

    pub async fn currency_by_code(&self, a_token: &str, a_code: &str) -> String
    {
        let reply = self.call(Method::GET, "/api/currencies", Some(a_token), None).await;
        reply
            .body
            .as_array()
            .unwrap()
            .iter()
            .find(|currency| currency["code"] == a_code)
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_string()
    }
}
