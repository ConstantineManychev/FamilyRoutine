use std::collections::HashMap;
use std::str::FromStr;

use chrono::{DateTime, Duration, NaiveDate, NaiveTime, Utc};
use jsonwebtoken::{Algorithm, EncodingKey, Header};
use reqwest::StatusCode;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use shared_schema::AspspDto;

use crate::banking::currency::is_valid_alpha;
use crate::banking::{clean_text, last_four_digits, BankAccount, BankTx, ProviderError};
use crate::config::EnableBankingConfig;

const JWT_LIFETIME_SECS: i64 = 600;
const BALANCE_PREFERENCE: &[&str] = &["ITBD", "CLBD", "ITAV", "CLAV", "XPCD"];
const FINGERPRINT_PREFIX: &str = "fp:";
const MAX_ERROR_DETAIL_CHARS: usize = 500;

pub struct EnableBankingClient
{
    http: reqwest::Client,
    base_url: String,
    app_id: String,
    key: EncodingKey,
    redirect_url: String,
    consent_days: i64,
}

pub struct EbSession
{
    pub session_id: String,
    pub valid_until: Option<DateTime<Utc>>,
    pub accounts: Vec<BankAccount>,
}

pub struct EbTxPage
{
    pub transactions: Vec<BankTx>,
    pub continuation_key: Option<String>,
}

#[derive(Serialize)]
struct Claims
{
    iss: &'static str,
    aud: &'static str,
    iat: i64,
    exp: i64,
}

#[derive(Deserialize)]
struct AspspList
{
    #[serde(default)]
    aspsps: Vec<AspspInfo>,
}

#[derive(Deserialize)]
struct ApplicationInfo
{
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    environment: Option<String>,
    #[serde(default)]
    active: Option<bool>,
    #[serde(default)]
    redirect_urls: Vec<String>,
}

#[derive(Deserialize)]
pub struct AspspInfo
{
    name: String,
    country: String,
    #[serde(default)]
    maximum_consent_validity: Option<i64>,
}

#[derive(Deserialize)]
struct AuthResponse
{
    url: String,
}

#[derive(Deserialize)]
struct SessionResponse
{
    session_id: String,
    #[serde(default)]
    accounts: Vec<EbAccount>,
    #[serde(default)]
    access: Option<EbAccess>,
    #[serde(default)]
    aspsp: Option<EbAspspRef>,
}

#[derive(Deserialize)]
struct EbAccess
{
    #[serde(default)]
    valid_until: Option<DateTime<Utc>>,
}

#[derive(Deserialize)]
struct EbAspspRef
{
    #[serde(default)]
    name: Option<String>,
}

#[derive(Deserialize)]
struct EbAccount
{
    uid: String,
    #[serde(default)]
    account_id: Option<EbAccountId>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    product: Option<String>,
    #[serde(default)]
    details: Option<String>,
    #[serde(default)]
    currency: Option<String>,
    #[serde(default)]
    cash_account_type: Option<String>,
}

#[derive(Deserialize)]
struct EbAccountId
{
    #[serde(default)]
    iban: Option<String>,
}

#[derive(Deserialize)]
struct BalancesResponse
{
    #[serde(default)]
    balances: Vec<EbBalance>,
}

#[derive(Deserialize)]
struct EbBalance
{
    balance_amount: EbAmount,
    #[serde(default)]
    balance_type: Option<String>,
}

#[derive(Deserialize)]
struct EbAmount
{
    amount: String,
}

#[derive(Deserialize)]
struct TransactionsResponse
{
    #[serde(default)]
    transactions: Vec<EbTransaction>,
    #[serde(default)]
    continuation_key: Option<String>,
}

#[derive(Deserialize)]
struct EbParty
{
    #[serde(default)]
    name: Option<String>,
}

