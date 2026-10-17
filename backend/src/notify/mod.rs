pub mod sender;
pub mod texts;
pub mod web_push;
pub mod worker;

use chrono::{DateTime, Duration, NaiveDate, NaiveTime, Utc};
use chrono_tz::Tz;
use rust_decimal::Decimal;
use serde_json::json;
use sha2::{Digest, Sha256};
use shared_schema::{NotifyKind, OccurrenceDto, StockMeasure};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::stock_handlers::Store;
use crate::domain::errors::ApiError;
use crate::notify::texts::{ExpiryDay, Lang, StockLine};
use crate::services::planner::{parse_zone, resolve_local};

pub const DEFAULT_PLAN_LEAD_MIN: i32 = 15;
pub const DEFAULT_WORKOUT_LEAD_MIN: i32 = 60;
pub const MAX_LEAD_MIN: i32 = 1440;
pub const MAX_BODY_LINES: usize = 5;
pub const WARN_HOUR: u32 = 9;
pub const PLANNER_LINK: &str = "/app/planner";
pub const STOCK_LINK: &str = "/app/stock";
pub const STOCK_HISTORY_LINK: &str = "/app/stock/history";
const KEY_HASH_BYTES: usize = 12;
const MAX_TITLE_CHARS: usize = 200;
const MAX_BODY_CHARS: usize = 500;

#[derive(Debug, Clone)]
pub struct Prefs
{
    pub user_id: Uuid,
    pub zone: Tz,
    pub lang: Lang,
    pub is_plan: bool,
    pub plan_lead_min: i32,
    pub is_workout: bool,
    pub workout_lead_min: i32,
    pub is_expiring: bool,
    pub is_expired: bool,
}

#[derive(Debug, Clone)]
pub struct Notice
{
    pub kind: NotifyKind,
    pub key: String,
    pub title: String,
    pub body: String,
    pub link: &'static str,
    pub params: serde_json::Value,
}

#[derive(Debug, Clone)]
pub struct StockItem
{
    pub title: String,
    pub qty: Decimal,
    pub measure: StockMeasure,
}

impl Prefs
{
    pub fn plan_rule(&self, a_occurrence: &OccurrenceDto) -> Option<(NotifyKind, Duration)>
    {
        let (kind, is_on, lead) = if a_occurrence.program_id.is_some()
        {
            (NotifyKind::Workout, self.is_workout, self.workout_lead_min)
        }
        else
        {
            (NotifyKind::Plan, self.is_plan, self.plan_lead_min)
        };
        is_on.then(|| (kind, Duration::minutes(i64::from(lead))))
    }

    pub fn plan_notice(&self, a_kind: NotifyKind, a_occurrence: &OccurrenceDto, a_lead: Duration) -> Notice
    {
        let title = match a_kind
        {
            NotifyKind::Workout => self.lang.workout_title(&a_occurrence.title),
            _ => a_occurrence.title.clone(),
        };
        let local_start = a_occurrence
            .start_ts
            .with_timezone(&self.zone)
            .format("%H:%M")
            .to_string();
        Notice {
            kind: a_kind,
            key: format!(
                "plan:{}:{}:{}",
                a_occurrence.event_id,
                a_occurrence.occ_date,
                a_occurrence.start_ts.timestamp()
            ),
            title,
            body: self.lang.starts_at(&local_start),
            link: PLANNER_LINK,
            params: json!({
                "title": a_occurrence.title,
                "event_id": a_occurrence.event_id,
                "occ_date": a_occurrence.occ_date,
                "start_ts": a_occurrence.start_ts,
                "lead_min": a_lead.num_minutes(),
            }),
        }
    }

    pub fn stock_notice(
        &self,
        a_kind: NotifyKind,
        a_key: &str,
        a_day: Option<ExpiryDay>,
        a_store_name: Option<&str>,
        a_items: &[StockItem],
    ) -> Notice
    {
        let shown = &a_items[..a_items.len().min(MAX_BODY_LINES)];
        let more = a_items.len() - shown.len();
        let lines: Vec<StockLine> = shown
            .iter()
            .map(|item| StockLine {
                title: item.title.clone(),
                qty: item.qty.normalize().to_string(),
                measure: item.measure,
            })
            .collect();
        let title = match a_day
        {
            Some(day) => self.lang.expiring_title(day).to_string(),
            None => self.lang.expired_title().to_string(),
        };
        Notice {
            kind: a_kind,
            key: a_key.to_string(),
            title,
            body: self.lang.stock_body(a_store_name, &lines, more),
            link: if a_kind == NotifyKind::Expired
            {
                STOCK_HISTORY_LINK
            }
            else
            {
                STOCK_LINK
            },
            params: json!({
                "day": a_day.map(ExpiryDay::as_str),
                "family_name": a_store_name,
                "more": more,
                "items": shown
                    .iter()
                    .map(|item| json!({ "title": item.title, "qty": item.qty.normalize(), "measure": item.measure }))
                    .collect::<Vec<_>>(),
            }),
        }
    }
}

pub fn lots_key(a_prefix: &str, a_lot_ids: &[Uuid]) -> String
{
    let mut ids = a_lot_ids.to_vec();
    ids.sort_unstable();
    let mut hasher = Sha256::new();
    for id in &ids
    {
        hasher.update(id.as_bytes());
    }
    let digest = hasher.finalize();
    let hex: String = digest[..KEY_HASH_BYTES]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    format!("{a_prefix}:{hex}")
}

