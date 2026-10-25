use std::collections::BTreeMap;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, NaiveDate, NaiveTime, Utc};
use chrono_tz::Tz;
use rust_decimal::Decimal;
use shared_schema::{
    BatchQuery, CookBatchDto, CookBatchItemDto, CookRequest, ItemKind, ItemUnit, MacrosDto, MoneyTotalDto, NetMeasure,
    NewStockLotRequest, SaveStockSettingsRequest, SetLotExpiryRequest, StockDto, StockFoodItemDto, StockFoodsDto,
    StockKind, StockLotDto, StockMeasure, StockMoveDto, StockMoveKind, StockMovesDto, StockMovesQuery, StockQuery,
    StockSettingsDto, StockSource, StockStoreDto, WasteReason, WasteRequest, WriteOffRequest,
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
use crate::services::planner::{local_date, parse_zone};
use crate::services::stock::{
    cost_share, display_pack, grams_per_unit, intake_qty, manual_qty, measure_of, piece_amount, plan_takes, qty,
    rescaled_qty, write_off_amount, Intake, ItemShape, LotLeft, Take, COST_SCALE,
};
use crate::state::AppState;

const MAX_LOTS_PER_STORE: i64 = 20_000;
const MAX_NOTE_LEN: usize = 500;
const MAX_PAST_DAYS: i64 = 3_660;
const DEFAULT_MOVES: i64 = 100;
const MAX_MOVES: i64 = 500;
const MAX_SHELF_DAYS: i64 = 3_660;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Store
{
    pub owner_id: Option<Uuid>,
    pub family_id: Option<Uuid>,
}

impl Store
{
    pub fn personal(a_user_id: Uuid) -> Self
    {
        Self {
            owner_id: Some(a_user_id),
            family_id: None,
        }
    }

    pub fn group(a_family_id: Uuid) -> Self
    {
        Self {
            owner_id: None,
            family_id: Some(a_family_id),
        }
    }

    pub fn of(a_owner_id: Option<Uuid>, a_family_id: Option<Uuid>) -> Self
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

#[derive(Debug, Clone, Copy)]
pub struct Consumed
{
    pub short: Decimal,
    pub is_pack_needed: bool,
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
    pack_size: Option<Decimal>,
    item_kind: Option<ItemKind>,
    item_unit: Option<ItemUnit>,
    net_qty: Option<Decimal>,
    net_measure: Option<NetMeasure>,
    item_kcal: Option<Decimal>,
    item_prot: Option<Decimal>,
    item_fat: Option<Decimal>,
    item_carb: Option<Decimal>,
    batch_kcal: Option<Decimal>,
    batch_prot: Option<Decimal>,
    batch_fat: Option<Decimal>,
    batch_carb: Option<Decimal>,
    expires_on: Option<NaiveDate>,
}

impl LotRow
{
    fn into_dto(self, a_today: NaiveDate) -> StockLotDto
    {
        let per_100 = match self.kind
        {
            StockKind::Item => item_per_100(self.item_kcal, self.item_prot, self.item_fat, self.item_carb),
            StockKind::Dish => item_per_100(self.batch_kcal, self.batch_prot, self.batch_fat, self.batch_carb),
        };
        let left_qty = self.left_qty.max(Decimal::ZERO);
        let pack_size = match (self.item_kind, self.item_unit)
        {
            (Some(kind), Some(unit)) => display_pack(
                &ItemShape {
                    kind,
                    unit,
                    net_qty: self.net_qty,
                    net_measure: self.net_measure,
                    piece_g: self.piece_g,
                },
                self.measure,
                self.pack_size,
            ),
            _ => None,
        };
        StockLotDto {
            id: self.id,
            kind: self.kind,
            item_id: self.item_id,
            dish_id: self.dish_id,
            batch_id: self.batch_id,
            title: self.title,
            measure: self.measure,
            qty: self.qty.normalize(),
            left_qty: left_qty.normalize(),
            cost: self.cost,
            left_cost: cost_share(self.cost, self.qty, left_qty),
            curr_code: self.curr_code,
            source: self.source,
            receipt_id: self.receipt_id,
            acquired_ts: self.acquired_ts,
            is_touched: self.is_touched,
            piece_g: self.piece_g.map(|value| value.normalize()),
            pack_size: pack_size.map(|value| value.normalize()),
            per_100,
            is_expired: self.expires_on.is_some_and(|expires_on| expires_on < a_today),
            expires_on: self.expires_on,
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

pub async fn store_zone(a_conn: &mut PgConnection, a_store: Store) -> Result<Tz, ApiError>
{
    let name = sqlx::query_scalar!(
        r#"
        SELECT ns.tz
        FROM notify_settings ns
        WHERE ns.user_id = COALESCE($1, (SELECT f.owner_id FROM families f WHERE f.id = $2))
        "#,
        a_store.owner_id,
        a_store.family_id
    )
    .fetch_optional(&mut *a_conn)
    .await?;
    Ok(name.as_deref().and_then(parse_zone).unwrap_or(Tz::UTC))
}

pub async fn store_today(a_conn: &mut PgConnection, a_store: Store) -> Result<NaiveDate, ApiError>
{
    Ok(local_date(store_zone(a_conn, a_store).await?, Utc::now()))
}

fn check_expiry(a_expires_on: Option<NaiveDate>, a_earliest: NaiveDate, a_today: NaiveDate) -> Result<(), ApiError>
{
    match a_expires_on
    {
        Some(expires_on) if expires_on < a_earliest || expires_on > a_today + Duration::days(MAX_SHELF_DAYS) =>
        {
            Err(ApiError::Validation("expires_on"))
        }
        _ => Ok(()),
    }
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

pub async fn insert_moves(
    a_conn: &mut PgConnection,
    a_takes: &[Take],
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
) -> Result<Consumed, ApiError>
{
    lock_store(a_conn, a_store).await?;
    let today = store_today(a_conn, a_store).await?;
    let rows = sqlx::query!(
        r#"
        SELECT l.id, l.measure AS "measure: StockMeasure", l.qty, l.cost, i.piece_g,
               l.qty - COALESCE((SELECT SUM(m.qty) FROM stock_moves m WHERE m.lot_id = l.id), 0) AS "left!"
        FROM stock_lots l
        JOIN items i ON i.id = l.item_id
        WHERE l.owner_id IS NOT DISTINCT FROM $1 AND l.family_id IS NOT DISTINCT FROM $2
          AND l.kind = 'item' AND l.item_id = $3
          AND (l.expires_on IS NULL OR l.expires_on >= $4)
        ORDER BY l.expires_on NULLS LAST, l.acquired_ts, l.created_ts, l.id
        "#,
        a_store.owner_id,
        a_store.family_id,
        a_item_id,
        today
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
    let (takes, short) = plan_takes(&lots, a_grams);
    insert_moves(a_conn, &takes, a_consumer, a_user_id).await?;
    let has_unmeasured = lots
        .iter()
        .any(|lot| lot.grams_per_unit.is_none() && lot.left > Decimal::ZERO);
    Ok(Consumed {
        short,
        is_pack_needed: short > Decimal::ZERO && has_unmeasured,
    })
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
    let (takes, short) = plan_takes(
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

#[derive(Debug, Clone, Copy)]
pub enum StockPool
{
    Item(Uuid),
    Cat(Uuid),
    Dish(Uuid),
}

#[derive(Debug, Clone)]
pub struct Portion
{
    pub item_id: Option<Uuid>,
    pub batch_id: Option<Uuid>,
    pub grams: Decimal,
    pub takes: Vec<Take>,
}

pub async fn pick_portions(
    a_conn: &mut PgConnection,
    a_store: Store,
    a_pool: StockPool,
    a_grams: Decimal,
) -> Result<(Vec<Portion>, Decimal), ApiError>
{
    lock_store(a_conn, a_store).await?;
    let today = store_today(a_conn, a_store).await?;
    let (item_id, cat_id, dish_id) = match a_pool
    {
        StockPool::Item(id) => (Some(id), None, None),
        StockPool::Cat(id) => (None, Some(id), None),
        StockPool::Dish(id) => (None, None, Some(id)),
    };
    let rows = sqlx::query!(
        r#"
        WITH RECURSIVE sub AS (
            SELECT id FROM product_cats WHERE id = $4
            UNION ALL
            SELECT c.id FROM product_cats c JOIN sub ON c.parent_id = sub.id
        )
        SELECT l.id, l.item_id, l.batch_id, l.measure AS "measure: StockMeasure", l.qty, l.cost, i.piece_g,
               l.qty - COALESCE((SELECT SUM(m.qty) FROM stock_moves m WHERE m.lot_id = l.id), 0) AS "left!"
        FROM stock_lots l
        LEFT JOIN items i ON i.id = l.item_id
        LEFT JOIN cook_batches b ON b.id = l.batch_id
        WHERE l.owner_id IS NOT DISTINCT FROM $1 AND l.family_id IS NOT DISTINCT FROM $2
          AND (l.expires_on IS NULL OR l.expires_on >= $6)
          AND (
              (l.kind = 'item' AND l.item_id = $3)
              OR (l.kind = 'item' AND i.type = 'food' AND i.kcal IS NOT NULL AND i.cat_id IN (SELECT id FROM sub))
              OR (l.kind = 'dish' AND b.dish_id = $5)
          )
        ORDER BY l.expires_on NULLS LAST, l.acquired_ts, l.created_ts, l.id
        "#,
        a_store.owner_id,
        a_store.family_id,
        item_id,
        cat_id,
        dish_id,
        today
    )
    .fetch_all(&mut *a_conn)
    .await?;

    let mut need = qty(a_grams);
    let mut portions: Vec<Portion> = Vec::new();
    for row in rows
    {
        if need <= Decimal::ZERO
        {
            break;
        }
        let lot = LotLeft {
            id: row.id,
            qty: row.qty,
            left: row.left,
            grams_per_unit: grams_per_unit(row.measure, row.piece_g),
            cost: row.cost,
        };
        let (takes, short) = plan_takes(&[lot], need);
        let used = need - short;
        if takes.is_empty() || used <= Decimal::ZERO
        {
            continue;
        }
        need = short;
        match portions
            .iter_mut()
            .find(|portion| portion.item_id == row.item_id && portion.batch_id == row.batch_id)
        {
            Some(portion) =>
            {
                portion.grams += used;
                portion.takes.extend(takes);
            }
            None => portions.push(Portion {
                item_id: row.item_id,
                batch_id: row.batch_id,
                grams: used,
                takes,
            }),
        }
    }
    Ok((portions, need))
}

pub async fn stock_foods(State(a_state): State<AppState>, a_user: AuthUser) -> Result<Json<StockFoodsDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let store = active_store(&mut conn, a_user.user_id).await?;
    let today = store_today(&mut conn, store).await?;
    let rows = sqlx::query!(
        r#"
        SELECT DISTINCT l.item_id, i.cat_id, b.dish_id
        FROM stock_lots l
        LEFT JOIN items i ON i.id = l.item_id
        LEFT JOIN cook_batches b ON b.id = l.batch_id
        WHERE l.owner_id IS NOT DISTINCT FROM $1 AND l.family_id IS NOT DISTINCT FROM $2
          AND (l.expires_on IS NULL OR l.expires_on >= $3)
          AND l.qty > COALESCE((SELECT SUM(m.qty) FROM stock_moves m WHERE m.lot_id = l.id), 0)
          AND ((l.kind = 'item' AND i.type = 'food') OR (l.kind = 'dish' AND b.dish_id IS NOT NULL))
        "#,
        store.owner_id,
        store.family_id,
        today
    )
    .fetch_all(&mut *conn)
    .await?;

    let mut items = Vec::new();
    let mut dish_ids = Vec::new();
    for row in rows
    {
        if let Some(item_id) = row.item_id
        {
            if !items.iter().any(|known: &StockFoodItemDto| known.item_id == item_id)
            {
                items.push(StockFoodItemDto {
                    item_id,
                    cat_id: row.cat_id,
                });
            }
        }
        if let Some(dish_id) = row.dish_id.filter(|id| !dish_ids.contains(id))
        {
            dish_ids.push(dish_id);
        }
    }
    Ok(Json(StockFoodsDto { items, dish_ids }))
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
    a_target: Option<Store>,
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

    let mut wanted: BTreeMap<i16, (Uuid, String, Intake, Decimal)> = BTreeMap::new();
    if a_target.is_some()
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
            if let Some(intake) = intake_qty(&shape, item.qty)
            {
                let cost = (item.amount * a_paid_share).round_dp(COST_SCALE);
                wanted.insert(item.pos, (item.item_id, item.name, intake, cost));
            }
        }
    }

    let previous = lots.first().map(|lot| Store::of(lot.owner_id, lot.family_id));
    if let Some(store) = previous
    {
        lock_store(a_conn, store).await?;
    }
    if let Some(store) = a_target.filter(|store| Some(*store) != previous)
    {
        lock_store(a_conn, store).await?;
    }

    for lot in &lots
    {
        let is_same = a_target == Some(Store::of(lot.owner_id, lot.family_id))
            && wanted
                .get(&lot.receipt_pos)
                .is_some_and(|(item_id, _, intake, _)| Some(*item_id) == lot.item_id && intake.measure == lot.measure);
        if is_same
        {
            if let Some((_, title, intake, cost)) = wanted.remove(&lot.receipt_pos)
            {
                sqlx::query!(
                    r#"
                    UPDATE stock_lots
                    SET qty = $2, cost = $3, curr_id = $4, title = $5, acquired_ts = $6, pack_size = $7
                    WHERE id = $1
                    "#,
                    lot.id,
                    intake.amount,
                    cost,
                    head.curr_id,
                    title,
                    head.receipt_ts,
                    intake.pack
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

    let Some(store) = a_target
    else
    {
        return Ok(());
    };
    require_room(a_conn, store, i64::try_from(wanted.len()).unwrap_or(i64::MAX)).await?;
    for (pos, (item_id, title, intake, cost)) in wanted
    {
        sqlx::query!(
            r#"
            INSERT INTO stock_lots (
                owner_id, family_id, kind, item_id, title, measure, qty, cost, curr_id, source, receipt_id,
                receipt_pos, added_by, acquired_ts, pack_size
            )
            VALUES ($1, $2, 'item', $3, $4, $5, $6, $7, $8, 'receipt', $9, $10, $11, $12, $13)
            "#,
            store.owner_id,
            store.family_id,
            item_id,
            title,
            intake.measure as StockMeasure,
            intake.amount,
            cost,
            head.curr_id,
            a_receipt_id,
            pos,
            a_owner_id,
            head.receipt_ts,
            intake.pack
        )
        .execute(&mut *a_conn)
        .await?;
    }
    Ok(())
}

pub async fn receipt_store(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_is_stocked: bool,
    a_choice: Option<shared_schema::StockStoreChoice>,
) -> Result<Option<Store>, ApiError>
{
    if !a_is_stocked
    {
        return Ok(None);
    }
    match a_choice
    {
        None => active_store(a_conn, a_user_id).await.map(Some),
        Some(choice) => match choice.family_id
        {
            Some(family_id) =>
            {
                require_member(&mut *a_conn, family_id, a_user_id)
                    .await
                    .map_err(|_| ApiError::Validation("stock_store"))?;
                Ok(Some(Store::group(family_id)))
            }
            None => Ok(Some(Store::personal(a_user_id))),
        },
    }
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
            l.pack_size,
            i.type AS "item_kind?: ItemKind",
            i.unit AS "item_unit?: ItemUnit",
            i.net_qty AS "net_qty?",
            i.net_measure AS "net_measure?: NetMeasure",
            i.kcal AS "item_kcal?",
            i.prot AS "item_prot?",
            i.fat AS "item_fat?",
            i.carb AS "item_carb?",
            b.kcal_100 AS "batch_kcal?",
            b.prot_100 AS "batch_prot?",
            b.fat_100 AS "batch_fat?",
            b.carb_100 AS "batch_carb?",
            l.expires_on
        FROM stock_lots l
        LEFT JOIN (SELECT lot_id, SUM(qty) AS used FROM stock_moves GROUP BY lot_id) mv ON mv.lot_id = l.id
        LEFT JOIN items i ON i.id = l.item_id
        LEFT JOIN cook_batches b ON b.id = l.batch_id
        LEFT JOIN currencies c ON c.id = l.curr_id
        WHERE l.owner_id IS NOT DISTINCT FROM $1 AND l.family_id IS NOT DISTINCT FROM $2
          AND ($3::uuid IS NULL OR l.id = $3)
          AND ($4 OR l.qty > COALESCE(mv.used, 0))
        ORDER BY l.kind, LOWER(l.title), l.expires_on NULLS LAST, l.acquired_ts, l.id
        "#,
        a_store.owner_id,
        a_store.family_id,
        a_lot_id,
        a_is_all
    )
    .fetch_all(&mut *a_conn)
    .await?;
    let today = store_today(a_conn, a_store).await?;
    Ok(rows.into_iter().map(|row| row.into_dto(today)).collect())
}

struct VisibleLot
{
    store: Store,
    source: StockSource,
    batch_id: Option<Uuid>,
    acquired_ts: DateTime<Utc>,
}

async fn visible_lot(a_conn: &mut PgConnection, a_lot_id: Uuid, a_user_id: Uuid) -> Result<VisibleLot, ApiError>
{
    let row = sqlx::query!(
        r#"
        SELECT l.owner_id, l.family_id, l.source AS "source: StockSource", l.batch_id, l.acquired_ts
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
        acquired_ts: row.acquired_ts,
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
    if measure_of(&shape).is_none()
    {
        return Err(ApiError::Validation("item_id"));
    }
    let intake = manual_qty(&shape, a_req.qty, a_req.unit).ok_or(ApiError::Validation("qty"))?;
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
    let store_day = store_today(&mut tx, store).await?;
    check_expiry(a_req.expires_on, store_day, store_day)?;
    require_room(&mut tx, store, 1).await?;
    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO stock_lots (
            owner_id, family_id, kind, item_id, title, measure, qty, cost, curr_id, source, added_by, acquired_ts,
            expires_on, pack_size
        )
        VALUES ($1, $2, 'item', $3, $4, $5, $6, $7, $8, 'manual', $9, $10, $11, $12)
        RETURNING id
        "#,
        store.owner_id,
        store.family_id,
        a_req.item_id,
        item.name,
        intake.measure as StockMeasure,
        intake.amount,
        cost,
        a_req.curr_id,
        a_user.user_id,
        acquired_ts,
        a_req.expires_on,
        intake.pack
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

pub async fn set_lot_expiry(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SetLotExpiryRequest>,
) -> Result<Json<StockLotDto>, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let lot = visible_lot(&mut tx, a_id, a_user.user_id).await?;
    lock_store(&mut tx, lot.store).await?;
    let zone = store_zone(&mut tx, lot.store).await?;
    let acquired_on = local_date(zone, lot.acquired_ts);
    check_expiry(a_req.expires_on, acquired_on, local_date(zone, Utc::now()))?;
    sqlx::query!(
        r#"
        UPDATE stock_lots
        SET expires_on = $2, warned_on = NULL, is_expiry_done = FALSE
        WHERE id = $1
        "#,
        a_id,
        a_req.expires_on
    )
    .execute(&mut *tx)
    .await?;
    let updated = load_lot(&mut tx, lot.store, a_id).await?;
    tx.commit().await?;
    Ok(Json(updated))
}

struct WriteOffLot
{
    id: Uuid,
    measure: StockMeasure,
    qty: Decimal,
    left: Decimal,
    cost: Option<Decimal>,
    pack: Option<Decimal>,
}

async fn write_off_lots(
    a_conn: &mut PgConnection,
    a_store: Store,
    a_item_id: Option<Uuid>,
    a_lot_id: Option<Uuid>,
) -> Result<Vec<WriteOffLot>, ApiError>
{
    let rows = sqlx::query!(
        r#"
        SELECT l.id, l.measure AS "measure: StockMeasure", l.qty, l.cost, l.pack_size,
               i.type AS "item_kind?: ItemKind", i.unit AS "item_unit?: ItemUnit", i.net_qty AS "net_qty?",
               i.net_measure AS "net_measure?: NetMeasure", i.piece_g AS "piece_g?",
               l.qty - COALESCE((SELECT SUM(m.qty) FROM stock_moves m WHERE m.lot_id = l.id), 0) AS "left!"
        FROM stock_lots l
        LEFT JOIN items i ON i.id = l.item_id
        WHERE l.owner_id IS NOT DISTINCT FROM $1 AND l.family_id IS NOT DISTINCT FROM $2
          AND ($3::uuid IS NULL OR (l.kind = 'item' AND l.item_id = $3))
          AND ($4::uuid IS NULL OR l.id = $4)
        ORDER BY l.expires_on NULLS LAST, l.acquired_ts, l.created_ts, l.id
        "#,
        a_store.owner_id,
        a_store.family_id,
        a_item_id,
        a_lot_id
    )
    .fetch_all(&mut *a_conn)
    .await?;
    Ok(rows
        .into_iter()
        .filter(|row| row.left > Decimal::ZERO)
        .map(|row| {
            let pack = match (row.item_kind, row.item_unit)
            {
                (Some(kind), Some(unit)) => display_pack(
                    &ItemShape {
                        kind,
                        unit,
                        net_qty: row.net_qty,
                        net_measure: row.net_measure,
                        piece_g: row.piece_g,
                    },
                    row.measure,
                    row.pack_size,
                ),
                _ => None,
            };
            WriteOffLot {
                id: row.id,
                measure: row.measure,
                qty: row.qty,
                left: row.left,
                cost: row.cost,
                pack,
            }
        })
        .collect())
}

async fn write_off(
    a_conn: &mut PgConnection,
    a_lots: &[WriteOffLot],
    a_qty: Decimal,
    a_unit: Option<StockMeasure>,
    a_reason: Option<WasteReason>,
    a_note: Option<&str>,
    a_user_id: Uuid,
) -> Result<(), ApiError>
{
    let Some(first) = a_lots.first()
    else
    {
        return Err(ApiError::Validation("qty"));
    };
    let measure = first.measure;
    let amount = write_off_amount(measure, a_unit, a_qty, first.pack).ok_or(ApiError::Validation("unit"))?;
    let same: Vec<&WriteOffLot> = a_lots.iter().filter(|lot| lot.measure == measure).collect();
    let available: Decimal = same.iter().map(|lot| lot.left).sum();
    if amount > available + Decimal::new(1, 1)
    {
        return Err(ApiError::Validation("qty"));
    }
    let lefts: Vec<LotLeft> = same
        .iter()
        .map(|lot| LotLeft {
            id: lot.id,
            qty: lot.qty,
            left: lot.left,
            grams_per_unit: Some(Decimal::ONE),
            cost: lot.cost,
        })
        .collect();
    let (takes, _) = plan_takes(&lefts, amount.min(available));
    let kind = if a_reason.is_some()
    {
        StockMoveKind::Waste
    }
    else
    {
        StockMoveKind::Used
    };
    for take in takes
    {
        sqlx::query!(
            r#"
            INSERT INTO stock_moves (lot_id, kind, qty, cost, reason, note, user_id)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            "#,
            take.lot_id,
            kind as StockMoveKind,
            take.qty,
            take.cost,
            a_reason as Option<WasteReason>,
            a_note,
            a_user_id
        )
        .execute(&mut *a_conn)
        .await?;
    }
    Ok(())
}

pub async fn waste_lot(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<WasteRequest>,
) -> Result<Json<StockLotDto>, ApiError>
{
    let note = clean_optional_text(a_req.note.as_deref(), MAX_NOTE_LEN, "note")?;
    let mut tx = a_state.db.begin().await?;
    let lot = visible_lot(&mut tx, a_id, a_user.user_id).await?;
    lock_store(&mut tx, lot.store).await?;
    let lots = write_off_lots(&mut tx, lot.store, None, Some(a_id)).await?;
    write_off(
        &mut tx,
        &lots,
        a_req.qty,
        a_req.unit,
        a_req.reason,
        note.as_deref(),
        a_user.user_id,
    )
    .await?;
    let updated = load_lot(&mut tx, lot.store, a_id).await?;
    tx.commit().await?;
    Ok(Json(updated))
}

pub async fn write_off_item(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<WriteOffRequest>,
) -> Result<StatusCode, ApiError>
{
    let note = clean_optional_text(a_req.note.as_deref(), MAX_NOTE_LEN, "note")?;
    let mut tx = a_state.db.begin().await?;
    let store = chosen_store(&mut tx, a_user.user_id, a_req.family_id, a_req.is_personal).await?;
    lock_store(&mut tx, store).await?;
    let lots = write_off_lots(&mut tx, store, Some(a_req.item_id), None).await?;
    write_off(
        &mut tx,
        &lots,
        a_req.qty,
        a_req.unit,
        a_req.reason,
        note.as_deref(),
        a_user.user_id,
    )
    .await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

struct ScaledLot
{
    id: Uuid,
    owner_id: Option<Uuid>,
    family_id: Option<Uuid>,
    measure: StockMeasure,
    qty: Decimal,
    pack_size: Option<Decimal>,
    created_ts: DateTime<Utc>,
}

pub async fn rescale_item_stock(a_conn: &mut PgConnection, a_item_id: Uuid) -> Result<(), ApiError>
{
    let Some(item) = sqlx::query!(
        r#"
        SELECT type AS "kind: ItemKind", unit AS "unit: ItemUnit", net_qty, net_measure AS "net_measure: NetMeasure",
               piece_g
        FROM items WHERE id = $1
        "#,
        a_item_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    else
    {
        return Ok(());
    };
    let shape = ItemShape {
        kind: item.kind,
        unit: item.unit,
        net_qty: item.net_qty,
        net_measure: item.net_measure,
        piece_g: item.piece_g,
    };
    let Some(target) = measure_of(&shape).filter(|measure| *measure != StockMeasure::Pcs)
    else
    {
        return Ok(());
    };
    if shape.unit != ItemUnit::Piece
    {
        return Ok(());
    }
    let Some(pack) = piece_amount(&shape, target).filter(|pack| *pack > Decimal::ZERO)
    else
    {
        return Ok(());
    };
    let lots = sqlx::query_as!(
        ScaledLot,
        r#"
        SELECT id, owner_id, family_id, measure AS "measure: StockMeasure", qty, pack_size, created_ts
        FROM stock_lots
        WHERE kind = 'item' AND item_id = $1 AND (measure = 'pcs' OR pack_size IS NOT NULL)
        ORDER BY created_ts
        "#,
        a_item_id
    )
    .fetch_all(&mut *a_conn)
    .await?;
    let mut converted: Vec<(Store, DateTime<Utc>)> = Vec::new();
    for lot in lots
    {
        let store = Store::of(lot.owner_id, lot.family_id);
        match (lot.measure, lot.pack_size)
        {
            (StockMeasure::Pcs, _) =>
            {
                lock_store(a_conn, store).await?;
                sqlx::query!(
                    r#"
                    UPDATE stock_lots
                    SET measure = $2, qty = LEAST(GREATEST(ROUND(qty * $3, 1), 0.1), 1000000), pack_size = $3
                    WHERE id = $1
                    "#,
                    lot.id,
                    target as StockMeasure,
                    pack
                )
                .execute(&mut *a_conn)
                .await?;
                sqlx::query!(
                    "UPDATE stock_moves SET qty = GREATEST(ROUND(qty * $2, 1), 0.1) WHERE lot_id = $1",
                    lot.id,
                    pack
                )
                .execute(&mut *a_conn)
                .await?;
                match converted.iter_mut().find(|(known, _)| *known == store)
                {
                    Some((_, since)) => *since = (*since).min(lot.created_ts),
                    None => converted.push((store, lot.created_ts)),
                }
            }
            (_, Some(old)) if old != pack || lot.measure != target =>
            {
                lock_store(a_conn, store).await?;
                sqlx::query!(
                    "UPDATE stock_lots SET measure = $2, qty = $3, pack_size = $4 WHERE id = $1",
                    lot.id,
                    target as StockMeasure,
                    rescaled_qty(lot.qty, old, pack),
                    pack
                )
                .execute(&mut *a_conn)
                .await?;
            }
            _ =>
            {}
        }
    }
    for (store, since) in converted
    {
        resync_short_entries(a_conn, store, a_item_id, since).await?;
    }
    Ok(())
}

async fn resync_short_entries(
    a_conn: &mut PgConnection,
    a_store: Store,
    a_item_id: Uuid,
    a_since: DateTime<Utc>,
) -> Result<(), ApiError>
{
    let entries = sqlx::query!(
        r#"
        SELECT e.id, e.user_id, e.grams AS "grams!"
        FROM meal_entries e
        WHERE e.item_id = $1 AND e.batch_id IS NULL AND e.stock_short > 0 AND e.grams IS NOT NULL
          AND e.created_ts >= $2
        ORDER BY e.created_ts, e.id
        "#,
        a_item_id,
        a_since
    )
    .fetch_all(&mut *a_conn)
    .await?;
    for entry in entries
    {
        if entry_store(a_conn, entry.id, entry.user_id).await? != a_store
        {
            continue;
        }
        sqlx::query!("DELETE FROM stock_moves WHERE meal_entry_id = $1", entry.id)
            .execute(&mut *a_conn)
            .await?;
        let consumed = consume_item(
            a_conn,
            a_store,
            a_item_id,
            entry.grams,
            Consumer::Entry(entry.id),
            entry.user_id,
        )
        .await?;
        sqlx::query!(
            "UPDATE meal_entries SET stock_short = $2 WHERE id = $1",
            entry.id,
            consumed.short.min(entry.grams)
        )
        .execute(&mut *a_conn)
        .await?;
    }
    Ok(())
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
               b.kcal_100, b.prot_100, b.fat_100, b.carb_100, b.missing_count, l.cost, c.code AS "curr_code?", b.note,
               l.expires_on
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
            expires_on: row.expires_on,
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
    let store_day = store_today(&mut tx, store).await?;
    check_expiry(a_req.expires_on, store_day, store_day)?;
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
        .await?
        .short;
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
            owner_id, family_id, kind, batch_id, title, measure, qty, cost, curr_id, source, added_by, acquired_ts,
            expires_on
        )
        VALUES ($1, $2, 'dish', $3, $4, 'g', $5, $6, $7, 'cooked', $8, NOW(), $9)
        "#,
        store.owner_id,
        store.family_id,
        batch_id,
        dish.name,
        cooked_g,
        cost,
        curr_id,
        a_user.user_id,
        a_req.expires_on
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
