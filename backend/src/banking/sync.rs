use std::sync::Arc;
use std::time::Duration as StdDuration;

use chrono::{DateTime, Duration, NaiveTime, TimeZone, Utc};
use chrono_tz::Tz;
use shared_schema::{BankConnStatus, BankProvider, BankType};
use tokio::sync::Semaphore;
use uuid::Uuid;

use crate::banking::enable_banking::assign_fingerprint_indices;
use crate::banking::monobank::{MAX_STATEMENT_SPAN_SECS, STATEMENT_PAGE_LIMIT};
use crate::banking::store::{self, LinkedAccount};
use crate::banking::{BankTx, ProviderError};
use crate::domain::errors::ApiError;
use crate::security::crypto::bank_conn_aad;
use crate::state::AppState;

const TICK_PERIOD: StdDuration = StdDuration::from_secs(30);
const MAX_PARALLEL_SYNCS: usize = 4;
const LEASE_MINUTES: i64 = 90;
const FORWARD_OVERLAP_DAYS: i64 = 2;
const EB_OVERLAP_DAYS: i64 = 7;
const MONO_BACKFILL_WINDOWS_PER_RUN: u32 = 3;
const MONO_EMPTY_WINDOWS_TO_STOP: u32 = 6;
const MAX_EB_PAGES: usize = 500;
const RETRY_MINUTES: i64 = 30;
const RATE_LIMIT_RETRY_MINUTES: i64 = 5;

pub struct ConnRow
{
    pub id: Uuid,
    pub owner_id: Uuid,
    pub provider: BankProvider,
    pub aspsp_name: Option<String>,
    pub secret: Option<Vec<u8>>,
    pub valid_until: Option<DateTime<Utc>>,
    pub last_call_ts: Option<DateTime<Utc>>,
}

pub enum SyncFailure
{
    Provider(ProviderError),
    Internal(ApiError),
}

impl From<ProviderError> for SyncFailure
{
    fn from(a_err: ProviderError) -> Self
    {
        Self::Provider(a_err)
    }
}

impl From<ApiError> for SyncFailure
{
    fn from(a_err: ApiError) -> Self
    {
        Self::Internal(a_err)
    }
}

impl From<sqlx::Error> for SyncFailure
{
    fn from(a_err: sqlx::Error) -> Self
    {
        Self::Internal(a_err.into())
    }
}

struct MonoGate<'a>
{
    state: &'a AppState,
    conn_id: Uuid,
    last_call: Option<DateTime<Utc>>,
}

impl MonoGate<'_>
{
    async fn wait(&self)
    {
        let gap = Duration::from_std(self.state.cfg.banks.mono_call_gap).unwrap_or_else(|_| Duration::seconds(61));

        if let Some(last_call) = self.last_call
        {
            let ready_at = last_call + gap;
            let delay = ready_at - Utc::now();
            if let Ok(delay) = delay.to_std()
            {
                tokio::time::sleep(delay).await;
            }
        }
    }

    async fn mark(&mut self) -> Result<(), SyncFailure>
    {
        let now = Utc::now();
        self.last_call = Some(now);

        sqlx::query!(
            "UPDATE bank_conns SET last_call_ts = $2 WHERE id = $1",
            self.conn_id,
            now
        )
        .execute(&self.state.db)
        .await?;

        Ok(())
    }
}

pub fn spawn(a_state: AppState)
{
    let permits = Arc::new(Semaphore::new(MAX_PARALLEL_SYNCS));

    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(TICK_PERIOD);
        loop
        {
            ticker.tick().await;

            let free = permits.available_permits();
            if free == 0
            {
                continue;
            }

            match claim_due(&a_state, free as i64).await
            {
                Ok(conn_ids) =>
                {
                    for conn_id in conn_ids
                    {
                        let Ok(permit) = permits.clone().acquire_owned().await
                        else
                        {
                            return;
                        };
                        let state = a_state.clone();
                        tokio::spawn(async move {
                            sync_connection(&state, conn_id).await;
                            drop(permit);
                        });
                    }
                }
                Err(err) => tracing::warn!("bank sync claim failed: {err:?}"),
            }
        }
    });
}

