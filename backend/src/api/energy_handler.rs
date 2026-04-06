use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use ts_rs::TS;

#[derive(Debug, Serialize, Deserialize, Clone, TS)]
#[ts(export, export_to = "../bindings/EnergyEventType.ts")]
pub enum EnergyEventType {
    BmrBase,
    Meal,
    Workout,
}

#[derive(Debug, Serialize, Deserialize, Clone, TS)]
#[ts(export, export_to = "../bindings/EnergyNodeDto.ts")]
pub struct EnergyNodeDto {
    #[ts(type = "string")]
    pub ts: DateTime<Utc>,
    pub event_type: EnergyEventType,
    pub val: f64,
    pub cum_val: f64,
}

#[derive(Deserialize)]
pub struct EnergyGraphReq {
    pub target_date: NaiveDate,
}