#[derive(Deserialize)]
struct EbTransaction
{
    #[serde(default)]
    entry_reference: Option<String>,
    transaction_amount: EbAmount,
    #[serde(default)]
    credit_debit_indicator: Option<String>,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    booking_date: Option<NaiveDate>,
    #[serde(default)]
    value_date: Option<NaiveDate>,
    #[serde(default)]
    transaction_date: Option<NaiveDate>,
    #[serde(default)]
    creditor: Option<EbParty>,
    #[serde(default)]
    debtor: Option<EbParty>,
    #[serde(default)]
    remittance_information: Vec<String>,
    #[serde(default)]
    note: Option<String>,
    #[serde(default)]
    merchant_category_code: Option<String>,
    #[serde(default)]
    balance_after_transaction: Option<EbAmount>,
}

impl EnableBankingClient
{
    pub fn new(a_http: reqwest::Client, a_cfg: &EnableBankingConfig) -> Self
    {
        Self {
            http: a_http,
            base_url: a_cfg.api_url.trim_end_matches('/').to_string(),
            app_id: a_cfg.app_id.clone(),
            key: a_cfg.key.clone(),
            redirect_url: a_cfg.redirect_url.clone(),
            consent_days: a_cfg.consent_days,
        }
    }

    pub async fn log_application_status(&self)
    {
        let app = match self
            .send::<ApplicationInfo>(self.http.get(self.url("/application")))
            .await
        {
            Ok(app) => app,
            Err(ProviderError::Unauthorized) =>
            {
                tracing::warn!(
                    "enable banking rejected application {}: check that the key belongs to it",
                    self.app_id
                );
                return;
            }
            Err(ProviderError::AppInactive) =>
            {
                tracing::warn!(
                    "enable banking application {} is not active, activate it in the Enable Banking control panel",
                    self.app_id
                );
                return;
            }
            Err(err) =>
            {
                tracing::warn!("enable banking self-check failed: {err:?}");
                return;
            }
        };

        tracing::info!(
            "enable banking application \"{}\": environment {}, active {}",
            app.name.unwrap_or_default(),
            app.environment.unwrap_or_default(),
            app.active.map_or_else(String::new, |is_active| is_active.to_string())
        );

        if app.active == Some(false)
        {
            tracing::warn!("enable banking application is not active, activate it in the Enable Banking control panel");
        }

        if !app.redirect_urls.contains(&self.redirect_url)
        {
            tracing::warn!(
                "redirect url {} is not registered in Enable Banking, registered: {:?}",
                self.redirect_url,
                app.redirect_urls
            );
        }
    }

    pub async fn aspsps(&self, a_country: &str) -> Result<Vec<AspspDto>, ProviderError>
    {
        Ok(self
            .aspsp_infos(a_country)
            .await?
            .into_iter()
            .map(|info| AspspDto {
                name: info.name,
                country: info.country,
            })
            .collect())
    }

    pub async fn find_aspsp(&self, a_name: &str, a_country: &str) -> Result<Option<AspspInfo>, ProviderError>
    {
        Ok(self
            .aspsp_infos(a_country)
            .await?
            .into_iter()
            .find(|info| info.name.eq_ignore_ascii_case(a_name)))
    }

    pub async fn start_auth(&self, a_aspsp: &AspspInfo, a_state: &str) -> Result<String, ProviderError>
    {
        let requested = Duration::days(self.consent_days);
        let validity = a_aspsp
            .maximum_consent_validity
            .map(Duration::seconds)
            .map_or(requested, |max| requested.min(max - Duration::minutes(5)));

        let body = json!({
            "access": { "valid_until": (Utc::now() + validity).to_rfc3339() },
            "aspsp": { "name": a_aspsp.name, "country": a_aspsp.country },
            "state": a_state,
            "redirect_url": self.redirect_url,
            "psu_type": "personal",
        });

        let response: AuthResponse = self.send(self.http.post(self.url("/auth")).json(&body)).await?;
        Ok(response.url)
    }

