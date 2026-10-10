use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use shared_schema::{
    AccountType, CreateTransferRequest, CreateTxRequest, MerchantDto, MerchantQuery, TransferDto, TxCategory, TxDto,
    TxPageDto, TxQuery, TxSource, TxType, UpdateTxRequest,
};
use sqlx::{PgConnection, PgExecutor};
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::domain::errors::ApiError;
use crate::domain::finance_access::{require_account_editor, AccountAccess};
use crate::domain::validation::{check_nonzero_money, check_positive_money, clean_optional_text, MAX_NOTE_LEN};
use crate::state::AppState;

const DEFAULT_PAGE: i64 = 50;
const MAX_PAGE: i64 = 200;
const MAX_QUERY_LEN: usize = 100;

struct TxOwnership
{
    account_id: Uuid,
    amount: Decimal,
    source: TxSource,
    transfer_id: Option<Uuid>,
    receipt_id: Option<Uuid>,
    is_editor: bool,
}

pub async fn list_transactions(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<TxQuery>,
) -> Result<Json<TxPageDto>, ApiError>
{
    let limit = a_query.limit.unwrap_or(DEFAULT_PAGE).clamp(1, MAX_PAGE);
    let cursor = a_query.cursor.as_deref().map(decode_cursor).transpose()?;
    let pattern = a_query
        .q
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| {
            if value.chars().count() > MAX_QUERY_LEN
            {
                return Err(ApiError::Validation("q"));
            }
            Ok(format!("%{}%", escape_like(value)))
        })
        .transpose()?;

    let mut items = sqlx::query_as!(
        TxDto,
        r#"
        SELECT
            t.id,
            t.account_id,
            a.name AS account_name,
            c.code AS curr_code,
            t.amount,
            t.op_amount,
            oc.code AS "op_curr_code?",
            t.tx_ts,
            t.tx_type AS "tx_type: TxType",
            t.source AS "source: TxSource",
            t.description,
            t.counterparty,
            t.category AS "category: TxCategory",
            t.merchant_id,
            m.name AS "merchant_name?",
            t.mcc,
            t.note,
            t.is_pending,
            t.transfer_id,
            t.receipt_id,
            v.is_editor AS "is_editable!"
        FROM transactions t
        JOIN account_viewers v ON v.account_id = t.account_id AND v.viewer_id = $1
        JOIN accounts a ON a.id = t.account_id
        JOIN currencies c ON c.id = t.curr_id
        LEFT JOIN currencies oc ON oc.id = t.op_curr_id
        LEFT JOIN merchants m ON m.id = t.merchant_id
        WHERE ($2::uuid IS NULL OR t.account_id = $2)
          AND ($3::timestamptz IS NULL OR t.tx_ts >= $3)
          AND ($4::timestamptz IS NULL OR t.tx_ts < $4)
          AND (NOT $5 OR (t.receipt_id IS NULL AND t.source <> 'receipt_cash' AND t.amount < 0))
          AND ($6::text IS NULL
               OR t.description ILIKE $6 OR t.counterparty ILIKE $6 OR t.note ILIKE $6 OR m.name ILIKE $6)
          AND ($7::timestamptz IS NULL OR (t.tx_ts, t.id) < ($7, $8::uuid))
        ORDER BY t.tx_ts DESC, t.id DESC
        LIMIT $9
        "#,
        a_user.user_id,
        a_query.account_id,
        a_query.from,
        a_query.to,
        a_query.is_unlinked.unwrap_or(false),
        pattern,
        cursor.map(|(ts, _)| ts),
        cursor.map(|(_, id)| id),
        limit + 1
    )
    .fetch_all(&a_state.db)
    .await?;

    let next_cursor = if items.len() as i64 > limit
    {
        items.truncate(limit as usize);
        items.last().map(|last| encode_cursor(last.tx_ts, last.id))
    }
    else
    {
        None
    };

    Ok(Json(TxPageDto { items, next_cursor }))
}

pub async fn create_transaction(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<CreateTxRequest>,
) -> Result<(StatusCode, Json<TxDto>), ApiError>
{
    let amount = check_nonzero_money(a_req.amount, "amount")?;
    let note = clean_optional_text(a_req.note.as_deref(), MAX_NOTE_LEN, "note")?;

    let mut tx = a_state.db.begin().await?;
    let account = require_account_editor(&mut *tx, a_req.account_id, a_user.user_id).await?;

    if !account.is_manual()
    {
        return Err(ApiError::Validation("account_id"));
    }

    let category = a_req.category.unwrap_or(
        if amount > Decimal::ZERO
        {
            TxCategory::Income
        }
        else
        {
            TxCategory::Other
        },
    );
    let id = insert_manual(
        &mut tx,
        &account,
        a_user.user_id,
        amount,
        a_req.tx_ts,
        note.as_deref(),
        category,
        None,
    )
    .await?;

    tx.commit().await?;

    let created = load_tx(&a_state.db, id, a_user.user_id).await?;
    Ok((StatusCode::CREATED, Json(created)))
}

