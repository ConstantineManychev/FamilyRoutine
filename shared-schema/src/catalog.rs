use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::ItemOwnerKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "net_measure_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum NetMeasure
{
    G,
    Ml,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProductCatDto
{
    pub id: Uuid,
    pub parent_id: Option<Uuid>,
    pub code: Option<String>,
    pub name: String,
    pub depth: usize,
    pub item_count: i64,
    pub owner_kind: ItemOwnerKind,
    pub is_editable: bool,
    pub is_in_use: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProductCatTreeDto
{
    pub max_depth: usize,
    pub is_admin: bool,
    pub nodes: Vec<ProductCatDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveProductCatRequest
{
    pub name: String,
    #[serde(default)]
    pub parent_id: Option<Uuid>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MergeProductCatRequest
{
    pub target_id: Uuid,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct CatPriceQuery
{
    #[serde(default)]
    pub convert_to: Option<String>,
    #[serde(default)]
    pub days: Option<i64>,
    #[serde(default)]
    pub place_id: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CatPriceRowDto
{
    pub item_id: Uuid,
    pub item_name: String,
    pub cat_id: Option<Uuid>,
    pub measure: NetMeasure,
    pub curr_code: String,
    pub best_100: Decimal,
    pub best_store: Option<String>,
    pub best_branch: Option<String>,
    pub best_ts: DateTime<Utc>,
    pub last_100: Decimal,
    pub last_store: Option<String>,
    pub last_ts: DateTime<Utc>,
    pub count: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct CatItemRefDto
{
    pub id: Uuid,
    pub name: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct CatPricesDto
{
    pub rows: Vec<CatPriceRowDto>,
    pub unmeasured: Vec<CatItemRefDto>,
    pub missing_rates: bool,
}
