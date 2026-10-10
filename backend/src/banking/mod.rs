pub mod categories;
pub mod currency;
pub mod enable_banking;
pub mod monobank;
pub mod store;
pub mod sync;

use std::time::Duration;

use chrono::{DateTime, Utc};
use rust_decimal::Decimal;

use crate::config::BankConfig;

const HTTP_TIMEOUT: Duration = Duration::from_secs(30);
const HTTP_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Clone)]
pub struct BankAccount
{
    pub ext_id: String,
    pub name: String,
    pub curr_code: String,
    pub mask: Option<String>,
    pub balance: Option<Decimal>,
    pub is_card: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct BankTx
{
    pub ext_id: String,
    pub tx_ts: DateTime<Utc>,
    pub amount: Decimal,
    pub op_amount: Option<Decimal>,
    pub op_curr_code: Option<String>,
    pub description: Option<String>,
    pub counterparty: Option<String>,
    pub mcc: Option<i16>,
    pub balance_after: Option<Decimal>,
    pub is_pending: bool,
}

#[derive(Debug)]
pub enum ProviderError
{
    Unauthorized,
    RateLimited,
    Rejected(String),
    Transient(String),
}

impl ProviderError
{
    pub fn code(&self) -> &'static str
    {
        match self
        {
            Self::Unauthorized => "UNAUTHORIZED",
            Self::RateLimited => "RATE_LIMITED",
            Self::Rejected(_) => "REJECTED",
            Self::Transient(_) => "UNAVAILABLE",
        }
    }
}

pub struct BankClients
{
    pub monobank: monobank::MonobankClient,
    pub enable_banking: Option<enable_banking::EnableBankingClient>,
}

impl BankClients
{
    pub fn new(a_cfg: &BankConfig) -> Result<Self, String>
    {
        let http = reqwest::Client::builder()
            .timeout(HTTP_TIMEOUT)
            .connect_timeout(HTTP_CONNECT_TIMEOUT)
            .user_agent("FamilyRoutine")
            .build()
            .map_err(|err| format!("http client: {err}"))?;

        Ok(Self {
            monobank: monobank::MonobankClient::new(http.clone(), &a_cfg.mono_api_url),
            enable_banking: a_cfg
                .enable_banking
                .as_ref()
                .map(|eb_cfg| enable_banking::EnableBankingClient::new(http, eb_cfg)),
        })
    }
}

pub fn clean_text(a_value: Option<&str>, a_max_chars: usize) -> Option<String>
{
    let collapsed = a_value?
        .chars()
        .map(|ch| {
            if ch.is_control()
            {
                ' '
            }
            else
            {
                ch
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");

    if collapsed.is_empty()
    {
        return None;
    }

    Some(collapsed.chars().take(a_max_chars).collect())
}

pub fn last_four_digits(a_value: &str) -> Option<String>
{
    let digits: Vec<char> = a_value.chars().filter(char::is_ascii_digit).collect();
    (digits.len() >= 4).then(|| digits[digits.len() - 4..].iter().collect())
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn text_is_trimmed_collapsed_and_limited()
    {
        assert_eq!(
            clean_text(Some("  Silpo\n  Kyiv  "), 100).as_deref(),
            Some("Silpo Kyiv")
        );
        assert_eq!(clean_text(Some("   "), 100), None);
        assert_eq!(clean_text(Some("abcdef"), 3).as_deref(), Some("abc"));
    }

    #[test]
    fn mask_takes_last_four_digits()
    {
        assert_eq!(last_four_digits("537541******1234").as_deref(), Some("1234"));
        assert_eq!(last_four_digits("IE29AIBK93115212345678").as_deref(), Some("5678"));
        assert_eq!(last_four_digits("12"), None);
    }
}