async fn claim_due(a_state: &AppState, a_limit: i64) -> Result<Vec<Uuid>, ApiError>
{
    let ids = sqlx::query_scalar!(
        r#"
        UPDATE bank_conns SET lease_until = NOW() + make_interval(mins => $2::int)
        WHERE id IN (
            SELECT id FROM bank_conns
            WHERE status = 'active' AND next_sync_ts <= NOW() AND (lease_until IS NULL OR lease_until < NOW())
            ORDER BY next_sync_ts
            LIMIT $1
            FOR UPDATE SKIP LOCKED
        )
        RETURNING id
        "#,
        a_limit,
        LEASE_MINUTES as i32
    )
    .fetch_all(&a_state.db)
    .await?;

    Ok(ids)
}

pub async fn sync_connection(a_state: &AppState, a_conn_id: Uuid)
{
    let conn = match load_conn(a_state, a_conn_id).await
    {
        Ok(Some(conn)) => conn,
        Ok(None) => return,
        Err(err) =>
        {
            tracing::warn!("bank sync load failed: {err:?}");
            return;
        }
    };

    let outcome = run(a_state, &conn).await;
    if let Err(err) = finish(a_state, &conn, outcome).await
    {
        tracing::warn!("bank sync finalize failed: {err:?}");
    }
}

pub async fn load_conn(a_state: &AppState, a_conn_id: Uuid) -> Result<Option<ConnRow>, ApiError>
{
    let conn = sqlx::query_as!(
        ConnRow,
        r#"
        SELECT id, owner_id, provider AS "provider: BankProvider", aspsp_name, secret, valid_until, last_call_ts
        FROM bank_conns
        WHERE id = $1 AND status = 'active'
        "#,
        a_conn_id
    )
    .fetch_optional(&a_state.db)
    .await?;

    Ok(conn)
}

async fn run(a_state: &AppState, a_conn: &ConnRow) -> Result<DateTime<Utc>, SyncFailure>
{
    match a_conn.provider
    {
        BankProvider::Monobank => sync_monobank(a_state, a_conn, &open_secret(a_state, a_conn)?).await,
        BankProvider::EnableBanking => sync_enable_banking(a_state, a_conn).await,
    }
}

pub fn open_secret(a_state: &AppState, a_conn: &ConnRow) -> Result<String, SyncFailure>
{
    let sealed = a_conn
        .secret
        .as_deref()
        .ok_or(SyncFailure::Provider(ProviderError::Unauthorized))?;
    let secret = a_state.secret_box.open(sealed, &bank_conn_aad(a_conn.id))?;

    Ok(String::from_utf8(secret).map_err(|_| ApiError::internal("bank secret is not utf-8"))?)
}

async fn finish(
    a_state: &AppState,
    a_conn: &ConnRow,
    a_outcome: Result<DateTime<Utc>, SyncFailure>,
) -> Result<(), ApiError>
{
    let (status, next_sync, error) = match a_outcome
    {
        Ok(next_sync) => (BankConnStatus::Active, Some(next_sync), None),
        Err(SyncFailure::Provider(ProviderError::Unauthorized)) =>
        {
            let status = match a_conn.provider
            {
                BankProvider::Monobank => BankConnStatus::Error,
                BankProvider::EnableBanking => BankConnStatus::Expired,
            };
            (status, None, Some(ProviderError::Unauthorized.code()))
        }
        Err(SyncFailure::Provider(err)) =>
        {
            let delay = match err
            {
                ProviderError::RateLimited => Duration::minutes(RATE_LIMIT_RETRY_MINUTES),
                _ => Duration::minutes(RETRY_MINUTES),
            };
            let next_sync = match a_conn.provider
            {
                BankProvider::Monobank => Utc::now() + delay,
                BankProvider::EnableBanking => next_slot(a_state, Utc::now()),
            };
            tracing::warn!("bank sync {} failed: {err:?}", a_conn.id);
            (BankConnStatus::Active, Some(next_sync), Some(err.code()))
        }
        Err(SyncFailure::Internal(err)) =>
        {
            tracing::warn!("bank sync {} internal failure: {err:?}", a_conn.id);
            (
                BankConnStatus::Active,
                Some(Utc::now() + Duration::minutes(RETRY_MINUTES)),
                Some("INTERNAL"),
            )
        }
    };

    sqlx::query!(
        r#"
        UPDATE bank_conns
        SET status = $2,
            next_sync_ts = $3,
            last_error = $4::varchar,
            last_sync_ts = CASE WHEN $4::varchar IS NULL THEN NOW() ELSE last_sync_ts END,
            lease_until = NULL
        WHERE id = $1
        "#,
        a_conn.id,
        status as BankConnStatus,
        next_sync,
        error
    )
    .execute(&a_state.db)
    .await?;

    Ok(())
}

