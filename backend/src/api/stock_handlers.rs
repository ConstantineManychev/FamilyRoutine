use std::collections::BTreeMap;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, NaiveTime, Utc};
use rust_decimal::Decimal;
use shared_schema::{
    BatchQuery, CookBatchDto, CookBatchItemDto, CookRequest, ItemKind, ItemUnit, MacrosDto, MoneyTotalDto, NetMeasure,
    NewStockLotRequest, SaveStockSettingsRequest, StockDto, StockKind, StockLotDto, StockMeasure, StockMoveDto,
    StockMoveKind, StockMovesDto, StockMovesQuery, StockQuery, StockSettingsDto, StockSource, StockStoreDto,
    WasteReason, WasteRequest,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::api::nutrition_handlers::{
    bounded, item_per_100, load_dish, require_food_items, COOKED_RATIO_LIMIT, MAX_COOKED_G, MAX_INGREDIENTS,
    MAX_INGREDIENT_G,
};
use crate::domain::errors::ApiError;
use crate::domain::validation::{check_money, clean_optional_text};
use crate::security::authz::require_member;
use crate::services::nutrition::{dish_math, Ingredient};
use crate::services::stock::{
    cost_share, grams_per_unit, intake_qty, manual_qty, plan_fifo, qty, ItemShape, LotLeft, COST_SCALE,
};
use crate::state::AppState;

const MAX_LOTS_PER_STORE: i64 = 20_000;
const MAX_NOTE_LEN: usize = 500;
const MAX_PAST_DAYS: i64 = 3_660;
const DEFAULT_MOVES: i64 = 100;
const MAX_MOVES: i64 = 500;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Store
{
    pub owner_id: Option<Uuid>,
    pub family_id: Option<Uuid>,
}

impl Store
{
    fn personal(a_user_id: Uuid) -> Self
    {
        Self {
            owner_id: Some(a_user_id),
            family_id: None,
        }
    }

    fn group(a_family_id: Uuid) -> Self
    {
        Self {
            owner_id: None,
            family_id: Some(a_family_id),
        }
    }

    fn of(a_owner_id: Option<Uuid>, a_family_id: Option<Uuid>) -> Self
    {
        Self {
            owner_id: a_owner_id,
            family_id: a_family_id,
        }
    }

    fn lock_key(&self) -> String
    {
        format!("stock:{}", self.family_id.or(self.owner_id).unwrap_or_default())
    }
}

#[derive(Debug, Clone, Copy)]
pub enum Consumer
{
    Entry(Uuid),
    Batch(Uuid),
}

struct LotRow
{
    id: Uuid,
    kind: StockKind,
    item_id: Option<Uuid>,
    dish_id: Option<Uuid>,
    batch_id: Option<Uuid>,
    title: String,
    measure: StockMeasure,
    qty: Decimal,
    left_qty: Decimal,
    cost: Option<Decimal>,
    curr_code: Option<String>,
    source: StockSource,
    receipt_id: Option<Uuid>,
    acquired_ts: DateTime<Utc>,
    is_touched: bool,
    piece_g: Option<Decimal>,
    item_kcal: Option<Decimal>,
    item_prot: Option<Decimal>,
    item_fat: Option<Decimal>,
    item_carb: Option<Decimal>,
    batch_kcal: Option<Decimal>,
    batch_prot: Option<Decimal>,
    batch_fat: Option<Decimal>,
    batch_carb: Option<Decimal>,
}

impl From<LotRow> for StockLotDto
{
    fn from(a_row: LotRow) -> Self
    {
        let per_100 = match a_row.kind
        {
            StockKind::Item => item_per_100(a_row.item_kcal, a_row.item_prot, a_row.item_fat, a_row.item_carb),
            StockKind::Dish => item_per_100(a_row.batch_kcal, a_row.batch_prot, a_row.batch_fat, a_row.batch_carb),
        };
        let left_qty = a_row.left_qty.max(Decimal::ZERO);
        Self {
            id: a_row.id,
            kind: a_row.kind,
            item_id: a_row.item_id,
            dish_id: a_row.dish_id,
            batch_id: a_row.batch_id,
            title: a_row.title,
            measure: a_row.measure,
            qty: a_row.qty.normalize(),
            left_qty: left_qty.normalize(),
            cost: a_row.cost,
            left_cost: cost_share(a_row.cost, a_row.qty, left_qty),
            curr_code: a_row.curr_code,
            source: a_row.source,
            receipt_id: a_row.receipt_id,
            acquired_ts: a_row.acquired_ts,
            is_touched: a_row.is_touched,
            piece_g: a_row.piece_g.map(|value| value.normalize()),
            per_100,
        }
    }
}

pub async fn lock_store(a_conn: &mut PgConnection, a_store: Store) -> Result<(), ApiError>
{
    sqlx::query!("SELECT pg_advisory_xact_lock(hashtext($1))", a_store.lock_key())
        .execute(&mut *a_conn)
        .await?;
    Ok(())
}

pub async fn active_store(a_conn: &mut PgConnection, a_user_id: Uuid) -> Result<Store, ApiError>
{
    let family_id = sqlx::query_scalar!(
        r#"
        SELECT s.family_id AS "family_id!"
        FROM stock_settings s
        JOIN family_mems fm ON fm.family_id = s.family_id AND fm.user_id = s.user_id
        WHERE s.user_id = $1
        "#,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?;
    Ok(family_id.map_or_else(|| Store::personal(a_user_id), Store::group))
}

async fn chosen_store(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_family_id: Option<Uuid>,
    a_is_personal: bool,
) -> Result<Store, ApiError>
{
    match (a_family_id, a_is_personal)
    {
        (Some(family_id), false) =>
        {
            require_member(&mut *a_conn, family_id, a_user_id).await?;
            Ok(Store::group(family_id))
        }
        (None, true) => Ok(Store::personal(a_user_id)),
        (None, false) => active_store(a_conn, a_user_id).await,
        (Some(_), true) => Err(ApiError::Validation("family_id")),
    }
}

async fn require_room(a_conn: &mut PgConnection, a_store: Store, a_added: i64) -> Result<(), ApiError>
{
    let count = sqlx::query_scalar!(
        r#"
        SELECT COUNT(*) AS "count!"
        FROM stock_lots
        WHERE owner_id IS NOT DISTINCT FROM $1 AND family_id IS NOT DISTINCT FROM $2
        "#,
        a_store.owner_id,
        a_store.family_id
    )
    .fetch_one(&mut *a_conn)
    .await?;
    if count + a_added > MAX_LOTS_PER_STORE
    {
        return Err(ApiError::Conflict("TOO_MANY_LOTS"));
    }
    Ok(())
}

async fn store_name(a_conn: &mut PgConnection, a_store: Store) -> Result<Option<String>, ApiError>
{
    let Some(family_id) = a_store.family_id
    else
    {
        return Ok(None);
    };
    Ok(
        sqlx::query_scalar!("SELECT name FROM families WHERE id = $1", family_id)
            .fetch_optional(&mut *a_conn)
            .await?,
    )
}

async fn insert_moves(
    a_conn: &mut PgConnection,
    a_takes: &[crate::services::stock::Take],
    a_consumer: Consumer,
    a_user_id: Uuid,
) -> Result<(), ApiError>
{
    let (kind, entry_id, batch_id) = match a_consumer
    {
        Consumer::Entry(id) => (StockMoveKind::Eaten, Some(id), None),
        Consumer::Batch(id) => (StockMoveKind::Cooked, None, Some(id)),
    };
    for take in a_takes
    {
        sqlx::query!(
            r#"
            INSERT INTO stock_moves (lot_id, kind, qty, cost, meal_entry_id, batch_id, user_id)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            "#,
            take.lot_id,
            kind as StockMoveKind,
            take.qty,
            take.cost,
            entry_id,
            batch_id,
            a_user_id
        )
        .execute(&mut *a_conn)
        .await?;
    }
    Ok(())
}

pub async fn consume_item(
    a_conn: &mut PgConnection,
    a_store: Store,
    a_item_id: Uuid,
    a_grams: Decimal,
    a_consumer: Consumer,
    a_user_id: Uuid,
) -> Result<Decimal, ApiError>
{
    lock_store(a_conn, a_store).await?;
    let rows = sqlx::query!(
        r#"
        SELECT l.id, l.measure AS "measure: StockMeasure", l.qty, l.cost, i.piece_g,
               l.qty - COALESCE((SELECT SUM(m.qty) FROM stock_moves m WHERE m.lot_id = l.id), 0) AS "left!"
        FROM stock_lots l
        JOIN items i ON i.id = l.item_id
        WHERE l.owner_id IS NOT DISTINCT FROM $1 AND l.family_id IS NOT DISTINCT FROM $2
          AND l.kind = 'item' AND l.item_id = $3
        ORDER BY l.acquired_ts, l.created_ts, l.id
        "#,
        a_store.owner_id,
        a_store.family_id,
        a_item_id
    )
    .fetch_all(&mut *a_conn)
    .await?;
    let lots: Vec<LotLeft> = rows
        .into_iter()
        .map(|row| LotLeft {
            id: row.id,
            qty: row.qty,
            left: row.left,
            grams_per_unit: grams_per_unit(row.measure, row.piece_g),
            cost: row.cost,
        })
        .collect();
    let (takes, short) = plan_fifo(&lots, a_grams);
    insert_moves(a_conn, &takes, a_consumer, a_user_id).await?;
    Ok(short)
}

pub async fn consume_batch(
    a_conn: &mut PgConnection,
    a_batch_id: Uuid,
    a_grams: Decimal,
    a_entry_id: Uuid,
    a_user_id: Uuid,
) -> Result<Decimal, ApiError>
{
    let Some(lot) = sqlx::query!(
        "SELECT id, owner_id, family_id, qty, cost FROM stock_lots WHERE batch_id = $1",
        a_batch_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    else
    {
        return Ok(qty(a_grams));
    };
    lock_store(a_conn, Store::of(lot.owner_id, lot.family_id)).await?;
    let left = sqlx::query_scalar!(
        r#"SELECT $2 - COALESCE(SUM(qty), 0) AS "left!" FROM stock_moves WHERE lot_id = $1"#,
        lot.id,
        lot.qty
    )
    .fetch_one(&mut *a_conn)
    .await?;
    let (takes, short) = plan_fifo(
        &[LotLeft {
            id: lot.id,
            qty: lot.qty,
            left,
            grams_per_unit: Some(Decimal::ONE),
            cost: lot.cost,
        }],
        a_grams,
    );
    insert_moves(a_conn, &takes, Consumer::Entry(a_entry_id), a_user_id).await?;
    Ok(short)
}

pub async fn entry_store(a_conn: &mut PgConnection, a_entry_id: Uuid, a_user_id: Uuid) -> Result<Store, ApiError>
{
    let used = sqlx::query!(
        r#"
        SELECT l.owner_id, l.family_id
        FROM stock_moves m
        JOIN stock_lots l ON l.id = m.lot_id
        WHERE m.meal_entry_id = $1
        LIMIT 1
        "#,
        a_entry_id
    )
    .fetch_optional(&mut *a_conn)
    .await?;
    match used
    {
        Some(row) => Ok(Store::of(row.owner_id, row.family_id)),
        None => active_store(a_conn, a_user_id).await,
    }
}

pub async fn require_visible_batch(a_conn: &mut PgConnection, a_batch_id: Uuid, a_user_id: Uuid)
    -> Result<(), ApiError>
{
    let is_visible = sqlx::query_scalar!(
        r#"
        SELECT EXISTS (
            SELECT 1 FROM cook_batches b
            WHERE b.id = $1
              AND (b.owner_id = $2 OR b.family_id IN (SELECT family_id FROM family_mems WHERE user_id = $2))
        ) AS "exists!"
        "#,
        a_batch_id,
        a_user_id
    )
    .fetch_one(&mut *a_conn)
    .await?;
    if !is_visible
    {
        return Err(ApiError::Validation("batch_id"));
    }
    Ok(())
}

pub async fn sync_receipt_stock(
    a_conn: &mut PgConnection,
    a_receipt_id: Uuid,
    a_owner_id: Uuid,
    a_is_stocked: bool,
    a_paid_share: Decimal,
) -> Result<(), ApiError>
{
    let head = sqlx::query!("SELECT curr_id, receipt_ts FROM receipts WHERE id = $1", a_receipt_id)
        .fetch_one(&mut *a_conn)
        .await?;
    let lots = sqlx::query!(
        r#"
        SELECT l.id, l.receipt_pos AS "receipt_pos!", l.item_id, l.measure AS "measure: StockMeasure", l.owner_id,
               l.family_id, EXISTS (SELECT 1 FROM stock_moves m WHERE m.lot_id = l.id) AS "is_touched!"
        FROM stock_lots l
        WHERE l.receipt_id = $1 AND l.receipt_pos IS NOT NULL
        FOR UPDATE
        "#,
        a_receipt_id
    )
    .fetch_all(&mut *a_conn)
    .await?;
    let items = sqlx::query!(
        r#"
        SELECT ri.pos, ri.item_id, ri.qty, ri.amount, i.name, i.type AS "kind: ItemKind", i.unit AS "unit: ItemUnit",
               i.net_qty, i.net_measure AS "net_measure: NetMeasure", i.piece_g
        FROM receipt_items ri
        JOIN items i ON i.id = ri.item_id
        WHERE ri.receipt_id = $1
        ORDER BY ri.pos
        "#,
        a_receipt_id
    )
    .fetch_all(&mut *a_conn)
    .await?;

    let mut wanted: BTreeMap<i16, (Uuid, String, StockMeasure, Decimal, Decimal)> = BTreeMap::new();
    if a_is_stocked
    {
        for item in items
        {
            let shape = ItemShape {
                kind: item.kind,
                unit: item.unit,
                net_qty: item.net_qty,
                net_measure: item.net_measure,
                piece_g: item.piece_g,
            };
            if let Some((measure, amount)) = intake_qty(&shape, item.qty)
            {
                let cost = (item.amount * a_paid_share).round_dp(COST_SCALE);
                wanted.insert(item.pos, (item.item_id, item.name, measure, amount, cost));
            }
        }
    }

    let store = match lots.first()
    {
        Some(lot) => Store::of(lot.owner_id, lot.family_id),
        None if wanted.is_empty() => return Ok(()),
        None => active_store(a_conn, a_owner_id).await?,
    };
    lock_store(a_conn, store).await?;

    for lot in &lots
    {
        let is_same = wanted
            .get(&lot.receipt_pos)
            .is_some_and(|(item_id, _, measure, _, _)| Some(*item_id) == lot.item_id && *measure == lot.measure);
        if is_same
        {
            if let Some((_, title, _, amount, cost)) = wanted.remove(&lot.receipt_pos)
            {
                sqlx::query!(
                    r#"
                    UPDATE stock_lots
                    SET qty = $2, cost = $3, curr_id = $4, title = $5, acquired_ts = $6
                    WHERE id = $1
                    "#,
                    lot.id,
                    amount,
                    cost,
                    head.curr_id,
                    title,
                    head.receipt_ts
                )
                .execute(&mut *a_conn)
                .await?;
            }
        }
        else if lot.is_touched
        {
            sqlx::query!("UPDATE stock_lots SET receipt_pos = NULL WHERE id = $1", lot.id)
                .execute(&mut *a_conn)
                .await?;
        }
        else
        {
            sqlx::query!("DELETE FROM stock_lots WHERE id = $1", lot.id)
                .execute(&mut *a_conn)
                .await?;
        }
    }

    require_room(a_conn, store, i64::try_from(wanted.len()).unwrap_or(i64::MAX)).await?;
    for (pos, (item_id, title, measure, amount, cost)) in wanted
    {
        sqlx::query!(
            r#"
            INSERT INTO stock_lots (
                owner_id, family_id, kind, item_id, title, measure, qty, cost, curr_id, source, receipt_id,
                receipt_pos, added_by, acquired_ts
            )
            VALUES ($1, $2, 'item', $3, $4, $5, $6, $7, $8, 'receipt', $9, $10, $11, $12)
            "#,
            store.owner_id,
            store.family_id,
            item_id,
            title,
            measure as StockMeasure,
            amount,
            cost,
            head.curr_id,
            a_receipt_id,
            pos,
            a_owner_id,
            head.receipt_ts
        )
        .execute(&mut *a_conn)
        .await?;
    }
    Ok(())
}

pub async fn release_receipt_stock(a_conn: &mut PgConnection, a_receipt_id: Uuid) -> Result<(), ApiError>
{
    sqlx::query!(
        r#"
        DELETE FROM stock_lots l
        WHERE l.receipt_id = $1 AND NOT EXISTS (SELECT 1 FROM stock_moves m WHERE m.lot_id = l.id)
        "#,
        a_receipt_id
    )
    .execute(&mut *a_conn)
    .await?;
    sqlx::query!(
        "UPDATE stock_lots SET receipt_pos = NULL WHERE receipt_id = $1",
        a_receipt_id
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(())
}

async fn query_lots(
    a_conn: &mut PgConnection,
    a_store: Store,
    a_lot_id: Option<Uuid>,
    a_is_all: bool,
) -> Result<Vec<StockLotDto>, ApiError>
{
    let rows = sqlx::query_as!(
        LotRow,
        r#"
        SELECT
            l.id,
            l.kind AS "kind: StockKind",
            l.item_id,
            b.dish_id AS "dish_id?",
            l.batch_id,
            l.title,
            l.measure AS "measure: StockMeasure",
            l.qty,
            l.qty - COALESCE(mv.used, 0) AS "left_qty!",
            l.cost,
            c.code AS "curr_code?",
            l.source AS "source: StockSource",
            l.receipt_id,
            l.acquired_ts,
            (mv.used IS NOT NULL) AS "is_touched!",
            i.piece_g AS "piece_g?",
            i.kcal AS "item_kcal?",
            i.prot AS "item_prot?",
            i.fat AS "item_fat?",
            i.carb AS "item_carb?",
            b.kcal_100 AS "batch_kcal?",
            b.prot_100 AS "batch_prot?",
            b.fat_100 AS "batch_fat?",
            b.carb_100 AS "batch_carb?"
        FROM stock_lots l
        LEFT JOIN (SELECT lot_id, SUM(qty) AS used FROM stock_moves GROUP BY lot_id) mv ON mv.lot_id = l.id
        LEFT JOIN items i ON i.id = l.item_id
        LEFT JOIN cook_batches b ON b.id = l.batch_id
        LEFT JOIN currencies c ON c.id = l.curr_id
        WHERE l.owner_id IS NOT DISTINCT FROM $1 AND l.family_id IS NOT DISTINCT FROM $2
          AND ($3::uuid IS NULL OR l.id = $3)
          AND ($4 OR l.qty > COALESCE(mv.used, 0))
        ORDER BY l.kind, LOWER(l.title), l.acquired_ts, l.id
        "#,
        a_store.owner_id,
        a_store.family_id,
        a_lot_id,
        a_is_all
    )
    .fetch_all(&mut *a_conn)
    .await?;
    Ok(rows.into_iter().map(StockLotDto::from).collect())
}

struct VisibleLot
{
    store: Store,
    source: StockSource,
    batch_id: Option<Uuid>,
}

async fn visible_lot(a_conn: &mut PgConnection, a_lot_id: Uuid, a_user_id: Uuid) -> Result<VisibleLot, ApiError>
{
    let row = sqlx::query!(
        r#"
        SELECT l.owner_id, l.family_id, l.source AS "source: StockSource", l.batch_id
        FROM stock_lots l
        WHERE l.id = $1
          AND (l.owner_id = $2 OR l.family_id IN (SELECT family_id FROM family_mems WHERE user_id = $2))
        "#,
        a_lot_id,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .ok_or(ApiError::NotFound)?;
    Ok(VisibleLot {
        store: Store::of(row.owner_id, row.family_id),
        source: row.source,
        batch_id: row.batch_id,
    })
}

async fn load_lot(a_conn: &mut PgConnection, a_store: Store, a_lot_id: Uuid) -> Result<StockLotDto, ApiError>
{
    query_lots(a_conn, a_store, Some(a_lot_id), true)
        .await?
        .into_iter()
        .next()
        .ok_or(ApiError::NotFound)
}

pub async fn get_settings(State(a_state): State<AppState>, a_user: AuthUser)
    -> Result<Json<StockSettingsDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let active = active_store(&mut conn, a_user.user_id).await?;
    let rows = sqlx::query!(
        r#"
        SELECT NULL::uuid AS family_id, NULL::text AS family_name, 0 AS "rank!",
               (SELECT COUNT(*) FROM stock_lots l WHERE l.owner_id = $1
                  AND l.qty > COALESCE((SELECT SUM(m.qty) FROM stock_moves m WHERE m.lot_id = l.id), 0)) AS "lot_count!"
        UNION ALL
        SELECT f.id, f.name, 1,
               (SELECT COUNT(*) FROM stock_lots l WHERE l.family_id = f.id
                  AND l.qty > COALESCE((SELECT SUM(m.qty) FROM stock_moves m WHERE m.lot_id = l.id), 0))
        FROM families f
        JOIN family_mems fm ON fm.family_id = f.id AND fm.user_id = $1
        ORDER BY 3, 2
        "#,
        a_user.user_id
    )
    .fetch_all(&mut *conn)
    .await?;
    Ok(Json(StockSettingsDto {
        active_family_id: active.family_id,
        stores: rows
            .into_iter()
            .map(|row| StockStoreDto {
                is_active: row.family_id == active.family_id,
                family_id: row.family_id,
                family_name: row.family_name,
                lot_count: row.lot_count,
            })
            .collect(),
    }))
}

pub async fn save_settings(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SaveStockSettingsRequest>,
) -> Result<Json<StockSettingsDto>, ApiError>
{
    {
        let mut conn = a_state.db.acquire().await?;
        if let Some(family_id) = a_req.family_id
        {
            require_member(&mut *conn, family_id, a_user.user_id).await?;
        }
        sqlx::query!(
            r#"
            INSERT INTO stock_settings (user_id, family_id) VALUES ($1, $2)
            ON CONFLICT (user_id) DO UPDATE SET family_id = EXCLUDED.family_id, updated_ts = NOW()
            "#,
            a_user.user_id,
            a_req.family_id
        )
        .execute(&mut *conn)
        .await?;
    }
    get_settings(State(a_state), a_user).await
}

pub async fn list_stock(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<StockQuery>,
) -> Result<Json<StockDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let store = chosen_store(&mut conn, a_user.user_id, a_query.family_id, a_query.is_personal).await?;
    let active = active_store(&mut conn, a_user.user_id).await?;
    let lots = query_lots(&mut conn, store, None, false).await?;
    Ok(Json(StockDto {
        family_id: store.family_id,
        family_name: store_name(&mut conn, store).await?,
        is_active: store == active,
        lots,
    }))
}

pub async fn create_lot(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<NewStockLotRequest>,
) -> Result<(StatusCode, Json<StockLotDto>), ApiError>
{
    let cost = match (a_req.cost, a_req.curr_id)
    {
        (Some(cost), Some(_)) =>
        {
            let cost = check_money(cost, "cost")?;
            if cost < Decimal::ZERO
            {
                return Err(ApiError::Validation("cost"));
            }
            Some(cost)
        }
        (None, None) => None,
        _ => return Err(ApiError::Validation("cost")),
    };
    let today = Utc::now().date_naive();
    let acquired_on = a_req.acquired_on.unwrap_or(today);
    if acquired_on > today + Duration::days(1) || acquired_on < today - Duration::days(MAX_PAST_DAYS)
    {
        return Err(ApiError::Validation("acquired_on"));
    }
    let acquired_ts = if acquired_on == today
    {
        Utc::now()
    }
    else
    {
        acquired_on.and_time(NaiveTime::MIN).and_utc()
    };

    let mut tx = a_state.db.begin().await?;
    let store = chosen_store(&mut tx, a_user.user_id, a_req.family_id, a_req.is_personal).await?;
    let item = sqlx::query!(
        r#"
        SELECT name, type AS "kind: ItemKind", unit AS "unit: ItemUnit", net_qty,
               net_measure AS "net_measure: NetMeasure", piece_g
        FROM items WHERE id = $1
        "#,
        a_req.item_id
    )
    .fetch_optional(&mut *tx)
    .await?
    .ok_or(ApiError::Validation("item_id"))?;
    let shape = ItemShape {
        kind: item.kind,
        unit: item.unit,
        net_qty: item.net_qty,
        net_measure: item.net_measure,
        piece_g: item.piece_g,
    };
    let (measure, amount) = manual_qty(&shape, a_req.qty, a_req.unit).ok_or(ApiError::Validation("qty"))?;
    if let Some(curr_id) = a_req.curr_id
    {
        let is_known = sqlx::query_scalar!(
            r#"SELECT EXISTS (SELECT 1 FROM currencies WHERE id = $1) AS "exists!""#,
            curr_id
        )
        .fetch_one(&mut *tx)
        .await?;
        if !is_known
        {
            return Err(ApiError::Validation("curr_id"));
        }
    }
    lock_store(&mut tx, store).await?;
    require_room(&mut tx, store, 1).await?;
    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO stock_lots (
            owner_id, family_id, kind, item_id, title, measure, qty, cost, curr_id, source, added_by, acquired_ts
        )
        VALUES ($1, $2, 'item', $3, $4, $5, $6, $7, $8, 'manual', $9, $10)
        RETURNING id
        "#,
        store.owner_id,
        store.family_id,
        a_req.item_id,
        item.name,
        measure as StockMeasure,
        amount,
        cost,
        a_req.curr_id,
        a_user.user_id,
        acquired_ts
    )
    .fetch_one(&mut *tx)
    .await?;
    let lot = load_lot(&mut tx, store, id).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(lot)))
}

