use axum_extra::extract::cookie::Cookie;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::{Duration, Utc};
use rand::rngs::OsRng;
use rand::RngCore;
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use uuid::Uuid;

use crate::config::AppConfig;
use crate::domain::errors::ApiError;

pub const COOKIE_NAME: &str = "fr_session";
pub const COOKIE_PATH: &str = "/api";
pub const CSRF_HEADER: &str = "x-requested-with";
pub const CSRF_VALUE: &str = "FamilyRoutine";
pub const ABSOLUTE_TTL_DAYS: i64 = 30;
pub const IDLE_TTL_DAYS: i32 = 7;

const TOKEN_BYTES: usize = 32;
const TOKEN_CHARS: usize = 43;
const TOUCH_INTERVAL_SECS: i64 = 300;

#[derive(Debug, Clone, Copy)]
pub struct SessionInfo
{
    pub session_id: Uuid,
    pub user_id: Uuid,
}

pub fn generate_token() -> String
{
    let mut bytes = [0u8; TOKEN_BYTES];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn hash_token(a_token: &str) -> Vec<u8>
{
    Sha256::digest(a_token.as_bytes()).to_vec()
}

fn is_token_well_formed(a_token: &str) -> bool
{
    a_token.len() == TOKEN_CHARS
        && a_token
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

pub async fn create(a_db: &PgPool, a_user_id: Uuid) -> Result<String, ApiError>
{
    let token = generate_token();
    let expires_ts = Utc::now() + Duration::days(ABSOLUTE_TTL_DAYS);

    sqlx::query!(
        "INSERT INTO sessions (user_id, token_hash, expires_ts) VALUES ($1, $2, $3)",
        a_user_id,
        hash_token(&token),
        expires_ts
    )
    .execute(a_db)
    .await?;

    Ok(token)
}

pub async fn resolve(a_db: &PgPool, a_token: &str) -> Result<SessionInfo, ApiError>
{
    if !is_token_well_formed(a_token)
    {
        return Err(ApiError::Unauthenticated);
    }

    let row = sqlx::query!(
        r#"
        SELECT id, user_id, last_seen_ts
        FROM sessions
        WHERE token_hash = $1
          AND expires_ts > NOW()
          AND last_seen_ts > NOW() - make_interval(days => $2)
        "#,
        hash_token(a_token),
        IDLE_TTL_DAYS
    )
    .fetch_optional(a_db)
    .await?
    .ok_or(ApiError::Unauthenticated)?;

    if (Utc::now() - row.last_seen_ts).num_seconds() > TOUCH_INTERVAL_SECS
    {
        sqlx::query!("UPDATE sessions SET last_seen_ts = NOW() WHERE id = $1", row.id)
            .execute(a_db)
            .await?;
    }

    Ok(SessionInfo {
        session_id: row.id,
        user_id: row.user_id,
    })
}

pub async fn revoke(a_db: &PgPool, a_session_id: Uuid) -> Result<(), ApiError>
{
    sqlx::query!("DELETE FROM sessions WHERE id = $1", a_session_id)
        .execute(a_db)
        .await?;
    Ok(())
}

pub async fn revoke_all(a_db: &PgPool, a_user_id: Uuid) -> Result<(), ApiError>
{
    sqlx::query!("DELETE FROM sessions WHERE user_id = $1", a_user_id)
        .execute(a_db)
        .await?;
    Ok(())
}

pub async fn purge_expired(a_db: &PgPool) -> Result<u64, ApiError>
{
    let result = sqlx::query!(
        "DELETE FROM sessions WHERE expires_ts <= NOW() OR last_seen_ts <= NOW() - make_interval(days => $1)",
        IDLE_TTL_DAYS
    )
    .execute(a_db)
    .await?;

    Ok(result.rows_affected())
}

pub fn issue_cookie(a_token: String, a_cfg: &AppConfig) -> Cookie<'static>
{
    Cookie::build((COOKIE_NAME, a_token))
        .path(COOKIE_PATH)
        .http_only(true)
        .secure(a_cfg.is_cookie_secure)
        .same_site(a_cfg.cookie_same_site)
        .max_age(time::Duration::days(ABSOLUTE_TTL_DAYS))
        .build()
}

pub fn removal_cookie(a_cfg: &AppConfig) -> Cookie<'static>
{
    Cookie::build((COOKIE_NAME, ""))
        .path(COOKIE_PATH)
        .http_only(true)
        .secure(a_cfg.is_cookie_secure)
        .same_site(a_cfg.cookie_same_site)
        .max_age(time::Duration::ZERO)
        .build()
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn tokens_are_unique_and_well_formed()
    {
        let first = generate_token();
        let second = generate_token();

        assert_ne!(first, second);
        assert!(is_token_well_formed(&first));
        assert!(!is_token_well_formed("short"));
        assert!(!is_token_well_formed(&format!("{}!", &first[..TOKEN_CHARS - 1])));
    }

    #[test]
    fn token_hash_does_not_contain_the_token()
    {
        let token = generate_token();
        let hash = hash_token(&token);

        assert_eq!(hash.len(), 32);
        assert_ne!(hash, token.as_bytes());
    }
}
