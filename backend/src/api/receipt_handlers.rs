use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use rust_decimal::Decimal;
use shared_schema::{
    AccountType, ItemKind, ItemUnit, NewItemRequest, ReceiptDto, ReceiptItemDto, ReceiptListItemDto, ReceiptQuery,
    SaveReceiptItemRequest, SaveReceiptRequest, TxSource,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::api::item_handlers::{require_visible_items, resolve_new_item, MAX_ITEM_NAME_LEN};
use crate::api::place_handlers::{learn_merchant_places, place_from_receipt, require_visible_place};
use crate::api::recognize_handlers::alias_key;
use crate::api::tx_handlers::load_txs;
use crate::domain::errors::ApiError;
use crate::domain::finance_access::require_account_editor;
use crate::domain::validation::{
    check_money, check_qty, clean_barcode, clean_optional_text, clean_text, money, MAX_NAME_LEN, MAX_NOTE_LEN,
};
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
    place_addr_id: Option<Uuid>,
    branch: Option<String>,
    curr_id: Uuid,
    curr_code: String,
    cash_account_id: Option<Uuid>,
    note: Option<String>,
    discount: Decimal,
    is_editable: bool,
    owner_name: Option<String>,
}

enum ItemRef
{
    Existing(Uuid),
    New(NewItemRequest),
}

struct CleanItem
{
    item: ItemRef,
    alias: Option<String>,
    qty: Decimal,
    unit_price: Option<Decimal>,
    amount: Decimal,
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
            r.discount,
            (SELECT COUNT(*) FROM receipt_items i WHERE i.receipt_id = r.id) AS "item_count!",
            (SELECT COUNT(*) FROM transactions t WHERE t.receipt_id = r.id AND t.source <> 'receipt_cash') AS "tx_count!",
            CASE WHEN r.owner_id <> $1 THEN owner.first_name || ' ' || owner.last_name END AS owner_name
        FROM receipts r
        JOIN users owner ON owner.id = r.owner_id
        JOIN currencies c ON c.id = r.curr_id
        LEFT JOIN merchants m ON m.id = r.merchant_id
        LEFT JOIN places p ON p.id = r.place_id
        WHERE (r.owner_id = $1 OR EXISTS (
                SELECT 1 FROM transactions t
                JOIN account_viewers v ON v.account_id = t.account_id AND v.viewer_id = $1
                WHERE t.receipt_id = r.id
              ))
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
    let items_total: Decimal = items.iter().map(|item| item.amount).sum();
    let discount = check_money(a_req.discount, "discount")?;
    if discount < Decimal::ZERO || discount > items_total
    {
        return Err(ApiError::Validation("discount"));
    }
    let mut tx_ids = a_req.tx_ids.clone();
    tx_ids.sort_unstable();
    tx_ids.dedup();

    if tx_ids.len() > MAX_LINKED_TXS
    {
        return Err(ApiError::Validation("tx_ids"));
    }

    let mut tx = a_state.db.begin().await?;
    let attached_place_id = match a_id
    {
        Some(id) => lock_owned(&mut tx, id, a_user_id).await?,
        None => None,
    };

    let item_ids: Vec<Uuid> = items
        .iter()
        .filter_map(|item| match item.item
        {
            ItemRef::Existing(id) => Some(id),
            ItemRef::New(_) => None,
        })
        .collect();
    require_visible_items(&mut tx, &item_ids, a_user_id, a_id).await?;

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

