use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{Datelike, Duration, NaiveDate, NaiveTime, Utc};
use shared_schema::{
    AiKeyDto, AiKeySavedDto, AiModelDto, AiProvider, AiServerDto, AiSettingsDto, AiSource, AiUsageDto,
    SaveAiKeyRequest, SaveAiSettingsRequest, SetAiModelRequest,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, AuthUser};
use crate::domain::errors::ApiError;
use crate::receipt_ai::{is_valid_model_id, preferred_model, AiTarget, ReadError, Usage};
use crate::security::crypto::ai_key_aad;
use crate::security::rate_limit::AI_KEY_CHECK_PER_USER;
use crate::state::AppState;

const DEFAULT_OWN_DAILY_LIMIT: i32 = 30;
const DEFAULT_OWN_MONTHLY_LIMIT: i32 = 300;
const MAX_DAILY_LIMIT: i32 = 1000;
const MAX_MONTHLY_LIMIT: i32 = 30_000;
const MIN_KEY_LEN: usize = 20;
const MAX_KEY_LEN: usize = 512;
const KEY_HINT_LEN: usize = 4;

pub struct ResolvedAi
{
    pub target: AiTarget,
    pub is_own_key: bool,
    pub daily_limit: i32,
    pub monthly_limit: i32,
}

struct SettingsRow
{
    source: AiSource,
    daily_limit: Option<i32>,
    monthly_limit: Option<i32>,
}

struct KeyRow
{
    sealed_key: Vec<u8>,
    model: String,
}

pub async fn get_settings(State(a_state): State<AppState>, a_user: AuthUser) -> Result<Json<AiSettingsDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    settings_dto(&a_state, &mut conn, a_user.user_id).await.map(Json)
}

pub async fn save_settings(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SaveAiSettingsRequest>,
) -> Result<Json<AiSettingsDto>, ApiError>
{
    check_limit(a_req.daily_limit, MAX_DAILY_LIMIT, "daily_limit")?;
    check_limit(a_req.monthly_limit, MAX_MONTHLY_LIMIT, "monthly_limit")?;

    let mut conn = a_state.db.acquire().await?;
    match a_req.source
    {
        AiSource::Off =>
        {}
        AiSource::Server if a_state.cfg.receipt_ai.server.is_none() =>
        {
            return Err(ApiError::Conflict("AI_SERVER_UNAVAILABLE"));
        }
        AiSource::Server =>
        {}
        own =>
        {
            let provider = own.own_provider().ok_or(ApiError::Validation("source"))?;
            require_own_keys(&a_state)?;
            if load_key(&mut conn, a_user.user_id, provider).await?.is_none()
            {
                return Err(ApiError::Conflict("AI_KEY_MISSING"));
            }
        }
    }

    sqlx::query!(
        r#"
        INSERT INTO user_ai_settings (user_id, source, daily_limit, monthly_limit)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (user_id) DO UPDATE
        SET source = EXCLUDED.source, daily_limit = EXCLUDED.daily_limit,
            monthly_limit = EXCLUDED.monthly_limit, updated_ts = NOW()
        "#,
        a_user.user_id,
        a_req.source as AiSource,
        a_req.daily_limit,
        a_req.monthly_limit
    )
    .execute(&mut *conn)
    .await?;

    settings_dto(&a_state, &mut conn, a_user.user_id).await.map(Json)
}

