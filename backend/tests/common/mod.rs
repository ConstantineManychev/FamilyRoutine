use axum::body::Body;
use axum::http::{header, HeaderMap, Method, Request, StatusCode};
use axum::Router;
use axum_extra::extract::cookie::SameSite;
use backend::config::AppConfig;
use backend::{build_router, AppState};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use sqlx::PgPool;
use tower::ServiceExt;
use uuid::Uuid;

pub const PASSWORD: &str = "correct-horse-battery";

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
        let cfg = AppConfig {
            database_url: String::new(),
            bind_addr: "127.0.0.1:0".parse().unwrap(),
            allowed_origins: Vec::new(),
            is_cookie_secure: false,
            cookie_same_site: SameSite::Strict,
            is_proxy_trusted: false,
            data_key: [9u8; 32],
            password_pepper: vec![3u8; 32],
        };

        let state = AppState::new(a_db, cfg);

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
}
