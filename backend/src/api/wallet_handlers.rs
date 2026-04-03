use crate::api::auth_middleware::AuthenticatedUser;
use crate::domain::errors::ApiError;
use axum::extract::{Path, State};
use axum::{http::StatusCode, Json};
use serde::Deserialize;
use shared_schema::{AccountDto, AccountType, BankType, CurrencyDto};
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Deserialize)]
pub struct CreateWalletPayload {
    pub name: String,
    pub curr_id: Uuid,
    pub account_type: AccountType,
    #[serde(default)]
    pub bank_type: Option<BankType>,
    #[serde(default)]
    pub mask: Option<String>,
    #[serde(default)]
    pub sync_credentials: Option<serde_json::Value>,
    #[serde(default)]
    pub family_id: Option<Uuid>,
}

#[derive(Deserialize)]
pub struct UpdateWalletPayload {
    pub name: String,
    #[serde(default)]
    pub mask: Option<String>,
    #[serde(default)]
    pub sync_credentials: Option<serde_json::Value>,
}

#[derive(Deserialize)]
pub struct ArchiveWalletPayload {
    pub is_active: bool,
}

pub async fn get_currencies(
    State(db): State<PgPool>,
) -> Result<Json<Vec<CurrencyDto>>, ApiError> {
    let currs = sqlx::query_as!(
        CurrencyDto,
        "SELECT id, code FROM currencies ORDER BY code"
    )
    .fetch_all(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    Ok(Json(currs))
}

pub async fn get_wallets(
    State(db): State<PgPool>,
    user: AuthenticatedUser,
) -> Result<Json<Vec<AccountDto>>, ApiError> {
    let wallets = sqlx::query_as!(
        AccountDto,
        r#"
        SELECT 
            id, user_id, family_id, curr_id, 
            account_type as "account_type: AccountType", 
            bank_type as "bank_type: BankType", 
            name, mask, sync_credentials, is_active
        FROM accounts
        WHERE user_id = $1 OR family_id IN (
            SELECT family_id FROM family_mems WHERE user_id = $1
        )
        ORDER BY is_active DESC, name ASC
        "#,
        user.0
    )
    .fetch_all(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    Ok(Json(wallets))
}

pub async fn get_wallet_detail(
    State(db): State<PgPool>,
    Path(id): Path<Uuid>,
    user: AuthenticatedUser,
) -> Result<Json<AccountDto>, ApiError> {
    let wallet = sqlx::query_as!(
        AccountDto,
        r#"
        SELECT 
            id, user_id, family_id, curr_id, 
            account_type as "account_type: AccountType", 
            bank_type as "bank_type: BankType", 
            name, mask, sync_credentials, is_active
        FROM accounts
        WHERE id = $1 AND (user_id = $2 OR family_id IN (
            SELECT family_id FROM family_mems WHERE user_id = $2
        ))
        "#,
        id,
        user.0
    )
    .fetch_optional(&db)
    .await
    .map_err(ApiError::DatabaseError)?
    .ok_or(ApiError::Unauthorized)?;

    Ok(Json(wallet))
}

pub async fn create_wallet(
    State(db): State<PgPool>,
    user: AuthenticatedUser,
    Json(payload): Json<CreateWalletPayload>,
) -> Result<(StatusCode, Json<AccountDto>), ApiError> {
    let account = sqlx::query_as!(
        AccountDto,
        r#"
        INSERT INTO accounts (user_id, family_id, curr_id, account_type, bank_type, name, mask, sync_credentials)
        VALUES ($1, $2, $3, $4::text::acc_type_t, $5::text::bank_type_t, $6, $7, $8)
        RETURNING id, user_id, family_id, curr_id, 
                  account_type as "account_type: AccountType", 
                  bank_type as "bank_type: BankType", 
                  name, mask, sync_credentials, is_active
        "#,
        if payload.family_id.is_none() { Some(user.0) } else { None },
        payload.family_id,
        payload.curr_id,
        payload.account_type as AccountType,
        payload.bank_type as Option<BankType>,
        payload.name,
        payload.mask,
        payload.sync_credentials
    )
    .fetch_one(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    Ok((StatusCode::CREATED, Json(account)))
}

pub async fn update_wallet(
    State(db): State<PgPool>,
    Path(id): Path<Uuid>,
    user: AuthenticatedUser,
    Json(payload): Json<UpdateWalletPayload>,
) -> Result<Json<AccountDto>, ApiError> {
    let account = sqlx::query_as!(
        AccountDto,
        r#"
        UPDATE accounts
        SET name = $1, mask = $2, sync_credentials = $3
        WHERE id = $4 AND (user_id = $5 OR family_id IN (
            SELECT family_id FROM family_mems WHERE user_id = $5 AND role = 'admin'
        ))
        RETURNING id, user_id, family_id, curr_id, 
                  account_type as "account_type: AccountType", 
                  bank_type as "bank_type: BankType", 
                  name, mask, sync_credentials, is_active
        "#,
        payload.name,
        payload.mask,
        payload.sync_credentials,
        id,
        user.0
    )
    .fetch_optional(&db)
    .await
    .map_err(ApiError::DatabaseError)?
    .ok_or(ApiError::Unauthorized)?;

    Ok(Json(account))
}

pub async fn archive_wallet(
    State(db): State<PgPool>,
    Path(id): Path<Uuid>,
    user: AuthenticatedUser,
    Json(payload): Json<ArchiveWalletPayload>,
) -> Result<StatusCode, ApiError> {
    let res = sqlx::query!(
        r#"
        UPDATE accounts
        SET is_active = $1
        WHERE id = $2 AND (user_id = $3 OR family_id IN (
            SELECT family_id FROM family_mems WHERE user_id = $3 AND role = 'admin'
        ))
        "#,
        payload.is_active,
        id,
        user.0
    )
    .execute(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    if res.rows_affected() == 0 {
        return Err(ApiError::Unauthorized);
    }

    Ok(StatusCode::NO_CONTENT)
}

pub async fn delete_wallet(
    State(db): State<PgPool>,
    Path(id): Path<Uuid>,
    user: AuthenticatedUser,
) -> Result<StatusCode, ApiError> {
    let mut tx = db.begin().await.map_err(ApiError::DatabaseError)?;

    let res = sqlx::query!(
        r#"
        DELETE FROM accounts
        WHERE id = $1 AND (user_id = $2 OR family_id IN (
            SELECT family_id FROM family_mems WHERE user_id = $2 AND role = 'admin'
        ))
        "#,
        id,
        user.0
    )
    .execute(&mut *tx)
    .await
    .map_err(ApiError::DatabaseError)?;

    if res.rows_affected() == 0 {
        return Err(ApiError::Unauthorized);
    }

    tx.commit().await.map_err(ApiError::DatabaseError)?;
    Ok(StatusCode::NO_CONTENT)
}