use std::collections::HashMap;
use std::str::FromStr;
use std::time::Duration;

use chrono::{NaiveDate, Utc};
use rust_decimal::Decimal;
use serde::Deserialize;
use uuid::Uuid;

use crate::banking::{matching, ProviderError};
use crate::domain::errors::ApiError;
use crate::state::AppState;

const BASE_CURRENCY: &str = "UAH";
const STARTUP_DELAY: Duration = Duration::from_secs(15);
const TICK_PERIOD: Duration = Duration::from_secs(3600);
const BACKFILL_PAUSE: Duration = Duration::from_secs(5);
const REQUEST_GAP: Duration = Duration::from_millis(250);
const MAX_DAYS_PER_TICK: i64 = 120;
const MAX_HISTORY_DAYS: i32 = 3 * 366;

#[derive(Deserialize)]
struct NbuRate
{
    cc: String,
    rate: serde_json::Number,
}

pub struct FxClient
{
    http: reqwest::Client,
    base_url: String,
}

impl FxClient
{
    pub fn new(a_http: reqwest::Client, a_base_url: &str) -> Self
    {
        Self {
            http: a_http,
            base_url: a_base_url.trim_end_matches('/').to_string(),
        }
    }

    pub async fn rates_on(&self, a_date: NaiveDate) -> Result<Vec<(String, Decimal)>, ProviderError>
    {
        let url = format!(
            "{}/NBUStatService/v1/statdirectory/exchange?date={}&json",
            self.base_url,
            a_date.format("%Y%m%d")
        );

        let response = self
            .http
            .get(url)
            .send()
            .await
            .map_err(|err| ProviderError::Transient(err.without_url().to_string()))?;

        if !response.status().is_success()
        {
            return Err(ProviderError::Transient(format!("nbu {}", response.status())));
        }

        let rates: Vec<NbuRate> = response
            .json()
            .await
            .map_err(|err| ProviderError::Transient(format!("nbu payload: {}", err.without_url())))?;

        Ok(rates
            .into_iter()
            .filter_map(|rate| {
                let value = Decimal::from_str(&rate.rate.to_string()).ok()?;
                (value > Decimal::ZERO).then(|| (rate.cc.trim().to_ascii_uppercase(), value))
            })
            .collect())
    }
}

pub fn spawn(a_state: AppState)
{
    if a_state.banks.fx.is_none()
    {
        return;
    }

    tokio::spawn(async move {
        tokio::time::sleep(STARTUP_DELAY).await;

        loop
        {
            let pause = match sync_rates(&a_state).await
            {
                Ok(fetched) if fetched >= MAX_DAYS_PER_TICK as usize => BACKFILL_PAUSE,
                Ok(_) => TICK_PERIOD,
                Err(err) =>
                {
                    tracing::warn!("exchange rate sync failed: {err:?}");
                    TICK_PERIOD
                }
            };
            tokio::time::sleep(pause).await;
        }
    });
}

pub async fn sync_rates(a_state: &AppState) -> Result<usize, ApiError>
{
    let Some(client) = a_state.banks.fx.as_ref()
    else
    {
        return Ok(0);
    };

    let today = Utc::now().date_naive();
    let missing = sqlx::query_scalar!(
        r#"
        WITH bounds AS (
            SELECT GREATEST(
                COALESCE((SELECT MIN(tx_ts)::date FROM transactions), $1::date),
                $1::date - $2::int
            ) AS first_day
        )
        SELECT day::date AS "day!"
        FROM bounds, generate_series(bounds.first_day, $1::date, INTERVAL '1 day') AS day
        WHERE NOT EXISTS (SELECT 1 FROM fx_rate_days d WHERE d.rate_date = day::date)
        ORDER BY 1 DESC
        LIMIT $3
        "#,
        today,
        MAX_HISTORY_DAYS,
        MAX_DAYS_PER_TICK
    )
    .fetch_all(&a_state.db)
    .await?;

    if missing.is_empty()
    {
        return Ok(0);
    }

    let currencies: HashMap<String, Uuid> = sqlx::query!("SELECT id, code FROM currencies")
        .fetch_all(&a_state.db)
        .await?
        .into_iter()
        .map(|row| (row.code, row.id))
        .collect();
    let base_id = *currencies
        .get(BASE_CURRENCY)
        .ok_or_else(|| ApiError::internal("base currency is missing"))?;

    let mut fetched = 0;
    for day in missing
    {
        let rates = match client.rates_on(day).await
        {
            Ok(rates) => rates,
            Err(err) =>
            {
                tracing::warn!("exchange rates for {day} unavailable: {err:?}");
                break;
            }
        };

        if rates.is_empty()
        {
            tracing::warn!("exchange rate source returned no rates for {day}");
            break;
        }

        let mut tx = a_state.db.begin().await?;
        for (code, rate) in &rates
        {
            let Some(curr_id) = currencies.get(code)
            else
            {
                continue;
            };

            sqlx::query!(
                r#"
                INSERT INTO currency_rates (base_curr_id, target_curr_id, rate, date)
                VALUES ($1, $2, $3, $4)
                ON CONFLICT (base_curr_id, target_curr_id, date) DO UPDATE SET rate = EXCLUDED.rate
                "#,
                base_id,
                curr_id,
                rate.round_dp(6),
                day
            )
            .execute(&mut *tx)
            .await?;
        }

        sqlx::query!(
            "INSERT INTO fx_rate_days (rate_date) VALUES ($1) ON CONFLICT DO NOTHING",
            day
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;

        fetched += 1;
        tokio::time::sleep(REQUEST_GAP).await;
    }

    if fetched > 0
    {
        tracing::info!("loaded exchange rates for {fetched} days");
        matching::match_all(&a_state.db).await?;
    }

    Ok(fetched)
}