pub async fn delete_lot(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let lot = visible_lot(&mut tx, a_id, a_user.user_id).await?;
    lock_store(&mut tx, lot.store).await?;
    let is_touched = sqlx::query_scalar!(
        r#"SELECT EXISTS (SELECT 1 FROM stock_moves WHERE lot_id = $1) AS "exists!""#,
        a_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if is_touched
    {
        return Err(ApiError::Conflict("STOCK_LOT_USED"));
    }
    match (lot.source, lot.batch_id)
    {
        (StockSource::Receipt, _) => return Err(ApiError::Conflict("STOCK_FROM_RECEIPT")),
        (StockSource::Cooked, Some(batch_id)) =>
        {
            sqlx::query!("DELETE FROM cook_batches WHERE id = $1", batch_id)
                .execute(&mut *tx)
                .await?;
        }
        _ =>
        {
            sqlx::query!("DELETE FROM stock_lots WHERE id = $1", a_id)
                .execute(&mut *tx)
                .await?;
        }
    }
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn waste_lot(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<WasteRequest>,
) -> Result<Json<StockLotDto>, ApiError>
{
    let note = clean_optional_text(a_req.note.as_deref(), MAX_NOTE_LEN, "note")?;
    let amount = qty(a_req.qty);
    if amount <= Decimal::ZERO
    {
        return Err(ApiError::Validation("qty"));
    }
    let mut tx = a_state.db.begin().await?;
    let lot = visible_lot(&mut tx, a_id, a_user.user_id).await?;
    lock_store(&mut tx, lot.store).await?;
    let current = load_lot(&mut tx, lot.store, a_id).await?;
    if amount > current.left_qty
    {
        return Err(ApiError::Validation("qty"));
    }
    sqlx::query!(
        r#"
        INSERT INTO stock_moves (lot_id, kind, qty, cost, reason, note, user_id)
        VALUES ($1, 'waste', $2, $3, $4, $5, $6)
        "#,
        a_id,
        amount,
        cost_share(current.cost, current.qty, amount),
        a_req.reason as WasteReason,
        note,
        a_user.user_id
    )
    .execute(&mut *tx)
    .await?;
    let updated = load_lot(&mut tx, lot.store, a_id).await?;
    tx.commit().await?;
    Ok(Json(updated))
}

async fn load_batches(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_batch_id: Option<Uuid>,
    a_dish_id: Option<Uuid>,
) -> Result<Vec<CookBatchDto>, ApiError>
{
    let rows = sqlx::query!(
        r#"
        SELECT b.id, l.id AS lot_id, b.dish_id, b.family_id, b.title, b.cooked_ts, b.raw_g, b.cooked_g,
               l.qty - COALESCE((SELECT SUM(m.qty) FROM stock_moves m WHERE m.lot_id = l.id), 0) AS "left_g!",
               b.kcal_100, b.prot_100, b.fat_100, b.carb_100, b.missing_count, l.cost, c.code AS "curr_code?", b.note
        FROM cook_batches b
        JOIN stock_lots l ON l.batch_id = b.id
        LEFT JOIN currencies c ON c.id = l.curr_id
        WHERE (b.owner_id = $1 OR b.family_id IN (SELECT family_id FROM family_mems WHERE user_id = $1))
          AND ($2::uuid IS NULL OR b.id = $2)
          AND ($3::uuid IS NULL OR b.dish_id = $3)
        ORDER BY b.cooked_ts, b.id
        "#,
        a_user_id,
        a_batch_id,
        a_dish_id
    )
    .fetch_all(&mut *a_conn)
    .await?;
    let ids: Vec<Uuid> = rows.iter().map(|row| row.id).collect();
    let items = sqlx::query!(
        r#"
        SELECT batch_id, item_id, item_name, grams, short_g
        FROM cook_batch_items
        WHERE batch_id = ANY($1)
        ORDER BY batch_id, position
        "#,
        &ids
    )
    .fetch_all(&mut *a_conn)
    .await?;
    let mut by_batch: BTreeMap<Uuid, Vec<CookBatchItemDto>> = BTreeMap::new();
    for item in items
    {
        by_batch.entry(item.batch_id).or_default().push(CookBatchItemDto {
            item_id: item.item_id,
            item_name: item.item_name,
            grams: item.grams.normalize(),
            short_g: item.short_g.normalize(),
        });
    }
    Ok(rows
        .into_iter()
        .map(|row| CookBatchDto {
            ingredients: by_batch.remove(&row.id).unwrap_or_default(),
            id: row.id,
            lot_id: row.lot_id,
            dish_id: row.dish_id,
            family_id: row.family_id,
            title: row.title,
            cooked_ts: row.cooked_ts,
            raw_g: row.raw_g.normalize(),
            cooked_g: row.cooked_g.normalize(),
            left_g: row.left_g.max(Decimal::ZERO).normalize(),
            per_100: MacrosDto {
                kcal: row.kcal_100.normalize(),
                prot: row.prot_100.normalize(),
                fat: row.fat_100.normalize(),
                carb: row.carb_100.normalize(),
            },
            missing_count: row.missing_count,
            cost: row.cost,
            curr_code: row.curr_code,
            note: row.note,
        })
        .collect())
}

pub async fn load_batch(a_conn: &mut PgConnection, a_user_id: Uuid, a_batch_id: Uuid)
    -> Result<CookBatchDto, ApiError>
{
    load_batches(a_conn, a_user_id, Some(a_batch_id), None)
        .await?
        .into_iter()
        .next()
        .ok_or(ApiError::NotFound)
}

pub async fn list_batches(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<BatchQuery>,
) -> Result<Json<Vec<CookBatchDto>>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let batches = load_batches(&mut conn, a_user.user_id, None, Some(a_query.dish_id)).await?;
    Ok(Json(
        batches
            .into_iter()
            .filter(|batch| batch.left_g > Decimal::ZERO)
            .collect(),
    ))
}

pub async fn cook(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<CookRequest>,
) -> Result<(StatusCode, Json<CookBatchDto>), ApiError>
{
    let note = clean_optional_text(a_req.note.as_deref(), MAX_NOTE_LEN, "note")?;
    if a_req.ingredients.is_empty() || a_req.ingredients.len() > MAX_INGREDIENTS
    {
        return Err(ApiError::Validation("ingredients"));
    }
    let mut item_ids = Vec::with_capacity(a_req.ingredients.len());
    let mut grams = Vec::with_capacity(a_req.ingredients.len());
    for ingredient in &a_req.ingredients
    {
        item_ids.push(ingredient.item_id);
        grams.push(bounded(ingredient.grams, MAX_INGREDIENT_G, "ingredients.grams")?);
    }
    let raw_g: Decimal = grams.iter().sum();
    let cooked_g = bounded(a_req.cooked_g, MAX_COOKED_G, "cooked_g")?;
    let ratio = Decimal::from(COOKED_RATIO_LIMIT);
    if cooked_g * ratio < raw_g || cooked_g > raw_g * ratio
    {
        return Err(ApiError::Validation("cooked_g"));
    }

    let mut tx = a_state.db.begin().await?;
    let store = chosen_store(&mut tx, a_user.user_id, a_req.family_id, a_req.is_personal).await?;
    let dish = match load_dish(&mut tx, a_user.user_id, a_req.dish_id).await
    {
        Err(ApiError::NotFound) => return Err(ApiError::Validation("dish_id")),
        other => other?,
    };
    require_food_items(&mut tx, &item_ids).await?;
    let rows = sqlx::query!(
        "SELECT id, name, kcal, prot, fat, carb FROM items WHERE id = ANY($1)",
        &item_ids
    )
    .fetch_all(&mut *tx)
    .await?;
    let inputs: Vec<(Uuid, String, Ingredient)> = item_ids
        .iter()
        .zip(&grams)
        .filter_map(|(item_id, grams)| {
            rows.iter().find(|row| row.id == *item_id).map(|row| {
                (
                    row.id,
                    row.name.clone(),
                    Ingredient {
                        per_100: item_per_100(row.kcal, row.prot, row.fat, row.carb),
                        grams: *grams,
                    },
                )
            })
        })
        .collect();
    let math = dish_math(
        &inputs.iter().map(|(_, _, input)| *input).collect::<Vec<_>>(),
        Some(cooked_g),
        None,
        None,
    );

    lock_store(&mut tx, store).await?;
    require_room(&mut tx, store, 1).await?;
    let batch_id = sqlx::query_scalar!(
        r#"
        INSERT INTO cook_batches (
            owner_id, family_id, dish_id, title, cooked_by, raw_g, cooked_g, kcal_100, prot_100, fat_100, carb_100,
            missing_count, note
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        RETURNING id
        "#,
        store.owner_id,
        store.family_id,
        dish.id,
        dish.name,
        a_user.user_id,
        math.raw_g,
        cooked_g,
        math.per_100.kcal,
        math.per_100.prot,
        math.per_100.fat,
        math.per_100.carb,
        i32::try_from(math.missing_count).unwrap_or(i32::MAX),
        note
    )
    .fetch_one(&mut *tx)
    .await?;

    for (position, (item_id, name, input)) in inputs.iter().enumerate()
    {
        let short = consume_item(
            &mut tx,
            store,
            *item_id,
            input.grams,
            Consumer::Batch(batch_id),
            a_user.user_id,
        )
        .await?;
        sqlx::query!(
            r#"
            INSERT INTO cook_batch_items (batch_id, position, item_id, item_name, grams, short_g)
            VALUES ($1, $2, $3, $4, $5, $6)
            "#,
            batch_id,
            i16::try_from(position).unwrap_or(i16::MAX),
            item_id,
            name,
            input.grams,
            short.min(input.grams)
        )
        .execute(&mut *tx)
        .await?;
    }

    let costs = sqlx::query!(
        r#"
        SELECT l.curr_id AS "curr_id!", SUM(m.cost) AS "cost!"
        FROM stock_moves m
        JOIN stock_lots l ON l.id = m.lot_id
        WHERE m.batch_id = $1 AND m.cost IS NOT NULL
        GROUP BY l.curr_id
        "#,
        batch_id
    )
    .fetch_all(&mut *tx)
    .await?;
    let (cost, curr_id) = match costs.as_slice()
    {
        [single] => (Some(single.cost), Some(single.curr_id)),
        _ => (None, None),
    };
    sqlx::query!(
        r#"
        INSERT INTO stock_lots (
            owner_id, family_id, kind, batch_id, title, measure, qty, cost, curr_id, source, added_by, acquired_ts
        )
        VALUES ($1, $2, 'dish', $3, $4, 'g', $5, $6, $7, 'cooked', $8, NOW())
        "#,
        store.owner_id,
        store.family_id,
        batch_id,
        dish.name,
        cooked_g,
        cost,
        curr_id,
        a_user.user_id
    )
    .execute(&mut *tx)
    .await?;

    let batch = load_batch(&mut tx, a_user.user_id, batch_id).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(batch)))
}

