use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use axum::http::HeaderValue;
use axum_extra::extract::cookie::SameSite;
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use chrono_tz::Tz;
use jsonwebtoken::EncodingKey;
use shared_schema::AiProvider;

use crate::receipt_ai::is_valid_model_id;

pub const DATA_KEY_LEN: usize = 32;
pub const MIN_PEPPER_LEN: usize = 32;

const DEFAULT_MONO_API: &str = "https://api.monobank.ua";
const DEFAULT_EB_API: &str = "https://api.enablebanking.com";
const DEFAULT_FX_API: &str = "https://bank.gov.ua";
const DEFAULT_ANTHROPIC_API: &str = "https://api.anthropic.com";
const DEFAULT_OPENAI_API: &str = "https://api.openai.com";
const DEFAULT_GEMINI_API: &str = "https://generativelanguage.googleapis.com";
const DEFAULT_ANTHROPIC_MODEL: &str = "claude-opus-5-5";
const DEFAULT_OFF_API: &str = "https://world.openfoodfacts.org";
pub const DEFAULT_ANDROID_PACKAGE: &str = "com.familyroutine.family_routine";
const SHA256_BYTES: usize = 32;
const MAX_PACKAGE_LEN: usize = 255;

pub struct BankConfig
{
    pub mono_api_url: String,
    pub mono_poll_interval: Duration,
    pub mono_call_gap: Duration,
    pub mono_history_months: u32,
    pub enable_banking: Option<EnableBankingConfig>,
    pub sync_timezone: Tz,
    pub eb_sync_hours: Vec<u32>,
    pub fx_api_url: Option<String>,
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
    pub fn from_env(a_env_dir: Option<&Path>) -> Result<Self, String>
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
            enable_banking: EnableBankingConfig::from_env(a_env_dir)?,
            sync_timezone,
            eb_sync_hours: parse_hours(&optional("ENABLE_BANKING_SYNC_HOURS").unwrap_or_else(|| "0,6,12,18".into()))?,
            fx_api_url: parse_bool("FX_SYNC_ENABLED", true)?
                .then(|| optional("FX_RATES_URL").unwrap_or_else(|| DEFAULT_FX_API.into())),
        })
    }
}

impl EnableBankingConfig
{
    fn from_env(a_env_dir: Option<&Path>) -> Result<Option<Self>, String>
    {
        let app_id = optional("ENABLE_BANKING_APP_ID");
        let key_file = optional("ENABLE_BANKING_KEY_FILE");

        let (app_id, key_file) = match (app_id, key_file)
        {
            (None, None) => return Ok(None),
            (Some(app_id), Some(key_file)) => (app_id, key_file),
            _ => return Err("ENABLE_BANKING_APP_ID and ENABLE_BANKING_KEY_FILE must be set together".into()),
        };

        let key_path = resolve_path(a_env_dir, &key_file);
        let pem = std::fs::read(&key_path)
            .map_err(|err| format!("cannot read ENABLE_BANKING_KEY_FILE {}: {err}", key_path.display()))?;
        let key = EncodingKey::from_rsa_pem(&pem)
            .map_err(|_| "ENABLE_BANKING_KEY_FILE must contain an RSA private key in PEM format".to_string())?;

        let redirect_url = optional("ENABLE_BANKING_REDIRECT_URL")
            .or_else(|| optional("APP_DOMAIN").map(|domain| format!("https://{domain}/app/bank-callback")))
            .ok_or_else(|| "ENABLE_BANKING_REDIRECT_URL or APP_DOMAIN must be set".to_string())?;

        Ok(Some(Self {
            api_url: optional("ENABLE_BANKING_API_URL").unwrap_or_else(|| DEFAULT_EB_API.into()),
            app_id,
            key,
            redirect_url,
            consent_days: parse_u64("ENABLE_BANKING_CONSENT_DAYS", 180, 1, 730)? as i64,
        }))
    }
}

#[derive(Clone)]
pub struct AiEndpoints
{
    pub anthropic: String,
    pub openai: String,
    pub gemini: String,
}

pub struct ServerAiConfig
{
    pub provider: AiProvider,
    pub api_key: String,
    pub model: String,
    pub daily_limit: i32,
    pub monthly_limit: i32,
}

pub struct ReceiptAiConfig
{
    pub endpoints: AiEndpoints,
    pub server: Option<ServerAiConfig>,
    pub is_own_keys_allowed: bool,
}

impl AiEndpoints
{
    fn from_env() -> Self
    {
        Self {
            anthropic: optional("ANTHROPIC_API_URL").unwrap_or_else(|| DEFAULT_ANTHROPIC_API.into()),
            openai: optional("OPENAI_API_URL").unwrap_or_else(|| DEFAULT_OPENAI_API.into()),
            gemini: optional("GEMINI_API_URL").unwrap_or_else(|| DEFAULT_GEMINI_API.into()),
        }
    }
}