pub fn expiring_due(a_zone: Tz, a_expires_on: NaiveDate) -> DateTime<Utc>
{
    resolve_local(
        a_zone,
        a_expires_on - Duration::days(1),
        NaiveTime::from_hms_opt(WARN_HOUR, 0, 0).unwrap_or(NaiveTime::MIN),
    )
}

pub fn expired_due(a_zone: Tz, a_expires_on: NaiveDate) -> DateTime<Utc>
{
    resolve_local(a_zone, a_expires_on + Duration::days(1), NaiveTime::MIN)
}

pub fn zone_of(a_name: Option<&str>) -> Tz
{
    a_name.and_then(parse_zone).unwrap_or(Tz::UTC)
}

pub async fn load_prefs(a_conn: &mut PgConnection, a_user_ids: &[Uuid]) -> Result<Vec<Prefs>, ApiError>
{
    let rows = sqlx::query!(
        r#"
        SELECT u.id, ns.tz AS "tz?", ns.lang AS "lang?", COALESCE(ns.is_plan, TRUE) AS "is_plan!",
               COALESCE(ns.plan_lead_min, $2) AS "plan_lead_min!", COALESCE(ns.is_workout, TRUE) AS "is_workout!",
               COALESCE(ns.workout_lead_min, $3) AS "workout_lead_min!",
               COALESCE(ns.is_expiring, TRUE) AS "is_expiring!", COALESCE(ns.is_expired, TRUE) AS "is_expired!"
        FROM users u
        LEFT JOIN notify_settings ns ON ns.user_id = u.id
        WHERE u.id = ANY($1) AND NOT u.is_managed
        ORDER BY u.id
        "#,
        a_user_ids,
        DEFAULT_PLAN_LEAD_MIN,
        DEFAULT_WORKOUT_LEAD_MIN
    )
    .fetch_all(&mut *a_conn)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| Prefs {
            user_id: row.id,
            zone: zone_of(row.tz.as_deref()),
            lang: Lang::parse(row.lang.as_deref().unwrap_or_default()),
            is_plan: row.is_plan,
            plan_lead_min: row.plan_lead_min,
            is_workout: row.is_workout,
            workout_lead_min: row.workout_lead_min,
            is_expiring: row.is_expiring,
            is_expired: row.is_expired,
        })
        .collect())
}

pub async fn store_recipients(a_conn: &mut PgConnection, a_store: Store) -> Result<Vec<Prefs>, ApiError>
{
    let ids = sqlx::query_scalar!(
        r#"
        SELECT u.id
        FROM users u
        WHERE u.id = $1 OR u.id IN (SELECT fm.user_id FROM family_mems fm WHERE fm.family_id = $2)
        "#,
        a_store.owner_id,
        a_store.family_id
    )
    .fetch_all(&mut *a_conn)
    .await?;
    load_prefs(a_conn, &ids).await
}

pub async fn insert_notice(a_conn: &mut PgConnection, a_user_id: Uuid, a_notice: &Notice) -> Result<bool, ApiError>
{
    let title: String = a_notice.title.chars().take(MAX_TITLE_CHARS).collect();
    let body: String = a_notice.body.chars().take(MAX_BODY_CHARS).collect();
    let inserted = sqlx::query!(
        r#"
        INSERT INTO notifications (user_id, kind, dedup_key, title, body, link, params)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        ON CONFLICT (user_id, dedup_key) DO NOTHING
        "#,
        a_user_id,
        a_notice.kind as NotifyKind,
        a_notice.key,
        title,
        body,
        a_notice.link,
        a_notice.params
    )
    .execute(&mut *a_conn)
    .await?
    .rows_affected();
    Ok(inserted > 0)
}

pub async fn replan(a_conn: &mut PgConnection, a_user_id: Uuid) -> Result<(), ApiError>
{
    sqlx::query!(
        r#"
        INSERT INTO plan_remind_due (user_id, due_ts)
        SELECT id, NOW() FROM users WHERE id = $1 AND NOT is_managed
        ON CONFLICT (user_id) DO UPDATE SET due_ts = LEAST(plan_remind_due.due_ts, EXCLUDED.due_ts)
        "#,
        a_user_id
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn expiry_moments_follow_the_store_zone()
    {
        let kyiv: Tz = "Europe/Kyiv".parse().unwrap();
        let date = NaiveDate::from_ymd_opt(2026, 10, 20).unwrap();
        assert_eq!(expiring_due(kyiv, date).to_rfc3339(), "2026-10-19T06:00:00+00:00");
        assert_eq!(expired_due(kyiv, date).to_rfc3339(), "2026-10-20T21:00:00+00:00");
        assert_eq!(expired_due(Tz::UTC, date).to_rfc3339(), "2026-10-21T00:00:00+00:00");
    }

    #[test]
    fn lot_keys_do_not_depend_on_order()
    {
        let first = Uuid::new_v4();
        let second = Uuid::new_v4();
        assert_eq!(
            lots_key("expired", &[first, second]),
            lots_key("expired", &[second, first])
        );
        assert_ne!(lots_key("expired", &[first]), lots_key("expired", &[second]));
        assert_eq!(
            lots_key("expired", &[first]).len(),
            "expired:".len() + KEY_HASH_BYTES * 2
        );
    }
}
