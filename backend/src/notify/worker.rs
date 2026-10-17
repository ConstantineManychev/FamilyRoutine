use std::collections::BTreeMap;
use std::time::Duration as StdDuration;

use chrono::{DateTime, Duration, NaiveDate, Utc};
use rust_decimal::Decimal;
use shared_schema::{NotifyKind, PlanState, StockMeasure};
use uuid::Uuid;

use crate::api::planner_handlers::load_occurrences;
use crate::api::stock_handlers::{lock_store, Store};
use crate::domain::errors::ApiError;
use crate::notify::texts::ExpiryDay;
use crate::notify::{
    expired_due, expiring_due, insert_notice, load_prefs, lots_key, sender, store_recipients, zone_of, StockItem,
};
use crate::services::planner::local_date;
use crate::services::stock::cost_share;
use crate::state::AppState;

const STARTUP_DELAY: StdDuration = StdDuration::from_secs(10);
const TICK_PERIOD: StdDuration = StdDuration::from_secs(60);
const PURGE_EVERY_TICKS: u32 = 60;
const LOT_BATCH: i64 = 500;
const USER_BATCH: i64 = 200;
const RECHECK: Duration = Duration::hours(6);
const KEEP_DAYS: i64 = 90;

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct TickReport
{
    pub expired_lots: usize,
    pub warned_lots: usize,
    pub reminders: usize,
    pub pushed: usize,
}

type StoreKey = (Option<Uuid>, Option<Uuid>);

struct ExpiredGroup
{
    family_name: Option<String>,
    ids: Vec<Uuid>,
}

struct WarnGroup
{
    family_name: Option<String>,
    day: ExpiryDay,
    ids: Vec<Uuid>,
}

struct LotCandidate
{
    id: Uuid,
    store: Store,
    expires_on: NaiveDate,
    family_name: Option<String>,
    zone: chrono_tz::Tz,
}

pub fn spawn(a_state: AppState)
{
    tokio::spawn(async move {
        tokio::time::sleep(STARTUP_DELAY).await;
        let mut ticker = tokio::time::interval(TICK_PERIOD);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut ticks: u32 = 0;
        loop
        {
            ticker.tick().await;
            if let Err(err) = run_tick(&a_state, Utc::now()).await
            {
                tracing::warn!("notification tick failed: {err:?}");
            }
            ticks = ticks.wrapping_add(1);
            if ticks.is_multiple_of(PURGE_EVERY_TICKS)
            {
                if let Err(err) = purge_old(&a_state, Utc::now()).await
                {
                    tracing::warn!("notification purge failed: {err:?}");
                }
            }
        }
    });
}

pub async fn run_tick(a_state: &AppState, a_now: DateTime<Utc>) -> Result<TickReport, ApiError>
{
    let expired_lots = expire_lots(a_state, a_now).await?;
    let warned_lots = warn_expiring(a_state, a_now).await?;
    let reminders = remind_plans(a_state, a_now).await?;
    let pushed = sender::deliver(a_state, a_now).await?;
    Ok(TickReport {
        expired_lots,
        warned_lots,
        reminders,
        pushed,
    })
}

pub async fn purge_old(a_state: &AppState, a_now: DateTime<Utc>) -> Result<u64, ApiError>
{
    Ok(sqlx::query!(
        "DELETE FROM notifications WHERE created_ts < $1",
        a_now - Duration::days(KEEP_DAYS)
    )
    .execute(&a_state.db)
    .await?
    .rows_affected())
}

async fn lot_candidates(
    a_state: &AppState,
    a_last_day: NaiveDate,
    a_is_unwarned: bool,
) -> Result<Vec<LotCandidate>, ApiError>
{
    let rows = sqlx::query!(
        r#"
        SELECT l.id, l.owner_id, l.family_id, l.expires_on AS "expires_on!", f.name AS "family_name?", ns.tz AS "tz?"
        FROM stock_lots l
        LEFT JOIN families f ON f.id = l.family_id
        LEFT JOIN notify_settings ns ON ns.user_id = COALESCE(l.owner_id, f.owner_id)
        WHERE l.expires_on IS NOT NULL AND NOT l.is_expiry_done AND l.expires_on <= $1
          AND (NOT $2 OR l.warned_on IS DISTINCT FROM l.expires_on)
        ORDER BY l.expires_on, l.id
        LIMIT $3
        "#,
        a_last_day,
        a_is_unwarned,
        LOT_BATCH
    )
    .fetch_all(&a_state.db)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| LotCandidate {
            id: row.id,
            store: Store::of(row.owner_id, row.family_id),
            expires_on: row.expires_on,
            family_name: row.family_name,
            zone: zone_of(row.tz.as_deref()),
        })
        .collect())
}

