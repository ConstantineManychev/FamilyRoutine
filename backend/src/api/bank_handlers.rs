use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::{Duration, Utc};
use rand::RngCore;
use sha2::{Digest, Sha256};
use shared_schema::{
    AspspDto, AspspQuery, BankConnDto, BankConnStatus, BankProvider, BankType, CompleteBankAuthRequest,
    ConnectMonobankRequest, StartBankAuthRequest, StartBankAuthResponse,
};
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::banking::enable_banking::EnableBankingClient;
use crate::banking::{store, ProviderError};
use crate::domain::errors::ApiError;
use crate::domain::validation::{clean_name, clean_sync_token};
use crate::security::crypto::bank_conn_aad;
use crate::security::rate_limit::BANK_CONNECT_PER_USER;
use crate::state::AppState;

const PENDING_AUTH_TTL_MINUTES: i32 = 60;
const MONO_MANUAL_SYNC_GAP_MIN: i64 = 2;
const EB_MANUAL_SYNC_GAP_MIN: i64 = 120;
const STATE_BYTES: usize = 32;

pub async fn list_connections(
    State(a_state): State<AppState>,
    a_user: AuthUser,
) -> Result<Json<Vec<BankConnDto>>, ApiError>
{
    let conns = sqlx::query_as!(
        BankConnDto,
        r#"
        SELECT
            c.id,
            c.provider AS "provider: BankProvider",
            c.aspsp_name,
            c.status AS "status: BankConnStatus",
            c.valid_until,
            c.last_sync_ts,
            c.next_sync_ts,
            c.last_error,
            (SELECT COUNT(*) FROM accounts a WHERE a.conn_id = c.id) AS "account_count!"
        FROM bank_conns c
        WHERE c.owner_id = $1 AND c.status <> 'pending'
        ORDER BY c.created_ts
        "#,
        a_user.user_id
    )
    .fetch_all(&a_state.db)
    .await?;

    Ok(Json(conns))
}

pub async fn connect_monobank(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<ConnectMonobankRequest>,
) -> Result<(StatusCode, Json<BankConnDto>), ApiError>
{
    let token = clean_sync_token(&a_req.token)?;
    a_state
        .limiter
        .hit(&format!("bank-connect:{}", a_user.user_id), &BANK_CONNECT_PER_USER)?;

    let accounts = a_state
        .banks
        .monobank
        .accounts(&token)
        .await
        .map_err(|err| provider_error(err, "token"))?;

    let ext_ids: Vec<String> = accounts.iter().map(|account| account.ext_id.clone()).collect();
    let is_duplicate = sqlx::query_scalar!(
        r#"
        SELECT EXISTS(
            SELECT 1 FROM accounts a
            JOIN bank_conns c ON c.id = a.conn_id
            WHERE c.owner_id = $1 AND c.provider = 'monobank' AND a.ext_acc_id = ANY($2)
        ) AS "exists!"
        "#,
        a_user.user_id,
        &ext_ids
    )
    .fetch_one(&a_state.db)
    .await?;

    if is_duplicate
    {
        return Err(ApiError::Conflict("ALREADY_CONNECTED"));
    }

    let conn_id = Uuid::new_v4();
    let secret = a_state.secret_box.seal(token.as_bytes(), &bank_conn_aad(conn_id))?;

    sqlx::query!(
        r#"
        INSERT INTO bank_conns (id, owner_id, provider, aspsp_name, secret, status, last_call_ts, next_sync_ts)
        VALUES ($1, $2, 'monobank', 'Monobank', $3, 'active', NOW(), NOW())
        "#,
        conn_id,
        a_user.user_id,
        secret
    )
    .execute(&a_state.db)
    .await?;

    store::upsert_accounts(&a_state.db, conn_id, a_user.user_id, BankType::Monobank, &accounts).await?;

    let conn = load_connection(&a_state, conn_id, a_user.user_id).await?;
    Ok((StatusCode::CREATED, Json(conn)))
}

pub async fn list_aspsps(
    State(a_state): State<AppState>,
    _a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<AspspQuery>,
) -> Result<Json<Vec<AspspDto>>, ApiError>
{
    let country = clean_country(&a_query.country)?;
    let client = enable_banking(&a_state)?;

    let aspsps = client
        .aspsps(&country)
        .await
        .map_err(|err| enable_banking_error(err, None))?;

    Ok(Json(aspsps))
}