async fn sync_monobank(a_state: &AppState, a_conn: &ConnRow, a_token: &str) -> Result<DateTime<Utc>, SyncFailure>
{
    let client = &a_state.banks.monobank;
    let mut gate = MonoGate {
        state: a_state,
        conn_id: a_conn.id,
        last_call: a_conn.last_call_ts,
    };

    gate.wait().await;
    let accounts = client.accounts(a_token).await;
    gate.mark().await?;
    store::upsert_accounts(&a_state.db, a_conn.id, a_conn.owner_id, BankType::Monobank, &accounts?).await?;

    let history_months = a_state.cfg.banks.mono_history_months;
    let history_limit = Utc::now() - Duration::days(i64::from(history_months) * 30);
    let mut is_backfill_pending = false;

    for account in store::linked_accounts(&a_state.db, a_conn.id).await?
    {
        let now = Utc::now();
        let forward_from = account
            .latest_tx_ts
            .map(|latest| latest - Duration::days(FORWARD_OVERLAP_DAYS))
            .unwrap_or_else(|| now - Duration::seconds(MAX_STATEMENT_SPAN_SECS - 60));

        fetch_mono_range(a_state, &mut gate, a_conn, a_token, &account, forward_from, now).await?;

        if account.is_history_done || history_months == 0
        {
            store::set_history(&a_state.db, account.id, None, true).await?;
            continue;
        }

        let mut boundary = account.history_from_ts.unwrap_or(forward_from).min(forward_from);
        let mut empty_windows = 0;
        let mut is_done = false;

        for _ in 0..MONO_BACKFILL_WINDOWS_PER_RUN
        {
            if boundary <= history_limit || empty_windows >= MONO_EMPTY_WINDOWS_TO_STOP
            {
                is_done = true;
                break;
            }

            let window_from = (boundary - Duration::seconds(MAX_STATEMENT_SPAN_SECS)).max(history_limit);
            let fetched =
                fetch_mono_range(a_state, &mut gate, a_conn, a_token, &account, window_from, boundary).await?;
            empty_windows = if fetched == 0 { empty_windows + 1 } else { 0 };
            boundary = window_from;
        }

        is_done = is_done || boundary <= history_limit;
        store::set_history(&a_state.db, account.id, Some(boundary), is_done).await?;
        is_backfill_pending |= !is_done;
    }

    let next = if is_backfill_pending
    {
        Duration::from_std(a_state.cfg.banks.mono_call_gap)
            .unwrap_or_else(|_| Duration::seconds(61))
            .max(Duration::minutes(1))
    }
    else
    {
        Duration::from_std(a_state.cfg.banks.mono_poll_interval).unwrap_or_else(|_| Duration::hours(1))
    };

    Ok(Utc::now() + next)
}

async fn fetch_mono_range(
    a_state: &AppState,
    a_gate: &mut MonoGate<'_>,
    a_conn: &ConnRow,
    a_token: &str,
    a_account: &LinkedAccount,
    a_from: DateTime<Utc>,
    a_to: DateTime<Utc>,
) -> Result<usize, SyncFailure>
{
    let mut total = 0;
    let mut window_from = a_from;

    while window_from < a_to
    {
        let window_to = (window_from + Duration::seconds(MAX_STATEMENT_SPAN_SECS)).min(a_to);
        let mut page_to = window_to.timestamp();

        loop
        {
            a_gate.wait().await;
            let page = a_state
                .banks
                .monobank
                .statement(
                    a_token,
                    &a_account.ext_id,
                    &a_account.curr_code,
                    window_from.timestamp(),
                    page_to,
                )
                .await;
            a_gate.mark().await?;
            let page = page?;

            store::store_transactions(&a_state.db, a_account, a_conn.owner_id, &page).await?;
            total += page.len();

            let oldest = page.iter().map(|tx| tx.tx_ts.timestamp()).min();
            match oldest
            {
                Some(oldest) if page.len() >= STATEMENT_PAGE_LIMIT && oldest < page_to => page_to = oldest,
                _ => break,
            }
        }

        window_from = window_to;
    }

    Ok(total)
}