struct LeftLot
{
    id: Uuid,
    title: String,
    measure: StockMeasure,
    qty: Decimal,
    cost: Option<Decimal>,
    left: Decimal,
}

async fn left_lots(a_conn: &mut sqlx::PgConnection, a_ids: &[Uuid]) -> Result<Vec<LeftLot>, ApiError>
{
    let rows = sqlx::query!(
        r#"
        SELECT l.id, l.title, l.measure AS "measure: StockMeasure", l.qty, l.cost,
               l.qty - COALESCE((SELECT SUM(m.qty) FROM stock_moves m WHERE m.lot_id = l.id), 0) AS "left!"
        FROM stock_lots l
        WHERE l.id = ANY($1) AND NOT l.is_expiry_done
        ORDER BY LOWER(l.title), l.id
        FOR UPDATE
        "#,
        a_ids
    )
    .fetch_all(&mut *a_conn)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| LeftLot {
            id: row.id,
            title: row.title,
            measure: row.measure,
            qty: row.qty,
            cost: row.cost,
            left: row.left,
        })
        .collect())
}

async fn expire_lots(a_state: &AppState, a_now: DateTime<Utc>) -> Result<usize, ApiError>
{
    let candidates = lot_candidates(a_state, a_now.date_naive(), false).await?;
    let mut groups: BTreeMap<StoreKey, ExpiredGroup> = BTreeMap::new();
    for lot in candidates
    {
        if a_now >= expired_due(lot.zone, lot.expires_on)
        {
            groups
                .entry((lot.store.owner_id, lot.store.family_id))
                .or_insert_with(|| ExpiredGroup {
                    family_name: lot.family_name.clone(),
                    ids: Vec::new(),
                })
                .ids
                .push(lot.id);
        }
    }

    let mut wasted = 0;
    for ((owner_id, family_id), group) in groups
    {
        let store = Store::of(owner_id, family_id);
        let mut tx = a_state.db.begin().await?;
        lock_store(&mut tx, store).await?;
        let lots = left_lots(&mut tx, &group.ids).await?;
        let mut items = Vec::new();
        let mut wasted_ids = Vec::new();
        for lot in &lots
        {
            if lot.left <= Decimal::ZERO
            {
                continue;
            }
            sqlx::query!(
                r#"
                INSERT INTO stock_moves (lot_id, kind, qty, cost, reason)
                VALUES ($1, 'waste', $2, $3, 'expired')
                "#,
                lot.id,
                lot.left,
                cost_share(lot.cost, lot.qty, lot.left)
            )
            .execute(&mut *tx)
            .await?;
            wasted_ids.push(lot.id);
            items.push(StockItem {
                title: lot.title.clone(),
                qty: lot.left,
                measure: lot.measure,
            });
        }
        let checked: Vec<Uuid> = lots.iter().map(|lot| lot.id).collect();
        sqlx::query!(
            "UPDATE stock_lots SET is_expiry_done = TRUE WHERE id = ANY($1)",
            &checked
        )
        .execute(&mut *tx)
        .await?;
        if !items.is_empty()
        {
            let key = lots_key("expired", &wasted_ids);
            for prefs in store_recipients(&mut tx, store).await?
            {
                if prefs.is_expired
                {
                    let notice =
                        prefs.stock_notice(NotifyKind::Expired, &key, None, group.family_name.as_deref(), &items);
                    insert_notice(&mut tx, prefs.user_id, &notice).await?;
                }
            }
        }
        tx.commit().await?;
        wasted += wasted_ids.len();
    }
    Ok(wasted)
}

