use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "notify_kind_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum NotifyKind
{
    Plan,
    Workout,
    Expiring,
    Expired,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "push_state_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum PushState
{
    Pending,
    Sending,
    Sent,
    Skipped,
    Failed,
}

#[derive(Debug, Clone, Serialize)]
pub struct NotifySettingsDto
{
    pub tz: String,
    pub lang: String,
    pub is_plan: bool,
    pub plan_lead_min: i32,
    pub is_workout: bool,
    pub workout_lead_min: i32,
    pub is_expiring: bool,
    pub is_expired: bool,
    pub is_web_push: bool,
    pub push_subs: i64,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SaveNotifySettingsRequest
{
    #[serde(default)]
    pub tz: Option<String>,
    #[serde(default)]
    pub lang: Option<String>,
    #[serde(default)]
    pub is_plan: Option<bool>,
    #[serde(default)]
    pub plan_lead_min: Option<i32>,
    #[serde(default)]
    pub is_workout: Option<bool>,
    #[serde(default)]
    pub workout_lead_min: Option<i32>,
    #[serde(default)]
    pub is_expiring: Option<bool>,
    #[serde(default)]
    pub is_expired: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
pub struct NotificationDto
{
    pub id: Uuid,
    pub kind: NotifyKind,
    pub title: String,
    pub body: String,
    pub link: String,
    pub params: serde_json::Value,
    pub created_ts: DateTime<Utc>,
    pub is_read: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct NotificationsDto
{
    pub items: Vec<NotificationDto>,
    pub unread: i64,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct NotificationsQuery
{
    #[serde(default)]
    pub limit: Option<i64>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct MarkReadRequest
{
    #[serde(default)]
    pub ids: Vec<Uuid>,
    #[serde(default)]
    pub is_all: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct PushKeyDto
{
    pub public_key: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PushSubRequest
{
    pub endpoint: String,
    pub p256dh: String,
    pub auth: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PushUnsubRequest
{
    pub endpoint: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct UpcomingQuery
{
    #[serde(default)]
    pub hours: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct UpcomingNotifyDto
{
    pub key: String,
    pub kind: NotifyKind,
    pub due_ts: DateTime<Utc>,
    pub title: String,
    pub body: String,
    pub link: String,
    pub params: serde_json::Value,
}
