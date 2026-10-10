use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "mem_role_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum MemberRole
{
    Admin,
    Standard,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "acc_type_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum AccountType
{
    Cash,
    Card,
    BankAcc,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "bank_type_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum BankType
{
    Monobank,
    Aib,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "ex_type_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ExType
{
    Cardio,
    Strength,
    Flexibility,
    Mixed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "weight_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum WeightType
{
    External,
    Hybrid,
    Bodyweight,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "musc_grp_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum MuscGrpType
{
    Chest,
    Back,
    Legs,
    Shoulders,
    Arms,
    Core,
    Cardio,
    FullBody,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RegisterRequest
{
    pub first_name: String,
    pub last_name: String,
    pub email: String,
    pub password: String,
    pub birth_date: NaiveDate,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LoginRequest
{
    pub email: String,
    pub password: String,
    #[serde(default)]
    pub is_cookie_mode: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct UserDto
{
    pub id: Uuid,
    pub email: String,
    pub first_name: String,
    pub last_name: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct LoginResponse
{
    pub user: UserDto,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DictMetaDto
{
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct FamListItemDto
{
    pub id: Uuid,
    pub name: String,
    pub role: MemberRole,
    pub is_owner: bool,
    pub member_count: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct FamMemberDto
{
    pub id: Uuid,
    pub first_name: String,
    pub last_name: String,
    pub role: MemberRole,
    pub is_owner: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct FamDetailDto
{
    pub id: Uuid,
    pub name: String,
    pub my_role: MemberRole,
    pub is_owner: bool,
    pub members: Vec<FamMemberDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateFamilyRequest
{
    pub name: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RenameFamilyRequest
{
    pub name: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct UpdateMemberRoleRequest
{
    pub role: MemberRole,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TransferOwnershipRequest
{
    pub user_id: Uuid,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateInviteRequest
{
    pub role: MemberRole,
    #[serde(default)]
    pub label: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CreatedInviteDto
{
    pub id: Uuid,
    pub code: String,
    pub role: MemberRole,
    pub label: Option<String>,
    pub expires_ts: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct FamInviteDto
{
    pub id: Uuid,
    pub role: MemberRole,
    pub label: Option<String>,
    pub created_ts: DateTime<Utc>,
    pub expires_ts: DateTime<Utc>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AcceptInviteRequest
{
    pub code: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct AcceptInviteResponse
{
    pub family_id: Uuid,
}

#[derive(Debug, Clone, Serialize)]
pub struct CurrencyDto
{
    pub id: Uuid,
    pub code: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct AccountDto
{
    pub id: Uuid,
    pub user_id: Option<Uuid>,
    pub family_id: Option<Uuid>,
    pub curr_id: Uuid,
    pub account_type: AccountType,
    pub bank_type: Option<BankType>,
    pub name: String,
    pub mask: Option<String>,
    pub is_sync_token_set: bool,
    pub is_active: bool,
    pub is_editable: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateWalletRequest
{
    pub name: String,
    pub curr_id: Uuid,
    pub account_type: AccountType,
    #[serde(default)]
    pub bank_type: Option<BankType>,
    #[serde(default)]
    pub mask: Option<String>,
    #[serde(default)]
    pub sync_token: Option<String>,
    #[serde(default)]
    pub family_id: Option<Uuid>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct UpdateWalletRequest
{
    pub name: String,
    #[serde(default)]
    pub mask: Option<String>,
    #[serde(default)]
    pub sync_token: Option<String>,
    #[serde(default)]
    pub is_sync_token_removed: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ArchiveWalletRequest
{
    pub is_active: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct CountryDto
{
    pub id: Uuid,
    pub code: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct CityDto
{
    pub id: Uuid,
    pub country_id: Uuid,
    pub name: String,
    pub is_editable: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct StreetDto
{
    pub id: Uuid,
    pub city_id: Uuid,
    pub name: String,
    pub is_editable: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct GeoNameRequest
{
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaceAddrDto
{
    #[serde(default)]
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

#[derive(Debug, Clone, Serialize)]
pub struct PlaceDto
{
    pub id: Uuid,
    pub name: String,
    pub addrs: Vec<PlaceAddrDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SavePlaceRequest
{
    pub name: String,
    #[serde(default)]
    pub addrs: Vec<PlaceAddrDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExMuscGrpDto
{
    pub grp: MuscGrpType,
    pub pct: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct DictExDto
{
    pub id: Uuid,
    pub name: String,
    pub ex_type: ExType,
    pub met_val: f64,
    pub weight_type: WeightType,
    pub bw_pct: f64,
    pub is_custom: bool,
    pub musc_grps: Vec<ExMuscGrpDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveExRequest
{
    pub name: String,
    pub ex_type: ExType,
    pub met_val: f64,
    pub weight_type: WeightType,
    #[serde(default)]
    pub bw_pct: f64,
    pub musc_grps: Vec<ExMuscGrpDto>,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EnergyEventType
{
    BmrBase,
    Meal,
    Workout,
}

#[derive(Debug, Clone, Serialize)]
pub struct EnergyNodeDto
{
    pub ts: DateTime<Utc>,
    pub event_type: EnergyEventType,
    pub val: f64,
    pub cum_val: f64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct EnergyGraphQuery
{
    pub target_date: NaiveDate,
}
