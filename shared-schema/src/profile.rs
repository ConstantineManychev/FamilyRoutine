use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "sex_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum Sex
{
    Male,
    Female,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "activity_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ActivityLevel
{
    Sedentary,
    Light,
    Moderate,
    Active,
    VeryActive,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "body_metric_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum BodyMetric
{
    Height,
    Weight,
    BodyFat,
    MuscleMass,
    SkeletalMuscle,
    BoneMass,
    BodyWater,
    Protein,
    VisceralFat,
    Neck,
    Chest,
    Waist,
    Hips,
    BicepsLeft,
    BicepsRight,
    ForearmLeft,
    ForearmRight,
    ThighLeft,
    ThighRight,
    CalfLeft,
    CalfRight,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MetricGroup
{
    Body,
    Composition,
    Measures,
}

impl BodyMetric
{
    pub fn group(self) -> MetricGroup
    {
        match self
        {
            BodyMetric::Height | BodyMetric::Weight => MetricGroup::Body,
            BodyMetric::BodyFat
            | BodyMetric::MuscleMass
            | BodyMetric::SkeletalMuscle
            | BodyMetric::BoneMass
            | BodyMetric::BodyWater
            | BodyMetric::Protein
            | BodyMetric::VisceralFat => MetricGroup::Composition,
            _ => MetricGroup::Measures,
        }
    }

    pub fn range(self) -> (Decimal, Decimal)
    {
        let (min, max) = match self
        {
            BodyMetric::Height => (30, 250),
            BodyMetric::Weight => (1, 350),
            BodyMetric::BodyFat => (2, 75),
            BodyMetric::MuscleMass => (1, 150),
            BodyMetric::SkeletalMuscle => (1, 100),
            BodyMetric::BoneMass => (0, 10),
            BodyMetric::BodyWater => (20, 85),
            BodyMetric::Protein => (5, 30),
            BodyMetric::VisceralFat => (1, 60),
            _ => (5, 250),
        };
        let min = if self == BodyMetric::BoneMass
        {
            Decimal::new(2, 1)
        }
        else
        {
            Decimal::from(min)
        };
        (min, Decimal::from(max))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "body_source_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum BodySource
{
    Manual,
    Import,
}

#[derive(Debug, Clone, Serialize)]
pub struct MetricValueDto
{
    pub metric: BodyMetric,
    pub value: Decimal,
    pub measured_ts: DateTime<Utc>,
    pub prev_value: Option<Decimal>,
    pub prev_ts: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProfileSharingDto
{
    pub family_id: Uuid,
    pub family_name: String,
    pub is_body_shared: bool,
    pub is_composition_shared: bool,
    pub is_measures_shared: bool,
    pub is_training_shared: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProfileDto
{
    pub id: Uuid,
    pub first_name: String,
    pub last_name: String,
    pub email: Option<String>,
    pub birth_date: Option<NaiveDate>,
    pub age: Option<i32>,
    pub sex: Option<Sex>,
    pub activity: Option<ActivityLevel>,
    pub is_self: bool,
    pub is_managed: bool,
    pub can_edit: bool,
    pub visible_groups: Vec<MetricGroup>,
    pub is_training_visible: bool,
    pub latest: Vec<MetricValueDto>,
    pub sharing: Vec<ProfileSharingDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct UpdateProfileRequest
{
    pub first_name: String,
    pub last_name: String,
    pub birth_date: NaiveDate,
    #[serde(default)]
    pub sex: Option<Sex>,
    #[serde(default)]
    pub activity: Option<ActivityLevel>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ChangePasswordRequest
{
    pub current_password: String,
    pub new_password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BodyValueDto
{
    pub metric: BodyMetric,
    pub value: Decimal,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveBodyEntryRequest
{
    pub measured_ts: DateTime<Utc>,
    #[serde(default)]
    pub note: Option<String>,
    pub values: Vec<BodyValueDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct BodyEntryDto
{
    pub id: Uuid,
    pub measured_ts: DateTime<Utc>,
    pub source: BodySource,
    pub note: Option<String>,
    pub values: Vec<BodyValueDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct MetricPointDto
{
    pub entry_id: Uuid,
    pub measured_ts: DateTime<Utc>,
    pub value: Decimal,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateChildRequest
{
    pub first_name: String,
    pub last_name: String,
    pub birth_date: NaiveDate,
    pub sex: Sex,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ProfileSharingRequest
{
    pub is_body_shared: bool,
    pub is_composition_shared: bool,
    pub is_measures_shared: bool,
    #[serde(default)]
    pub is_training_shared: Option<bool>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct EntriesQuery
{
    #[serde(default)]
    pub before: Option<DateTime<Utc>>,
    #[serde(default)]
    pub limit: Option<i64>,
}