    pub async fn create_session(&self, a_code: &str) -> Result<EbSession, ProviderError>
    {
        let response: SessionResponse = self
            .send(self.http.post(self.url("/sessions")).json(&json!({ "code": a_code })))
            .await?;

        let bank_name = response
            .aspsp
            .and_then(|aspsp| aspsp.name)
            .unwrap_or_else(|| "Bank".to_string());

        Ok(EbSession {
            session_id: response.session_id,
            valid_until: response.access.and_then(|access| access.valid_until),
            accounts: response
                .accounts
                .into_iter()
                .filter_map(|account| to_bank_account(account, &bank_name))
                .collect(),
        })
    }

    pub async fn balance(&self, a_account_uid: &str) -> Result<Option<Decimal>, ProviderError>
    {
        let response: BalancesResponse = self
            .send(self.http.get(self.url(&format!("/accounts/{a_account_uid}/balances"))))
            .await?;

        Ok(pick_balance(&response.balances))
    }

    pub async fn transactions(
        &self,
        a_account_uid: &str,
        a_date_from: Option<NaiveDate>,
        a_continuation_key: Option<&str>,
    ) -> Result<EbTxPage, ProviderError>
    {
        let mut query: Vec<(&str, String)> = vec![("transaction_status", "BOOK".to_string())];

        match a_date_from
        {
            Some(date_from) => query.push(("date_from", date_from.to_string())),
            None => query.push(("strategy", "longest".to_string())),
        }

        if let Some(key) = a_continuation_key
        {
            query.push(("continuation_key", key.to_string()));
        }

        let response: TransactionsResponse = self
            .send(
                self.http
                    .get(self.url(&format!("/accounts/{a_account_uid}/transactions")))
                    .query(&query),
            )
            .await?;

        Ok(EbTxPage {
            transactions: response.transactions.into_iter().filter_map(to_bank_tx).collect(),
            continuation_key: response.continuation_key.filter(|key| !key.is_empty()),
        })
    }

    pub async fn delete_session(&self, a_session_id: &str) -> Result<(), ProviderError>
    {
        let response = self
            .http
            .delete(self.url(&format!("/sessions/{a_session_id}")))
            .bearer_auth(self.token()?)
            .send()
            .await
            .map_err(|err| ProviderError::Transient(err.without_url().to_string()))?;

        match response.status()
        {
            status if status.is_success() || status == StatusCode::NOT_FOUND => Ok(()),
            _ => Err(failure(response).await),
        }
    }

    async fn aspsp_infos(&self, a_country: &str) -> Result<Vec<AspspInfo>, ProviderError>
    {
        let response: AspspList = self
            .send(self.http.get(self.url("/aspsps")).query(&[("country", a_country)]))
            .await?;

        Ok(response.aspsps)
    }

    async fn send<T>(&self, a_request: reqwest::RequestBuilder) -> Result<T, ProviderError>
    where
        T: for<'de> Deserialize<'de>,
    {
        let response = a_request
            .bearer_auth(self.token()?)
            .send()
            .await
            .map_err(|err| ProviderError::Transient(err.without_url().to_string()))?;

        if !response.status().is_success()
        {
            return Err(failure(response).await);
        }

        response
            .json::<T>()
            .await
            .map_err(|err| ProviderError::Transient(format!("enable banking payload: {}", err.without_url())))
    }

    fn token(&self) -> Result<String, ProviderError>
    {
        let now = Utc::now().timestamp();
        let mut header = Header::new(Algorithm::RS256);
        header.kid = Some(self.app_id.clone());
        header.typ = Some("JWT".into());

        let claims = Claims {
            iss: "enablebanking.com",
            aud: "api.enablebanking.com",
            iat: now,
            exp: now + JWT_LIFETIME_SECS,
        };

        jsonwebtoken::encode(&header, &claims, &self.key)
            .map_err(|err| ProviderError::Transient(format!("jwt signing: {err}")))
    }

    fn url(&self, a_path: &str) -> String
    {
        format!("{}{a_path}", self.base_url)
    }
}