async fn warn_expiring(a_state: &AppState, a_now: DateTime<Utc>) -> Result<usize, ApiError>
{
    let candidates = lot_candidates(a_state, a_now.date_naive() + Duration::days(2), true).await?;
    let mut groups: BTreeMap<(StoreKey, NaiveDate), WarnGroup> = BTreeMap::new();
    for lot in candidates
    {
        if a_now < expiring_due(lot.zone, lot.expires_on) || a_now >= expired_due(lot.zone, lot.expires_on)
        {
            continue;
        }
        let day = if local_date(lot.zone, a_now) >= lot.expires_on
        {
            ExpiryDay::Today
        }
        else
        {
            ExpiryDay::Tomorrow
        };
        groups
            .entry(((lot.store.owner_id, lot.store.family_id), lot.expires_on))
            .or_insert_with(|| WarnGroup {
                family_name: lot.family_name.clone(),
                day,
                ids: Vec::new(),
            })
            .ids
            .push(lot.id);
    }

    let mut warned = 0;
    for (((owner_id, family_id), expires_on), group) in groups
    {
        let store = Store::of(owner_id, family_id);
        let mut tx = a_state.db.begin().await?;
        lock_store(&mut tx, store).await?;
        let lots = left_lots(&mut tx, &group.ids).await?;
        let open: Vec<&LeftLot> = lots.iter().filter(|lot| lot.left > Decimal::ZERO).collect();
        let checked: Vec<Uuid> = lots.iter().map(|lot| lot.id).collect();
        sqlx::query!(
            "UPDATE stock_lots SET warned_on = expires_on WHERE id = ANY($1) AND expires_on = $2",
            &checked,
            expires_on
        )
        .execute(&mut *tx)
        .await?;
        if !open.is_empty()
        {
            let open_ids: Vec<Uuid> = open.iter().map(|lot| lot.id).collect();
            let key = format!("{}:{expires_on}", lots_key("expiring", &open_ids));
            let items: Vec<StockItem> = open
                .iter()
                .map(|lot| StockItem {
                    title: lot.title.clone(),
                    qty: lot.left,
                    measure: lot.measure,
                })
                .collect();
            for prefs in store_recipients(&mut tx, store).await?
            {
                if prefs.is_expiring
                {
                    let notice = prefs.stock_notice(
                        NotifyKind::Expiring,
                        &key,
                        Some(group.day),
                        group.family_name.as_deref(),
                        &items,
                    );
                    insert_notice(&mut tx, prefs.user_id, &notice).await?;
                }
            }
            warned += open.len();
        }
        tx.commit().await?;
    }
    Ok(warned)
}

async fn remind_plans(a_state: &AppState, a_now: DateTime<Utc>) -> Result<usize, ApiError>
{
    let users = sqlx::query_scalar!(
        "SELECT user_id FROM plan_remind_due WHERE due_ts <= $1 ORDER BY due_ts LIMIT $2",
        a_now,
        USER_BATCH
    )
    .fetch_all(&a_state.db)
    .await?;
    let mut sent = 0;
    for user_id in users
    {
        sent += remind_user(a_state, user_id, a_now).await?;
    }
    Ok(sent)
}

async fn remind_user(a_state: &AppState, a_user_id: Uuid, a_now: DateTime<Utc>) -> Result<usize, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let is_due = sqlx::query_scalar!(
        r#"SELECT due_ts <= $2 AS "is_due!" FROM plan_remind_due WHERE user_id = $1 FOR UPDATE"#,
        a_user_id,
        a_now
    )
    .fetch_optional(&mut *tx)
    .await?
    .unwrap_or(false);
    let Some(prefs) = load_prefs(&mut tx, &[a_user_id]).await?.into_iter().next()
    else
    {
        return Ok(0);
    };
    if !is_due
    {
        return Ok(0);
    }
    let mut next_due = a_now + RECHECK;
    let mut sent = 0;
    if prefs.is_plan || prefs.is_workout
    {
        let today = a_now.date_naive();
        for occurrence in
            load_occurrences(&mut tx, a_user_id, today - Duration::days(1), today + Duration::days(2)).await?
        {
            if occurrence.state != PlanState::Planned || occurrence.start_ts <= a_now
            {
                continue;
            }
            let Some((kind, lead)) = prefs.plan_rule(&occurrence)
            else
            {
                continue;
            };
            let due = occurrence.start_ts - lead;
            if due <= a_now
            {
                if insert_notice(&mut tx, a_user_id, &prefs.plan_notice(kind, &occurrence, lead)).await?
                {
                    sent += 1;
                }
            }
            else
            {
                next_due = next_due.min(due);
            }
        }
    }
    sqlx::query!(
        r#"
        INSERT INTO plan_remind_due (user_id, due_ts) VALUES ($1, $2)
        ON CONFLICT (user_id) DO UPDATE SET due_ts = EXCLUDED.due_ts
        "#,
        a_user_id,
        next_due
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(sent)
}