pub async fn start_bank_auth(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<StartBankAuthRequest>,
) -> Result<Json<StartBankAuthResponse>, ApiError>
{
    let aspsp_name = clean_name(&a_req.aspsp_name, "aspsp_name")?;
    let country = clean_country(&a_req.aspsp_country)?;
    let client = enable_banking(&a_state)?;
    a_state
        .limiter
        .hit(&format!("bank-connect:{}", a_user.user_id), &BANK_CONNECT_PER_USER)?;

    let aspsp = client
        .find_aspsp(&aspsp_name, &country)
        .await
        .map_err(|err| enable_banking_error(err, None))?
        .ok_or(ApiError::Validation("aspsp_name"))?;

    let mut state_bytes = [0u8; STATE_BYTES];
    rand::thread_rng().fill_bytes(&mut state_bytes);
    let state = URL_SAFE_NO_PAD.encode(state_bytes);

    sqlx::query!(
        r#"
        DELETE FROM bank_conns
        WHERE owner_id = $1 AND status = 'pending'
          AND created_ts < NOW() - make_interval(mins => $2::int)
        "#,
        a_user.user_id,
        PENDING_AUTH_TTL_MINUTES
    )
    .execute(&a_state.db)
    .await?;

    sqlx::query!(
        r#"
        INSERT INTO bank_conns (owner_id, provider, aspsp_name, aspsp_country, state_hash, status)
        VALUES ($1, 'enable_banking', $2, $3, $4, 'pending')
        "#,
        a_user.user_id,
        aspsp_name,
        country,
        state_hash(&state)
    )
    .execute(&a_state.db)
    .await?;

    let url = client
        .start_auth(&aspsp, &state)
        .await
        .map_err(|err| enable_banking_error(err, None))?;

    Ok(Json(StartBankAuthResponse { url }))
}

pub async fn complete_bank_auth(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<CompleteBankAuthRequest>,
) -> Result<(StatusCode, Json<BankConnDto>), ApiError>
{
    let client = enable_banking(&a_state)?;
    let code = a_req.code.trim();

    if code.is_empty() || code.len() > 512 || a_req.state.len() > 128
    {
        return Err(ApiError::Validation("code"));
    }

    let pending = sqlx::query!(
        r#"
        SELECT id, aspsp_name FROM bank_conns
        WHERE owner_id = $1 AND status = 'pending' AND state_hash = $2
          AND created_ts > NOW() - make_interval(mins => $3::int)
        "#,
        a_user.user_id,
        state_hash(&a_req.state),
        PENDING_AUTH_TTL_MINUTES
    )
    .fetch_optional(&a_state.db)
    .await?
    .ok_or(ApiError::NotFound)?;

    let session = client
        .create_session(code)
        .await
        .map_err(|err| enable_banking_error(err, Some("code")))?;

    let secret = a_state
        .secret_box
        .seal(session.session_id.as_bytes(), &bank_conn_aad(pending.id))?;

    sqlx::query!(
        r#"
        UPDATE bank_conns
        SET status = 'active', secret = $2, state_hash = NULL, valid_until = $3, next_sync_ts = NOW()
        WHERE id = $1
        "#,
        pending.id,
        secret,
        session.valid_until
    )
    .execute(&a_state.db)
    .await?;

    let bank_type = match pending.aspsp_name.as_deref()
    {
        Some(name) if name.to_uppercase().contains("AIB") => BankType::Aib,
        _ => BankType::Other,
    };
    store::upsert_accounts(&a_state.db, pending.id, a_user.user_id, bank_type, &session.accounts).await?;

    let conn = load_connection(&a_state, pending.id, a_user.user_id).await?;
    Ok((StatusCode::CREATED, Json(conn)))
}

pub async fn request_sync(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_conn_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let conn = sqlx::query!(
        r#"
        SELECT provider AS "provider: BankProvider", last_sync_ts
        FROM bank_conns
        WHERE id = $1 AND owner_id = $2 AND status = 'active'
        "#,
        a_conn_id,
        a_user.user_id
    )
    .fetch_optional(&a_state.db)
    .await?
    .ok_or(ApiError::NotFound)?;

    let min_gap = match conn.provider
    {
        BankProvider::Monobank => Duration::minutes(MONO_MANUAL_SYNC_GAP_MIN),
        BankProvider::EnableBanking => Duration::minutes(EB_MANUAL_SYNC_GAP_MIN),
    };

    if let Some(retry_after) = conn
        .last_sync_ts
        .map(|last| last + min_gap - Utc::now())
        .filter(|remaining| *remaining > Duration::zero())
    {
        return Err(ApiError::TooManyRequests(retry_after.num_seconds().max(1) as u64));
    }

    sqlx::query!("UPDATE bank_conns SET next_sync_ts = NOW() WHERE id = $1", a_conn_id)
        .execute(&a_state.db)
        .await?;

    Ok(StatusCode::ACCEPTED)
}

