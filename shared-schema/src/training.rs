use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::ExType;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "schedule_mode_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ScheduleMode
{
    Queue,
    Intervals,
    Weekdays,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProgramExerciseDto
{
    pub ex_id: Uuid,
    pub sets: i32,
    #[serde(default)]
    pub reps_min: Option<i32>,
    #[serde(default)]
    pub reps_max: Option<i32>,
    #[serde(default)]
    pub duration_sec: Option<i32>,
    #[serde(default)]
    pub weight_kg: Option<Decimal>,
    #[serde(default)]
    pub rest_sec: Option<i32>,
    #[serde(default)]
    pub weight_step: Option<Decimal>,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProgramDayDto
{
    #[serde(default)]
    pub id: Option<Uuid>,
    pub name: String,
    #[serde(default = "default_rest_days")]
    pub rest_days_after: i32,
    #[serde(default)]
    pub weekdays: Vec<u32>,
    #[serde(default)]
    pub exercises: Vec<ProgramExerciseDto>,
}

fn default_rest_days() -> i32
{
    1
}

#[derive(Debug, Clone, Serialize)]
pub struct ProgramDto
{
    pub id: Uuid,
    pub name: String,
    pub schedule_mode: ScheduleMode,
    pub is_active: bool,
    pub days: Vec<ProgramDayDto>,
    pub created_ts: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProgramListItemDto
{
    pub id: Uuid,
    pub name: String,
    pub schedule_mode: ScheduleMode,
    pub is_active: bool,
    pub day_count: i64,
    pub updated_ts: DateTime<Utc>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveProgramRequest
{
    pub name: String,
    pub schedule_mode: ScheduleMode,
    pub days: Vec<ProgramDayDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct PlannedWorkoutDto
{
    pub day_id: Uuid,
    pub day_name: String,
    pub date: Option<NaiveDate>,
    pub is_overdue: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionSummaryDto
{
    pub id: Uuid,
    pub program_name: Option<String>,
    pub day_name: Option<String>,
    pub started_ts: DateTime<Utc>,
    pub finished_ts: Option<DateTime<Utc>>,
    pub kcal: Option<Decimal>,
    pub done_sets: i64,
    pub volume_kg: Decimal,
}

#[derive(Debug, Clone, Serialize)]
pub struct PersonTrainingDto
{
    pub plan: TrainingPlanDto,
    pub program: Option<ProgramDto>,
    pub sessions: Vec<SessionSummaryDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TrainingPlanDto
{
    pub program: Option<ProgramListItemDto>,
    pub upcoming: Vec<PlannedWorkoutDto>,
    pub active_session_id: Option<Uuid>,
    pub last_session: Option<SessionSummaryDto>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct PlanQuery
{
    #[serde(default)]
    pub tz_offset_min: i32,
    #[serde(default)]
    pub days: Option<i64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SetTodayRequest
{
    pub day_id: Uuid,
    pub date: NaiveDate,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StartSessionRequest
{
    #[serde(default)]
    pub day_id: Option<Uuid>,
    #[serde(default)]
    pub started_ts: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSetDto
{
    #[serde(default)]
    pub reps: Option<i32>,
    #[serde(default)]
    pub weight_kg: Option<Decimal>,
    #[serde(default)]
    pub duration_sec: Option<i32>,
    #[serde(default)]
    pub is_done: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionExerciseDto
{
    pub ex_id: Uuid,
    pub ex_code: Option<String>,
    pub ex_name: String,
    pub ex_type: ExType,
    pub reps_min: Option<i32>,
    pub reps_max: Option<i32>,
    pub duration_sec: Option<i32>,
    pub target_weight: Option<Decimal>,
    pub rest_sec: Option<i32>,
    pub sets: Vec<SessionSetDto>,
    pub previous: Vec<SessionSetDto>,
    pub previous_ts: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionDto
{
    pub id: Uuid,
    pub program_id: Option<Uuid>,
    pub program_name: Option<String>,
    pub day_id: Option<Uuid>,
    pub day_name: Option<String>,
    pub started_ts: DateTime<Utc>,
    pub finished_ts: Option<DateTime<Utc>>,
    pub intensity: Option<i32>,
    pub kcal: Option<Decimal>,
    pub note: Option<String>,
    pub exercises: Vec<SessionExerciseDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveSessionExercise
{
    pub ex_id: Uuid,
    #[serde(default)]
    pub reps_min: Option<i32>,
    #[serde(default)]
    pub reps_max: Option<i32>,
    #[serde(default)]
    pub duration_sec: Option<i32>,
    #[serde(default)]
    pub target_weight: Option<Decimal>,
    #[serde(default)]
    pub rest_sec: Option<i32>,
    #[serde(default)]
    pub sets: Vec<SessionSetDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveSessionRequest
{
    #[serde(default)]
    pub note: Option<String>,
    pub exercises: Vec<SaveSessionExercise>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct FinishSessionRequest
{
    #[serde(default)]
    pub finished_ts: Option<DateTime<Utc>>,
    pub intensity: i32,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SessionsQuery
{
    #[serde(default)]
    pub limit: Option<i64>,
}
