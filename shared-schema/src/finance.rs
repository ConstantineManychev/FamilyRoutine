use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "bank_provider_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum BankProvider
{
    Monobank,
    EnableBanking,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "bank_conn_status_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum BankConnStatus
{
    Pending,
    Active,
    Error,
    Expired,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "tx_source_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum TxSource
{
    Manual,
    Bank,
    ReceiptCash,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "tx_type_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum TxType
{
    Income,
    Expense,
    Transfer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "tx_cat_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum TxCategory
{
    Groceries,
    Restaurants,
    Transport,
    Fuel,
    Shopping,
    Health,
    Utilities,
    Entertainment,
    Travel,
    Education,
    Home,
    Cash,
    Transfer,
    Fees,
    Income,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "item_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ItemKind
{
    Product,
    Service,
    Food,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "item_unit_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ItemUnit
{
    Piece,
    Kilogram,
    Liter,
    Meter,
    SquareMeter,
    Hour,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FlowMode
{
    #[default]
    Net,
    Turnover,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StatsBucket
{
    Hour,
    Day,
}

#[derive(Debug, Clone, Serialize)]
pub struct BankConnDto
{
    pub id: Uuid,
    pub provider: BankProvider,
    pub aspsp_name: Option<String>,
    pub status: BankConnStatus,
    pub valid_until: Option<DateTime<Utc>>,
    pub last_sync_ts: Option<DateTime<Utc>>,
    pub next_sync_ts: Option<DateTime<Utc>>,
    pub last_error: Option<String>,
    pub account_count: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ConnectMonobankRequest
{
    pub token: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StartBankAuthRequest
{
    pub aspsp_name: String,
    pub aspsp_country: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct StartBankAuthResponse
{
    pub url: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CompleteBankAuthRequest
{
    pub code: String,
    pub state: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AspspQuery
{
    pub country: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AspspDto
{
    pub name: String,
    pub country: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct TxDto
{
    pub id: Uuid,
    pub account_id: Uuid,
    pub account_name: String,
    pub curr_code: String,
    pub amount: Decimal,
    pub op_amount: Option<Decimal>,
    pub op_curr_code: Option<String>,
    pub tx_ts: DateTime<Utc>,
    pub tx_type: TxType,
    pub source: TxSource,
    pub description: Option<String>,
    pub counterparty: Option<String>,
    pub category: Option<TxCategory>,
    pub merchant_id: Option<Uuid>,
    pub merchant_name: Option<String>,
    pub mcc: Option<i16>,
    pub note: Option<String>,
    pub is_pending: bool,
    pub transfer_id: Option<Uuid>,
    pub receipt_id: Option<Uuid>,
    pub is_editable: bool,
    pub is_auto_transfer: bool,
    pub peer_account_name: Option<String>,
    pub peer_amount: Option<Decimal>,
    pub peer_curr_code: Option<String>,
    pub similar_key: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TxPageDto
{
    pub items: Vec<TxDto>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct TxQuery
{
    #[serde(default)]
    pub account_id: Option<Uuid>,
    #[serde(default)]
    pub from: Option<DateTime<Utc>>,
    #[serde(default)]
    pub to: Option<DateTime<Utc>>,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub limit: Option<i64>,
    #[serde(default)]
    pub is_unlinked: Option<bool>,
    #[serde(default)]
    pub q: Option<String>,
    #[serde(default)]
    pub category: Option<TxCategory>,
    #[serde(default)]
    pub is_uncategorized: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateTxRequest
{
    pub account_id: Uuid,
    pub amount: Decimal,
    pub tx_ts: DateTime<Utc>,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub category: Option<TxCategory>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct UpdateTxRequest
{
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub category: Option<TxCategory>,
    #[serde(default)]
    pub is_apply_to_similar: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateTransferRequest
{
    pub from_account_id: Uuid,
    pub to_account_id: Uuid,
    #[serde(default)]
    pub amount: Option<Decimal>,
    #[serde(default)]
    pub to_amount: Option<Decimal>,
    pub tx_ts: DateTime<Utc>,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub from_tx_id: Option<Uuid>,
    #[serde(default)]
    pub to_tx_id: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TransferDto
{
    pub transfer_id: Uuid,
    pub txs: Vec<TxDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ReceiptItemDto
{
    pub item_id: Uuid,
    pub name: String,
    pub kind: ItemKind,
    pub unit: ItemUnit,
    pub qty: Decimal,
    pub unit_price: Option<Decimal>,
    pub amount: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NewItemRequest
{
    pub name: String,
    pub kind: ItemKind,
    pub unit: ItemUnit,
    #[serde(default)]
    pub barcode: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct NewPlaceRequest
{
    #[serde(default)]
    pub place_id: Option<Uuid>,
    pub name: String,
    #[serde(default)]
    pub country_code: Option<String>,
    #[serde(default)]
    pub city: Option<String>,
    #[serde(default)]
    pub street: Option<String>,
    #[serde(default)]
    pub house_num: Option<String>,
    #[serde(default)]
    pub zip: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveReceiptItemRequest
{
    #[serde(default)]
    pub item_id: Option<Uuid>,
    #[serde(default)]
    pub new_item: Option<NewItemRequest>,
    #[serde(default)]
    pub source_text: Option<String>,
    #[serde(default = "default_qty")]
    pub qty: Decimal,
    #[serde(default)]
    pub unit_price: Option<Decimal>,
    pub amount: Decimal,
}

fn default_qty() -> Decimal
{
    Decimal::ONE
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveReceiptRequest
{
    pub receipt_ts: DateTime<Utc>,
    #[serde(default)]
    pub merchant_name: Option<String>,
    #[serde(default)]
    pub merchant_id: Option<Uuid>,
    #[serde(default)]
    pub place_id: Option<Uuid>,
    #[serde(default)]
    pub place_addr_id: Option<Uuid>,
    pub curr_id: Uuid,
    #[serde(default)]
    pub cash_account_id: Option<Uuid>,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub items: Vec<SaveReceiptItemRequest>,
    #[serde(default)]
    pub tx_ids: Vec<Uuid>,
    #[serde(default)]
    pub new_place: Option<NewPlaceRequest>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RecognizeReceiptRequest
{
    pub image: String,
    pub media_type: String,
    #[serde(default)]
    pub tz_offset_min: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LineMatch
{
    Barcode,
    Alias,
    Name,
    Similar,
    New,
}

#[derive(Debug, Clone, Serialize)]
pub struct RecognizedLineDto
{
    pub text: String,
    pub name: String,
    pub kind: ItemKind,
    pub unit: ItemUnit,
    pub qty: Decimal,
    pub unit_price: Option<Decimal>,
    pub amount: Decimal,
    pub barcode: Option<String>,
    pub item_id: Option<Uuid>,
    pub item_name: Option<String>,
    pub match_kind: LineMatch,
}

#[derive(Debug, Clone, Serialize)]
pub struct RecognizedReceiptDto
{
    pub receipt_ts: Option<DateTime<Utc>>,
    pub curr_id: Option<Uuid>,
    pub curr_code: Option<String>,
    pub total: Option<Decimal>,
    pub lines_total: Decimal,
    pub store_name: Option<String>,
    pub place_id: Option<Uuid>,
    pub place_name: Option<String>,
    pub place_addr_id: Option<Uuid>,
    pub new_place: Option<NewPlaceRequest>,
    pub lines: Vec<RecognizedLineDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct FeaturesDto
{
    pub is_receipt_recognition: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct ReceiptDto
{
    pub id: Uuid,
    pub receipt_ts: DateTime<Utc>,
    pub merchant_id: Option<Uuid>,
    pub merchant_name: Option<String>,
    pub place_id: Option<Uuid>,
    pub place_name: Option<String>,
    pub place_addr_id: Option<Uuid>,
    pub branch: Option<String>,
    pub curr_id: Uuid,
    pub curr_code: String,
    pub cash_account_id: Option<Uuid>,
    pub note: Option<String>,
    pub items: Vec<ReceiptItemDto>,
    pub txs: Vec<TxDto>,
    pub items_total: Decimal,
    pub paid_total: Decimal,
    pub rest_amount: Decimal,
    pub cash_amount: Decimal,
}

#[derive(Debug, Clone, Serialize)]
pub struct ReceiptListItemDto
{
    pub id: Uuid,
    pub receipt_ts: DateTime<Utc>,
    pub merchant_name: Option<String>,
    pub place_name: Option<String>,
    pub curr_code: String,
    pub items_total: Decimal,
    pub item_count: i64,
    pub tx_count: i64,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct ReceiptQuery
{
    #[serde(default)]
    pub from: Option<DateTime<Utc>>,
    #[serde(default)]
    pub to: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CashflowQuery
{
    pub from: DateTime<Utc>,
    pub to: DateTime<Utc>,
    pub bucket: StatsBucket,
    #[serde(default)]
    pub tz_offset_min: i32,
    #[serde(default)]
    pub account_id: Option<Uuid>,
    #[serde(default)]
    pub mode: FlowMode,
    #[serde(default)]
    pub convert_to: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CashflowPointDto
{
    pub ts: DateTime<Utc>,
    pub income: Decimal,
    pub expense: Decimal,
}

#[derive(Debug, Clone, Serialize)]
pub struct CashflowSeriesDto
{
    pub curr_code: String,
    pub income_total: Decimal,
    pub expense_total: Decimal,
    pub points: Vec<CashflowPointDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CashflowDto
{
    pub bucket: StatsBucket,
    pub series: Vec<CashflowSeriesDto>,
    pub missing_rates: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CategoryQuery
{
    pub from: DateTime<Utc>,
    pub to: DateTime<Utc>,
    #[serde(default)]
    pub tz_offset_min: i32,
    #[serde(default)]
    pub account_id: Option<Uuid>,
    #[serde(default)]
    pub mode: FlowMode,
    #[serde(default)]
    pub convert_to: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CategoryAmountDto
{
    pub category: Option<TxCategory>,
    pub income: Decimal,
    pub expense: Decimal,
    pub tx_count: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct CategorySeriesDto
{
    pub curr_code: String,
    pub income_total: Decimal,
    pub expense_total: Decimal,
    pub items: Vec<CategoryAmountDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CategoryStatsDto
{
    pub series: Vec<CategorySeriesDto>,
    pub missing_rates: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MerchantQuery
{
    #[serde(default)]
    pub q: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct MerchantDto
{
    pub id: Uuid,
    pub name: String,
    pub mcc: Option<i16>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DictItemDto
{
    pub id: Uuid,
    pub name: String,
    pub kind: ItemKind,
    pub unit: ItemUnit,
    pub barcode: Option<String>,
    pub is_custom: bool,
    pub family_id: Option<Uuid>,
    pub family_name: Option<String>,
    pub is_editable: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveItemRequest
{
    pub name: String,
    pub kind: ItemKind,
    pub unit: ItemUnit,
    #[serde(default)]
    pub barcode: Option<String>,
    #[serde(default)]
    pub family_id: Option<Uuid>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ItemQuery
{
    #[serde(default)]
    pub q: Option<String>,
    #[serde(default)]
    pub barcode: Option<String>,
    #[serde(default)]
    pub limit: Option<i64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ShareToFamilyRequest
{
    pub family_id: Uuid,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MergeItemRequest
{
    pub target_id: Uuid,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct ItemPriceQuery
{
    #[serde(default)]
    pub convert_to: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ItemPriceDto
{
    pub store_name: Option<String>,
    pub branch: Option<String>,
    pub curr_code: String,
    pub last_price: Decimal,
    pub min_price: Decimal,
    pub avg_price: Decimal,
    pub count: i64,
    pub last_ts: DateTime<Utc>,
    pub is_shared: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct ItemPricesDto
{
    pub prices: Vec<ItemPriceDto>,
    pub missing_rates: Vec<String>,
    pub matched_items: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ManualPriceDto
{
    pub id: Uuid,
    pub place_id: Option<Uuid>,
    pub place_addr_id: Option<Uuid>,
    pub store_name: Option<String>,
    pub branch: Option<String>,
    pub curr_code: String,
    pub qty: Decimal,
    pub price: Decimal,
    pub seen_ts: DateTime<Utc>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveManualPriceRequest
{
    #[serde(default)]
    pub place_id: Option<Uuid>,
    #[serde(default)]
    pub place_addr_id: Option<Uuid>,
    #[serde(default)]
    pub merchant_name: Option<String>,
    pub curr_id: Uuid,
    #[serde(default = "default_qty")]
    pub qty: Decimal,
    pub price: Decimal,
    #[serde(default)]
    pub seen_ts: Option<DateTime<Utc>>,
    #[serde(default)]
    pub note: Option<String>,
}
