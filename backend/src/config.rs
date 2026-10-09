use std::net::SocketAddr;

use axum::http::HeaderValue;
use axum_extra::extract::cookie::SameSite;
use base64::engine::general_purpose::STANDARD;
use base64::Engine;

pub const DATA_KEY_LEN: usize = 32;
pub const MIN_PEPPER_LEN: usize = 32;

pub struct AppConfig
{
    pub database_url: String,
    pub bind_addr: SocketAddr,
    pub allowed_origins: Vec<HeaderValue>,
    pub is_cookie_secure: bool,
    pub cookie_same_site: SameSite,
    pub is_proxy_trusted: bool,
    pub data_key: [u8; DATA_KEY_LEN],
    pub password_pepper: Vec<u8>,
}

impl AppConfig
{
    pub fn from_env() -> Result<Self, String>
    {
        let database_url = required("DATABASE_URL")?;

        let bind_addr = optional("BIND_ADDR")
            .unwrap_or_else(|| "0.0.0.0:3000".to_string())
            .parse::<SocketAddr>()
            .map_err(|_| "BIND_ADDR must be host:port".to_string())?;

        let allowed_origins = parse_origins(&optional("ALLOWED_ORIGINS").unwrap_or_default())?;
        let is_cookie_secure = parse_bool("COOKIE_SECURE", true)?;
        let cookie_same_site = parse_same_site(&optional("COOKIE_SAMESITE").unwrap_or_else(|| "strict".into()))?;
        let is_proxy_trusted = parse_bool("TRUST_PROXY", false)?;

        if cookie_same_site == SameSite::None && !is_cookie_secure
        {
            return Err("COOKIE_SAMESITE=none requires COOKIE_SECURE=true".into());
        }

        let data_key = decode_data_key(&required("DATA_ENC_KEY")?)?;
        let password_pepper = decode_pepper(&required("PASSWORD_PEPPER")?)?;

        Ok(Self {
            database_url,
            bind_addr,
            allowed_origins,
            is_cookie_secure,
            cookie_same_site,
            is_proxy_trusted,
            data_key,
            password_pepper,
        })
    }
}

pub fn decode_data_key(a_encoded: &str) -> Result<[u8; DATA_KEY_LEN], String>
{
    let bytes = STANDARD
        .decode(a_encoded.trim())
        .map_err(|_| "DATA_ENC_KEY must be base64".to_string())?;

    bytes
        .try_into()
        .map_err(|_| format!("DATA_ENC_KEY must decode to exactly {DATA_KEY_LEN} bytes"))
}

pub fn decode_pepper(a_encoded: &str) -> Result<Vec<u8>, String>
{
    let bytes = STANDARD
        .decode(a_encoded.trim())
        .map_err(|_| "PASSWORD_PEPPER must be base64".to_string())?;

    if bytes.len() < MIN_PEPPER_LEN
    {
        return Err(format!(
            "PASSWORD_PEPPER must decode to at least {MIN_PEPPER_LEN} bytes"
        ));
    }

    Ok(bytes)
}

fn required(a_name: &str) -> Result<String, String>
{
    optional(a_name).ok_or_else(|| format!("{a_name} is not set"))
}

fn optional(a_name: &str) -> Option<String>
{
    std::env::var(a_name)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn parse_bool(a_name: &str, a_is_default: bool) -> Result<bool, String>
{
    match optional(a_name).as_deref().map(str::to_ascii_lowercase).as_deref()
    {
        None => Ok(a_is_default),
        Some("1" | "true" | "yes") => Ok(true),
        Some("0" | "false" | "no") => Ok(false),
        Some(_) => Err(format!("{a_name} must be true or false")),
    }
}

fn parse_same_site(a_value: &str) -> Result<SameSite, String>
{
    match a_value.to_ascii_lowercase().as_str()
    {
        "strict" => Ok(SameSite::Strict),
        "lax" => Ok(SameSite::Lax),
        "none" => Ok(SameSite::None),
        _ => Err("COOKIE_SAMESITE must be strict, lax or none".into()),
    }
}

fn parse_origins(a_value: &str) -> Result<Vec<HeaderValue>, String>
{
    a_value
        .split(',')
        .map(str::trim)
        .filter(|origin| !origin.is_empty())
        .map(|origin| {
            if origin == "*"
            {
                return Err("ALLOWED_ORIGINS must list explicit origins".to_string());
            }
            HeaderValue::from_str(origin.trim_end_matches('/')).map_err(|_| format!("invalid origin {origin}"))
        })
        .collect()
}