pub async fn update_transaction(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<UpdateTxRequest>,
) -> Result<Json<TxDto>, ApiError>
{
    let note = clean_optional_text(a_req.note.as_deref(), MAX_NOTE_LEN, "note")?;
    let ownership = tx_ownership(&a_state.db, a_id, a_user.user_id).await?;

    if !ownership.is_editor
    {
        return Err(ApiError::Forbidden);
    }

    sqlx::query!(
        "UPDATE transactions SET note = $2, category = $3 WHERE id = $1",
        a_id,
        note,
        a_req.category as Option<TxCategory>
    )
    .execute(&a_state.db)
    .await?;

    load_tx(&a_state.db, a_id, a_user.user_id).await.map(Json)
}

pub async fn delete_transaction(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let ownership = tx_ownership(&a_state.db, a_id, a_user.user_id).await?;

    if !ownership.is_editor
    {
        return Err(ApiError::Forbidden);
    }

    if ownership.source != TxSource::Manual
    {
        return Err(ApiError::Validation("source"));
    }

    let mut tx = a_state.db.begin().await?;

    match ownership.transfer_id
    {
        Some(transfer_id) => dissolve_transfer(&mut tx, transfer_id, a_user.user_id).await?,
        None =>
        {
            sqlx::query!("DELETE FROM transactions WHERE id = $1", a_id)
                .execute(&mut *tx)
                .await?;
        }
    }

    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn create_transfer(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<CreateTransferRequest>,
) -> Result<(StatusCode, Json<TransferDto>), ApiError>
{
    if a_req.from_account_id == a_req.to_account_id
    {
        return Err(ApiError::Validation("to_account_id"));
    }

    let note = clean_optional_text(a_req.note.as_deref(), MAX_NOTE_LEN, "note")?;
    let mut tx = a_state.db.begin().await?;

    let from = require_account_editor(&mut *tx, a_req.from_account_id, a_user.user_id).await?;
    let to = require_account_editor(&mut *tx, a_req.to_account_id, a_user.user_id).await?;

    let from_amount = match a_req.from_tx_id
    {
        Some(tx_id) => -linkable_leg(&mut tx, tx_id, from.id, a_user.user_id, true, "from_tx_id").await?,
        None if from.is_manual() =>
        {
            check_positive_money(a_req.amount.ok_or(ApiError::Validation("amount"))?, "amount")?
        }
        None => return Err(ApiError::Validation("from_tx_id")),
    };

    let to_amount = match a_req.to_tx_id
    {
        Some(tx_id) => linkable_leg(&mut tx, tx_id, to.id, a_user.user_id, false, "to_tx_id").await?,
        None if !to.is_manual() => return Err(ApiError::Validation("to_tx_id")),
        None => match a_req.to_amount
        {
            Some(value) => check_positive_money(value, "to_amount")?,
            None if from.curr_id == to.curr_id => from_amount,
            None => return Err(ApiError::Validation("to_amount")),
        },
    };

    let transfer_id = Uuid::new_v4();
    let category = if to.account_type == AccountType::Cash
    {
        TxCategory::Cash
    }
    else
    {
        TxCategory::Transfer
    };
    let mut leg_ids = Vec::with_capacity(2);

    let from_leg = match a_req.from_tx_id
    {
        Some(tx_id) => link_leg(&mut tx, tx_id, transfer_id).await?,
        None =>
        {
            insert_manual(
                &mut tx,
                &from,
                a_user.user_id,
                -from_amount,
                a_req.tx_ts,
                note.as_deref(),
                category,
                Some(transfer_id),
            )
            .await?
        }
    };
    leg_ids.push(from_leg);

    let to_leg = match a_req.to_tx_id
    {
        Some(tx_id) => link_leg(&mut tx, tx_id, transfer_id).await?,
        None =>
        {
            insert_manual(
                &mut tx,
                &to,
                a_user.user_id,
                to_amount,
                a_req.tx_ts,
                note.as_deref(),
                category,
                Some(transfer_id),
            )
            .await?
        }
    };
    leg_ids.push(to_leg);

    tx.commit().await?;

    let txs = load_txs(&a_state.db, &leg_ids, a_user.user_id).await?;
    Ok((StatusCode::CREATED, Json(TransferDto { transfer_id, txs })))
}

pub async fn delete_transfer(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_transfer_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    dissolve_transfer(&mut tx, a_transfer_id, a_user.user_id).await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn list_merchants(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<MerchantQuery>,
) -> Result<Json<Vec<MerchantDto>>, ApiError>
{
    let pattern = a_query
        .q
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| {
            format!(
                "{}%",
                escape_like(&value.chars().take(MAX_QUERY_LEN).collect::<String>())
            )
        });

    let merchants = sqlx::query_as!(
        MerchantDto,
        r#"
        SELECT m.id, m.name, m.mcc
        FROM merchants m
        WHERE EXISTS (
            SELECT 1 FROM transactions t
            JOIN account_viewers v ON v.account_id = t.account_id AND v.viewer_id = $1
            WHERE t.merchant_id = m.id
        )
        AND ($2::text IS NULL OR m.name ILIKE $2 OR m.name_key ILIKE $2)
        ORDER BY m.name
        LIMIT 30
        "#,
        a_user.user_id,
        pattern
    )
    .fetch_all(&a_state.db)
    .await?;

    Ok(Json(merchants))
}

#[allow(clippy::too_many_arguments)]
pub async fn insert_manual(
    a_conn: &mut PgConnection,
    a_account: &AccountAccess,
    a_user_id: Uuid,
    a_amount: Decimal,
    a_tx_ts: DateTime<Utc>,
    a_note: Option<&str>,
    a_category: TxCategory,
    a_transfer_id: Option<Uuid>,
) -> Result<Uuid, ApiError>
{
    let tx_type = match (a_transfer_id, a_amount > Decimal::ZERO)
    {
        (Some(_), _) => TxType::Transfer,
        (None, true) => TxType::Income,
        (None, false) => TxType::Expense,
    };

    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO transactions (user_id, account_id, curr_id, amount, tx_type, tx_ts, source, note, category, transfer_id)
        VALUES ($1, $2, $3, $4, $5, $6, 'manual', $7, $8, $9)
        RETURNING id
        "#,
        a_user_id,
        a_account.id,
        a_account.curr_id,
        a_amount,
        tx_type as TxType,
        a_tx_ts,
        a_note,
        a_category as TxCategory,
        a_transfer_id
    )
    .fetch_one(&mut *a_conn)
    .await?;

    Ok(id)
}