impl ServerAiConfig
{
    fn from_env() -> Result<Option<Self>, String>
    {
        let provider = match optional("RECEIPT_AI_PROVIDER")
            .as_deref()
            .map(str::to_ascii_lowercase)
            .as_deref()
        {
            None | Some("anthropic") => AiProvider::Anthropic,
            Some("openai") => AiProvider::Openai,
            Some("gemini") => AiProvider::Gemini,
            Some(_) => return Err("RECEIPT_AI_PROVIDER must be anthropic, openai or gemini".into()),
        };
        let key_var = match provider
        {
            AiProvider::Anthropic => "ANTHROPIC_API_KEY",
            AiProvider::Openai => "OPENAI_API_KEY",
            AiProvider::Gemini => "GEMINI_API_KEY",
        };

        let Some(api_key) = optional(key_var)
        else
        {
            return Ok(None);
        };

        if !parse_bool("RECEIPT_AI_ENABLED", true)?
        {
            return Ok(None);
        }

        let model = match (optional("RECEIPT_AI_MODEL"), provider)
        {
            (Some(model), _) => model,
            (None, AiProvider::Anthropic) => DEFAULT_ANTHROPIC_MODEL.into(),
            (None, _) => return Err(format!("RECEIPT_AI_MODEL is required for {}", provider.as_str())),
        };
        if !is_valid_model_id(provider, &model)
        {
            return Err("RECEIPT_AI_MODEL contains unsupported characters".into());
        }

        Ok(Some(Self {
            provider,
            api_key,
            model,
            daily_limit: parse_u64("RECEIPT_AI_DAILY_LIMIT", 30, 1, 1000)? as i32,
            monthly_limit: parse_u64("RECEIPT_AI_MONTHLY_LIMIT", 300, 1, 30_000)? as i32,
        }))
    }
}

impl ReceiptAiConfig
{
    fn from_env() -> Result<Self, String>
    {
        Ok(Self {
            endpoints: AiEndpoints::from_env(),
            server: ServerAiConfig::from_env()?,
            is_own_keys_allowed: parse_bool("RECEIPT_AI_USER_KEYS", true)?,
        })
    }
}

pub struct CatalogConfig
{
    pub admin_emails: Vec<String>,
    pub off_api_url: Option<String>,
}

