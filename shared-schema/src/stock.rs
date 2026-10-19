use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::MacrosDto;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "stock_measure_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum StockMeasure
{
    G,
    Ml,
    Pcs,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "stock_kind_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum StockKind
{
    Item,
    Dish,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "stock_source_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum StockSource
{
    Receipt,
    Manual,
    Cooked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "stock_move_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum StockMoveKind
{
    Eaten,
    Cooked,
    Waste,
    Used,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "waste_reason_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum WasteReason
{
    Spoiled,
    Leftovers,
    Other,
    Expired,
}

#[derive(Debug, Clone, Serialize)]
pub struct StockStoreDto
{
    pub family_id: Option<Uuid>,
    pub family_name: Option<String>,
    pub is_active: bool,
    pub lot_count: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct StockSettingsDto
{
    pub active_family_id: Option<Uuid>,
    pub stores: Vec<StockStoreDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveStockSettingsRequest
{
    #[serde(default)]
    pub family_id: Option<Uuid>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct StockQuery
{
    #[serde(default)]
    pub family_id: Option<Uuid>,
    #[serde(default)]
    pub is_personal: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct StockLotDto
{
    pub id: Uuid,
    pub kind: StockKind,
    pub item_id: Option<Uuid>,
    pub dish_id: Option<Uuid>,
    pub batch_id: Option<Uuid>,
    pub title: String,
    pub measure: StockMeasure,
    pub qty: Decimal,
    pub left_qty: Decimal,
    pub cost: Option<Decimal>,
    pub left_cost: Option<Decimal>,
    pub curr_code: Option<String>,
    pub source: StockSource,
    pub receipt_id: Option<Uuid>,
    pub acquired_ts: DateTime<Utc>,
    pub is_touched: bool,
    pub piece_g: Option<Decimal>,
    pub pack_size: Option<Decimal>,
    pub per_100: Option<MacrosDto>,
    pub expires_on: Option<NaiveDate>,
    pub is_expired: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct StockDto
{
    pub family_id: Option<Uuid>,
    pub family_name: Option<String>,
    pub is_active: bool,
    pub lots: Vec<StockLotDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NewStockLotRequest
{
    #[serde(default)]
    pub family_id: Option<Uuid>,
    #[serde(default)]
    pub is_personal: bool,
    pub item_id: Uuid,
    pub qty: Decimal,
    pub unit: StockMeasure,
    #[serde(default)]
    pub cost: Option<Decimal>,
    #[serde(default)]
    pub curr_id: Option<Uuid>,
    #[serde(default)]
    pub acquired_on: Option<NaiveDate>,
    #[serde(default)]
    pub expires_on: Option<NaiveDate>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SetLotExpiryRequest
{
    #[serde(default)]
    pub expires_on: Option<NaiveDate>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WasteRequest
{
    pub qty: Decimal,
    #[serde(default)]
    pub unit: Option<StockMeasure>,
    #[serde(default)]
    pub reason: Option<WasteReason>,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WriteOffRequest
{
    #[serde(default)]
    pub family_id: Option<Uuid>,
    #[serde(default)]
    pub is_personal: bool,
    pub item_id: Uuid,
    pub qty: Decimal,
    #[serde(default)]
    pub unit: Option<StockMeasure>,
    #[serde(default)]
    pub reason: Option<WasteReason>,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
pub struct StockStoreChoice
{
    #[serde(default)]
    pub family_id: Option<Uuid>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CookIngredientRequest
{
    pub item_id: Uuid,
    pub grams: Decimal,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CookRequest
{
    #[serde(default)]
    pub family_id: Option<Uuid>,
    #[serde(default)]
    pub is_personal: bool,
    pub dish_id: Uuid,
    pub cooked_g: Decimal,
    pub ingredients: Vec<CookIngredientRequest>,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub expires_on: Option<NaiveDate>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CookBatchItemDto
{
    pub item_id: Option<Uuid>,
    pub item_name: String,
    pub grams: Decimal,
    pub short_g: Decimal,
}

#[derive(Debug, Clone, Serialize)]
pub struct CookBatchDto
{
    pub id: Uuid,
    pub lot_id: Uuid,
    pub dish_id: Option<Uuid>,
    pub family_id: Option<Uuid>,
    pub title: String,
    pub cooked_ts: DateTime<Utc>,
    pub raw_g: Decimal,
    pub cooked_g: Decimal,
    pub left_g: Decimal,
    pub per_100: MacrosDto,
    pub missing_count: i32,
    pub cost: Option<Decimal>,
    pub curr_code: Option<String>,
    pub note: Option<String>,
    pub expires_on: Option<NaiveDate>,
    pub ingredients: Vec<CookBatchItemDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct BatchQuery
{
    pub dish_id: Uuid,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct StockMovesQuery
{
    #[serde(default)]
    pub family_id: Option<Uuid>,
    #[serde(default)]
    pub is_personal: bool,
    #[serde(default)]
    pub kind: Option<StockMoveKind>,
    #[serde(default)]
    pub from: Option<DateTime<Utc>>,
    #[serde(default)]
    pub to: Option<DateTime<Utc>>,
    #[serde(default)]
    pub limit: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct StockMoveDto
{
    pub id: Uuid,
    pub kind: StockMoveKind,
    pub lot_id: Uuid,
    pub title: String,
    pub measure: StockMeasure,
    pub qty: Decimal,
    pub cost: Option<Decimal>,
    pub curr_code: Option<String>,
    pub reason: Option<WasteReason>,
    pub note: Option<String>,
    pub actor_name: Option<String>,
    pub created_ts: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct MoneyTotalDto
{
    pub curr_code: String,
    pub amount: Decimal,
}

#[derive(Debug, Clone, Serialize)]
pub struct StockMovesDto
{
    pub moves: Vec<StockMoveDto>,
    pub waste_g: Decimal,
    pub waste_ml: Decimal,
    pub waste_pcs: Decimal,
    pub waste_costs: Vec<MoneyTotalDto>,
}
