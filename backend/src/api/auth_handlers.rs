use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use axum_extra::extract::CookieJar;
use shared_schema::{LoginRequest, LoginResponse, RegisterRequest};

use crate::api::extract::{ApiJson, AuthUser, ClientIp};
use crate::domain::errors::ApiError;
use crate::domain::validation::{check_login_password, MAX_EMAIL_LEN};
use crate::security::rate_limit::{LOGIN_PER_EMAIL, LOGIN_PER_IP, REGISTER_PER_IP};
use crate::security::session;
use crate::services::auth_service;
use crate::state::AppState;

pub async fn register(
    State(a_state): State<AppState>,
    ClientIp(a_ip): ClientIp,
    ApiJson(a_req): ApiJson<RegisterRequest>,
) -> Result<StatusCode, ApiError>
{
    a_state.limiter.hit(&format!("register-ip:{a_ip}"), &REGISTER_PER_IP)?;
    auth_service::register(&a_state, a_req).await?;
    Ok(StatusCode::CREATED)
}

pub async fn login(
    State(a_state): State<AppState>,
    ClientIp(a_ip): ClientIp,
    a_jar: CookieJar,
    ApiJson(a_req): ApiJson<LoginRequest>,
) -> Result<(CookieJar, Json<LoginResponse>), ApiError>
{
    a_state.limiter.hit(&format!("login-ip:{a_ip}"), &LOGIN_PER_IP)?;

    let email_key: String = a_req.email.trim().to_lowercase().chars().take(MAX_EMAIL_LEN).collect();
    let email_key = format!("login-email:{email_key}");
    a_state.limiter.hit(&email_key, &LOGIN_PER_EMAIL)?;

    check_login_password(&a_req.password)?;

    let user = auth_service::authenticate(&a_state, &a_req.email, a_req.password).await?;
    a_state.limiter.reset(&email_key);

    let token = session::create(&a_state.db, user.id).await?;

    if a_req.is_cookie_mode
    {
        let jar = a_jar.add(session::issue_cookie(token, &a_state.cfg));
        return Ok((jar, Json(LoginResponse { user, token: None })));
    }

    Ok((
        a_jar,
        Json(LoginResponse {
            user,
            token: Some(token),
        }),
    ))
}

pub async fn logout(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    a_jar: CookieJar,
) -> Result<(CookieJar, StatusCode), ApiError>
{
    session::revoke(&a_state.db, a_user.session_id).await?;
    Ok((a_jar.add(session::removal_cookie(&a_state.cfg)), StatusCode::NO_CONTENT))
}

pub async fn logout_all(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    a_jar: CookieJar,
) -> Result<(CookieJar, StatusCode), ApiError>
{
    session::revoke_all(&a_state.db, a_user.user_id).await?;
    Ok((a_jar.add(session::removal_cookie(&a_state.cfg)), StatusCode::NO_CONTENT))
}
