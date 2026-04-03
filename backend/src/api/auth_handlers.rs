use crate::api::auth_middleware::AuthClaims;
use crate::domain::errors::ApiError;
use crate::services::auth_service::{authenticate_user, register_new_user};
use axum::{extract::State, http::StatusCode, response::IntoResponse, Json};
use axum_extra::extract::{
    cookie::{Cookie, SameSite},
    CookieJar,
};
use chrono::{Duration as ChronoDuration, Utc};
use jsonwebtoken::{encode, EncodingKey, Header};
use serde_json::Value;
use shared_schema::{CreateUserRequest, LoginRequest};
use sqlx::PgPool;
use time::Duration as TimeDuration;

pub async fn handle_user_registration(
    State(db): State<PgPool>,
    Json(mut payload): Json<CreateUserRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    payload.email = payload.email.to_lowercase();
    let res = register_new_user(&db, payload).await?;
    Ok((StatusCode::CREATED, Json(res)))
}

pub async fn handle_user_login(
    State(db): State<PgPool>,
    jar: CookieJar,
    Json(mut payload): Json<LoginRequest>,
) -> Result<impl IntoResponse, ApiError> {
    payload.email = payload.email.to_lowercase();
    let user = authenticate_user(&db, payload).await?;
    
    let now = Utc::now();
    let expiration_chrono = now + ChronoDuration::days(7);
    
    let claims = AuthClaims { 
        sub: user.id, 
        exp: expiration_chrono.timestamp() as usize 
    };
    
    let secret = std::env::var("JWT_SECRET").unwrap_or_else(|_| "very_secret_key_123".into());
    let token = encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_ref())
    ).map_err(|_| ApiError::InternalServerError)?;

    let cookie = Cookie::build(("jwt_token", token.clone()))
    .path("/")
    .http_only(true)
    .same_site(SameSite::Lax)
    .max_age(TimeDuration::days(7))
    .build();

    let mut res = Json(user).into_response();
    res.headers_mut().insert(
        axum::http::header::SET_COOKIE,
        cookie.to_string().parse().unwrap()
    );
    res.headers_mut().insert("X-Auth-Token", token.parse().unwrap());

    Ok((jar, res))
}

pub async fn handle_user_logout() -> StatusCode {
    StatusCode::OK
}