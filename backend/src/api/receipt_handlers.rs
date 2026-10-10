use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use rust_decimal::Decimal;
use shared_schema::{
    AccountType, ItemKind, ItemUnit, ReceiptDto, ReceiptItemDto, ReceiptListItemDto, ReceiptQuery,
    SaveReceiptItemRequest, SaveReceiptRequest, TxSource,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::api::item_handlers::require_visible_items;
use crate::api::tx_handlers::load_txs;
use crate::domain::errors::ApiError;
use crate::domain::finance_access::require_account_editor;
use crate::domain::validation::{check_money, check_qty, clean_optional_text, money, MAX_NAME_LEN, MAX_NOTE_LEN};
use crate::state::AppState;

const MAX_ITEMS: usize = 300;
const MAX_LINKED_TXS: usize = 20;

struct ReceiptHead
{
    id: Uuid,
    receipt_ts: chrono::DateTime<chrono::Utc>,
    merchant_id: Option<Uuid>,
    merchant_name: Option<String>,
    place_id: Option<Uuid>,
    place_name: Option<String>,
    curr_id: Uuid,
    curr_code: String,
    cash_account_id: Option<Uuid>,
    note: Option<String>,
}

struct LinkCandidate
{
    amount: Decimal,
    op_amount: Option<Decimal>,
    curr_id: Uuid,
    op_curr_id: Option<Uuid>,
    source: TxSource,
    receipt_id: Option<Uuid>,
    is_editor: bool,
}

pub async fn list_receipts(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<ReceiptQuery>,
) -> Result<Json<Vec<ReceiptListItemDto>>, ApiError>
{
    let receipts = sqlx::query_as!(
        ReceiptListItemDto,
        r#"
        SELECT
            r.id,
            r.receipt_ts,
            COALESCE(r.merchant_name, m.name) AS merchant_name,
            p.name AS "place_name?",
            c.code AS curr_code,
            COALESCE((SELECT SUM(i.amount) FROM receipt_items i WHERE i.receipt_id = r.id), 0) AS "items_total!",
            (SELECT COUNT(*) FROM receipt_items i WHERE i.receipt_id = r.id) AS "item_count!",
            (SELECT COUNT(*) FROM transactions t WHERE t.receipt_id = r.id AND t.source <> 'receipt_cash') AS "tx_count!"
        FROM receipts r
        JOIN currencies c ON c.id = r.curr_id
        LEFT JOIN merchants m ON m.id = r.merchant_id
        LEFT JOIN places p ON p.id = r.place_id
        WHERE r.owner_id = $1
          AND ($2::timestamptz IS NULL OR r.receipt_ts >= $2)
          AND ($3::timestamptz IS NULL OR r.receipt_ts < $3)
        ORDER BY r.receipt_ts DESC
        LIMIT 500
        "#,
        a_user.user_id,
        a_query.from,
        a_query.to
    )
    .fetch_all(&a_state.db)
    .await?;

    Ok(Json(receipts))
}

pub async fn get_receipt(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<Json<ReceiptDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    load_receipt(&mut conn, a_id, a_user.user_id).await.map(Json)
}

pub async fn create_receipt(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SaveReceiptRequest>,
) -> Result<(StatusCode, Json<ReceiptDto>), ApiError>
{
    let receipt = save_receipt(&a_state, None, a_user.user_id, a_req).await?;
    Ok((StatusCode::CREATED, Json(receipt)))
}

pub async fn update_receipt(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SaveReceiptRequest>,
) -> Result<Json<ReceiptDto>, ApiError>
{
    save_receipt(&a_state, Some(a_id), a_user.user_id, a_req)
        .await
        .map(Json)
}

pub async fn delete_receipt(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    lock_owned(&mut tx, a_id, a_user.user_id).await?;

    sqlx::query!(
        "DELETE FROM transactions WHERE receipt_id = $1 AND source = 'receipt_cash'",
        a_id
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query!("DELETE FROM receipts WHERE id = $1", a_id)
        .execute(&mut *tx)
        .await?;

    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn save_receipt(
    a_state: &AppState,
    a_id: Option<Uuid>,
    a_user_id: Uuid,
    a_req: SaveReceiptRequest,
) -> Result<ReceiptDto, ApiError>
{
    let merchant_name = clean_optional_text(a_req.merchant_name.as_deref(), MAX_NAME_LEN, "merchant_name")?;
    let note = clean_optional_text(a_req.note.as_deref(), MAX_NOTE_LEN, "note")?;
    let items = clean_items(&a_req.items)?;
    let mut tx_ids = a_req.tx_ids.clone();
    tx_ids.sort_unstable();
    tx_ids.dedup();

    if tx_ids.len() > MAX_LINKED_TXS
    {
        return Err(ApiError::Validation("tx_ids"));
    }

    let mut tx = a_state.db.begin().await?;

    let item_ids: Vec<Uuid> = items.iter().map(|item| item.item_id).collect();
    require_visible_items(&mut tx, &item_ids, a_user_id).await?;

    let is_currency_known = sqlx::query_scalar!(
        r#"SELECT EXISTS(SELECT 1 FROM currencies WHERE id = $1) AS "exists!""#,
        a_req.curr_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if !is_currency_known
    {
        return Err(ApiError::Validation("curr_id"));
    }

    if let Some(place_id) = a_req.place_id
    {
        let is_own_place = sqlx::query_scalar!(
            r#"SELECT EXISTS(SELECT 1 FROM places WHERE id = $1 AND owner_id = $2) AS "exists!""#,
            place_id,
            a_user_id
        )
        .fetch_one(&mut *tx)
        .await?;
        if !is_own_place
        {
            return Err(ApiError::Validation("place_id"));
        }
    }

    if let Some(merchant_id) = a_req.merchant_id
    {
        let is_merchant_known = sqlx::query_scalar!(
            r#"SELECT EXISTS(SELECT 1 FROM merchants WHERE id = $1) AS "exists!""#,
            merchant_id
        )
        .fetch_one(&mut *tx)
        .await?;
        if !is_merchant_known
        {
            return Err(ApiError::Validation("merchant_id"));
        }
    }

    if let Some(cash_account_id) = a_req.cash_account_id
    {
        let cash = require_account_editor(&mut *tx, cash_account_id, a_user_id)
            .await
            .map_err(|_| ApiError::Validation("cash_account_id"))?;
        if cash.account_type != AccountType::Cash || !cash.is_manual() || cash.curr_id != a_req.curr_id
        {
            return Err(ApiError::Validation("cash_account_id"));
        }
    }

    let receipt_id = match a_id
    {
        Some(id) =>
        {
            lock_owned(&mut tx, id, a_user_id).await?;
            sqlx::query!(
                r#"
                UPDATE receipts
                SET receipt_ts = $2, merchant_id = $3, merchant_name = $4, place_id = $5, curr_id = $6,
                    cash_account_id = $7, note = $8
                WHERE id = $1
                "#,
                id,
                a_req.receipt_ts,
                a_req.merchant_id,
                merchant_name,
                a_req.place_id,
                a_req.curr_id,
                a_req.cash_account_id,
                note
            )
            .execute(&mut *tx)
            .await?;
            id
        }
        None => sqlx::query_scalar!(
            r#"
            INSERT INTO receipts (owner_id, receipt_ts, merchant_id, merchant_name, place_id, curr_id, cash_account_id, note)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            RETURNING id
            "#,
            a_user_id,
            a_req.receipt_ts,
            a_req.merchant_id,
            merchant_name,
            a_req.place_id,
            a_req.curr_id,
            a_req.cash_account_id,
            note
        )
        .fetch_one(&mut *tx)
        .await?,
    };

    sqlx::query!("DELETE FROM receipt_items WHERE receipt_id = $1", receipt_id)
        .execute(&mut *tx)
        .await?;

    for (pos, item) in items.iter().enumerate()
    {
        sqlx::query!(
            r#"
            INSERT INTO receipt_items (receipt_id, pos, item_id, qty, unit_price, amount)
            VALUES ($1, $2, $3, $4, $5, $6)
            "#,
            receipt_id,
            pos as i16,
            item.item_id,
            item.qty,
            item.unit_price,
            item.amount
        )
        .execute(&mut *tx)
        .await?;
    }

    let paid_total = link_transactions(&mut tx, receipt_id, a_user_id, a_req.curr_id, &tx_ids).await?;
    let items_total: Decimal = items.iter().map(|item| item.amount).sum();
    let cash_amount = (items_total - paid_total).max(Decimal::ZERO);

    sync_cash_payment(
        &mut tx,
        receipt_id,
        a_user_id,
        a_req.cash_account_id,
        cash_amount,
        a_req.receipt_ts,
        merchant_name.as_deref(),
    )
    .await?;

    let receipt = load_receipt(&mut tx, receipt_id, a_user_id).await?;
    tx.commit().await?;
    Ok(receipt)
}

fn clean_items(a_items: &[SaveReceiptItemRequest]) -> Result<Vec<SaveReceiptItemRequest>, ApiError>
{
    if a_items.len() > MAX_ITEMS
    {
        return Err(ApiError::Validation("items"));
    }

    a_items
        .iter()
        .map(|item| {
            let amount = check_money(item.amount, "amount")?;
            if amount < Decimal::ZERO
            {
                return Err(ApiError::Validation("amount"));
            }

            let unit_price = item
                .unit_price
                .map(|price| check_money(price, "unit_price"))
                .transpose()?
                .filter(|price| *price >= Decimal::ZERO);

            Ok(SaveReceiptItemRequest {
                item_id: item.item_id,
                qty: check_qty(item.qty)?,
                unit_price,
                amount,
            })
        })
        .collect()
}

async fn link_transactions(
    a_conn: &mut PgConnection,
    a_receipt_id: Uuid,
    a_user_id: Uuid,
    a_curr_id: Uuid,
    a_tx_ids: &[Uuid],
) -> Result<Decimal, ApiError>
{
    let candidates = sqlx::query_as!(
        LinkCandidate,
        r#"
        SELECT
            t.amount,
            t.op_amount,
            t.curr_id,
            t.op_curr_id,
            t.source AS "source: TxSource",
            t.receipt_id,
            v.is_editor AS "is_editor!"
        FROM transactions t
        JOIN account_viewers v ON v.account_id = t.account_id AND v.viewer_id = $2
        WHERE t.id = ANY($1)
        "#,
        a_tx_ids,
        a_user_id
    )
    .fetch_all(&mut *a_conn)
    .await?;

    if candidates.len() != a_tx_ids.len()
    {
        return Err(ApiError::Validation("tx_ids"));
    }

    let mut paid_total = Decimal::ZERO;

    for candidate in &candidates
    {
        let is_linkable = candidate.is_editor
            && candidate.amount < Decimal::ZERO
            && candidate.source != TxSource::ReceiptCash
            && candidate.receipt_id.is_none_or(|linked| linked == a_receipt_id);

        let paid = if candidate.curr_id == a_curr_id
        {
            Some(-candidate.amount)
        }
        else if candidate.op_curr_id == Some(a_curr_id)
        {
            candidate.op_amount.map(|amount| -amount)
        }
        else
        {
            None
        };

        match paid
        {
            Some(paid) if is_linkable => paid_total += paid,
            _ => return Err(ApiError::Validation("tx_ids")),
        }
    }

    sqlx::query!(
        r#"
        UPDATE transactions SET receipt_id = NULL
        WHERE receipt_id = $1 AND source <> 'receipt_cash' AND NOT (id = ANY($2))
        "#,
        a_receipt_id,
        a_tx_ids
    )
    .execute(&mut *a_conn)
    .await?;

    sqlx::query!(
        "UPDATE transactions SET receipt_id = $1 WHERE id = ANY($2)",
        a_receipt_id,
        a_tx_ids
    )
    .execute(&mut *a_conn)
    .await?;

    Ok(paid_total)
}

async fn sync_cash_payment(
    a_conn: &mut PgConnection,
    a_receipt_id: Uuid,
    a_user_id: Uuid,
    a_cash_account_id: Option<Uuid>,
    a_cash_amount: Decimal,
    a_receipt_ts: chrono::DateTime<chrono::Utc>,
    a_merchant_name: Option<&str>,
) -> Result<(), ApiError>
{
    match a_cash_account_id.filter(|_| a_cash_amount > Decimal::ZERO)
    {
        None =>
        {
            sqlx::query!(
                "DELETE FROM transactions WHERE receipt_id = $1 AND source = 'receipt_cash'",
                a_receipt_id
            )
            .execute(&mut *a_conn)
            .await?;
        }
        Some(cash_account_id) =>
        {
            sqlx::query!(
                r#"
                DELETE FROM transactions
                WHERE receipt_id = $1 AND source = 'receipt_cash' AND account_id <> $2
                "#,
                a_receipt_id,
                cash_account_id
            )
            .execute(&mut *a_conn)
            .await?;

            sqlx::query!(
                r#"
                INSERT INTO transactions (
                    user_id, account_id, curr_id, amount, tx_type, tx_ts, source, description, receipt_id
                )
                SELECT $1, a.id, a.curr_id, $3, 'expense', $4, 'receipt_cash', $5, $6
                FROM accounts a WHERE a.id = $2
                ON CONFLICT (receipt_id) WHERE source = 'receipt_cash' DO UPDATE SET
                    amount = EXCLUDED.amount,
                    tx_ts = EXCLUDED.tx_ts,
                    description = EXCLUDED.description
                "#,
                a_user_id,
                cash_account_id,
                -a_cash_amount,
                a_receipt_ts,
                a_merchant_name,
                a_receipt_id
            )
            .execute(&mut *a_conn)
            .await?;
        }
    }

    Ok(())
}

async fn lock_owned(a_conn: &mut PgConnection, a_id: Uuid, a_user_id: Uuid) -> Result<(), ApiError>
{
    sqlx::query_scalar!(
        "SELECT id FROM receipts WHERE id = $1 AND owner_id = $2 FOR UPDATE",
        a_id,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .ok_or(ApiError::NotFound)?;

    Ok(())
}

async fn load_receipt(a_conn: &mut PgConnection, a_id: Uuid, a_user_id: Uuid) -> Result<ReceiptDto, ApiError>
{
    let head = sqlx::query_as!(
        ReceiptHead,
        r#"
        SELECT
            r.id,
            r.receipt_ts,
            r.merchant_id,
            COALESCE(r.merchant_name, m.name) AS merchant_name,
            r.place_id,
            p.name AS "place_name?",
            r.curr_id,
            c.code AS curr_code,
            r.cash_account_id,
            r.note
        FROM receipts r
        JOIN currencies c ON c.id = r.curr_id
        LEFT JOIN merchants m ON m.id = r.merchant_id
        LEFT JOIN places p ON p.id = r.place_id
        WHERE r.id = $1 AND r.owner_id = $2
        "#,
        a_id,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .ok_or(ApiError::NotFound)?;

    let items = sqlx::query_as!(
        ReceiptItemDto,
        r#"
        SELECT ri.item_id, i.name, i.type AS "kind: ItemKind", i.unit AS "unit: ItemUnit", ri.qty, ri.unit_price, ri.amount
        FROM receipt_items ri
        JOIN items i ON i.id = ri.item_id
        WHERE ri.receipt_id = $1
        ORDER BY ri.pos
        "#,
        a_id
    )
    .fetch_all(&mut *a_conn)
    .await?;

    let tx_ids = sqlx::query_scalar!(
        "SELECT id FROM transactions WHERE receipt_id = $1 AND source <> 'receipt_cash'",
        a_id
    )
    .fetch_all(&mut *a_conn)
    .await?;
    let txs = load_txs(&mut *a_conn, &tx_ids, a_user_id).await?;

    let items_total: Decimal = items.iter().map(|item| item.amount).sum();
    let paid_total: Decimal = txs
        .iter()
        .map(|tx| match tx.op_curr_code.as_deref()
        {
            Some(code) if code == head.curr_code && tx.curr_code != head.curr_code => -tx.op_amount.unwrap_or_default(),
            _ => -tx.amount,
        })
        .sum();

    Ok(ReceiptDto {
        id: head.id,
        receipt_ts: head.receipt_ts,
        merchant_id: head.merchant_id,
        merchant_name: head.merchant_name,
        place_id: head.place_id,
        place_name: head.place_name,
        curr_id: head.curr_id,
        curr_code: head.curr_code,
        cash_account_id: head.cash_account_id,
        note: head.note,
        items,
        txs,
        items_total: money(items_total),
        paid_total: money(paid_total),
        rest_amount: money((paid_total - items_total).max(Decimal::ZERO)),
        cash_amount: money((items_total - paid_total).max(Decimal::ZERO)),
    })
}
