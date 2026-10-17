use std::collections::BTreeMap;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, NaiveDate, Utc};
use rust_decimal::Decimal;
use sha2::{Digest, Sha256};
use shared_schema::{
    MarkReadRequest, NotificationDto, NotificationsDto, NotificationsQuery, NotifyKind, NotifySettingsDto, PlanState,
    PushKeyDto, PushSubRequest, PushUnsubRequest, SaveNotifySettingsRequest, StockMeasure, UpcomingNotifyDto,
    UpcomingQuery,
};
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiQuery, AuthUser};
use crate::api::planner_handlers::load_occurrences;
use crate::api::stock_handlers::Store;
use crate::domain::errors::ApiError;
use crate::notify::sender::{check_endpoint, StoredSub};
use crate::notify::texts::{ExpiryDay, LANGS};
use crate::notify::web_push::Subscription;
use crate::notify::{
    expired_due, expiring_due, load_prefs, lots_key, replan, zone_of, Notice, StockItem, DEFAULT_PLAN_LEAD_MIN,
    DEFAULT_WORKOUT_LEAD_MIN, MAX_LEAD_MIN,
};
use crate::security::crypto::push_sub_aad;
use crate::services::planner::parse_zone;
use crate::state::AppState;

const DEFAULT_TZ: &str = "UTC";
const DEFAULT_LANG: &str = "en";
const DEFAULT_LIMIT: i64 = 50;
const MAX_LIMIT: i64 = 200;
const MAX_READ_IDS: usize = 200;
const MAX_SUBS_PER_USER: i64 = 10;
const DEFAULT_HORIZON_HOURS: i64 = 48;
const MAX_HORIZON_HOURS: i64 = 72;
const MAX_UPCOMING: usize = 200;

fn endpoint_hash(a_endpoint: &str) -> Vec<u8>
{
    Sha256::digest(a_endpoint.as_bytes()).to_vec()
}

async fn load_settings(a_state: &AppState, a_user_id: Uuid) -> Result<NotifySettingsDto, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let row = sqlx::query!(
        r#"
        SELECT tz, lang, is_plan, plan_lead_min, is_workout, workout_lead_min, is_expiring, is_expired
        FROM notify_settings WHERE user_id = $1
        "#,
        a_user_id
    )
    .fetch_optional(&mut *conn)
    .await?;
    let push_subs = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM push_subs WHERE user_id = $1"#,
        a_user_id
    )
    .fetch_one(&mut *conn)
    .await?;
    let is_web_push = a_state.cfg.push.vapid.is_some();
    Ok(match row
    {
        Some(row) => NotifySettingsDto {
            tz: row.tz,
            lang: row.lang,
            is_plan: row.is_plan,
            plan_lead_min: row.plan_lead_min,
            is_workout: row.is_workout,
            workout_lead_min: row.workout_lead_min,
            is_expiring: row.is_expiring,
            is_expired: row.is_expired,
            is_web_push,
            push_subs,
        },
        None => NotifySettingsDto {
            tz: DEFAULT_TZ.into(),
            lang: DEFAULT_LANG.into(),
            is_plan: true,
            plan_lead_min: DEFAULT_PLAN_LEAD_MIN,
            is_workout: true,
            workout_lead_min: DEFAULT_WORKOUT_LEAD_MIN,
            is_expiring: true,
            is_expired: true,
            is_web_push,
            push_subs,
        },
    })
}

pub async fn get_settings(
    State(a_state): State<AppState>,
    a_user: AuthUser,
) -> Result<Json<NotifySettingsDto>, ApiError>
{
    Ok(Json(load_settings(&a_state, a_user.user_id).await?))
}