pub async fn load_tx<'e, E>(a_db: E, a_id: Uuid, a_user_id: Uuid) -> Result<TxDto, ApiError>
where
    E: PgExecutor<'e>,
{
    load_txs(a_db, &[a_id], a_user_id)
        .await?
        .into_iter()
        .next()
        .ok_or(ApiError::NotFound)
}

pub async fn load_txs<'e, E>(a_db: E, a_ids: &[Uuid], a_user_id: Uuid) -> Result<Vec<TxDto>, ApiError>
where
    E: PgExecutor<'e>,
{
    let txs = sqlx::query_as!(
        TxDto,
        r#"
        SELECT
            t.id,
            t.account_id,
            a.name AS account_name,
            c.code AS curr_code,
            t.amount,
            t.op_amount,
            oc.code AS "op_curr_code?",
            t.tx_ts,
            t.tx_type AS "tx_type: TxType",
            t.source AS "source: TxSource",
            t.description,
            t.counterparty,
            t.category AS "category: TxCategory",
            t.merchant_id,
            m.name AS "merchant_name?",
            t.mcc,
            t.note,
            t.is_pending,
            t.transfer_id,
            t.receipt_id,
            v.is_editor AS "is_editable!"
        FROM transactions t
        JOIN account_viewers v ON v.account_id = t.account_id AND v.viewer_id = $2
        JOIN accounts a ON a.id = t.account_id
        JOIN currencies c ON c.id = t.curr_id
        LEFT JOIN currencies oc ON oc.id = t.op_curr_id
        LEFT JOIN merchants m ON m.id = t.merchant_id
        WHERE t.id = ANY($1)
        ORDER BY t.tx_ts DESC, t.id DESC
        "#,
        a_ids,
        a_user_id
    )
    .fetch_all(a_db)
    .await?;

    Ok(txs)
}

async fn tx_ownership<'e, E>(a_db: E, a_id: Uuid, a_user_id: Uuid) -> Result<TxOwnership, ApiError>
where
    E: PgExecutor<'e>,
{
    sqlx::query_as!(
        TxOwnership,
        r#"
        SELECT
            t.account_id,
            t.amount,
            t.source AS "source: TxSource",
            t.transfer_id,
            t.receipt_id,
            v.is_editor AS "is_editor!"
        FROM transactions t
        JOIN account_viewers v ON v.account_id = t.account_id AND v.viewer_id = $2
        WHERE t.id = $1
        "#,
        a_id,
        a_user_id
    )
    .fetch_optional(a_db)
    .await?
    .ok_or(ApiError::NotFound)
}

