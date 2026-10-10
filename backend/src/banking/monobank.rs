use chrono::{DateTime, Utc};
use reqwest::StatusCode;
use rust_decimal::Decimal;
use serde::Deserialize;

use crate::banking::currency::{alpha_from_numeric, minor_exponent};
use crate::banking::{clean_text, last_four_digits, BankAccount, BankTx, ProviderError};

pub const STATEMENT_PAGE_LIMIT: usize = 500;
pub const MAX_STATEMENT_SPAN_SECS: i64 = 31 * 86_400;

pub struct MonobankClient
{
    http: reqwest::Client,
    base_url: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClientInfo
{
    #[serde(default)]
    accounts: Vec<MonoAccount>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MonoAccount
{
    id: String,
    #[serde(default)]
    balance: Option<i64>,
    currency_code: i64,
    #[serde(rename = "type", default)]
    kind: Option<String>,
    #[serde(default)]
    masked_pan: Vec<String>,
    #[serde(default)]
    iban: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MonoStatementItem
{
    id: String,
    time: i64,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    mcc: Option<i64>,
    #[serde(default)]
    hold: bool,
    amount: i64,
    #[serde(default)]
    operation_amount: Option<i64>,
    #[serde(default)]
    currency_code: Option<i64>,
    #[serde(default)]
    balance: Option<i64>,
    #[serde(default)]
    counter_name: Option<String>,
}

impl MonobankClient
{
    pub fn new(a_http: reqwest::Client, a_base_url: &str) -> Self
    {
        Self {
            http: a_http,
            base_url: a_base_url.trim_end_matches('/').to_string(),
        }
    }

    pub async fn accounts(&self, a_token: &str) -> Result<Vec<BankAccount>, ProviderError>
    {
        let info: ClientInfo = self.get(a_token, "/personal/client-info").await?;

        Ok(info.accounts.into_iter().filter_map(to_bank_account).collect())
    }

    pub async fn statement(
        &self,
        a_token: &str,
        a_account_ext_id: &str,
        a_account_curr: &str,
        a_from: i64,
        a_to: i64,
    ) -> Result<Vec<BankTx>, ProviderError>
    {
        let path = format!("/personal/statement/{a_account_ext_id}/{a_from}/{a_to}");
        let items: Vec<MonoStatementItem> = self.get(a_token, &path).await?;

        Ok(items
            .into_iter()
            .filter_map(|item| to_bank_tx(item, a_account_curr))
            .collect())
    }

    async fn get<T>(&self, a_token: &str, a_path: &str) -> Result<T, ProviderError>
    where
        T: for<'de> Deserialize<'de>,
    {
        let response = self
            .http
            .get(format!("{}{a_path}", self.base_url))
            .header("X-Token", a_token)
            .send()
            .await
            .map_err(|err| ProviderError::Transient(err.without_url().to_string()))?;

        match response.status()
        {
            status if status.is_success() => response
                .json::<T>()
                .await
                .map_err(|err| ProviderError::Transient(format!("monobank payload: {}", err.without_url()))),
            StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => Err(ProviderError::Unauthorized),
            StatusCode::TOO_MANY_REQUESTS => Err(ProviderError::RateLimited),
            status if status.is_client_error() => Err(ProviderError::Rejected(format!("monobank {status}"))),
            status => Err(ProviderError::Transient(format!("monobank {status}"))),
        }
    }
}

fn to_bank_account(a_account: MonoAccount) -> Option<BankAccount>
{
    let curr_code = alpha_from_numeric(a_account.currency_code)?;
    let kind = a_account
        .kind
        .as_deref()
        .map(capitalize)
        .unwrap_or_else(|| "Account".to_string());
    let mask = a_account
        .masked_pan
        .first()
        .and_then(|pan| last_four_digits(pan))
        .or_else(|| a_account.iban.as_deref().and_then(last_four_digits));

    Some(BankAccount {
        ext_id: a_account.id,
        name: format!("Monobank {kind} {curr_code}"),
        curr_code: curr_code.to_string(),
        mask,
        balance: a_account.balance.map(|minor| from_minor(minor, curr_code)),
        is_card: !a_account.masked_pan.is_empty(),
    })
}

fn to_bank_tx(a_item: MonoStatementItem, a_account_curr: &str) -> Option<BankTx>
{
    let tx_ts = DateTime::<Utc>::from_timestamp(a_item.time, 0)?;
    let op_curr = a_item.currency_code.and_then(alpha_from_numeric);
    let is_foreign = op_curr.is_some_and(|code| code != a_account_curr);

    if a_item.amount == 0
    {
        return None;
    }

    Some(BankTx {
        ext_id: a_item.id,
        tx_ts,
        amount: from_minor(a_item.amount, a_account_curr),
        op_amount: is_foreign
            .then(|| a_item.operation_amount.zip(op_curr))
            .flatten()
            .map(|(minor, code)| from_minor(minor, code)),
        op_curr_code: is_foreign.then(|| op_curr.map(str::to_string)).flatten(),
        description: clean_text(a_item.description.as_deref(), 500),
        counterparty: clean_text(a_item.counter_name.as_deref(), 200),
        mcc: a_item
            .mcc
            .and_then(|mcc| i16::try_from(mcc).ok())
            .filter(|mcc| (0..=9999).contains(mcc)),
        balance_after: a_item.balance.map(|minor| from_minor(minor, a_account_curr)),
        is_pending: a_item.hold,
    })
}

fn from_minor(a_minor: i64, a_curr: &str) -> Decimal
{
    Decimal::new(a_minor, minor_exponent(a_curr))
}

fn capitalize(a_value: &str) -> String
{
    let mut chars = a_value.chars();
    match chars.next()
    {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests
{
    use super::*;
    use std::str::FromStr;

    #[test]
    fn statement_item_converts_minor_units_and_foreign_amount()
    {
        let item: MonoStatementItem = serde_json::from_str(
            r#"{"id":"ZuHWzqkKGVo=","time":1700000000,"description":"Silpo","mcc":5411,"originalMcc":5411,
                "hold":false,"amount":-12550,"operationAmount":-300,"currencyCode":840,"balance":1000000,
                "counterName":null}"#,
        )
        .unwrap();

        let tx = to_bank_tx(item, "UAH").unwrap();
        assert_eq!(tx.amount, Decimal::from_str("-125.50").unwrap());
        assert_eq!(tx.op_amount, Some(Decimal::from_str("-3.00").unwrap()));
        assert_eq!(tx.op_curr_code.as_deref(), Some("USD"));
        assert_eq!(tx.balance_after, Some(Decimal::from_str("10000.00").unwrap()));
        assert_eq!(tx.mcc, Some(5411));
    }

    #[test]
    fn same_currency_operation_is_not_duplicated()
    {
        let item: MonoStatementItem = serde_json::from_str(
            r#"{"id":"a","time":1700000000,"amount":-500,"operationAmount":-500,"currencyCode":980}"#,
        )
        .unwrap();

        let tx = to_bank_tx(item, "UAH").unwrap();
        assert_eq!(tx.op_amount, None);
        assert_eq!(tx.op_curr_code, None);
    }

    #[test]
    fn account_gets_readable_name_and_mask()
    {
        let account: MonoAccount = serde_json::from_str(
            r#"{"id":"acc1","balance":12345,"currencyCode":980,"type":"black","maskedPan":["537541******4321"]}"#,
        )
        .unwrap();

        let converted = to_bank_account(account).unwrap();
        assert_eq!(converted.name, "Monobank Black UAH");
        assert_eq!(converted.mask.as_deref(), Some("4321"));
        assert_eq!(converted.balance, Some(Decimal::from_str("123.45").unwrap()));
        assert!(converted.is_card);
    }
}
