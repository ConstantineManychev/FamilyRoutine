use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "study_unit_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum StudyUnit
{
    Percent,
    Pages,
    Tasks,
    Lessons,
    Chapters,
    Hours,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct StudyProgressDto
{
    pub percent: Decimal,
    pub done: Option<Decimal>,
    pub target: Option<Decimal>,
    pub unit: Option<StudyUnit>,
    pub is_aggregated: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct StudyTopicDto
{
    pub id: Uuid,
    pub parent_id: Option<Uuid>,
    pub title: String,
    pub description: Option<String>,
    pub unit: StudyUnit,
    pub target: Decimal,
    pub done: Decimal,
    pub depth: usize,
    pub child_count: usize,
    pub note_count: i64,
    pub progress: StudyProgressDto,
    pub updated_ts: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct StudyTreeDto
{
    pub max_depth: usize,
    pub topics: Vec<StudyTopicDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveTopicRequest
{
    #[serde(default)]
    pub parent_id: Option<Uuid>,
    pub title: String,
    #[serde(default)]
    pub description: Option<String>,
    pub unit: StudyUnit,
    pub target: Decimal,
    pub done: Decimal,
}

#[derive(Debug, Clone, Serialize)]
pub struct StudyNoteDto
{
    pub id: Uuid,
    pub topic_id: Uuid,
    pub topic_path: Vec<String>,
    pub body: String,
    pub note_ts: DateTime<Utc>,
    pub created_ts: DateTime<Utc>,
    pub updated_ts: DateTime<Utc>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct StudyNotesQuery
{
    #[serde(default)]
    pub is_branch: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveNoteRequest
{
    pub body: String,
    #[serde(default)]
    pub note_ts: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct MarkStudyDto
{
    pub topics: Vec<StudyTopicDto>,
    pub notes: Vec<StudyNoteDto>,
}
