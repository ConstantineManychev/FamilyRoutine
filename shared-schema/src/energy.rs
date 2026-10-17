use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Deserialize)]
pub struct EnergyDayQuery
{
    pub date: NaiveDate,
    pub tz: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct EnergyPointDto
{
    pub ts: DateTime<Utc>,
    pub kcal: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct EnergyPersonDto
{
    pub person_id: Uuid,
    pub first_name: String,
    pub last_name: String,
    pub is_me: bool,
    pub is_managed: bool,
    pub can_edit: bool,
    pub daily_burn: Option<Decimal>,
    pub eaten: i64,
    pub burned_base: i64,
    pub burned_workouts: i64,
    pub balance: i64,
    pub points: Vec<EnergyPointDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct EnergyDayDto
{
    pub date: NaiveDate,
    pub day_start: DateTime<Utc>,
    pub day_end: DateTime<Utc>,
    pub people: Vec<EnergyPersonDto>,
}