async fn sync_enable_banking(a_state: &AppState, a_conn: &ConnRow) -> Result<DateTime<Utc>, SyncFailure>
{
    let client = a_state
        .banks
        .enable_banking
        .as_ref()
        .ok_or(SyncFailure::Provider(ProviderError::Transient(
            "enable banking is not configured".into(),
        )))?;

    if a_conn.valid_until.is_some_and(|valid_until| valid_until <= Utc::now())
    {
        return Err(SyncFailure::Provider(ProviderError::Unauthorized));
    }

    for account in store::linked_accounts(&a_state.db, a_conn.id).await?
    {
        if let Some(balance) = client.balance(&account.ext_id).await?
        {
            store::set_balance(&a_state.db, account.id, balance).await?;
        }

        let date_from = account.is_history_done.then(|| {
            account
                .latest_tx_ts
                .map(|latest| latest - Duration::days(EB_OVERLAP_DAYS))
                .unwrap_or_else(|| Utc::now() - Duration::days(30))
                .date_naive()
        });

        let mut txs: Vec<BankTx> = Vec::new();
        let mut continuation_key: Option<String> = None;

        for _ in 0..MAX_EB_PAGES
        {
            let page = client
                .transactions(&account.ext_id, date_from, continuation_key.as_deref())
                .await?;
            txs.extend(page.transactions);
            continuation_key = page.continuation_key;
            if continuation_key.is_none()
            {
                break;
            }
        }

        assign_fingerprint_indices(&mut txs);
        store::store_transactions(&a_state.db, &account, a_conn.owner_id, &txs).await?;

        let oldest = txs.iter().map(|tx| tx.tx_ts).min();
        store::set_history(&a_state.db, account.id, oldest, true).await?;
    }

    Ok(next_slot(a_state, Utc::now()))
}

pub fn next_slot(a_state: &AppState, a_now: DateTime<Utc>) -> DateTime<Utc>
{
    next_slot_in(a_state.cfg.banks.sync_timezone, &a_state.cfg.banks.eb_sync_hours, a_now)
}

pub fn next_slot_in(a_tz: Tz, a_hours: &[u32], a_now: DateTime<Utc>) -> DateTime<Utc>
{
    let local_today = a_now.with_timezone(&a_tz).date_naive();

    (0..=2)
        .filter_map(|offset| local_today.checked_add_signed(Duration::days(offset)))
        .flat_map(|day| a_hours.iter().map(move |hour| (day, *hour)))
        .filter_map(|(day, hour)| {
            let naive = day.and_time(NaiveTime::from_hms_opt(hour, 0, 0)?);
            a_tz.from_local_datetime(&naive).earliest()
        })
        .map(|local| local.with_timezone(&Utc))
        .find(|candidate| *candidate > a_now)
        .unwrap_or_else(|| a_now + Duration::hours(6))
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn slots_follow_local_midnight_and_six_hour_steps()
    {
        let tz: Tz = "Europe/Dublin".parse().unwrap();
        let hours = [0, 6, 12, 18];

        let winter = Utc.with_ymd_and_hms(2026, 1, 10, 19, 30, 0).unwrap();
        assert_eq!(
            next_slot_in(tz, &hours, winter),
            Utc.with_ymd_and_hms(2026, 1, 11, 0, 0, 0).unwrap()
        );

        let summer = Utc.with_ymd_and_hms(2026, 7, 10, 22, 30, 0).unwrap();
        assert_eq!(
            next_slot_in(tz, &hours, summer),
            Utc.with_ymd_and_hms(2026, 7, 10, 23, 0, 0).unwrap()
        );

        let morning = Utc.with_ymd_and_hms(2026, 1, 10, 6, 0, 0).unwrap();
        assert_eq!(
            next_slot_in(tz, &hours, morning),
            Utc.with_ymd_and_hms(2026, 1, 10, 12, 0, 0).unwrap()
        );
    }
}
