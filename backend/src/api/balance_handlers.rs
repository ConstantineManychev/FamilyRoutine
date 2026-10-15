use std::collections::HashMap;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, TimeZone, Utc};
use rust_decimal::Decimal;
use shared_schema::{BalanceDocDto, BalanceWriteOffDto, BalanceWriteOffRequest, SaveBalanceDocRequest, TxCategory};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, AuthUser};
use crate::api::tx_handlers::insert_manual;
use crate::domain::errors::ApiError;
use crate::domain::finance_access::{account_access, AccountAccess};
use crate::domain::validation::{check_money, check_nonzero_money, clean_optional_text, money, MAX_NOTE_LEN};
use crate::state::AppState;

const MAX_DOCS_PER_WALLET: i64 = 2000;
const MAX_WRITE_OFFS_PER_DOC: i64 = 100;
const MAX_FUTURE_MINUTES: i64 = 5;
const EARLIEST_YEAR: i32 = 2000;

struct DocRow
{
    id: Uuid,
    account_id: Uuid,
    balance_ts: DateTime<Utc>,
    amount: Decimal,
    note: Option<String>,
    prev_ts: Option<DateTime<Utc>>,
    expected: Option<Decimal>,
    delta: Option<Decimal>,
}

fn require_manual_editor(a_access: &AccountAccess) -> Result<(), ApiError>
{
    if !a_access.is_editor
    {
        return Err(ApiError::Forbidden);
    }

    if !a_access.is_manual()
    {
        return Err(ApiError::Validation("account_id"));
    }

    Ok(())
}