pub async fn delete_connection(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_conn_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let conn = sqlx::query!(
        r#"SELECT provider AS "provider: BankProvider", secret FROM bank_conns WHERE id = $1 AND owner_id = $2"#,
        a_conn_id,
        a_user.user_id
    )
    .fetch_optional(&a_state.db)
    .await?
    .ok_or(ApiError::NotFound)?;

    if let (BankProvider::EnableBanking, Some(sealed), Some(client)) = (
        conn.provider,
        conn.secret.as_deref(),
        a_state.banks.enable_banking.as_ref(),
    )
    {
        let session_id = a_state.secret_box.open(sealed, &bank_conn_aad(a_conn_id))?;
        if let Err(err) = client.delete_session(&String::from_utf8_lossy(&session_id)).await
        {
            tracing::warn!("enable banking session revoke failed: {err:?}");
        }
    }

    sqlx::query!("DELETE FROM bank_conns WHERE id = $1", a_conn_id)
        .execute(&a_state.db)
        .await?;

    Ok(StatusCode::NO_CONTENT)
}

async fn load_connection(a_state: &AppState, a_conn_id: Uuid, a_user_id: Uuid) -> Result<BankConnDto, ApiError>
{
    sqlx::query_as!(
        BankConnDto,
        r#"
        SELECT
            c.id,
            c.provider AS "provider: BankProvider",
            c.aspsp_name,
            c.status AS "status: BankConnStatus",
            c.valid_until,
            c.last_sync_ts,
            c.next_sync_ts,
            c.last_error,
            (SELECT COUNT(*) FROM accounts a WHERE a.conn_id = c.id) AS "account_count!"
        FROM bank_conns c
        WHERE c.id = $1 AND c.owner_id = $2
        "#,
        a_conn_id,
        a_user_id
    )
    .fetch_optional(&a_state.db)
    .await?
    .ok_or(ApiError::NotFound)
}

fn enable_banking(a_state: &AppState) -> Result<&EnableBankingClient, ApiError>
{
    a_state
        .banks
        .enable_banking
        .as_ref()
        .ok_or(ApiError::Conflict("BANK_NOT_CONFIGURED"))
}

fn enable_banking_error(a_err: ProviderError, a_rejected_field: Option<&'static str>) -> ApiError
{
    match (a_err, a_rejected_field)
    {
        (ProviderError::Unauthorized, _) => ApiError::Upstream("BANK_APP_REJECTED"),
        (ProviderError::AppInactive, _) => ApiError::Upstream("BANK_APP_INACTIVE"),
        (ProviderError::Rejected(_), Some(field)) => ApiError::Validation(field),
        (ProviderError::Rejected(_), None) => ApiError::Upstream("BANK_REJECTED"),
        (other, _) => provider_error(other, "bank"),
    }
}

fn provider_error(a_err: ProviderError, a_field: &'static str) -> ApiError
{
    match a_err
    {
        ProviderError::Unauthorized => ApiError::Validation(a_field),
        ProviderError::AppInactive => ApiError::Upstream("BANK_APP_INACTIVE"),
        ProviderError::RateLimited => ApiError::TooManyRequests(60),
        ProviderError::Rejected(reason) =>
        {
            tracing::info!("bank rejected request: {reason}");
            ApiError::Validation(a_field)
        }
        ProviderError::Transient(reason) =>
        {
            tracing::warn!("bank unavailable: {reason}");
            ApiError::Upstream("BANK_UNAVAILABLE")
        }
    }
}

fn clean_country(a_value: &str) -> Result<String, ApiError>
{
    let country = a_value.trim().to_uppercase();

    if country.len() != 2 || !country.bytes().all(|byte| byte.is_ascii_uppercase())
    {
        return Err(ApiError::Validation("country"));
    }

    Ok(country)
}

fn state_hash(a_state: &str) -> Vec<u8>
{
    let mut hasher = Sha256::new();
    hasher.update(b"family-routine/bank-auth-state/v1/");
    hasher.update(a_state.as_bytes());
    hasher.finalize().to_vec()
}