impl CatalogConfig
{
    fn from_env() -> Result<Self, String>
    {
        Ok(Self {
            admin_emails: parse_admin_emails(&optional("ADMIN_EMAILS").unwrap_or_default())?,
            off_api_url: parse_bool("OFF_ENABLED", true)?
                .then(|| optional("OFF_API_URL").unwrap_or_else(|| DEFAULT_OFF_API.into())),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AndroidLinks
{
    pub package_name: String,
    pub cert_fingerprints: Vec<String>,
}

impl AndroidLinks
{
    fn from_env() -> Result<Option<Self>, String>
    {
        parse_android_links(
            optional("ANDROID_PACKAGE_NAME").as_deref(),
            &optional("ANDROID_CERT_SHA256").unwrap_or_default(),
        )
    }
}

pub fn parse_android_links(a_package: Option<&str>, a_fingerprints: &str) -> Result<Option<AndroidLinks>, String>
{
    let cert_fingerprints = parse_cert_fingerprints(a_fingerprints)?;
    if cert_fingerprints.is_empty()
    {
        return Ok(None);
    }

    let package_name = a_package
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .unwrap_or(DEFAULT_ANDROID_PACKAGE);
    if !is_android_package(package_name)
    {
        return Err("ANDROID_PACKAGE_NAME must be an Android application id such as com.example.app".into());
    }

    Ok(Some(AndroidLinks {
        package_name: package_name.to_string(),
        cert_fingerprints,
    }))
}

fn is_android_package(a_name: &str) -> bool
{
    let is_segment = |segment: &str| {
        let mut chars = segment.chars();
        chars.next().is_some_and(|first| first.is_ascii_alphabetic())
            && chars.all(|rest| rest.is_ascii_alphanumeric() || rest == '_')
    };
    a_name.len() <= MAX_PACKAGE_LEN && a_name.split('.').count() >= 2 && a_name.split('.').all(is_segment)
}

pub fn parse_cert_fingerprints(a_value: &str) -> Result<Vec<String>, String>
{
    let mut fingerprints: Vec<String> = Vec::new();
    for raw in a_value
        .split(|ch: char| ch == ',' || ch.is_whitespace())
        .filter(|item| !item.is_empty())
    {
        let hex = normalize_fingerprint(raw).ok_or_else(|| {
            "ANDROID_CERT_SHA256 must list SHA-256 certificate fingerprints: 32 hex bytes, with or without colons"
                .to_string()
        })?;
        if !fingerprints.contains(&hex)
        {
            fingerprints.push(hex);
        }
    }
    Ok(fingerprints)
}

fn normalize_fingerprint(a_raw: &str) -> Option<String>
{
    let bytes: Vec<&str> = if a_raw.contains(':')
    {
        a_raw.split(':').collect()
    }
    else
    {
        (0..a_raw.len())
            .step_by(2)
            .filter_map(|start| a_raw.get(start..start + 2))
            .collect()
    };

    let is_valid = bytes.len() == SHA256_BYTES
        && a_raw.len()
            == if a_raw.contains(':')
            {
                SHA256_BYTES * 3 - 1
            }
            else
            {
                SHA256_BYTES * 2
            }
        && bytes
            .iter()
            .all(|byte| byte.len() == 2 && byte.chars().all(|ch| ch.is_ascii_hexdigit()));
    is_valid.then(|| bytes.join(":").to_ascii_uppercase())
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
    pub receipt_ai: ReceiptAiConfig,
    pub catalog: CatalogConfig,
    pub android_links: Option<AndroidLinks>,
}

impl AppConfig
{
    pub fn from_env(a_env_dir: Option<&Path>) -> Result<Self, String>
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
            banks: BankConfig::from_env(a_env_dir)?,
            receipt_ai: ReceiptAiConfig::from_env()?,
            catalog: CatalogConfig::from_env()?,
            android_links: AndroidLinks::from_env()?,
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

pub fn parse_admin_emails(a_value: &str) -> Result<Vec<String>, String>
{
    let mut emails: Vec<String> = a_value
        .split(',')
        .map(str::trim)
        .filter(|email| !email.is_empty())
        .map(str::to_lowercase)
        .collect();

    let is_email = |email: &String| {
        email.split_once('@').is_some_and(|(local, domain)| {
            !local.is_empty() && !domain.is_empty() && !domain.contains('@') && !email.contains(char::is_whitespace)
        })
    };
    if !emails.iter().all(is_email)
    {
        return Err("ADMIN_EMAILS must be a comma-separated list of e-mail addresses".into());
    }

    emails.sort_unstable();
    emails.dedup();
    Ok(emails)
}

fn resolve_path(a_base_dir: Option<&Path>, a_path: &str) -> PathBuf
{
    match a_base_dir
    {
        Some(base_dir) => base_dir.join(a_path),
        None => PathBuf::from(a_path),
    }
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

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn admin_emails_are_trimmed_lowercased_and_deduplicated()
    {
        let emails = parse_admin_emails(" Admin@Example.com, ops@example.org ,,admin@example.com ").unwrap();
        assert_eq!(emails, ["admin@example.com", "ops@example.org"]);
        assert!(parse_admin_emails("").unwrap().is_empty());
    }

    #[test]
    fn android_links_need_fingerprints_and_normalize_them()
    {
        let colons = "ab:".repeat(31) + "ab";
        let plain = "Cd".repeat(32);
        let links = parse_android_links(None, &format!(" {colons}, {plain}\n{colons} "))
            .unwrap()
            .unwrap();
        assert_eq!(links.package_name, DEFAULT_ANDROID_PACKAGE);
        assert_eq!(
            links.cert_fingerprints,
            [colons.to_uppercase(), "CD:".repeat(31) + "CD"]
        );

        let custom = parse_android_links(Some(" org.example.app_2 "), &plain)
            .unwrap()
            .unwrap();
        assert_eq!(custom.package_name, "org.example.app_2");
        assert_eq!(parse_android_links(Some("org.example.app"), " ").unwrap(), None);
    }

    #[test]
    fn malformed_android_links_are_rejected()
    {
        let plain = "ab".repeat(32);
        assert!(parse_android_links(None, &"ab".repeat(31)).is_err());
        assert!(parse_android_links(None, &"zz".repeat(32)).is_err());
        assert!(parse_android_links(None, &format!("{}a:b", "ab:".repeat(30))).is_err());
        assert!(parse_android_links(None, &format!("SHA256:{plain}")).is_err());
        assert!(parse_android_links(Some("app"), &plain).is_err());
        assert!(parse_android_links(Some("com.1example.app"), &plain).is_err());
        assert!(parse_android_links(Some("com.example..app"), &plain).is_err());
    }

    #[test]
    fn malformed_admin_emails_are_rejected()
    {
        assert!(parse_admin_emails("admin").is_err());
        assert!(parse_admin_emails("admin@").is_err());
        assert!(parse_admin_emails("a@b@c").is_err());
        assert!(parse_admin_emails("ad min@example.com").is_err());
    }
}