fn check_balance_ts(a_ts: DateTime<Utc>, a_field: &'static str) -> Result<DateTime<Utc>, ApiError>
{
    let earliest = Utc
        .with_ymd_and_hms(EARLIEST_YEAR, 1, 1, 0, 0, 0)
        .single()
        .ok_or_else(|| ApiError::internal("earliest balance date"))?;
    let latest = Utc::now() + Duration::minutes(MAX_FUTURE_MINUTES);

    if a_ts < earliest || a_ts > latest
    {
        return Err(ApiError::Validation(a_field));
    }

    Ok(a_ts)
}

async fn doc_account(a_conn: &mut PgConnection, a_doc_id: Uuid, a_user_id: Uuid) -> Result<AccountAccess, ApiError>
{
    let account_id = sqlx::query_scalar!("SELECT account_id FROM balance_docs WHERE id = $1", a_doc_id)
        .fetch_optional(&mut *a_conn)
        .await?
        .ok_or(ApiError::NotFound)?;

    account_access(&mut *a_conn, account_id, a_user_id).await
}

async fn load_rows(
    a_conn: &mut PgConnection,
    a_account_id: Uuid,
    a_doc_id: Option<Uuid>,
) -> Result<Vec<DocRow>, ApiError>
{
    let rows = sqlx::query_as!(
        DocRow,
        r#"
        SELECT
            d.id AS "id!",
            d.account_id AS "account_id!",
            d.balance_ts AS "balance_ts!",
            d.amount AS "amount!",
            d.note,
            d.prev_ts AS "prev_ts?",
            flow.expected AS "expected?",
            d.amount - flow.expected AS "delta?"
        FROM (
            SELECT
                bd.id, bd.account_id, bd.balance_ts, bd.amount, bd.note,
                LAG(bd.balance_ts) OVER ordered AS prev_ts,
                LAG(bd.amount) OVER ordered AS prev_amount
            FROM balance_docs bd
            WHERE bd.account_id = $1
            WINDOW ordered AS (ORDER BY bd.balance_ts)
        ) d
        LEFT JOIN LATERAL (
            SELECT d.prev_amount + COALESCE(SUM(t.amount), 0) AS expected
            FROM transactions t
            WHERE t.account_id = d.account_id
              AND NOT t.is_pending
              AND t.tx_ts > d.prev_ts
              AND t.tx_ts <= d.balance_ts
        ) flow ON d.prev_ts IS NOT NULL
        WHERE $2::uuid IS NULL OR d.id = $2
        ORDER BY d.balance_ts DESC
        "#,
        a_account_id,
        a_doc_id
    )
    .fetch_all(&mut *a_conn)
    .await?;

    Ok(rows)
}

async fn load_write_offs(
    a_conn: &mut PgConnection,
    a_account_id: Uuid,
) -> Result<HashMap<Uuid, Vec<BalanceWriteOffDto>>, ApiError>
{
    let write_offs = sqlx::query_as!(
        BalanceWriteOffDto,
        r#"
        SELECT
            t.id,
            t.balance_doc_id AS "balance_doc_id!",
            t.tx_ts,
            t.amount,
            t.category AS "category: TxCategory",
            t.note
        FROM transactions t
        JOIN balance_docs d ON d.id = t.balance_doc_id
        WHERE d.account_id = $1
        ORDER BY t.tx_ts, t.id
        "#,
        a_account_id
    )
    .fetch_all(&mut *a_conn)
    .await?;

    let mut grouped: HashMap<Uuid, Vec<BalanceWriteOffDto>> = HashMap::new();
    for write_off in write_offs
    {
        grouped.entry(write_off.balance_doc_id).or_default().push(write_off);
    }

    Ok(grouped)
}

async fn load_docs(
    a_conn: &mut PgConnection,
    a_account_id: Uuid,
    a_doc_id: Option<Uuid>,
) -> Result<Vec<BalanceDocDto>, ApiError>
{
    let rows = load_rows(&mut *a_conn, a_account_id, a_doc_id).await?;
    let mut write_offs = load_write_offs(&mut *a_conn, a_account_id).await?;

    Ok(rows
        .into_iter()
        .map(|row| BalanceDocDto {
            write_offs: write_offs.remove(&row.id).unwrap_or_default(),
            id: row.id,
            account_id: row.account_id,
            balance_ts: row.balance_ts,
            amount: money(row.amount),
            note: row.note,
            prev_ts: row.prev_ts,
            expected: row.expected.map(money),
            delta: row.delta.map(money),
        })
        .collect())
}

async fn load_doc(a_conn: &mut PgConnection, a_account_id: Uuid, a_doc_id: Uuid) -> Result<BalanceDocDto, ApiError>
{
    load_docs(a_conn, a_account_id, Some(a_doc_id))
        .await?
        .into_iter()
        .next()
        .ok_or(ApiError::NotFound)
}

pub async fn list_balance_docs(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_account_id): ApiPath<Uuid>,
) -> Result<Json<Vec<BalanceDocDto>>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    account_access(&mut *conn, a_account_id, a_user.user_id).await?;

    load_docs(&mut conn, a_account_id, None).await.map(Json)
}

pub async fn create_balance_doc(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_account_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SaveBalanceDocRequest>,
) -> Result<(StatusCode, Json<BalanceDocDto>), ApiError>
{
    let amount = check_money(a_req.amount, "amount")?;
    let balance_ts = check_balance_ts(a_req.balance_ts, "balance_ts")?;
    let note = clean_optional_text(a_req.note.as_deref(), MAX_NOTE_LEN, "note")?;

    let mut tx = a_state.db.begin().await?;
    let access = account_access(&mut *tx, a_account_id, a_user.user_id).await?;
    require_manual_editor(&access)?;

    let doc_count = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM balance_docs WHERE account_id = $1"#,
        a_account_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if doc_count >= MAX_DOCS_PER_WALLET
    {
        return Err(ApiError::Conflict("LIMIT_REACHED"));
    }

    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO balance_docs (account_id, balance_ts, amount, note, created_by)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id
        "#,
        a_account_id,
        balance_ts,
        amount,
        note,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;

    let doc = load_doc(&mut tx, a_account_id, id).await?;
    tx.commit().await?;

    Ok((StatusCode::CREATED, Json(doc)))
}

