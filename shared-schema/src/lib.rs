use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use ts_rs::TS;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, TS)]
#[ts(export, export_to = "../bindings/FamilyResponse.ts")]
pub struct FamilyResponse {
    pub id: Uuid,
    pub name: String,
    pub country: Option<String>,
    pub region: Option<String>,
    pub city: Option<String>,
    pub street: Option<String>,
    pub building: Option<String>,
    pub apartment: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, TS)]
#[ts(export, export_to = "../bindings/UserResponse.ts")]
pub struct UserResponse {
    pub id: Uuid,
    pub username: String,
    pub email: String,
    pub first_name: String,
    pub last_name: String,
    pub birth_date: NaiveDate,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, TS)]
#[ts(export, export_to = "../bindings/CreateFamMemDto.ts")]
pub struct CreateFamMemDto {
    pub email: String,
    pub role: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, TS)]
#[ts(export, export_to = "../bindings/CreateFamilyRequest.ts")]
pub struct CreateFamilyRequest {
    pub name: String,
    pub country: Option<String>,
    pub region: Option<String>,
    pub city: Option<String>,
    pub street: Option<String>,
    pub building: Option<String>,
    pub apartment: Option<String>,
    pub members: Vec<CreateFamMemDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateFamNameDto {
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateFamMemRoleDto {
    pub role: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, TS)]
#[ts(export, export_to = "../../frontend/shared/src/types/CreateUserRequest.ts")]
pub struct CreateUserRequest {
    pub first_name: String,
    pub last_name: String,
    pub email: String,
    pub password: String,
    pub birth_date: NaiveDate,
}

#[derive(Serialize, Deserialize, TS)]
#[ts(export, export_to = "../../frontend/shared/src/types/LoginRequest.ts")]
pub struct LoginRequest {
    pub email: String,
    pub password: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, sqlx::Type, TS)]
#[sqlx(type_name = "acc_type_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
#[ts(export, export_to = "../bindings/AccountType.ts")]
pub enum AccountType {
    Cash,
    Card,
    BankAcc,
}

#[derive(Debug, Serialize, Deserialize, Clone, sqlx::Type, TS)]
#[sqlx(type_name = "bank_type_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
#[ts(export, export_to = "../bindings/BankType.ts")]
pub enum BankType {
    Monobank,
    Aib,
    Other,
}

#[derive(Debug, Serialize, Deserialize, Clone, sqlx::Type, TS)]
#[sqlx(type_name = "tx_type_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
#[ts(export, export_to = "../bindings/TxType.ts")]
pub enum TxType {
    Income,
    Expense,
    Transfer,
}

#[derive(Debug, Serialize, Deserialize, Clone, TS)]
#[ts(export, export_to = "../bindings/CurrencyDto.ts")]
pub struct CurrencyDto {
    pub id: Uuid,
    pub code: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, TS)]
#[ts(export, export_to = "../bindings/CurrencyRateDto.ts")]
pub struct CurrencyRateDto {
    pub id: Uuid,
    pub base_curr_id: Uuid,
    pub target_curr_id: Uuid,
    pub rate: f64,
    pub date: NaiveDate,
}

#[derive(Debug, Serialize, Deserialize, Clone, TS)]
#[ts(export, export_to = "../bindings/AccountDto.ts")]
pub struct AccountDto {
    pub id: Uuid,
    pub user_id: Option<Uuid>,
    pub family_id: Option<Uuid>,
    pub curr_id: Uuid,
    pub account_type: AccountType,
    pub bank_type: Option<BankType>,
    pub name: String,
    pub mask: Option<String>,
    #[ts(type = "Record<string, any> | null")]
    pub sync_credentials: Option<serde_json::Value>,
    pub is_active: bool,
}

#[derive(Debug, Serialize, Deserialize, Clone, TS)]
#[ts(export, export_to = "../bindings/TransactionDto.ts")]
pub struct TransactionDto {
    pub id: Uuid,
    pub user_id: Uuid,
    pub account_id: Uuid,
    pub curr_id: Uuid,
    pub amount: f64,
    pub tx_type: TxType,
    pub date: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FamMemberDto {
    pub id: Uuid,
    pub first_name: String,
    pub last_name: String,
    pub role: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FamDetailDto {
    pub id: Uuid,
    pub name: String,
    pub members: Vec<FamMemberDto>,
}

#[derive(Debug, Serialize, Deserialize, Clone, TS)]
#[ts(export, export_to = "../bindings/CountryDto.ts")]
pub struct CountryDto {
    pub id: Uuid,
    pub code: String,
    pub name: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, TS)]
#[ts(export, export_to = "../bindings/CityDto.ts")]
pub struct CityDto {
    pub id: Uuid,
    pub country_id: Uuid,
    pub name: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, TS)]
#[ts(export, export_to = "../bindings/StreetDto.ts")]
pub struct StreetDto {
    pub id: Uuid,
    pub city_id: Uuid,
    pub name: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, TS)]
#[ts(export, export_to = "../bindings/PlaceAddrDto.ts")]
pub struct PlaceAddrDto {
    pub id: Option<Uuid>,
    pub is_main: bool,
    pub country_id: Uuid,
    pub city_id: Uuid,
    pub street_id: Uuid,
    pub house_num: String,
    #[serde(default)]
    pub apt: Option<String>,
    pub zip: String,
    #[serde(default)]
    pub merchant_id: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone, TS)]
#[ts(export, export_to = "../bindings/PlaceDto.ts")]
pub struct PlaceDto {
    pub id: Uuid,
    pub name: String,
    pub addrs: Vec<PlaceAddrDto>,
}

#[derive(Deserialize)]
pub struct CreateCityReq {
    pub name: String,
}

#[derive(Deserialize)]
pub struct CreateStreetReq {
    pub name: String,
}

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
    pub ts: DateTime<Utc>,
    pub event_type: EnergyEventType,
    pub val: f64,
    pub cum_val: f64,
}

#[derive(Deserialize)]
pub struct EnergyGraphReq {
    pub target_date: NaiveDate,
}