async fn linkable_leg(
    a_conn: &mut PgConnection,
    a_tx_id: Uuid,
    a_account_id: Uuid,
    a_user_id: Uuid,
    a_is_outflow: bool,
    a_field: &'static str,
) -> Result<Decimal, ApiError>
{
    let leg = tx_ownership(&mut *a_conn, a_tx_id, a_user_id)
        .await
        .map_err(|_| ApiError::Validation(a_field))?;

    let is_direction_valid = if a_is_outflow
    {
        leg.amount < Decimal::ZERO
    }
    else
    {
        leg.amount > Decimal::ZERO
    };

    if leg.account_id != a_account_id
        || !is_direction_valid
        || leg.transfer_id.is_some()
        || leg.receipt_id.is_some()
        || leg.source == TxSource::ReceiptCash
    {
        return Err(ApiError::Validation(a_field));
    }

    Ok(leg.amount)
}

async fn link_leg(a_conn: &mut PgConnection, a_tx_id: Uuid, a_transfer_id: Uuid) -> Result<Uuid, ApiError>
{
    sqlx::query!(
        "UPDATE transactions SET transfer_id = $2, tx_type = 'transfer' WHERE id = $1",
        a_tx_id,
        a_transfer_id
    )
    .execute(&mut *a_conn)
    .await?;

    Ok(a_tx_id)
}

async fn dissolve_transfer(a_conn: &mut PgConnection, a_transfer_id: Uuid, a_user_id: Uuid) -> Result<(), ApiError>
{
    let legs = sqlx::query!(
        r#"
        SELECT t.id, COALESCE(BOOL_AND(v.is_editor), FALSE) AS "is_editor!"
        FROM transactions t
        LEFT JOIN account_viewers v ON v.account_id = t.account_id AND v.viewer_id = $2
        WHERE t.transfer_id = $1
        GROUP BY t.id
        "#,
        a_transfer_id,
        a_user_id
    )
    .fetch_all(&mut *a_conn)
    .await?;

    if legs.is_empty()
    {
        return Err(ApiError::NotFound);
    }

    if legs.iter().any(|leg| !leg.is_editor)
    {
        return Err(ApiError::Forbidden);
    }

    sqlx::query!(
        "DELETE FROM transactions WHERE transfer_id = $1 AND source = 'manual'",
        a_transfer_id
    )
    .execute(&mut *a_conn)
    .await?;

    sqlx::query!(
        r#"
        UPDATE transactions
        SET transfer_id = NULL,
            tx_type = CASE WHEN amount > 0 THEN 'income'::tx_type_t ELSE 'expense'::tx_type_t END
        WHERE transfer_id = $1
        "#,
        a_transfer_id
    )
    .execute(&mut *a_conn)
    .await?;

    Ok(())
}

fn encode_cursor(a_ts: DateTime<Utc>, a_id: Uuid) -> String
{
    URL_SAFE_NO_PAD.encode(format!("{}:{a_id}", a_ts.timestamp_micros()))
}

fn decode_cursor(a_cursor: &str) -> Result<(DateTime<Utc>, Uuid), ApiError>
{
    let raw = URL_SAFE_NO_PAD
        .decode(a_cursor)
        .ok()
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .ok_or(ApiError::Validation("cursor"))?;

    let (micros, id) = raw.split_once(':').ok_or(ApiError::Validation("cursor"))?;
    let ts = micros
        .parse::<i64>()
        .ok()
        .and_then(DateTime::<Utc>::from_timestamp_micros)
        .ok_or(ApiError::Validation("cursor"))?;
    let id = id.parse::<Uuid>().map_err(|_| ApiError::Validation("cursor"))?;

    Ok((ts, id))
}

pub fn escape_like(a_value: &str) -> String
{
    a_value.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn cursor_round_trips_and_rejects_garbage()
    {
        let ts = DateTime::<Utc>::from_timestamp_micros(1_700_000_000_123_456).unwrap();
        let id = Uuid::new_v4();

        assert_eq!(decode_cursor(&encode_cursor(ts, id)).unwrap(), (ts, id));
        assert!(decode_cursor("not-a-cursor").is_err());
    }

    #[test]
    fn like_wildcards_are_escaped()
    {
        assert_eq!(escape_like("50%_off\\"), "50\\%\\_off\\\\");
    }
}
