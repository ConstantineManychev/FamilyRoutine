use std::collections::hash_map::Entry;
use std::collections::HashMap;
use std::net::IpAddr;
use std::time::Duration as StdDuration;

use axum::http::header::{AUTHORIZATION, CONTENT_ENCODING, CONTENT_TYPE};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::json;
use shared_schema::{NotifyKind, PushState};
use uuid::Uuid;

use crate::domain::errors::ApiError;
use crate::notify::web_push::{encrypt, Subscription, VapidKeys};
use crate::security::crypto::push_sub_aad;
use crate::state::AppState;

pub const MAX_ENDPOINT_LEN: usize = 1024;
const HTTP_TIMEOUT: StdDuration = StdDuration::from_secs(10);
const HTTP_CONNECT_TIMEOUT: StdDuration = StdDuration::from_secs(5);
const CLAIM_BATCH: i64 = 100;
const RECLAIM_AFTER: Duration = Duration::minutes(5);
const STALE_AFTER: Duration = Duration::hours(6);
const MAX_TRIES: i16 = 3;
const MAX_SUB_FAILS: i32 = 10;
const PLAN_TTL_SEC: u32 = 3600;
const STOCK_TTL_SEC: u32 = 12 * 3600;

pub struct PushClient
{
    http: reqwest::Client,
}

impl PushClient
{
    pub fn new() -> Result<Self, String>
    {
        let http = reqwest::Client::builder()
            .timeout(HTTP_TIMEOUT)
            .connect_timeout(HTTP_CONNECT_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|err| format!("push client: {err}"))?;
        Ok(Self { http })
    }
}

#[derive(Serialize, Deserialize)]
pub struct StoredSub
{
    pub endpoint: String,
    pub p256dh: String,
    pub auth: String,
}

struct ActiveSub
{
    id: Uuid,
    subscription: Subscription,
}

enum Outcome
{
    Delivered,
    Gone,
    Retry,
}

fn is_loopback(a_host: &str) -> bool
{
    a_host == "localhost"
        || a_host
            .trim_start_matches('[')
            .trim_end_matches(']')
            .parse::<IpAddr>()
            .is_ok_and(|ip| ip.is_loopback())
}

pub fn check_endpoint(a_hosts: &[String], a_endpoint: &str) -> Result<(), ApiError>
{
    let invalid = ApiError::Validation("endpoint");
    if a_endpoint.len() > MAX_ENDPOINT_LEN
    {
        return Err(invalid);
    }
    let url = reqwest::Url::parse(a_endpoint).map_err(|_| ApiError::Validation("endpoint"))?;
    if !url.username().is_empty() || url.password().is_some()
    {
        return Err(invalid);
    }
    let Some(host) = url.host_str().map(str::to_ascii_lowercase)
    else
    {
        return Err(invalid);
    };
    let is_listed = a_hosts
        .iter()
        .any(|allowed| host == *allowed || host.ends_with(&format!(".{allowed}")));
    let is_allowed = match url.scheme()
    {
        "https" => is_listed,
        "http" => is_loopback(&host) && a_hosts.contains(&host),
        _ => false,
    };
    if is_allowed
    {
        Ok(())
    }
    else
    {
        Err(invalid)
    }
}

async fn load_subs(a_state: &AppState, a_user_id: Uuid) -> Result<Vec<ActiveSub>, ApiError>
{
    let rows = sqlx::query!(
        "SELECT id, sealed FROM push_subs WHERE user_id = $1 ORDER BY created_ts",
        a_user_id
    )
    .fetch_all(&a_state.db)
    .await?;
    let mut subs = Vec::with_capacity(rows.len());
    for row in rows
    {
        let parsed = a_state
            .secret_box
            .open(&row.sealed, &push_sub_aad(a_user_id))
            .ok()
            .and_then(|plain| serde_json::from_slice::<StoredSub>(&plain).ok())
            .and_then(|stored| Subscription::parse(&stored.endpoint, &stored.p256dh, &stored.auth).ok());
        match parsed
        {
            Some(subscription) => subs.push(ActiveSub {
                id: row.id,
                subscription,
            }),
            None =>
            {
                sqlx::query!("DELETE FROM push_subs WHERE id = $1", row.id)
                    .execute(&a_state.db)
                    .await?;
            }
        }
    }
    Ok(subs)
}

