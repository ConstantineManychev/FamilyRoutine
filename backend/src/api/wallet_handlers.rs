use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use shared_schema::{
    AccountDto, AccountType, ArchiveWalletRequest, BankType, CreateWalletRequest, CurrencyDto, UpdateWalletRequest,
};
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, AuthUser};
use crate::domain::errors::ApiError;
use crate::domain::validation::{clean_mask, clean_name, clean_sync_token};
use crate::security::authz::require_member;
use crate::security::crypto::account_token_aad;
use crate::state::AppState;

struct WalletAccess
{
    user_id: Option<Uuid>,
    bank_type: Option<BankType>,
    is_editable: bool,
}

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
            a.account_type AS "account_type: AccountType",
            a.bank_type AS "bank_type: BankType",
            a.name,
            a.mask,
            (a.sync_secret IS NOT NULL) AS "is_sync_token_set!",
            a.is_active,
            COALESCE(a.user_id = $1 OR fm.role = 'admin' OR (fm.user_id IS NOT NULL AND a.created_by = $1), FALSE) AS "is_editable!"
        FROM accounts a
        LEFT JOIN family_mems fm ON fm.family_id = a.family_id AND fm.user_id = $1
        WHERE a.user_id = $1 OR fm.user_id IS NOT NULL
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
    let is_personal = a_req.family_id.is_none();

    if let Some(family_id) = a_req.family_id
    {
        require_member(&a_state.db, family_id, a_user.user_id).await?;
    }

    let id = Uuid::new_v4();
    let sync_secret = match a_req.sync_token.as_deref().filter(|token| !token.trim().is_empty())
    {
        None => None,
        Some(token) => Some(seal_token(&a_state, id, token, is_personal, bank_type)?),
    };

    sqlx::query!(
        r#"
        INSERT INTO accounts (id, user_id, family_id, curr_id, account_type, bank_type, name, mask, sync_secret, created_by)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        "#,
        id,
        is_personal.then_some(a_user.user_id),
        a_req.family_id,
        a_req.curr_id,
        a_req.account_type as AccountType,
        bank_type as Option<BankType>,
        name,
        mask,
        sync_secret,
        a_user.user_id
    )
    .execute(&a_state.db)
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
    let access = require_editable(&a_state, a_id, a_user.user_id).await?;
    let name = clean_name(&a_req.name, "name")?;
    let mask = clean_mask(a_req.mask.as_deref())?;

    let new_secret = match a_req.sync_token.as_deref().filter(|token| !token.trim().is_empty())
    {
        Some(_) if a_req.is_sync_token_removed => return Err(ApiError::Validation("sync_token")),
        Some(token) => Some(seal_token(
            &a_state,
            a_id,
            token,
            access.user_id.is_some(),
            access.bank_type,
        )?),
        None => None,
    };

    sqlx::query!(
        r#"
        UPDATE accounts
        SET name = $2,
            mask = $3,
            sync_secret = CASE WHEN $4 THEN NULL ELSE COALESCE($5, sync_secret) END
        WHERE id = $1
        "#,
        a_id,
        name,
        mask,
        a_req.is_sync_token_removed,
        new_secret
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
    require_editable(&a_state, a_id, a_user.user_id).await?;

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
    require_editable(&a_state, a_id, a_user.user_id).await?;

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
            a.account_type AS "account_type: AccountType",
            a.bank_type AS "bank_type: BankType",
            a.name,
            a.mask,
            (a.sync_secret IS NOT NULL) AS "is_sync_token_set!",
            a.is_active,
            COALESCE(a.user_id = $2 OR fm.role = 'admin' OR (fm.user_id IS NOT NULL AND a.created_by = $2), FALSE) AS "is_editable!"
        FROM accounts a
        LEFT JOIN family_mems fm ON fm.family_id = a.family_id AND fm.user_id = $2
        WHERE a.id = $1 AND (a.user_id = $2 OR fm.user_id IS NOT NULL)
        "#,
        a_id,
        a_user_id
    )
    .fetch_optional(&a_state.db)
    .await?
    .ok_or(ApiError::NotFound)
}

async fn require_editable(a_state: &AppState, a_id: Uuid, a_user_id: Uuid) -> Result<WalletAccess, ApiError>
{
    let access = sqlx::query_as!(
        WalletAccess,
        r#"
        SELECT
            a.user_id,
            a.bank_type AS "bank_type: BankType",
            COALESCE(a.user_id = $2 OR fm.role = 'admin' OR (fm.user_id IS NOT NULL AND a.created_by = $2), FALSE) AS "is_editable!"
        FROM accounts a
        LEFT JOIN family_mems fm ON fm.family_id = a.family_id AND fm.user_id = $2
        WHERE a.id = $1 AND (a.user_id = $2 OR fm.user_id IS NOT NULL)
        "#,
        a_id,
        a_user_id
    )
    .fetch_optional(&a_state.db)
    .await?
    .ok_or(ApiError::NotFound)?;

    if !access.is_editable
    {
        return Err(ApiError::Forbidden);
    }

    Ok(access)
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

fn seal_token(
    a_state: &AppState,
    a_account_id: Uuid,
    a_token: &str,
    a_is_personal: bool,
    a_bank_type: Option<BankType>,
) -> Result<Vec<u8>, ApiError>
{
    if !a_is_personal || a_bank_type != Some(BankType::Monobank)
    {
        return Err(ApiError::Validation("sync_token"));
    }

    let token = clean_sync_token(a_token)?;
    a_state
        .secret_box
        .seal(token.as_bytes(), &account_token_aad(a_account_id))
}
