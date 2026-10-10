use std::net::SocketAddr;
use std::time::Duration;

use axum::http::HeaderValue;
use axum_extra::extract::cookie::SameSite;
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use chrono_tz::Tz;
use jsonwebtoken::EncodingKey;

pub const DATA_KEY_LEN: usize = 32;
pub const MIN_PEPPER_LEN: usize = 32;

const DEFAULT_MONO_API: &str = "https://api.monobank.ua";
const DEFAULT_EB_API: &str = "https://api.enablebanking.com";

pub struct BankConfig
{
    pub mono_api_url: String,
    pub mono_poll_interval: Duration,
    pub mono_call_gap: Duration,
    pub mono_history_months: u32,
    pub enable_banking: Option<EnableBankingConfig>,
    pub sync_timezone: Tz,
    pub eb_sync_hours: Vec<u32>,
}

pub struct EnableBankingConfig
{
    pub api_url: String,
    pub app_id: String,
    pub key: EncodingKey,
    pub redirect_url: String,
    pub consent_days: i64,
}

impl BankConfig
{
    pub fn from_env() -> Result<Self, String>
    {
        let mono_poll_minutes = parse_u64("MONOBANK_POLL_INTERVAL_MIN", 60, 1, 24 * 60)?;
        let mono_call_gap = parse_u64("MONOBANK_CALL_GAP_SEC", 61, 0, 600)?;
        let mono_history_months = parse_u64("MONOBANK_HISTORY_MONTHS", 24, 0, 120)? as u32;

        let sync_timezone = optional("BANK_SYNC_TIMEZONE")
            .unwrap_or_else(|| "Europe/Dublin".into())
            .parse::<Tz>()
            .map_err(|_| "BANK_SYNC_TIMEZONE must be an IANA time zone".to_string())?;

        Ok(Self {
            mono_api_url: optional("MONOBANK_API_URL").unwrap_or_else(|| DEFAULT_MONO_API.into()),
            mono_poll_interval: Duration::from_secs(mono_poll_minutes * 60),
            mono_call_gap: Duration::from_secs(mono_call_gap),
            mono_history_months,
            enable_banking: EnableBankingConfig::from_env()?,
            sync_timezone,
            eb_sync_hours: parse_hours(&optional("ENABLE_BANKING_SYNC_HOURS").unwrap_or_else(|| "0,6,12,18".into()))?,
        })
    }
}

impl EnableBankingConfig
{
    fn from_env() -> Result<Option<Self>, String>
    {
        let app_id = optional("ENABLE_BANKING_APP_ID");
        let key_path = optional("ENABLE_BANKING_KEY_PATH");

        let (app_id, key_path) = match (app_id, key_path)
        {
            (None, None) => return Ok(None),
            (Some(app_id), Some(key_path)) => (app_id, key_path),
            _ => return Err("ENABLE_BANKING_APP_ID and ENABLE_BANKING_KEY_PATH must be set together".into()),
        };

        let pem = std::fs::read(&key_path).map_err(|_| format!("cannot read ENABLE_BANKING_KEY_PATH {key_path}"))?;
        let key = EncodingKey::from_rsa_pem(&pem)
            .map_err(|_| "ENABLE_BANKING_KEY_PATH must contain an RSA private key in PEM format".to_string())?;

        Ok(Some(Self {
            api_url: optional("ENABLE_BANKING_API_URL").unwrap_or_else(|| DEFAULT_EB_API.into()),
            app_id,
            key,
            redirect_url: required("ENABLE_BANKING_REDIRECT_URL")?,
            consent_days: parse_u64("ENABLE_BANKING_CONSENT_DAYS", 180, 1, 730)? as i64,
        }))
    }
}

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
    pub banks: BankConfig,
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
            banks: BankConfig::from_env()?,
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

fn parse_u64(a_name: &str, a_default: u64, a_min: u64, a_max: u64) -> Result<u64, String>
{
    let value = match optional(a_name)
    {
        None => return Ok(a_default),
        Some(raw) => raw.parse::<u64>().map_err(|_| format!("{a_name} must be a number"))?,
    };

    if !(a_min..=a_max).contains(&value)
    {
        return Err(format!("{a_name} must be between {a_min} and {a_max}"));
    }

    Ok(value)
}

fn parse_hours(a_value: &str) -> Result<Vec<u32>, String>
{
    let mut hours = a_value
        .split(',')
        .map(str::trim)
        .filter(|hour| !hour.is_empty())
        .map(|hour| hour.parse::<u32>().ok().filter(|hour| *hour < 24))
        .collect::<Option<Vec<_>>>()
        .filter(|hours| !hours.is_empty())
        .ok_or_else(|| "ENABLE_BANKING_SYNC_HOURS must list hours 0-23".to_string())?;

    hours.sort_unstable();
    hours.dedup();
    Ok(hours)
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