    let (place_id, place_addr_id) = match (&a_req.new_place, a_req.place_id)
    {
        (Some(new_place), None) if new_place.place_id.is_none() =>
        {
            let (place_id, addr_id) = place_from_receipt(&mut tx, a_user_id, new_place).await?;
            (Some(place_id), addr_id)
        }
        (Some(new_place), Some(place_id)) if new_place.place_id == Some(place_id) && a_req.place_addr_id.is_none() =>
        {
            require_visible_place(&mut tx, Some(place_id), None, a_user_id, attached_place_id).await?;
            let (_, addr_id) = place_from_receipt(&mut tx, a_user_id, new_place).await?;
            (Some(place_id), addr_id)
        }
        _ =>
        {
            require_visible_place(
                &mut tx,
                a_req.place_id,
                a_req.place_addr_id,
                a_user_id,
                attached_place_id,
            )
            .await?;
            (a_req.place_id, a_req.place_addr_id)
        }
    };

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
            sqlx::query!(
                r#"
                UPDATE receipts
                SET receipt_ts = $2, merchant_id = $3, merchant_name = $4, place_id = $5, curr_id = $6,
                    cash_account_id = $7, note = $8, place_addr_id = $9, discount = $10
                WHERE id = $1
                "#,
                id,
                a_req.receipt_ts,
                a_req.merchant_id,
                merchant_name,
                place_id,
                a_req.curr_id,
                a_req.cash_account_id,
                note,
                place_addr_id,
                discount
            )
            .execute(&mut *tx)
            .await?;
            id
        }
        None => sqlx::query_scalar!(
            r#"
            INSERT INTO receipts (
                owner_id, receipt_ts, merchant_id, merchant_name, place_id, curr_id, cash_account_id, note, place_addr_id,
                discount
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            RETURNING id
            "#,
            a_user_id,
            a_req.receipt_ts,
            a_req.merchant_id,
            merchant_name,
            place_id,
            a_req.curr_id,
            a_req.cash_account_id,
            note,
            place_addr_id,
            discount
        )
        .fetch_one(&mut *tx)
        .await?,
    };

    sqlx::query!("DELETE FROM receipt_items WHERE receipt_id = $1", receipt_id)
        .execute(&mut *tx)
        .await?;

    let mut created: Vec<(String, Uuid)> = Vec::new();
    for (pos, item) in items.iter().enumerate()
    {
        let item_id = match &item.item
        {
            ItemRef::Existing(id) => *id,
            ItemRef::New(new_item) =>
            {
                let key = new_item.name.to_lowercase();
                match created.iter().find(|(name, _)| *name == key)
                {
                    Some((_, id)) => *id,
                    None =>
                    {
                        let id = resolve_new_item(&mut tx, a_user_id, new_item).await?;
                        created.push((key, id));
                        id
                    }
                }
            }
        };

        sqlx::query!(
            r#"
            INSERT INTO receipt_items (receipt_id, pos, item_id, qty, unit_price, amount)
            VALUES ($1, $2, $3, $4, $5, $6)
            "#,
            receipt_id,
            pos as i16,
            item_id,
            item.qty,
            item.unit_price,
            item.amount
        )
        .execute(&mut *tx)
        .await?;

        if let Some(alias) = &item.alias
        {
            sqlx::query!(
                r#"
                INSERT INTO item_aliases (user_id, alias_key, item_id)
                VALUES ($1, $2, $3)
                ON CONFLICT (user_id, alias_key) DO UPDATE SET item_id = EXCLUDED.item_id, updated_ts = NOW()
                "#,
                a_user_id,
                alias,
                item_id
            )
            .execute(&mut *tx)
            .await?;
        }
    }

    let paid_total = link_transactions(&mut tx, receipt_id, a_user_id, a_req.curr_id, &tx_ids).await?;
    learn_merchant_places(&mut tx, a_user_id, receipt_id, place_id, place_addr_id).await?;
    let cash_amount = (items_total - discount - paid_total).max(Decimal::ZERO);

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

fn clean_items(a_items: &[SaveReceiptItemRequest]) -> Result<Vec<CleanItem>, ApiError>
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

            let item_ref = match (item.item_id, &item.new_item)
            {
                (Some(id), None) => ItemRef::Existing(id),
                (None, Some(new_item)) => ItemRef::New(NewItemRequest {
                    name: clean_text(&new_item.name, 1, MAX_ITEM_NAME_LEN, "new_item.name")?,
                    kind: new_item.kind,
                    unit: new_item.unit,
                    barcode: clean_barcode(new_item.barcode.as_deref())?,
                    family_id: new_item.family_id,
                }),
                _ => return Err(ApiError::Validation("item_id")),
            };

            Ok(CleanItem {
                item: item_ref,
                alias: item.source_text.as_deref().and_then(alias_key),
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

async fn lock_owned(a_conn: &mut PgConnection, a_id: Uuid, a_user_id: Uuid) -> Result<Option<Uuid>, ApiError>
{
    let row = sqlx::query!(
        "SELECT place_id FROM receipts WHERE id = $1 AND owner_id = $2 FOR UPDATE",
        a_id,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .ok_or(ApiError::NotFound)?;

    Ok(row.place_id)
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
            r.place_addr_id,
            CASE WHEN pa.id IS NOT NULL THEN addr_label(ci.name, st.name, pa.house_num, pa.zip) END AS branch,
            r.curr_id,
            c.code AS curr_code,
            r.cash_account_id,
            r.note,
            r.discount,
            (r.owner_id = $2) AS "is_editable!",
            CASE WHEN r.owner_id <> $2 THEN owner.first_name || ' ' || owner.last_name END AS owner_name
        FROM receipts r
        JOIN users owner ON owner.id = r.owner_id
        JOIN currencies c ON c.id = r.curr_id
        LEFT JOIN merchants m ON m.id = r.merchant_id
        LEFT JOIN places p ON p.id = r.place_id
        LEFT JOIN place_addrs pa ON pa.id = r.place_addr_id
        LEFT JOIN streets st ON st.id = pa.street_id
        LEFT JOIN cities ci ON ci.id = pa.city_id
        WHERE r.id = $1 AND (r.owner_id = $2 OR EXISTS (
            SELECT 1 FROM transactions t
            JOIN account_viewers v ON v.account_id = t.account_id AND v.viewer_id = $2
            WHERE t.receipt_id = r.id
        ))
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
    let payable = items_total - head.discount;
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
        place_addr_id: head.place_addr_id,
        branch: head.branch,
        curr_id: head.curr_id,
        curr_code: head.curr_code,
        cash_account_id: head.cash_account_id,
        note: head.note,
        items,
        txs,
        items_total: money(items_total),
        discount: money(head.discount),
        paid_total: money(paid_total),
        rest_amount: money((paid_total - payable).max(Decimal::ZERO)),
        cash_amount: money((payable - paid_total).max(Decimal::ZERO)),
        is_editable: head.is_editable,
        owner_name: head.owner_name,
    })
}