pub async fn list_moves(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<StockMovesQuery>,
) -> Result<Json<StockMovesDto>, ApiError>
{
    let limit = a_query.limit.unwrap_or(DEFAULT_MOVES).clamp(1, MAX_MOVES);
    if let (Some(from), Some(to)) = (a_query.from, a_query.to)
    {
        if from >= to
        {
            return Err(ApiError::Validation("to"));
        }
    }
    let mut conn = a_state.db.acquire().await?;
    let store = chosen_store(&mut conn, a_user.user_id, a_query.family_id, a_query.is_personal).await?;
    let rows = sqlx::query!(
        r#"
        SELECT m.id, m.kind AS "kind: StockMoveKind", m.lot_id, l.title, l.measure AS "measure: StockMeasure", m.qty,
               m.cost, c.code AS "curr_code?", m.reason AS "reason: WasteReason", m.note, m.created_ts,
               CASE WHEN m.kind <> 'eaten' THEN u.first_name || ' ' || u.last_name END AS actor_name
        FROM stock_moves m
        JOIN stock_lots l ON l.id = m.lot_id
        LEFT JOIN currencies c ON c.id = l.curr_id
        LEFT JOIN users u ON u.id = m.user_id
        WHERE l.owner_id IS NOT DISTINCT FROM $1 AND l.family_id IS NOT DISTINCT FROM $2
          AND ($3::stock_move_t IS NULL OR m.kind = $3)
          AND ($4::timestamptz IS NULL OR m.created_ts >= $4)
          AND ($5::timestamptz IS NULL OR m.created_ts < $5)
        ORDER BY m.created_ts DESC, m.id
        LIMIT $6
        "#,
        store.owner_id,
        store.family_id,
        a_query.kind as Option<StockMoveKind>,
        a_query.from,
        a_query.to,
        limit
    )
    .fetch_all(&mut *conn)
    .await?;
    let totals = sqlx::query!(
        r#"
        SELECT l.measure AS "measure: StockMeasure", c.code AS "curr_code?", SUM(m.qty) AS "qty!",
               SUM(m.cost) AS cost
        FROM stock_moves m
        JOIN stock_lots l ON l.id = m.lot_id
        LEFT JOIN currencies c ON c.id = l.curr_id
        WHERE l.owner_id IS NOT DISTINCT FROM $1 AND l.family_id IS NOT DISTINCT FROM $2
          AND m.kind = 'waste'
          AND ($3::timestamptz IS NULL OR m.created_ts >= $3)
          AND ($4::timestamptz IS NULL OR m.created_ts < $4)
        GROUP BY 1, 2
        "#,
        store.owner_id,
        store.family_id,
        a_query.from,
        a_query.to
    )
    .fetch_all(&mut *conn)
    .await?;

    let mut waste_g = Decimal::ZERO;
    let mut waste_ml = Decimal::ZERO;
    let mut waste_pcs = Decimal::ZERO;
    let mut costs: BTreeMap<String, Decimal> = BTreeMap::new();
    for total in totals
    {
        match total.measure
        {
            StockMeasure::G => waste_g += total.qty,
            StockMeasure::Ml => waste_ml += total.qty,
            StockMeasure::Pcs => waste_pcs += total.qty,
        }
        if let (Some(code), Some(cost)) = (total.curr_code, total.cost)
        {
            *costs.entry(code).or_default() += cost;
        }
    }

    Ok(Json(StockMovesDto {
        moves: rows
            .into_iter()
            .map(|row| StockMoveDto {
                id: row.id,
                kind: row.kind,
                lot_id: row.lot_id,
                title: row.title,
                measure: row.measure,
                qty: row.qty.normalize(),
                cost: row.cost,
                curr_code: row.curr_code,
                reason: row.reason,
                note: row.note,
                actor_name: row.actor_name,
                created_ts: row.created_ts,
            })
            .collect(),
        waste_g: waste_g.normalize(),
        waste_ml: waste_ml.normalize(),
        waste_pcs: waste_pcs.normalize(),
        waste_costs: costs
            .into_iter()
            .map(|(curr_code, amount)| MoneyTotalDto { curr_code, amount })
            .collect(),
    }))
}
