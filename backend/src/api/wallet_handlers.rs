use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use shared_schema::{
    AccountDto, AccountType, ArchiveWalletRequest, BankProvider, BankType, CreateWalletRequest, CurrencyDto,
    UpdateWalletRequest,
};
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, AuthUser};
use crate::domain::errors::ApiError;
use crate::domain::finance_access::require_account_editor;
use crate::domain::validation::{clean_mask, clean_name};
use crate::security::authz::require_member;
use crate::state::AppState;

pub async fn list_currencies(
    State(a_state): State<AppState>,
    _a_user: AuthUser,
) -> Result<Json<Vec<CurrencyDto>>, ApiError>
{
    let currencies = sqlx::query_as!(CurrencyDto, "SELECT id, code FROM currencies ORDER BY code")
        .fetch_all(&a_state.db)
        .await?;

    Ok(Json(currencies))
}

pub async fn list_wallets(State(a_state): State<AppState>, a_user: AuthUser)
    -> Result<Json<Vec<AccountDto>>, ApiError>
{
    let wallets = sqlx::query_as!(
        AccountDto,
        r#"
        SELECT
            a.id,
            a.user_id,
            a.family_id,
            a.curr_id,
            c.code AS curr_code,
            a.account_type AS "account_type: AccountType",
            a.bank_type AS "bank_type: BankType",
            a.name,
            a.mask,
            a.conn_id,
            bc.provider AS "provider?: BankProvider",
            a.balance,
            a.balance_ts,
            a.is_active,
            v.is_editor AS "is_editable!"
        FROM accounts a
        JOIN account_viewers v ON v.account_id = a.id AND v.viewer_id = $1
        JOIN currencies c ON c.id = a.curr_id
        LEFT JOIN bank_conns bc ON bc.id = a.conn_id
        ORDER BY a.is_active DESC, a.name ASC
        "#,
        a_user.user_id
    )
    .fetch_all(&a_state.db)
    .await?;

    Ok(Json(wallets))
}

pub async fn get_wallet(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<Json<AccountDto>, ApiError>
{
    load_wallet(&a_state, a_id, a_user.user_id).await.map(Json)
}

pub async fn create_wallet(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<CreateWalletRequest>,
) -> Result<(StatusCode, Json<AccountDto>), ApiError>
{
    let name = clean_name(&a_req.name, "name")?;
    let bank_type = clean_bank_type(a_req.account_type, a_req.bank_type)?;
    let mask = clean_mask(a_req.mask.as_deref())?;

    if let Some(family_id) = a_req.family_id
    {
        require_member(&a_state.db, family_id, a_user.user_id).await?;
    }

    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO accounts (user_id, family_id, curr_id, account_type, bank_type, name, mask, created_by)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        RETURNING id
        "#,
        a_req.family_id.is_none().then_some(a_user.user_id),
        a_req.family_id,
        a_req.curr_id,
        a_req.account_type as AccountType,
        bank_type as Option<BankType>,
        name,
        mask,
        a_user.user_id
    )
    .fetch_one(&a_state.db)
    .await?;

    let wallet = load_wallet(&a_state, id, a_user.user_id).await?;
    Ok((StatusCode::CREATED, Json(wallet)))
}

pub async fn update_wallet(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<UpdateWalletRequest>,
) -> Result<Json<AccountDto>, ApiError>
{
    require_account_editor(&a_state.db, a_id, a_user.user_id).await?;
    let name = clean_name(&a_req.name, "name")?;
    let mask = clean_mask(a_req.mask.as_deref())?;

    sqlx::query!(
        "UPDATE accounts SET name = $2, mask = $3 WHERE id = $1",
        a_id,
        name,
        mask
    )
    .execute(&a_state.db)
    .await?;

    load_wallet(&a_state, a_id, a_user.user_id).await.map(Json)
}

pub async fn archive_wallet(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<ArchiveWalletRequest>,
) -> Result<StatusCode, ApiError>
{
    require_account_editor(&a_state.db, a_id, a_user.user_id).await?;

    sqlx::query!(
        "UPDATE accounts SET is_active = $2 WHERE id = $1",
        a_id,
        a_req.is_active
    )
    .execute(&a_state.db)
    .await?;

    Ok(StatusCode::NO_CONTENT)
}

pub async fn delete_wallet(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let access = require_account_editor(&a_state.db, a_id, a_user.user_id).await?;

    if !access.is_manual()
    {
        return Err(ApiError::Conflict("BANK_LINKED"));
    }

    sqlx::query!("DELETE FROM accounts WHERE id = $1", a_id)
        .execute(&a_state.db)
        .await?;

    Ok(StatusCode::NO_CONTENT)
}

async fn load_wallet(a_state: &AppState, a_id: Uuid, a_user_id: Uuid) -> Result<AccountDto, ApiError>
{
    sqlx::query_as!(
        AccountDto,
        r#"
        SELECT
            a.id,
            a.user_id,
            a.family_id,
            a.curr_id,
            c.code AS curr_code,
            a.account_type AS "account_type: AccountType",
            a.bank_type AS "bank_type: BankType",
            a.name,
            a.mask,
            a.conn_id,
            bc.provider AS "provider?: BankProvider",
            a.balance,
            a.balance_ts,
            a.is_active,
            v.is_editor AS "is_editable!"
        FROM accounts a
        JOIN account_viewers v ON v.account_id = a.id AND v.viewer_id = $2
        JOIN currencies c ON c.id = a.curr_id
        LEFT JOIN bank_conns bc ON bc.id = a.conn_id
        WHERE a.id = $1
        "#,
        a_id,
        a_user_id
    )
    .fetch_optional(&a_state.db)
    .await?
    .ok_or(ApiError::NotFound)
}

fn clean_bank_type(a_account_type: AccountType, a_bank_type: Option<BankType>) -> Result<Option<BankType>, ApiError>
{
    match (a_account_type, a_bank_type)
    {
        (AccountType::Cash, None) => Ok(None),
        (AccountType::Cash, Some(_)) => Err(ApiError::Validation("bank_type")),
        (_, bank_type) => Ok(bank_type),
    }
}
