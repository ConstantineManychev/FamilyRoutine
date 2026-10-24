use chrono::{DateTime, NaiveDate, NaiveTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{MacrosDto, MealSource, QuickEntryRequest, RoutineStatus};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "plan_timing_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum PlanTiming
{
    Fixed,
    Window,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "plan_repeat_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum PlanRepeat
{
    #[default]
    Once,
    Daily,
    Weekly,
    Monthly,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "plan_state_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum PlanState
{
    Planned,
    Done,
    Skipped,
}

#[derive(Debug, Clone, Serialize)]
pub struct PlanEventDto
{
    pub id: Uuid,
    pub owner_id: Uuid,
    pub title: String,
    pub note: Option<String>,
    pub category: Option<RoutineStatus>,
    pub timing: PlanTiming,
    pub start_date: NaiveDate,
    pub start_time: NaiveTime,
    pub window_min: Option<i32>,
    pub duration_min: i32,
    pub tz: String,
    pub repeat: PlanRepeat,
    pub repeat_every: i32,
    pub weekday_mask: i32,
    pub until_date: Option<NaiveDate>,
    pub program_id: Option<Uuid>,
    pub program_name: Option<String>,
    pub day_id: Option<Uuid>,
    pub day_name: Option<String>,
    pub content: PlanContentDto,
}

#[derive(Debug, Clone, Serialize)]
pub struct PlanFoodDto
{
    pub id: Uuid,
    pub source: MealSource,
    pub item_id: Option<Uuid>,
    pub dish_id: Option<Uuid>,
    pub title: Option<String>,
    pub grams: Option<Decimal>,
    pub portions: Option<Decimal>,
    pub portion_g: Option<Decimal>,
    pub is_ml: bool,
    pub total: MacrosDto,
}

#[derive(Debug, Clone, Serialize)]
pub struct PlanTaskDto
{
    pub id: Uuid,
    pub title: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct PlanStudyDto
{
    pub id: Uuid,
    pub topic_id: Uuid,
    pub topic_title: String,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct PlanContentDto
{
    pub foods: Vec<PlanFoodDto>,
    pub total: MacrosDto,
    pub tasks: Vec<PlanTaskDto>,
    pub studies: Vec<PlanStudyDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PlanFoodInput
{
    #[serde(default)]
    pub item_id: Option<Uuid>,
    #[serde(default)]
    pub dish_id: Option<Uuid>,
    #[serde(default)]
    pub quick: Option<QuickEntryRequest>,
    #[serde(default)]
    pub grams: Option<Decimal>,
    #[serde(default)]
    pub portions: Option<Decimal>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PlanTaskInput
{
    pub title: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PlanStudyInput
{
    pub topic_id: Uuid,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct PlanContentInput
{
    #[serde(default)]
    pub foods: Vec<PlanFoodInput>,
    #[serde(default)]
    pub tasks: Vec<PlanTaskInput>,
    #[serde(default)]
    pub studies: Vec<PlanStudyInput>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveOccurrenceContentRequest
{
    #[serde(flatten)]
    pub content: PlanContentInput,
    #[serde(default)]
    pub day_id: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize)]
pub struct OccurrenceDetailsDto
{
    pub occurrence: OccurrenceDto,
    pub owner_id: Uuid,
    pub is_custom: bool,
    pub content: PlanContentDto,
    pub program_name: Option<String>,
    pub day_id: Option<Uuid>,
    pub day_name: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SavePlanEventRequest
{
    #[serde(default)]
    pub person_id: Option<Uuid>,
    pub title: String,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub category: Option<RoutineStatus>,
    pub timing: PlanTiming,
    pub start_date: NaiveDate,
    pub start_time: NaiveTime,
    #[serde(default)]
    pub window_min: Option<i32>,
    pub duration_min: i32,
    pub tz: String,
    #[serde(default)]
    pub repeat: PlanRepeat,
    #[serde(default = "default_every")]
    pub repeat_every: i32,
    #[serde(default)]
    pub weekday_mask: i32,
    #[serde(default)]
    pub until_date: Option<NaiveDate>,
    #[serde(default)]
    pub program_id: Option<Uuid>,
    #[serde(default)]
    pub day_id: Option<Uuid>,
    #[serde(default)]
    pub content: Option<PlanContentInput>,
}

fn default_every() -> i32
{
    1
}

#[derive(Debug, Clone, Deserialize)]
pub struct AgendaQuery
{
    #[serde(default)]
    pub person_id: Option<Uuid>,
    pub from: NaiveDate,
    pub to: NaiveDate,
    pub tz: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct OccurrenceRefDto
{
    pub event_id: Uuid,
    pub occ_date: NaiveDate,
    pub title: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct OverloadDto
{
    pub window_min: i32,
    pub busy_min: i32,
}

#[derive(Debug, Clone, Serialize)]
pub struct OccurrenceDto
{
    pub event_id: Uuid,
    pub occ_date: NaiveDate,
    pub date: NaiveDate,
    pub title: String,
    pub note: Option<String>,
    pub category: Option<RoutineStatus>,
    pub timing: PlanTiming,
    pub start_ts: DateTime<Utc>,
    pub end_ts: DateTime<Utc>,
    pub duration_min: i32,
    pub tz: String,
    pub repeat: PlanRepeat,
    pub state: PlanState,
    pub is_moved: bool,
    pub program_id: Option<Uuid>,
    pub day_name: Option<String>,
    pub session_id: Option<Uuid>,
    pub status_mark_id: Option<Uuid>,
    pub is_session_active: bool,
    pub conflicts: Vec<OccurrenceRefDto>,
    pub overload: Option<OverloadDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct AgendaDto
{
    pub occurrences: Vec<OccurrenceDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveOccurrenceRequest
{
    pub state: PlanState,
    #[serde(default)]
    pub moved_date: Option<NaiveDate>,
    #[serde(default)]
    pub moved_time: Option<NaiveTime>,
    #[serde(default)]
    pub moved_start: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct PlanSlotDto
{
    pub event_id: Uuid,
    pub occ_date: NaiveDate,
    pub title: String,
    pub timing: PlanTiming,
    pub start_ts: DateTime<Utc>,
    pub end_ts: DateTime<Utc>,
    pub duration_min: i32,
    pub day_name: Option<String>,
}
