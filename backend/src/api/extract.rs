use std::net::SocketAddr;

use axum::async_trait;
use axum::extract::{ConnectInfo, FromRequest, FromRequestParts};
use axum::http::header::AUTHORIZATION;
use axum::http::request::Parts;
use axum::http::{HeaderMap, Method};
use axum_extra::extract::CookieJar;
use uuid::Uuid;

use crate::domain::errors::ApiError;
use crate::security::session;
use crate::state::AppState;

#[derive(FromRequest)]
#[from_request(via(axum::Json), rejection(ApiError))]
pub struct ApiJson<T>(pub T);

#[derive(FromRequestParts)]
#[from_request(via(axum::extract::Path), rejection(ApiError))]
pub struct ApiPath<T>(pub T);

#[derive(FromRequestParts)]
#[from_request(via(axum::extract::Query), rejection(ApiError))]
pub struct ApiQuery<T>(pub T);

#[derive(Debug, Clone, Copy)]
pub struct AuthUser
{
    pub user_id: Uuid,
    pub session_id: Uuid,
}

#[async_trait]
impl FromRequestParts<AppState> for AuthUser
{
    type Rejection = ApiError;

    async fn from_request_parts(a_parts: &mut Parts, a_state: &AppState) -> Result<Self, Self::Rejection>
    {
        let info = if let Some(token) = bearer_token(&a_parts.headers)
        {
            session::resolve(&a_state.db, &token).await?
        }
        else
        {
            let token = CookieJar::from_headers(&a_parts.headers)
                .get(session::COOKIE_NAME)
                .map(|cookie| cookie.value().to_string())
                .ok_or(ApiError::Unauthenticated)?;

            if !is_safe_method(&a_parts.method) && !has_csrf_header(&a_parts.headers)
            {
                return Err(ApiError::Forbidden);
            }

            session::resolve(&a_state.db, &token).await?
        };

        Ok(Self {
            user_id: info.user_id,
            session_id: info.session_id,
        })
    }
}

pub struct ClientIp(pub String);

#[async_trait]
impl FromRequestParts<AppState> for ClientIp
{
    type Rejection = ApiError;

    async fn from_request_parts(a_parts: &mut Parts, a_state: &AppState) -> Result<Self, Self::Rejection>
    {
        if a_state.cfg.is_proxy_trusted
        {
            let forwarded = a_parts
                .headers
                .get("x-real-ip")
                .and_then(|value| value.to_str().ok())
                .map(str::trim)
                .filter(|value| !value.is_empty());

            if let Some(ip) = forwarded
            {
                return Ok(Self(ip.to_string()));
            }
        }

        let ip = a_parts
            .extensions
            .get::<ConnectInfo<SocketAddr>>()
            .map(|info| info.0.ip().to_string())
            .unwrap_or_else(|| "unknown".to_string());

        Ok(Self(ip))
    }
}

fn bearer_token(a_headers: &HeaderMap) -> Option<String>
{
    a_headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(|token| token.trim().to_string())
        .filter(|token| !token.is_empty())
}

fn is_safe_method(a_method: &Method) -> bool
{
    matches!(*a_method, Method::GET | Method::HEAD | Method::OPTIONS)
}

fn has_csrf_header(a_headers: &HeaderMap) -> bool
{
    a_headers
        .get(session::CSRF_HEADER)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value == session::CSRF_VALUE)
}