pub async fn update_balance_doc(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SaveBalanceDocRequest>,
) -> Result<Json<BalanceDocDto>, ApiError>
{
    let amount = check_money(a_req.amount, "amount")?;
    let balance_ts = check_balance_ts(a_req.balance_ts, "balance_ts")?;
    let note = clean_optional_text(a_req.note.as_deref(), MAX_NOTE_LEN, "note")?;

    let mut tx = a_state.db.begin().await?;
    let access = doc_account(&mut tx, a_id, a_user.user_id).await?;
    require_manual_editor(&access)?;

    sqlx::query!(
        "UPDATE balance_docs SET balance_ts = $2, amount = $3, note = $4 WHERE id = $1",
        a_id,
        balance_ts,
        amount,
        note
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query!(
        r#"
        UPDATE transactions
        SET tx_ts = $2
        WHERE balance_doc_id = $1
          AND (
              tx_ts > $2
              OR tx_ts <= COALESCE(
                  (SELECT MAX(d.balance_ts) FROM balance_docs d WHERE d.account_id = $3 AND d.balance_ts < $2),
                  '-infinity'::timestamptz
              )
          )
        "#,
        a_id,
        balance_ts,
        access.id
    )
    .execute(&mut *tx)
    .await?;

    let doc = load_doc(&mut tx, access.id, a_id).await?;
    tx.commit().await?;

    Ok(Json(doc))
}

pub async fn delete_balance_doc(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let access = doc_account(&mut tx, a_id, a_user.user_id).await?;
    require_manual_editor(&access)?;

    sqlx::query!("DELETE FROM balance_docs WHERE id = $1", a_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;

    Ok(StatusCode::NO_CONTENT)
}

pub async fn create_write_off(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<BalanceWriteOffRequest>,
) -> Result<(StatusCode, Json<BalanceDocDto>), ApiError>
{
    let amount = check_nonzero_money(a_req.amount, "amount")?;
    let note = clean_optional_text(a_req.note.as_deref(), MAX_NOTE_LEN, "note")?;

    let mut tx = a_state.db.begin().await?;
    let access = doc_account(&mut tx, a_id, a_user.user_id).await?;
    require_manual_editor(&access)?;

    sqlx::query!(
        "SELECT id FROM balance_docs WHERE account_id = $1 FOR UPDATE",
        access.id
    )
    .fetch_all(&mut *tx)
    .await?;

    let doc = load_doc(&mut tx, access.id, a_id).await?;
    let delta = doc
        .delta
        .filter(|delta| !delta.is_zero())
        .ok_or(ApiError::Conflict("NOTHING_TO_WRITE_OFF"))?;

    if amount.is_sign_negative() != delta.is_sign_negative() || amount.abs() > delta.abs()
    {
        return Err(ApiError::Validation("amount"));
    }

    let tx_ts = a_req.tx_ts.unwrap_or(doc.balance_ts);
    if tx_ts > doc.balance_ts || doc.prev_ts.is_some_and(|prev_ts| tx_ts <= prev_ts)
    {
        return Err(ApiError::Validation("tx_ts"));
    }

    if i64::try_from(doc.write_offs.len()).unwrap_or(i64::MAX) >= MAX_WRITE_OFFS_PER_DOC
    {
        return Err(ApiError::Conflict("LIMIT_REACHED"));
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
    let tx_id = insert_manual(
        &mut tx,
        &access,
        a_user.user_id,
        amount,
        tx_ts,
        note.as_deref(),
        category,
        None,
    )
    .await?;

    sqlx::query!(
        "UPDATE transactions SET balance_doc_id = $2, is_match_blocked = TRUE WHERE id = $1",
        tx_id,
        a_id
    )
    .execute(&mut *tx)
    .await?;

    let updated = load_doc(&mut tx, access.id, a_id).await?;
    tx.commit().await?;

    Ok((StatusCode::CREATED, Json(updated)))
}