async fn send_one(
    a_state: &AppState,
    a_vapid: &VapidKeys,
    a_sub: &Subscription,
    a_payload: &[u8],
    a_kind: NotifyKind,
    a_topic: &str,
    a_now: DateTime<Utc>,
) -> Outcome
{
    if check_endpoint(&a_state.cfg.push.hosts, &a_sub.endpoint).is_err()
    {
        return Outcome::Gone;
    }
    let (Ok(body), Ok(authorization)) = (
        encrypt(a_payload, a_sub),
        a_vapid.authorization(&a_sub.endpoint, a_now.timestamp()),
    )
    else
    {
        return Outcome::Gone;
    };
    let (ttl, urgency) = match a_kind
    {
        NotifyKind::Plan | NotifyKind::Workout => (PLAN_TTL_SEC, "high"),
        NotifyKind::Expiring | NotifyKind::Expired => (STOCK_TTL_SEC, "normal"),
    };
    let response = a_state
        .push
        .http
        .post(&a_sub.endpoint)
        .header("TTL", ttl.to_string())
        .header("Urgency", urgency)
        .header("Topic", a_topic)
        .header(CONTENT_ENCODING, "aes128gcm")
        .header(CONTENT_TYPE, "application/octet-stream")
        .header(AUTHORIZATION, authorization)
        .body(body)
        .send()
        .await;
    match response
    {
        Ok(response) if response.status().is_success() => Outcome::Delivered,
        Ok(response) if matches!(response.status().as_u16(), 403 | 404 | 410) => Outcome::Gone,
        Ok(response) =>
        {
            tracing::debug!("push endpoint answered {}", response.status());
            Outcome::Retry
        }
        Err(err) =>
        {
            tracing::debug!("push delivery failed: {}", err.without_url());
            Outcome::Retry
        }
    }
}