pub fn assign_fingerprint_indices(a_txs: &mut [BankTx])
{
    let mut seen: HashMap<String, u32> = HashMap::new();

    for tx in a_txs.iter_mut().filter(|tx| tx.ext_id.starts_with(FINGERPRINT_PREFIX))
    {
        let counter = seen.entry(tx.ext_id.clone()).or_insert(0);
        tx.ext_id = format!("{}:{counter}", tx.ext_id);
        *counter += 1;
    }
}

async fn failure(a_response: reqwest::Response) -> ProviderError
{
    let status = a_response.status();
    let path = a_response.url().path().to_string();
    let body = a_response.text().await.unwrap_or_default();
    let detail: String = body.chars().take(MAX_ERROR_DETAIL_CHARS).collect();
    tracing::warn!("enable banking {status} on {path}: {detail}");

    if status == StatusCode::FORBIDDEN && is_inactive_application(&body)
    {
        return ProviderError::AppInactive;
    }
    map_status(status)
}

fn is_inactive_application(a_body: &str) -> bool
{
    a_body.to_ascii_lowercase().contains("not active")
}

fn map_status(a_status: StatusCode) -> ProviderError
{
    match a_status
    {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => ProviderError::Unauthorized,
        StatusCode::TOO_MANY_REQUESTS => ProviderError::RateLimited,
        status if status.is_client_error() => ProviderError::Rejected(format!("enable banking {status}")),
        status => ProviderError::Transient(format!("enable banking {status}")),
    }
}

fn to_bank_account(a_account: EbAccount, a_bank_name: &str) -> Option<BankAccount>
{
    let curr_code = a_account.currency.filter(|code| is_valid_alpha(code))?;
    let label = a_account
        .name
        .or(a_account.product)
        .or(a_account.details)
        .unwrap_or_else(|| "Account".to_string());
    let name = clean_text(Some(&format!("{a_bank_name} {label} {curr_code}")), 100)?;

    Some(BankAccount {
        ext_id: a_account.uid,
        name,
        curr_code,
        mask: a_account
            .account_id
            .and_then(|id| id.iban)
            .as_deref()
            .and_then(last_four_digits),
        balance: None,
        is_card: a_account.cash_account_type.as_deref() == Some("CARD"),
    })
}

fn pick_balance(a_balances: &[EbBalance]) -> Option<Decimal>
{
    BALANCE_PREFERENCE
        .iter()
        .find_map(|preferred| {
            a_balances
                .iter()
                .find(|balance| balance.balance_type.as_deref() == Some(*preferred))
        })
        .or_else(|| a_balances.first())
        .and_then(|balance| Decimal::from_str(&balance.balance_amount.amount).ok())
}

fn to_bank_tx(a_tx: EbTransaction) -> Option<BankTx>
{
    if a_tx.status.as_deref().is_some_and(|status| status != "BOOK")
    {
        return None;
    }

    let raw_amount = Decimal::from_str(&a_tx.transaction_amount.amount).ok()?;
    let is_debit = match a_tx.credit_debit_indicator.as_deref()
    {
        Some("DBIT") => true,
        Some("CRDT") => false,
        _ => raw_amount < Decimal::ZERO,
    };
    let amount = if is_debit { -raw_amount.abs() } else { raw_amount.abs() };

    if amount.is_zero()
    {
        return None;
    }

    let date = a_tx.transaction_date.or(a_tx.booking_date).or(a_tx.value_date)?;
    let tx_ts = date.and_time(NaiveTime::from_hms_opt(12, 0, 0)?).and_utc();

    let remittance = a_tx.remittance_information.join("; ");
    let description = clean_text(Some(&remittance), 500).or_else(|| clean_text(a_tx.note.as_deref(), 500));
    let party = if is_debit { a_tx.creditor } else { a_tx.debtor };
    let counterparty = clean_text(party.and_then(|party| party.name).as_deref(), 200);

    let ext_id = match a_tx
        .entry_reference
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        Some(reference) => format!("ref:{}", reference.chars().take(120).collect::<String>()),
        None => fingerprint(date, amount, description.as_deref(), counterparty.as_deref()),
    };

    Some(BankTx {
        ext_id,
        tx_ts,
        amount,
        op_amount: None,
        op_curr_code: None,
        description,
        counterparty,
        mcc: a_tx
            .merchant_category_code
            .and_then(|code| code.trim().parse::<i16>().ok())
            .filter(|mcc| (0..=9999).contains(mcc)),
        balance_after: a_tx
            .balance_after_transaction
            .and_then(|balance| Decimal::from_str(&balance.amount).ok()),
        is_pending: false,
    })
}