pub async fn save_key(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_provider): ApiPath<AiProvider>,
    ApiJson(a_req): ApiJson<SaveAiKeyRequest>,
) -> Result<Json<AiKeySavedDto>, ApiError>
{
    require_own_keys(&a_state)?;
    let api_key = clean_api_key(&a_req.api_key)?;
    if let Some(model) = &a_req.model
    {
        check_model_id(a_provider, model)?;
    }
    a_state
        .limiter
        .hit(&format!("ai-key:{}", a_user.user_id), &AI_KEY_CHECK_PER_USER)?;

    let models = list_models(&a_state, a_provider, &api_key).await?;
    let model = match a_req.model
    {
        Some(model) if models.iter().any(|known| known.id == model) => model,
        Some(_) => return Err(ApiError::Validation("model")),
        None => preferred_model(a_provider, &models).ok_or(ApiError::Conflict("AI_NO_MODELS"))?,
    };

    let sealed_key = a_state
        .secret_box
        .seal(api_key.as_bytes(), &ai_key_aad(a_user.user_id, a_provider.as_str()))?;
    let key_hint = key_hint(&api_key);

    let mut tx = a_state.db.begin().await?;
    let key = sqlx::query_as!(
        AiKeyDto,
        r#"
        INSERT INTO user_ai_keys (user_id, provider, sealed_key, key_hint, model)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (user_id, provider) DO UPDATE
        SET sealed_key = EXCLUDED.sealed_key, key_hint = EXCLUDED.key_hint, model = EXCLUDED.model, updated_ts = NOW()
        RETURNING provider AS "provider: AiProvider", key_hint, model, updated_ts
        "#,
        a_user.user_id,
        a_provider as AiProvider,
        sealed_key,
        key_hint,
        model
    )
    .fetch_one(&mut *tx)
    .await?;

    sqlx::query!(
        r#"
        INSERT INTO user_ai_settings (user_id, source) VALUES ($1, $2)
        ON CONFLICT (user_id) DO UPDATE SET source = EXCLUDED.source, updated_ts = NOW()
        "#,
        a_user.user_id,
        AiSource::from(a_provider) as AiSource
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    Ok(Json(AiKeySavedDto { key, models }))
}

pub async fn set_model(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_provider): ApiPath<AiProvider>,
    ApiJson(a_req): ApiJson<SetAiModelRequest>,
) -> Result<Json<AiKeyDto>, ApiError>
{
    check_model_id(a_provider, &a_req.model)?;
    let models = stored_key_models(&a_state, a_user.user_id, a_provider).await?;
    if !models.iter().any(|model| model.id == a_req.model)
    {
        return Err(ApiError::Validation("model"));
    }

    let key = sqlx::query_as!(
        AiKeyDto,
        r#"
        UPDATE user_ai_keys SET model = $3, updated_ts = NOW()
        WHERE user_id = $1 AND provider = $2
        RETURNING provider AS "provider: AiProvider", key_hint, model, updated_ts
        "#,
        a_user.user_id,
        a_provider as AiProvider,
        a_req.model
    )
    .fetch_optional(&a_state.db)
    .await?
    .ok_or(ApiError::NotFound)?;

    Ok(Json(key))
}

pub async fn get_models(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_provider): ApiPath<AiProvider>,
) -> Result<Json<Vec<AiModelDto>>, ApiError>
{
    stored_key_models(&a_state, a_user.user_id, a_provider).await.map(Json)
}

