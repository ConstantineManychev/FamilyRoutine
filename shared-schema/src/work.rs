use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "task_kind_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum TaskKind
{
    General,
    Day,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "task_event_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum TaskEventKind
{
    Created,
    Edited,
    Progress,
    Done,
    Reopened,
    Deleted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "task_field_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum TaskField
{
    Title,
    Note,
    Kind,
    Date,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskAction
{
    Progress,
    Done,
    Reopen,
}

#[derive(Debug, Clone, Serialize)]
pub struct WorkTaskDto
{
    pub id: Uuid,
    pub kind: TaskKind,
    pub title: String,
    pub note: Option<String>,
    pub start_on: NaiveDate,
    pub done_on: Option<NaiveDate>,
    pub done_ts: Option<DateTime<Utc>>,
    pub deleted_ts: Option<DateTime<Utc>>,
    pub created_ts: DateTime<Utc>,
    pub updated_ts: DateTime<Utc>,
    pub last_report: Option<String>,
    pub last_report_ts: Option<DateTime<Utc>>,
    pub report_count: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct TaskEventDto
{
    pub id: Uuid,
    pub kind: TaskEventKind,
    pub field: Option<TaskField>,
    pub old_value: Option<String>,
    pub new_value: Option<String>,
    pub report: Option<String>,
    pub event_on: NaiveDate,
    pub event_ts: DateTime<Utc>,
    pub status_mark_id: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize)]
pub struct WorkDayDto
{
    pub date: NaiveDate,
    pub general: Vec<WorkTaskDto>,
    pub day: Vec<WorkTaskDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct WorkTaskDetailsDto
{
    pub task: WorkTaskDto,
    pub events: Vec<TaskEventDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WorkDayQuery
{
    pub date: NaiveDate,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveTaskRequest
{
    pub kind: TaskKind,
    pub title: String,
    #[serde(default)]
    pub note: Option<String>,
    pub date: NaiveDate,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TaskLogRequest
{
    pub action: TaskAction,
    #[serde(default)]
    pub report: Option<String>,
    pub date: NaiveDate,
    #[serde(default)]
    pub status_mark_id: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize)]
pub struct BlockLogDto
{
    pub task_id: Uuid,
    pub task_title: String,
    pub kind: TaskEventKind,
    pub report: Option<String>,
    pub event_ts: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct MarkWorkDto
{
    pub date: NaiveDate,
    pub general: Vec<WorkTaskDto>,
    pub day: Vec<WorkTaskDto>,
    pub logged: Vec<BlockLogDto>,
}