pub async fn save_settings(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SaveNotifySettingsRequest>,
) -> Result<Json<NotifySettingsDto>, ApiError>
{
    if a_req.tz.as_deref().is_some_and(|tz| parse_zone(tz).is_none())
    {
        return Err(ApiError::Validation("tz"));
    }
    if a_req.lang.as_deref().is_some_and(|lang| !LANGS.contains(&lang))
    {
        return Err(ApiError::Validation("lang"));
    }
    let is_lead = |lead: Option<i32>| lead.is_none_or(|lead| (0..=MAX_LEAD_MIN).contains(&lead));
    if !is_lead(a_req.plan_lead_min)
    {
        return Err(ApiError::Validation("plan_lead_min"));
    }
    if !is_lead(a_req.workout_lead_min)
    {
        return Err(ApiError::Validation("workout_lead_min"));
    }

    let mut tx = a_state.db.begin().await?;
    sqlx::query!(
        r#"
        INSERT INTO notify_settings (
            user_id, tz, lang, is_plan, plan_lead_min, is_workout, workout_lead_min, is_expiring, is_expired
        )
        VALUES (
            $1, COALESCE($2::text, $10::text), COALESCE($3::text, $11::text), COALESCE($4::bool, TRUE),
            COALESCE($5::int, $12::int), COALESCE($6::bool, TRUE), COALESCE($7::int, $13::int),
            COALESCE($8::bool, TRUE), COALESCE($9::bool, TRUE)
        )
        ON CONFLICT (user_id) DO UPDATE
        SET tz = COALESCE($2::text, notify_settings.tz),
            lang = COALESCE($3::text, notify_settings.lang),
            is_plan = COALESCE($4::bool, notify_settings.is_plan),
            plan_lead_min = COALESCE($5::int, notify_settings.plan_lead_min),
            is_workout = COALESCE($6::bool, notify_settings.is_workout),
            workout_lead_min = COALESCE($7::int, notify_settings.workout_lead_min),
            is_expiring = COALESCE($8::bool, notify_settings.is_expiring),
            is_expired = COALESCE($9::bool, notify_settings.is_expired),
            updated_ts = NOW()
        "#,
        a_user.user_id,
        a_req.tz,
        a_req.lang,
        a_req.is_plan,
        a_req.plan_lead_min,
        a_req.is_workout,
        a_req.workout_lead_min,
        a_req.is_expiring,
        a_req.is_expired,
        DEFAULT_TZ,
        DEFAULT_LANG,
        DEFAULT_PLAN_LEAD_MIN,
        DEFAULT_WORKOUT_LEAD_MIN
    )
    .execute(&mut *tx)
    .await?;
    replan(&mut tx, a_user.user_id).await?;
    tx.commit().await?;
    Ok(Json(load_settings(&a_state, a_user.user_id).await?))
}

pub async fn list(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<NotificationsQuery>,
) -> Result<Json<NotificationsDto>, ApiError>
{
    let limit = a_query.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);
    let mut conn = a_state.db.acquire().await?;
    let rows = sqlx::query!(
        r#"
        SELECT id, kind AS "kind: NotifyKind", title, body, link, params, created_ts, read_ts IS NOT NULL AS "is_read!"
        FROM notifications
        WHERE user_id = $1
        ORDER BY created_ts DESC, id
        LIMIT $2
        "#,
        a_user.user_id,
        limit
    )
    .fetch_all(&mut *conn)
    .await?;
    let unread = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM notifications WHERE user_id = $1 AND read_ts IS NULL"#,
        a_user.user_id
    )
    .fetch_one(&mut *conn)
    .await?;
    Ok(Json(NotificationsDto {
        items: rows
            .into_iter()
            .map(|row| NotificationDto {
                id: row.id,
                kind: row.kind,
                title: row.title,
                body: row.body,
                link: row.link,
                params: row.params,
                created_ts: row.created_ts,
                is_read: row.is_read,
            })
            .collect(),
        unread,
    }))
}