pub async fn delete_key(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_provider): ApiPath<AiProvider>,
) -> Result<StatusCode, ApiError>
{
    let fallback_source = default_source(&a_state);
    let mut tx = a_state.db.begin().await?;
    let deleted = sqlx::query!(
        "DELETE FROM user_ai_keys WHERE user_id = $1 AND provider = $2",
        a_user.user_id,
        a_provider as AiProvider
    )
    .execute(&mut *tx)
    .await?
    .rows_affected();
    if deleted == 0
    {
        return Err(ApiError::NotFound);
    }

    sqlx::query!(
        "UPDATE user_ai_settings SET source = $3, updated_ts = NOW() WHERE user_id = $1 AND source = $2",
        a_user.user_id,
        AiSource::from(a_provider) as AiSource,
        fallback_source as AiSource
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    Ok(StatusCode::NO_CONTENT)
}

pub async fn resolve_ai(
    a_state: &AppState,
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
) -> Result<Option<ResolvedAi>, ApiError>
{
    let row = load_settings(a_conn, a_user_id).await?;
    let source = row.as_ref().map_or_else(|| default_source(a_state), |row| row.source);
    let (daily_limit, monthly_limit) = effective_limits(a_state, source, row.as_ref());

    if source == AiSource::Server
    {
        return Ok(a_state.cfg.receipt_ai.server.as_ref().map(|server| ResolvedAi {
            target: AiTarget {
                provider: server.provider,
                api_key: server.api_key.clone(),
                model: server.model.clone(),
            },
            is_own_key: false,
            daily_limit,
            monthly_limit,
        }));
    }

    let Some(provider) = source
        .own_provider()
        .filter(|_| a_state.cfg.receipt_ai.is_own_keys_allowed)
    else
    {
        return Ok(None);
    };
    let Some(key) = load_key(a_conn, a_user_id, provider).await?
    else
    {
        return Ok(None);
    };

    Ok(Some(ResolvedAi {
        target: AiTarget {
            provider,
            api_key: open_key(a_state, a_user_id, provider, &key.sealed_key)?,
            model: key.model,
        },
        is_own_key: true,
        daily_limit,
        monthly_limit,
    }))
}

pub async fn charge_scan(a_state: &AppState, a_user_id: Uuid, a_resolved: &ResolvedAi) -> Result<(), ApiError>
{
    let mut tx = a_state.db.begin().await?;
    sqlx::query!(
        "SELECT pg_advisory_xact_lock(hashtextextended('receipt-scan:' || $1::UUID::TEXT, 0))",
        a_user_id
    )
    .execute(&mut *tx)
    .await?;

    let today_count = sqlx::query_scalar!(
        r#"
        INSERT INTO receipt_scans (user_id, scan_day, is_own_key, scan_count)
        VALUES ($1, (NOW() AT TIME ZONE 'UTC')::date, $2, 1)
        ON CONFLICT (user_id, scan_day, is_own_key) DO UPDATE SET scan_count = receipt_scans.scan_count + 1
        RETURNING scan_count
        "#,
        a_user_id,
        a_resolved.is_own_key
    )
    .fetch_one(&mut *tx)
    .await?;

    let month_count = sqlx::query_scalar!(
        r#"
        SELECT COALESCE(SUM(scan_count), 0)::BIGINT AS "count!"
        FROM receipt_scans
        WHERE user_id = $1 AND is_own_key = $2
          AND scan_day >= date_trunc('month', NOW() AT TIME ZONE 'UTC')::date
        "#,
        a_user_id,
        a_resolved.is_own_key
    )
    .fetch_one(&mut *tx)
    .await?;

    let now = Utc::now();
    if today_count > a_resolved.daily_limit
    {
        return Err(ApiError::TooManyRequests(seconds_until(
            now,
            next_day(now.date_naive()),
        )));
    }
    if month_count > i64::from(a_resolved.monthly_limit)
    {
        return Err(ApiError::TooManyRequests(seconds_until(
            now,
            next_month(now.date_naive()),
        )));
    }

    tx.commit().await?;
    Ok(())
}

pub async fn refund_scan(a_state: &AppState, a_user_id: Uuid, a_is_own_key: bool) -> Result<(), ApiError>
{
    sqlx::query!(
        r#"
        UPDATE receipt_scans SET scan_count = GREATEST(scan_count - 1, 0)
        WHERE user_id = $1 AND is_own_key = $2 AND scan_day = (NOW() AT TIME ZONE 'UTC')::date
        "#,
        a_user_id,
        a_is_own_key
    )
    .execute(&a_state.db)
    .await?;
    Ok(())
}

pub async fn record_usage(
    a_state: &AppState,
    a_user_id: Uuid,
    a_is_own_key: bool,
    a_usage: Usage,
) -> Result<(), ApiError>
{
    sqlx::query!(
        r#"
        UPDATE receipt_scans
        SET input_tokens = input_tokens + $3, output_tokens = output_tokens + $4
        WHERE user_id = $1 AND is_own_key = $2 AND scan_day = (NOW() AT TIME ZONE 'UTC')::date
        "#,
        a_user_id,
        a_is_own_key,
        a_usage.input_tokens.max(0),
        a_usage.output_tokens.max(0)
    )
    .execute(&a_state.db)
    .await?;
    Ok(())
}

pub fn read_error(a_error: ReadError, a_is_own_key: bool) -> ApiError
{
    match (a_error, a_is_own_key)
    {
        (ReadError::Refused | ReadError::Unreadable, _) => ApiError::Conflict("RECEIPT_UNREADABLE"),
        (ReadError::KeyRejected, true) => ApiError::Conflict("AI_KEY_REJECTED"),
        (ReadError::ModelRejected, true) => ApiError::Conflict("AI_MODEL_REJECTED"),
        (ReadError::QuotaExceeded, true) => ApiError::Conflict("AI_QUOTA_EXCEEDED"),
        _ => ApiError::Upstream("RECOGNITION_UNAVAILABLE"),
    }
}

async fn settings_dto(a_state: &AppState, a_conn: &mut PgConnection, a_user_id: Uuid)
    -> Result<AiSettingsDto, ApiError>
{
    let row = load_settings(a_conn, a_user_id).await?;
    let source = row.as_ref().map_or_else(|| default_source(a_state), |row| row.source);
    let (effective_daily_limit, effective_monthly_limit) = effective_limits(a_state, source, row.as_ref());

    let keys = sqlx::query_as!(
        AiKeyDto,
        r#"
        SELECT provider AS "provider: AiProvider", key_hint, model, updated_ts
        FROM user_ai_keys WHERE user_id = $1 ORDER BY provider
        "#,
        a_user_id
    )
    .fetch_all(&mut *a_conn)
    .await?;

    let usage = sqlx::query_as!(
        AiUsageDto,
        r#"
        SELECT is_own_key,
               COALESCE(SUM(scan_count) FILTER (WHERE scan_day = (NOW() AT TIME ZONE 'UTC')::date), 0)::BIGINT AS "today_count!",
               COALESCE(SUM(scan_count), 0)::BIGINT AS "month_count!",
               COALESCE(SUM(input_tokens), 0)::BIGINT AS "month_input_tokens!",
               COALESCE(SUM(output_tokens), 0)::BIGINT AS "month_output_tokens!"
        FROM receipt_scans
        WHERE user_id = $1 AND scan_day >= date_trunc('month', NOW() AT TIME ZONE 'UTC')::date
        GROUP BY is_own_key
        ORDER BY is_own_key
        "#,
        a_user_id
    )
    .fetch_all(&mut *a_conn)
    .await?;

    Ok(AiSettingsDto {
        source,
        daily_limit: row.as_ref().and_then(|row| row.daily_limit),
        monthly_limit: row.as_ref().and_then(|row| row.monthly_limit),
        effective_daily_limit,
        effective_monthly_limit,
        server: a_state.cfg.receipt_ai.server.as_ref().map(|server| AiServerDto {
            provider: server.provider,
            model: server.model.clone(),
            daily_limit: server.daily_limit,
            monthly_limit: server.monthly_limit,
        }),
        is_own_keys_allowed: a_state.cfg.receipt_ai.is_own_keys_allowed,
        keys,
        usage,
    })
}

async fn load_settings(a_conn: &mut PgConnection, a_user_id: Uuid) -> Result<Option<SettingsRow>, ApiError>
{
    Ok(sqlx::query_as!(
        SettingsRow,
        r#"SELECT source AS "source: AiSource", daily_limit, monthly_limit FROM user_ai_settings WHERE user_id = $1"#,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?)
}

async fn load_key(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_provider: AiProvider,
) -> Result<Option<KeyRow>, ApiError>
{
    Ok(sqlx::query_as!(
        KeyRow,
        "SELECT sealed_key, model FROM user_ai_keys WHERE user_id = $1 AND provider = $2",
        a_user_id,
        a_provider as AiProvider
    )
    .fetch_optional(&mut *a_conn)
    .await?)
}

async fn stored_key_models(
    a_state: &AppState,
    a_user_id: Uuid,
    a_provider: AiProvider,
) -> Result<Vec<AiModelDto>, ApiError>
{
    require_own_keys(a_state)?;
    let mut conn = a_state.db.acquire().await?;
    let key = load_key(&mut conn, a_user_id, a_provider)
        .await?
        .ok_or(ApiError::NotFound)?;
    drop(conn);

    a_state
        .limiter
        .hit(&format!("ai-key:{a_user_id}"), &AI_KEY_CHECK_PER_USER)?;
    let api_key = open_key(a_state, a_user_id, a_provider, &key.sealed_key)?;
    list_models(a_state, a_provider, &api_key).await
}

async fn list_models(a_state: &AppState, a_provider: AiProvider, a_api_key: &str) -> Result<Vec<AiModelDto>, ApiError>
{
    let models = a_state
        .receipt_ai
        .list_models(a_provider, a_api_key)
        .await
        .map_err(|err| match err
        {
            ReadError::KeyRejected => ApiError::Conflict("AI_KEY_REJECTED"),
            ReadError::QuotaExceeded => ApiError::Conflict("AI_QUOTA_EXCEEDED"),
            _ => ApiError::Upstream("AI_PROVIDER_UNAVAILABLE"),
        })?;

    Ok(models
        .into_iter()
        .filter(|model| is_valid_model_id(a_provider, &model.id))
        .collect())
}

fn open_key(a_state: &AppState, a_user_id: Uuid, a_provider: AiProvider, a_sealed: &[u8]) -> Result<String, ApiError>
{
    let plain = a_state
        .secret_box
        .open(a_sealed, &ai_key_aad(a_user_id, a_provider.as_str()))?;
    String::from_utf8(plain).map_err(|_| ApiError::internal("ai key is not utf-8"))
}

fn default_source(a_state: &AppState) -> AiSource
{
    if a_state.cfg.receipt_ai.server.is_some()
    {
        AiSource::Server
    }
    else
    {
        AiSource::Off
    }
}

fn effective_limits(a_state: &AppState, a_source: AiSource, a_row: Option<&SettingsRow>) -> (i32, i32)
{
    let daily = a_row.and_then(|row| row.daily_limit);
    let monthly = a_row.and_then(|row| row.monthly_limit);

    match (a_source, a_state.cfg.receipt_ai.server.as_ref())
    {
        (AiSource::Off, _) | (AiSource::Server, None) => (0, 0),
        (AiSource::Server, Some(server)) => (
            daily.unwrap_or(server.daily_limit).min(server.daily_limit),
            monthly.unwrap_or(server.monthly_limit).min(server.monthly_limit),
        ),
        _ => (
            daily.unwrap_or(DEFAULT_OWN_DAILY_LIMIT),
            monthly.unwrap_or(DEFAULT_OWN_MONTHLY_LIMIT),
        ),
    }
}

fn require_own_keys(a_state: &AppState) -> Result<(), ApiError>
{
    if a_state.cfg.receipt_ai.is_own_keys_allowed
    {
        Ok(())
    }
    else
    {
        Err(ApiError::Conflict("AI_OWN_KEYS_DISABLED"))
    }
}

fn check_limit(a_value: Option<i32>, a_max: i32, a_field: &'static str) -> Result<(), ApiError>
{
    match a_value
    {
        Some(value) if !(1..=a_max).contains(&value) => Err(ApiError::Validation(a_field)),
        _ => Ok(()),
    }
}

fn check_model_id(a_provider: AiProvider, a_model: &str) -> Result<(), ApiError>
{
    if is_valid_model_id(a_provider, a_model)
    {
        Ok(())
    }
    else
    {
        Err(ApiError::Validation("model"))
    }
}

fn clean_api_key(a_value: &str) -> Result<String, ApiError>
{
    let key = a_value.trim();
    let is_printable = key.chars().all(|chr| chr.is_ascii_graphic());
    if !(MIN_KEY_LEN..=MAX_KEY_LEN).contains(&key.len()) || !is_printable
    {
        return Err(ApiError::Validation("api_key"));
    }
    Ok(key.to_string())
}

fn key_hint(a_key: &str) -> String
{
    a_key[a_key.len() - KEY_HINT_LEN..].to_string()
}

fn next_day(a_today: NaiveDate) -> NaiveDate
{
    a_today + Duration::days(1)
}

fn next_month(a_today: NaiveDate) -> NaiveDate
{
    let (year, month) = if a_today.month() == 12
    {
        (a_today.year() + 1, 1)
    }
    else
    {
        (a_today.year(), a_today.month() + 1)
    };
    NaiveDate::from_ymd_opt(year, month, 1).unwrap_or_else(|| next_day(a_today))
}

fn seconds_until(a_now: chrono::DateTime<Utc>, a_day: NaiveDate) -> u64
{
    (a_day.and_time(NaiveTime::MIN).and_utc() - a_now).num_seconds().max(1) as u64
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn api_keys_are_trimmed_and_checked()
    {
        assert_eq!(
            clean_api_key("  sk-proj-abcdefghijklmnop1234 \n").unwrap(),
            "sk-proj-abcdefghijklmnop1234"
        );
        assert!(clean_api_key("short").is_err());
        assert!(clean_api_key("sk-proj abcdefghijklmnop1234").is_err());
        assert!(clean_api_key("sk-proj-абвгдежзийклмноп").is_err());
        assert_eq!(key_hint("sk-proj-abcdefghijklmnop1234"), "1234");
    }

    #[test]
    fn month_boundaries_roll_over_the_year()
    {
        let december = NaiveDate::from_ymd_opt(2026, 12, 31).unwrap();
        assert_eq!(next_month(december), NaiveDate::from_ymd_opt(2027, 1, 1).unwrap());
        assert_eq!(next_day(december), NaiveDate::from_ymd_opt(2027, 1, 1).unwrap());
        assert_eq!(
            next_month(NaiveDate::from_ymd_opt(2026, 10, 11).unwrap()),
            NaiveDate::from_ymd_opt(2026, 11, 1).unwrap()
        );
    }
}