pub async fn deliver(a_state: &AppState, a_now: DateTime<Utc>) -> Result<usize, ApiError>
{
    let Some(vapid) = a_state.cfg.push.vapid.as_ref()
    else
    {
        sqlx::query!("UPDATE notifications SET push_state = 'skipped' WHERE push_state IN ('pending', 'sending')")
            .execute(&a_state.db)
            .await?;
        return Ok(0);
    };

    let claimed = sqlx::query!(
        r#"
        UPDATE notifications n
        SET push_state = 'sending', push_ts = $1, push_tries = n.push_tries + 1
        WHERE n.id IN (
            SELECT id FROM notifications
            WHERE push_state = 'pending' OR (push_state = 'sending' AND push_ts < $2)
            ORDER BY created_ts
            LIMIT $3
            FOR UPDATE SKIP LOCKED
        )
        RETURNING n.id, n.user_id, n.kind AS "kind: NotifyKind", n.title, n.body, n.link, n.created_ts, n.push_tries
        "#,
        a_now,
        a_now - RECLAIM_AFTER,
        CLAIM_BATCH
    )
    .fetch_all(&a_state.db)
    .await?;

    let mut subs_by_user: HashMap<Uuid, Vec<ActiveSub>> = HashMap::new();
    let mut sent = 0;
    for notice in claimed
    {
        let state = if notice.created_ts < a_now - STALE_AFTER
        {
            PushState::Skipped
        }
        else
        {
            let subs = match subs_by_user.entry(notice.user_id)
            {
                Entry::Occupied(entry) => entry.into_mut(),
                Entry::Vacant(entry) => entry.insert(load_subs(a_state, notice.user_id).await?),
            };
            let payload = json!({
                "id": notice.id,
                "tag": notice.id,
                "title": notice.title,
                "body": notice.body,
                "link": notice.link,
            })
            .to_string();
            let topic = notice.id.simple().to_string();
            let mut is_delivered = false;
            let mut is_retry = false;
            let mut gone = Vec::new();
            for sub in subs.iter()
            {
                match send_one(
                    a_state,
                    vapid,
                    &sub.subscription,
                    payload.as_bytes(),
                    notice.kind,
                    &topic,
                    a_now,
                )
                .await
                {
                    Outcome::Delivered =>
                    {
                        is_delivered = true;
                        sqlx::query!(
                            "UPDATE push_subs SET last_ok_ts = $2, fail_count = 0 WHERE id = $1",
                            sub.id,
                            a_now
                        )
                        .execute(&a_state.db)
                        .await?;
                    }
                    Outcome::Gone => gone.push(sub.id),
                    Outcome::Retry =>
                    {
                        is_retry = true;
                        let fails = sqlx::query_scalar!(
                            "UPDATE push_subs SET fail_count = fail_count + 1 WHERE id = $1 RETURNING fail_count",
                            sub.id
                        )
                        .fetch_optional(&a_state.db)
                        .await?;
                        if fails.is_some_and(|fails| fails >= MAX_SUB_FAILS)
                        {
                            gone.push(sub.id);
                        }
                    }
                }
            }
            if !gone.is_empty()
            {
                sqlx::query!("DELETE FROM push_subs WHERE id = ANY($1)", &gone)
                    .execute(&a_state.db)
                    .await?;
                subs.retain(|sub| !gone.contains(&sub.id));
            }
            match (is_delivered, is_retry)
            {
                (true, _) => PushState::Sent,
                (false, true) if notice.push_tries < MAX_TRIES => PushState::Pending,
                (false, true) => PushState::Failed,
                (false, false) => PushState::Skipped,
            }
        };
        sqlx::query!(
            "UPDATE notifications SET push_state = $2 WHERE id = $1",
            notice.id,
            state as PushState
        )
        .execute(&a_state.db)
        .await?;
        if state == PushState::Sent
        {
            sent += 1;
        }
    }
    Ok(sent)
}

#[cfg(test)]
mod tests
{
    use super::*;

    fn hosts(a_list: &[&str]) -> Vec<String>
    {
        a_list.iter().map(|host| host.to_string()).collect()
    }

    #[test]
    fn endpoints_must_use_known_push_services()
    {
        let allowed = hosts(&["fcm.googleapis.com", "push.services.mozilla.com", "127.0.0.1"]);
        assert!(check_endpoint(&allowed, "https://fcm.googleapis.com/fcm/send/abc").is_ok());
        assert!(check_endpoint(&allowed, "https://updates.push.services.mozilla.com/wpush/v2/x").is_ok());
        assert!(check_endpoint(&allowed, "http://127.0.0.1:4000/push/1").is_ok());
        assert!(check_endpoint(&allowed, "http://fcm.googleapis.com/fcm/send/abc").is_err());
        assert!(check_endpoint(&allowed, "https://evil-fcm.googleapis.com.example.org/x").is_err());
        assert!(check_endpoint(&allowed, "https://notfcm.googleapis.com.evil/x").is_err());
        assert!(check_endpoint(&allowed, "https://user:pw@fcm.googleapis.com/x").is_err());
        assert!(check_endpoint(&hosts(&["fcm.googleapis.com"]), "http://127.0.0.1:4000/push").is_err());
        assert!(check_endpoint(&allowed, "http://10.0.0.1/push").is_err());
        assert!(check_endpoint(
            &allowed,
            &format!("https://fcm.googleapis.com/{}", "a".repeat(MAX_ENDPOINT_LEN))
        )
        .is_err());
    }
}
