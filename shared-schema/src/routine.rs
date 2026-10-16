use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{MacrosDto, MealEntryDto, SessionDto};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "curr_status_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum RoutineStatus
{
    Home,
    Work,
    School,
    Gym,
    Transit,
    Sleep,
    Meal,
    Leisure,
    Other,
}

#[derive(Debug, Clone, Serialize)]
pub struct StatusMarkDto
{
    pub id: Uuid,
    pub status: RoutineStatus,
    pub note: Option<String>,
    pub start_ts: DateTime<Utc>,
    pub end_ts: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateMarkRequest
{
    pub status: RoutineStatus,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub start_ts: Option<DateTime<Utc>>,
    #[serde(default)]
    pub end_ts: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct UpdateMarkRequest
{
    pub status: RoutineStatus,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub start_ts: Option<DateTime<Utc>>,
    #[serde(default)]
    pub end_ts: Option<DateTime<Utc>>,
    #[serde(default)]
    pub is_open_end: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct MarkMealsDto
{
    pub total: MacrosDto,
    pub entries: Vec<MealEntryDto>,
    pub day_norm: Option<MacrosDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct MarkDetailsDto
{
    pub mark: StatusMarkDto,
    pub owner_id: Uuid,
    pub owner_name: String,
    pub is_mine: bool,
    pub is_details_hidden: bool,
    pub workout: Option<SessionDto>,
    pub meals: Option<MarkMealsDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LinkMarkMealsRequest
{
    pub entry_ids: Vec<Uuid>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TimelineQuery
{
    #[serde(default)]
    pub family_id: Option<Uuid>,
    pub from: DateTime<Utc>,
    pub to: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TimelineMemberDto
{
    pub user_id: Uuid,
    pub first_name: String,
    pub last_name: String,
    pub is_me: bool,
    pub marks: Vec<StatusMarkDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TimelineDto
{
    pub family_id: Option<Uuid>,
    pub family_name: Option<String>,
    pub members: Vec<TimelineMemberDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SharingRequest
{
    pub is_shared: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "widget_kind_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum WidgetKind
{
    MyStatus,
    FamilyTimeline,
    Cashflow,
    FamilyList,
    NextWorkout,
}

#[derive(Debug, Clone, Serialize)]
pub struct WidgetDto
{
    pub id: Uuid,
    pub kind: WidgetKind,
    pub family_id: Option<Uuid>,
    pub family_name: Option<String>,
    pub is_available: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct DashboardDto
{
    pub id: Uuid,
    pub name: String,
    pub widgets: Vec<WidgetDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveDashboardRequest
{
    pub name: String,
    #[serde(default)]
    pub is_prefilled: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateWidgetRequest
{
    pub kind: WidgetKind,
    #[serde(default)]
    pub family_id: Option<Uuid>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ReorderWidgetsRequest
{
    pub widget_ids: Vec<Uuid>,
}