fn fingerprint(a_date: NaiveDate, a_amount: Decimal, a_description: Option<&str>, a_party: Option<&str>) -> String
{
    let mut hasher = Sha256::new();
    hasher.update(a_date.to_string());
    hasher.update([0]);
    hasher.update(a_amount.normalize().to_string());
    hasher.update([0]);
    hasher.update(a_description.unwrap_or_default());
    hasher.update([0]);
    hasher.update(a_party.unwrap_or_default());

    let digest = hasher.finalize();
    let hex: String = digest[..16].iter().map(|byte| format!("{byte:02x}")).collect();
    format!("{FINGERPRINT_PREFIX}{hex}")
}

#[cfg(test)]
mod tests
{
    use super::*;

    fn parse(a_json: &str) -> Option<BankTx>
    {
        to_bank_tx(serde_json::from_str(a_json).unwrap())
    }

    #[test]
    fn debit_is_negative_and_uses_creditor()
    {
        let tx = parse(
            r#"{"entry_reference":"E1","transaction_amount":{"currency":"EUR","amount":"12.30"},
                "credit_debit_indicator":"DBIT","status":"BOOK","booking_date":"2026-01-05",
                "creditor":{"name":"TESCO"},"debtor":{"name":"ME"},"remittance_information":["VDP-TESCO STORES"],
                "merchant_category_code":"5411"}"#,
        )
        .unwrap();

        assert_eq!(tx.amount, Decimal::from_str("-12.30").unwrap());
        assert_eq!(tx.counterparty.as_deref(), Some("TESCO"));
        assert_eq!(tx.ext_id, "ref:E1");
        assert_eq!(tx.mcc, Some(5411));
        assert_eq!(tx.tx_ts.to_rfc3339(), "2026-01-05T12:00:00+00:00");
    }

    #[test]
    fn credit_without_reference_gets_stable_fingerprint_indices()
    {
        let json = r#"{"transaction_amount":{"currency":"EUR","amount":"5.00"},"credit_debit_indicator":"CRDT",
                       "booking_date":"2026-01-05","debtor":{"name":"JOHN"}}"#;
        let mut txs = vec![parse(json).unwrap(), parse(json).unwrap()];

        assert!(txs[0].amount > Decimal::ZERO);
        assert_eq!(txs[0].ext_id, txs[1].ext_id);

        assign_fingerprint_indices(&mut txs);
        assert!(txs[0].ext_id.ends_with(":0"));
        assert!(txs[1].ext_id.ends_with(":1"));
    }

    #[test]
    fn pending_transactions_are_skipped()
    {
        assert!(parse(
            r#"{"transaction_amount":{"currency":"EUR","amount":"1.00"},"credit_debit_indicator":"DBIT",
                "status":"PDNG","booking_date":"2026-01-05"}"#
        )
        .is_none());
    }

    #[test]
    fn booked_balance_is_preferred()
    {
        let response: BalancesResponse = serde_json::from_str(
            r#"{"balances":[{"balance_amount":{"currency":"EUR","amount":"90.00"},"balance_type":"XPCD"},
                            {"balance_amount":{"currency":"EUR","amount":"100.50"},"balance_type":"CLBD"}]}"#,
        )
        .unwrap();

        assert_eq!(
            pick_balance(&response.balances),
            Some(Decimal::from_str("100.50").unwrap())
        );
    }
}