pub async fn mark_read(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<MarkReadRequest>,
) -> Result<StatusCode, ApiError>
{
    if (!a_req.is_all && a_req.ids.is_empty()) || a_req.ids.len() > MAX_READ_IDS
    {
        return Err(ApiError::Validation("ids"));
    }
    sqlx::query!(
        r#"
        UPDATE notifications SET read_ts = NOW()
        WHERE user_id = $1 AND read_ts IS NULL AND ($2 OR id = ANY($3))
        "#,
        a_user.user_id,
        a_req.is_all,
        &a_req.ids
    )
    .execute(&a_state.db)
    .await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn push_key(State(a_state): State<AppState>, _a_user: AuthUser) -> Json<PushKeyDto>
{
    Json(PushKeyDto {
        public_key: a_state.cfg.push.vapid.as_ref().map(|vapid| vapid.public_base64()),
    })
}

pub async fn subscribe(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<PushSubRequest>,
) -> Result<StatusCode, ApiError>
{
    if a_state.cfg.push.vapid.is_none()
    {
        return Err(ApiError::Conflict("PUSH_UNAVAILABLE"));
    }
    check_endpoint(&a_state.cfg.push.hosts, &a_req.endpoint)?;
    Subscription::parse(&a_req.endpoint, &a_req.p256dh, &a_req.auth).map_err(|_| ApiError::Validation("keys"))?;
    let stored = serde_json::to_vec(&StoredSub {
        endpoint: a_req.endpoint.clone(),
        p256dh: a_req.p256dh.trim().to_string(),
        auth: a_req.auth.trim().to_string(),
    })
    .map_err(|_| ApiError::internal("push subscription encoding failed"))?;
    let sealed = a_state.secret_box.seal(&stored, &push_sub_aad(a_user.user_id))?;

    let mut tx = a_state.db.begin().await?;
    sqlx::query!(
        r#"
        INSERT INTO push_subs (user_id, endpoint_hash, sealed) VALUES ($1, $2, $3)
        ON CONFLICT (endpoint_hash) DO UPDATE
        SET user_id = EXCLUDED.user_id, sealed = EXCLUDED.sealed, fail_count = 0, created_ts = NOW()
        "#,
        a_user.user_id,
        endpoint_hash(&a_req.endpoint),
        sealed
    )
    .execute(&mut *tx)
    .await?;
    sqlx::query!(
        r#"
        DELETE FROM push_subs
        WHERE id IN (SELECT id FROM push_subs WHERE user_id = $1 ORDER BY created_ts DESC, id OFFSET $2)
        "#,
        a_user.user_id,
        MAX_SUBS_PER_USER
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn unsubscribe(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<PushUnsubRequest>,
) -> Result<StatusCode, ApiError>
{
    sqlx::query!(
        "DELETE FROM push_subs WHERE endpoint_hash = $1 AND user_id = $2",
        endpoint_hash(&a_req.endpoint),
        a_user.user_id
    )
    .execute(&a_state.db)
    .await?;
    Ok(StatusCode::NO_CONTENT)
}

fn upcoming_item(a_notice: Notice, a_due: DateTime<Utc>) -> UpcomingNotifyDto
{
    UpcomingNotifyDto {
        key: a_notice.key,
        kind: a_notice.kind,
        due_ts: a_due,
        title: a_notice.title,
        body: a_notice.body,
        link: a_notice.link.to_string(),
        params: a_notice.params,
    }
}

struct FeedLot
{
    id: Uuid,
    store: Store,
    family_name: Option<String>,
    item: StockItem,
    expires_on: NaiveDate,
    warned_on: Option<NaiveDate>,
    zone: chrono_tz::Tz,
}

pub async fn upcoming(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<UpcomingQuery>,
) -> Result<Json<Vec<UpcomingNotifyDto>>, ApiError>
{
    let hours = a_query
        .hours
        .unwrap_or(DEFAULT_HORIZON_HOURS)
        .clamp(1, MAX_HORIZON_HOURS);
    let now = Utc::now();
    let horizon = now + Duration::hours(hours);
    let mut conn = a_state.db.acquire().await?;
    let Some(prefs) = load_prefs(&mut conn, &[a_user.user_id]).await?.into_iter().next()
    else
    {
        return Err(ApiError::NotFound);
    };
    let mut items = Vec::new();

    if prefs.is_plan || prefs.is_workout
    {
        let today = now.date_naive();
        let last = horizon.date_naive() + Duration::days(1);
        for occurrence in load_occurrences(&mut conn, a_user.user_id, today - Duration::days(1), last).await?
        {
            if occurrence.state != PlanState::Planned || occurrence.start_ts <= now
            {
                continue;
            }
            if let Some((kind, lead)) = prefs.plan_rule(&occurrence)
            {
                let due = occurrence.start_ts - lead;
                if due > now && due <= horizon
                {
                    items.push(upcoming_item(prefs.plan_notice(kind, &occurrence, lead), due));
                }
            }
        }
    }

    if prefs.is_expiring || prefs.is_expired
    {
        let rows = sqlx::query!(
            r#"
            SELECT l.id, l.owner_id, l.family_id, l.title, l.measure AS "measure: StockMeasure",
                   l.expires_on AS "expires_on!", l.warned_on, f.name AS "family_name?", ns.tz AS "tz?",
                   l.qty - COALESCE((SELECT SUM(m.qty) FROM stock_moves m WHERE m.lot_id = l.id), 0) AS "left!"
            FROM stock_lots l
            LEFT JOIN families f ON f.id = l.family_id
            LEFT JOIN notify_settings ns ON ns.user_id = COALESCE(l.owner_id, f.owner_id)
            WHERE (l.owner_id = $1 OR l.family_id IN (SELECT family_id FROM family_mems WHERE user_id = $1))
              AND l.expires_on IS NOT NULL AND NOT l.is_expiry_done AND l.expires_on <= $2
            ORDER BY l.expires_on, LOWER(l.title), l.id
            "#,
            a_user.user_id,
            horizon.date_naive() + Duration::days(2)
        )
        .fetch_all(&mut *conn)
        .await?;
        let mut groups: BTreeMap<(Option<Uuid>, Option<Uuid>, NaiveDate), Vec<FeedLot>> = BTreeMap::new();
        for row in rows.into_iter().filter(|row| row.left > Decimal::ZERO)
        {
            groups
                .entry((row.owner_id, row.family_id, row.expires_on))
                .or_default()
                .push(FeedLot {
                    id: row.id,
                    store: Store::of(row.owner_id, row.family_id),
                    family_name: row.family_name,
                    item: StockItem {
                        title: row.title,
                        qty: row.left,
                        measure: row.measure,
                    },
                    expires_on: row.expires_on,
                    warned_on: row.warned_on,
                    zone: zone_of(row.tz.as_deref()),
                });
        }
        for lots in groups.values()
        {
            let Some(first) = lots.first()
            else
            {
                continue;
            };
            debug_assert!(lots.iter().all(|lot| lot.store == first.store));
            let ids: Vec<Uuid> = lots.iter().map(|lot| lot.id).collect();
            let stock_items: Vec<StockItem> = lots.iter().map(|lot| lot.item.clone()).collect();
            let family_name = first.family_name.as_deref();
            let warn_at = expiring_due(first.zone, first.expires_on);
            if prefs.is_expiring && first.warned_on != Some(first.expires_on) && warn_at > now && warn_at <= horizon
            {
                let key = format!("{}:{}", lots_key("expiring", &ids), first.expires_on);
                let notice = prefs.stock_notice(
                    NotifyKind::Expiring,
                    &key,
                    Some(ExpiryDay::Tomorrow),
                    family_name,
                    &stock_items,
                );
                items.push(upcoming_item(notice, warn_at));
            }
            let expire_at = expired_due(first.zone, first.expires_on);
            if prefs.is_expired && expire_at > now && expire_at <= horizon
            {
                let notice = prefs.stock_notice(
                    NotifyKind::Expired,
                    &lots_key("expired", &ids),
                    None,
                    family_name,
                    &stock_items,
                );
                items.push(upcoming_item(notice, expire_at));
            }
        }
    }

    items.sort_by(|left, right| left.due_ts.cmp(&right.due_ts).then_with(|| left.key.cmp(&right.key)));
    items.truncate(MAX_UPCOMING);
    Ok(Json(items))
}
