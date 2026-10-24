use std::collections::{BTreeSet, HashMap};

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, Utc};
use rust_decimal::Decimal;
use shared_schema::{
    DictItemDto, FillItemRequest, ItemKind, ItemOwnerKind, ItemPriceDto, ItemPriceQuery, ItemPricesDto, ItemQuery,
    ItemUnit, ManualPriceDto, MergeItemRequest, NetMeasure, NewItemRequest, NutritionDto, SaveItemRequest,
    SaveManualPriceRequest,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::api::place_handlers::require_visible_place;
use crate::api::stock_handlers::rescale_item_stock;
use crate::domain::errors::ApiError;
use crate::domain::validation::{
    check_money, check_qty, clean_barcode, clean_optional_text, clean_text, contains_pattern, money,
};
use crate::security::authz::is_catalog_admin;
use crate::state::AppState;

pub const MAX_ITEM_NAME_LEN: usize = 200;
const DEFAULT_LIST_LIMIT: i64 = 200;
const MAX_LIST_LIMIT: i64 = 500;
const MAX_STORE_NAME_LEN: usize = 100;
const MAX_PRICE_NOTE_LEN: usize = 200;
const MAX_MANUAL_PRICES_PER_ITEM: i64 = 500;
const MAX_OBSERVATIONS: i64 = 5000;
const MAX_PRICE_AGE_DAYS: i64 = 3650;
const MAX_KCAL: i64 = 1000;
const MAX_GRAMS: i64 = 100;
const MAX_PIECE_G: i64 = 10_000;
const MAX_NET_QTY: i64 = 1_000_000;
const NET_SCALE: u32 = 1;

pub struct Viewer
{
    pub user_id: Uuid,
    pub is_admin: bool,
}

struct ItemRow
{
    id: Uuid,
    name: String,
    kind: ItemKind,
    unit: ItemUnit,
    barcode: Option<String>,
    kcal: Option<Decimal>,
    prot: Option<Decimal>,
    fat: Option<Decimal>,
    carb: Option<Decimal>,
    piece_g: Option<Decimal>,
    net_qty: Option<Decimal>,
    net_measure: Option<NetMeasure>,
    cat_id: Option<Uuid>,
    owner_kind: String,
    owner_name: Option<String>,
    is_editable: bool,
    is_in_use: bool,
}

#[derive(Default)]
struct ItemFilter<'a>
{
    id: Option<Uuid>,
    pattern: Option<&'a str>,
    prefix: Option<&'a str>,
    query_barcode: Option<&'a str>,
    barcode: Option<&'a str>,
    is_mine: bool,
    kind: Option<ItemKind>,
    cat_id: Option<Uuid>,
}

struct ItemScope
{
    owner_id: Option<Uuid>,
    name: String,
    kind: ItemKind,
    unit: ItemUnit,
    barcode: Option<String>,
    piece_g: Option<Decimal>,
    net_qty: Option<Decimal>,
    net_measure: Option<NetMeasure>,
    cat_id: Option<Uuid>,
    is_used_by_others: bool,
}

struct Observation
{
    store_key: String,
    store_name: Option<String>,
    branch: Option<String>,
    curr_code: String,
    unit_price: Decimal,
    converted: Option<Decimal>,
    ts: DateTime<Utc>,
    is_shared: bool,
}

struct PriceAcc
{
    store_name: Option<String>,
    branch: Option<String>,
    curr_code: String,
    last_price: Decimal,
    last_ts: DateTime<Utc>,
    min_price: Decimal,
    sum: Decimal,
    count: i64,
    is_shared: bool,
}

impl From<ItemRow> for DictItemDto
{
    fn from(a_row: ItemRow) -> Self
    {
        let nutrition = NutritionDto {
            kcal: a_row.kcal.map(|value| value.normalize()),
            prot: a_row.prot.map(|value| value.normalize()),
            fat: a_row.fat.map(|value| value.normalize()),
            carb: a_row.carb.map(|value| value.normalize()),
            piece_g: a_row.piece_g.map(|value| value.normalize()),
        };
        Self {
            id: a_row.id,
            name: a_row.name,
            kind: a_row.kind,
            unit: a_row.unit,
            barcode: a_row.barcode,
            nutrition: (!nutrition.is_empty()).then_some(nutrition),
            net_qty: a_row.net_qty.map(|value| value.normalize()),
            net_measure: a_row.net_measure,
            cat_id: a_row.cat_id,
            owner_kind: ItemOwnerKind::parse(&a_row.owner_kind),
            owner_name: a_row.owner_name,
            is_editable: a_row.is_editable,
            is_in_use: a_row.is_in_use,
        }
    }
}

pub async fn list_items(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<ItemQuery>,
) -> Result<Json<Vec<DictItemDto>>, ApiError>
{
    let pattern = contains_pattern(a_query.q.as_deref())?;
    let prefix = pattern
        .as_deref()
        .map(|value| value.trim_start_matches('%').to_string());
    let query_barcode = clean_barcode(a_query.q.as_deref()).ok().flatten();
    let barcode = clean_barcode(a_query.barcode.as_deref())?;
    let limit = a_query.limit.unwrap_or(DEFAULT_LIST_LIMIT).clamp(1, MAX_LIST_LIMIT);

    let mut conn = a_state.db.acquire().await?;
    let viewer = load_viewer(&a_state, &mut conn, a_user.user_id).await?;
    let filter = ItemFilter {
        pattern: pattern.as_deref(),
        prefix: prefix.as_deref(),
        query_barcode: query_barcode.as_deref(),
        barcode: barcode.as_deref(),
        is_mine: a_query.is_mine,
        kind: a_query.kind,
        cat_id: a_query.cat_id,
        ..ItemFilter::default()
    };

    query_items(&a_state, &mut conn, &viewer, &filter, limit)
        .await
        .map(Json)
}

pub async fn get_item(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<Json<DictItemDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let viewer = load_viewer(&a_state, &mut conn, a_user.user_id).await?;
    load_item(&a_state, &mut conn, &viewer, a_id).await.map(Json)
}

pub async fn create_item(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SaveItemRequest>,
) -> Result<(StatusCode, Json<DictItemDto>), ApiError>
{
    let name = clean_text(&a_req.name, 1, MAX_ITEM_NAME_LEN, "name")?;
    let barcode = clean_barcode(a_req.barcode.as_deref())?;
    let nutrition = check_nutrition(a_req.nutrition.unwrap_or_default())?;
    let (net_qty, net_measure) = check_net(a_req.unit, a_req.net_qty, a_req.net_measure)?;
    let mut tx = a_state.db.begin().await?;
    let viewer = load_viewer(&a_state, &mut tx, a_user.user_id).await?;
    require_cat(&mut tx, a_req.cat_id).await?;

    require_unique_name(&mut tx, &name, None).await?;
    require_unique_barcode(&mut tx, barcode.as_deref(), None).await?;

    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO items (
            owner_id, created_by, name, type, unit, barcode, kcal, prot, fat, carb, piece_g, net_qty, net_measure, cat_id
        )
        VALUES ($1, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        RETURNING id
        "#,
        a_user.user_id,
        name,
        a_req.kind as ItemKind,
        a_req.unit as ItemUnit,
        barcode,
        nutrition.kcal,
        nutrition.prot,
        nutrition.fat,
        nutrition.carb,
        nutrition.piece_g,
        net_qty,
        net_measure as Option<NetMeasure>,
        a_req.cat_id
    )
    .fetch_one(&mut *tx)
    .await?;

    let item = load_item(&a_state, &mut tx, &viewer, id).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(item)))
}

pub async fn update_item(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SaveItemRequest>,
) -> Result<Json<DictItemDto>, ApiError>
{
    let name = clean_text(&a_req.name, 1, MAX_ITEM_NAME_LEN, "name")?;
    let barcode = clean_barcode(a_req.barcode.as_deref())?;
    let nutrition = check_nutrition(a_req.nutrition.unwrap_or_default())?;
    let (net_qty, net_measure) = check_net(a_req.unit, a_req.net_qty, a_req.net_measure)?;
    let mut tx = a_state.db.begin().await?;
    let viewer = load_viewer(&a_state, &mut tx, a_user.user_id).await?;
    let scope = require_editable(&mut tx, &viewer, a_id).await?;
    require_cat(&mut tx, a_req.cat_id).await?;

    let is_renamed = name.to_lowercase() != scope.name.to_lowercase();
    let is_identity_changed = name != scope.name
        || a_req.kind != scope.kind
        || a_req.unit != scope.unit
        || (scope.barcode.is_some() && barcode != scope.barcode);
    let is_filled_changed = (scope.net_qty.is_some() && (net_qty != scope.net_qty || net_measure != scope.net_measure))
        || (scope.piece_g.is_some() && nutrition.piece_g != scope.piece_g)
        || (scope.cat_id.is_some() && a_req.cat_id != scope.cat_id);
    if (is_identity_changed || is_filled_changed) && scope.is_used_by_others && !viewer.is_admin
    {
        return Err(ApiError::Conflict("ITEM_IN_USE"));
    }
    if is_renamed
    {
        require_unique_name(&mut tx, &name, Some(a_id)).await?;
    }
    if barcode != scope.barcode
    {
        require_unique_barcode(&mut tx, barcode.as_deref(), Some(a_id)).await?;
    }

    sqlx::query!(
        r#"
        UPDATE items
        SET name = $2, type = $3, unit = $4, barcode = $5, kcal = $6, prot = $7, fat = $8, carb = $9,
            piece_g = $10, net_qty = $11, net_measure = $12, cat_id = $13
        WHERE id = $1
        "#,
        a_id,
        name,
        a_req.kind as ItemKind,
        a_req.unit as ItemUnit,
        barcode,
        nutrition.kcal,
        nutrition.prot,
        nutrition.fat,
        nutrition.carb,
        nutrition.piece_g,
        net_qty,
        net_measure as Option<NetMeasure>,
        a_req.cat_id
    )
    .execute(&mut *tx)
    .await?;
    rescale_item_stock(&mut tx, a_id).await?;

    let item = load_item(&a_state, &mut tx, &viewer, a_id).await?;
    tx.commit().await?;
    Ok(Json(item))
}

pub async fn delete_item(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let viewer = load_viewer(&a_state, &mut tx, a_user.user_id).await?;
    let scope = require_editable(&mut tx, &viewer, a_id).await?;
    if scope.is_used_by_others
    {
        return Err(ApiError::Conflict("ITEM_IN_USE"));
    }

    sqlx::query!("DELETE FROM items WHERE id = $1", a_id)
        .execute(&mut *tx)
        .await
        .map_err(|err| match ApiError::from(err)
        {
            ApiError::Validation("reference") => ApiError::Conflict("IN_USE"),
            other => other,
        })?;

    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn fill_item(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<FillItemRequest>,
) -> Result<Json<DictItemDto>, ApiError>
{
    let nutrition = check_nutrition(a_req.nutrition.unwrap_or_default())?;
    let mut tx = a_state.db.begin().await?;
    let viewer = load_viewer(&a_state, &mut tx, a_user.user_id).await?;
    let scope = item_scope(&mut tx, a_id, a_user.user_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    if !nutrition.is_empty() && scope.kind != ItemKind::Food
    {
        return Err(ApiError::Validation("nutrition"));
    }
    let (net_qty, net_measure) = check_net(scope.unit, a_req.net_qty, a_req.net_measure)?;
    require_cat(&mut tx, a_req.cat_id).await?;

    sqlx::query!(
        r#"
        UPDATE items
        SET kcal = COALESCE(kcal, $2),
            prot = COALESCE(prot, $3),
            fat = COALESCE(fat, $4),
            carb = COALESCE(carb, $5),
            piece_g = COALESCE(piece_g, $6),
            net_measure = CASE WHEN net_qty IS NULL THEN $8 ELSE net_measure END,
            net_qty = COALESCE(net_qty, $7),
            cat_id = COALESCE(cat_id, $9)
        WHERE id = $1
        "#,
        a_id,
        nutrition.kcal,
        nutrition.prot,
        nutrition.fat,
        nutrition.carb,
        nutrition.piece_g,
        net_qty,
        net_measure as Option<NetMeasure>,
        a_req.cat_id
    )
    .execute(&mut *tx)
    .await?;
    rescale_item_stock(&mut tx, a_id).await?;

    let item = load_item(&a_state, &mut tx, &viewer, a_id).await?;
    tx.commit().await?;
    Ok(Json(item))
}

pub async fn merge_item(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<MergeItemRequest>,
) -> Result<Json<DictItemDto>, ApiError>
{
    if a_id == a_req.target_id
    {
        return Err(ApiError::Validation("target_id"));
    }

    let mut tx = a_state.db.begin().await?;
    let viewer = load_viewer(&a_state, &mut tx, a_user.user_id).await?;
    let source = require_editable(&mut tx, &viewer, a_id).await?;
    if source.is_used_by_others && !viewer.is_admin
    {
        return Err(ApiError::Conflict("ITEM_IN_USE"));
    }
    let target = item_scope(&mut tx, a_req.target_id, viewer.user_id)
        .await?
        .ok_or(ApiError::Validation("target_id"))?;
    if source.unit != target.unit
    {
        return Err(ApiError::Validation("target_id"));
    }

    sqlx::query!(
        "UPDATE receipt_items SET item_id = $2 WHERE item_id = $1",
        a_id,
        a_req.target_id
    )
    .execute(&mut *tx)
    .await?;
    sqlx::query!(
        "UPDATE item_prices SET item_id = $2 WHERE item_id = $1",
        a_id,
        a_req.target_id
    )
    .execute(&mut *tx)
    .await?;
    sqlx::query!(
        "UPDATE meal_entries SET item_id = $2 WHERE item_id = $1",
        a_id,
        a_req.target_id
    )
    .execute(&mut *tx)
    .await?;
    sqlx::query!(
        "UPDATE plan_foods SET item_id = $2 WHERE item_id = $1",
        a_id,
        a_req.target_id
    )
    .execute(&mut *tx)
    .await?;
    sqlx::query!(
        "UPDATE dish_ingredients SET item_id = $2 WHERE item_id = $1",
        a_id,
        a_req.target_id
    )
    .execute(&mut *tx)
    .await?;
    sqlx::query!(
        "UPDATE item_aliases SET item_id = $2 WHERE item_id = $1",
        a_id,
        a_req.target_id
    )
    .execute(&mut *tx)
    .await?;
    sqlx::query!(
        "UPDATE stock_lots SET item_id = $2 WHERE item_id = $1",
        a_id,
        a_req.target_id
    )
    .execute(&mut *tx)
    .await?;
    sqlx::query!(
        "UPDATE cook_batch_items SET item_id = $2 WHERE item_id = $1",
        a_id,
        a_req.target_id
    )
    .execute(&mut *tx)
    .await?;

    let removed = sqlx::query!(
        r#"
        DELETE FROM items WHERE id = $1
        RETURNING barcode, kcal, prot, fat, carb, piece_g, net_qty, net_measure AS "net_measure: NetMeasure", cat_id
        "#,
        a_id
    )
    .fetch_one(&mut *tx)
    .await?;

    let is_target_editable = viewer.is_admin || target.owner_id == Some(viewer.user_id);
    if is_target_editable
    {
        sqlx::query!(
            r#"
            UPDATE items
            SET barcode = COALESCE(barcode, $2),
                kcal = COALESCE(kcal, $3),
                prot = COALESCE(prot, $4),
                fat = COALESCE(fat, $5),
                carb = COALESCE(carb, $6),
                piece_g = COALESCE(piece_g, $7),
                net_measure = CASE WHEN net_qty IS NULL AND unit = 'piece' THEN $9 ELSE net_measure END,
                net_qty = CASE WHEN net_qty IS NULL AND unit = 'piece' THEN $8 ELSE net_qty END,
                cat_id = COALESCE(cat_id, $10)
            WHERE id = $1
            "#,
            a_req.target_id,
            removed.barcode,
            removed.kcal,
            removed.prot,
            removed.fat,
            removed.carb,
            removed.piece_g,
            removed.net_qty,
            removed.net_measure as Option<NetMeasure>,
            removed.cat_id
        )
        .execute(&mut *tx)
        .await?;
    }

    rescale_item_stock(&mut tx, a_req.target_id).await?;

    let item = load_item(&a_state, &mut tx, &viewer, a_req.target_id).await?;
    tx.commit().await?;
    Ok(Json(item))
}

pub async fn item_prices(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiQuery(a_query): ApiQuery<ItemPriceQuery>,
) -> Result<Json<ItemPricesDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    require_item(&mut conn, a_id).await?;

    let target = match a_query.convert_to.as_deref()
    {
        None => None,
        Some(code) => Some(
            sqlx::query!("SELECT id, code FROM currencies WHERE code = $1", code.to_uppercase())
                .fetch_optional(&mut *conn)
                .await?
                .ok_or(ApiError::Validation("convert_to"))?,
        ),
    };
    let target_id = target.as_ref().map(|currency| currency.id);
    let target_code = target.map(|currency| currency.code);

    let observations = sqlx::query_as!(
        Observation,
        r#"
        WITH sharers AS (
            SELECT DISTINCT theirs.user_id
            FROM family_mems mine
            JOIN family_mems theirs ON theirs.family_id = mine.family_id
            WHERE mine.user_id = $2 AND theirs.user_id <> $2
        ),
        obs AS (
            SELECT r.owner_id, r.place_id, r.place_addr_id, r.merchant_id, r.merchant_name, r.curr_id,
                   ri.amount / ri.qty AS unit_price, r.receipt_ts AS ts
            FROM receipt_items ri
            JOIN receipts r ON r.id = ri.receipt_id
            WHERE ri.item_id = $1
              AND (r.owner_id = $2 OR r.owner_id IN (SELECT user_id FROM sharers))
            UNION ALL
            SELECT ip.owner_id, ip.place_id, ip.place_addr_id, NULL::uuid, ip.merchant_name, ip.curr_id,
                   ip.price / ip.qty, ip.seen_ts
            FROM item_prices ip
            WHERE ip.item_id = $1
              AND (ip.owner_id = $2 OR ip.owner_id IN (SELECT user_id FROM sharers))
        )
        SELECT
            CASE
                WHEN o.place_id IS NOT NULL THEN 'p:' || o.place_id::text || ':' || COALESCE(o.place_addr_id::text, '')
                WHEN o.merchant_id IS NOT NULL THEN 'm:' || o.merchant_id::text
                WHEN o.merchant_name IS NOT NULL THEN 'n:' || LOWER(o.merchant_name)
                ELSE 'none'
            END AS "store_key!",
            COALESCE(pl.name, m.name, o.merchant_name) AS store_name,
            CASE WHEN pa.id IS NOT NULL THEN addr_label(ci.name, st.name, pa.house_num, pa.zip) END AS branch,
            c.code AS curr_code,
            o.unit_price AS "unit_price!",
            CASE
                WHEN $3::uuid IS NULL THEN NULL
                ELSE o.unit_price * uah_rate(o.curr_id, o.ts::date) / NULLIF(uah_rate($3, o.ts::date), 0)
            END AS converted,
            o.ts AS "ts!",
            (o.owner_id <> $2) AS "is_shared!"
        FROM obs o
        JOIN currencies c ON c.id = o.curr_id
        LEFT JOIN places pl ON pl.id = o.place_id
        LEFT JOIN place_addrs pa ON pa.id = o.place_addr_id
        LEFT JOIN streets st ON st.id = pa.street_id
        LEFT JOIN cities ci ON ci.id = pa.city_id
        LEFT JOIN merchants m ON m.id = o.merchant_id
        ORDER BY o.ts DESC
        LIMIT $4
        "#,
        a_id,
        a_user.user_id,
        target_id,
        MAX_OBSERVATIONS
    )
    .fetch_all(&mut *conn)
    .await?;

    let (prices, missing_rates) = aggregate_prices(observations, target_code.as_deref());

    Ok(Json(ItemPricesDto { prices, missing_rates }))
}

pub async fn list_manual_prices(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<Json<Vec<ManualPriceDto>>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    require_item(&mut conn, a_id).await?;
    load_manual_prices(&mut conn, a_id, a_user.user_id, None)
        .await
        .map(Json)
}

pub async fn create_manual_price(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SaveManualPriceRequest>,
) -> Result<(StatusCode, Json<ManualPriceDto>), ApiError>
{
    let merchant_name = clean_optional_text(a_req.merchant_name.as_deref(), MAX_STORE_NAME_LEN, "merchant_name")?;
    let note = clean_optional_text(a_req.note.as_deref(), MAX_PRICE_NOTE_LEN, "note")?;
    let qty = check_qty(a_req.qty)?;
    let price = check_money(a_req.price, "price")?;
    if price < Decimal::ZERO
    {
        return Err(ApiError::Validation("price"));
    }

    let now = Utc::now();
    let seen_ts = a_req.seen_ts.unwrap_or(now);
    if seen_ts > now + Duration::days(1) || seen_ts < now - Duration::days(MAX_PRICE_AGE_DAYS)
    {
        return Err(ApiError::Validation("seen_ts"));
    }
    if a_req.place_id.is_none() && merchant_name.is_none()
    {
        return Err(ApiError::Validation("place_id"));
    }

    let mut tx = a_state.db.begin().await?;
    require_item(&mut tx, a_id).await?;
    require_visible_place(&mut tx, a_req.place_id, a_req.place_addr_id, a_user.user_id, None).await?;

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

    let count = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM item_prices WHERE item_id = $1 AND owner_id = $2"#,
        a_id,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if count >= MAX_MANUAL_PRICES_PER_ITEM
    {
        return Err(ApiError::Validation("prices"));
    }

    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO item_prices (owner_id, item_id, place_id, place_addr_id, merchant_name, curr_id, qty, price, seen_ts, note)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        RETURNING id
        "#,
        a_user.user_id,
        a_id,
        a_req.place_id,
        a_req.place_addr_id,
        merchant_name,
        a_req.curr_id,
        qty,
        price,
        seen_ts,
        note
    )
    .fetch_one(&mut *tx)
    .await?;

    let created = load_manual_prices(&mut tx, a_id, a_user.user_id, Some(id))
        .await?
        .into_iter()
        .next()
        .ok_or(ApiError::NotFound)?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(created)))
}

pub async fn delete_manual_price(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath((a_id, a_price_id)): ApiPath<(Uuid, Uuid)>,
) -> Result<StatusCode, ApiError>
{
    let deleted = sqlx::query!(
        "DELETE FROM item_prices WHERE id = $1 AND item_id = $2 AND owner_id = $3",
        a_price_id,
        a_id,
        a_user.user_id
    )
    .execute(&a_state.db)
    .await?;

    if deleted.rows_affected() == 0
    {
        return Err(ApiError::NotFound);
    }

    Ok(StatusCode::NO_CONTENT)
}

pub async fn require_visible_items(a_conn: &mut PgConnection, a_item_ids: &[Uuid]) -> Result<(), ApiError>
{
    let mut ids = a_item_ids.to_vec();
    ids.sort_unstable();
    ids.dedup();

    let found = sqlx::query_scalar!(r#"SELECT COUNT(*) AS "count!" FROM items WHERE id = ANY($1)"#, &ids)
        .fetch_one(&mut *a_conn)
        .await?;

    if found as usize != ids.len()
    {
        return Err(ApiError::Validation("item_id"));
    }

    Ok(())
}

pub async fn resolve_new_item(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_item: &NewItemRequest,
) -> Result<Uuid, ApiError>
{
    lock_key(a_conn, &name_lock(&a_item.name)).await?;

    let existing = sqlx::query_scalar!(
        r#"
        SELECT i.id
        FROM items i
        WHERE ($2::text IS NOT NULL AND i.barcode = $2) OR LOWER(i.name) = LOWER($3)
        ORDER BY (i.barcode IS NOT DISTINCT FROM $2) DESC, (i.owner_id IS NOT DISTINCT FROM $1) DESC, i.created_ts
        LIMIT 1
        "#,
        a_user_id,
        a_item.barcode,
        a_item.name
    )
    .fetch_optional(&mut *a_conn)
    .await?;
    if let Some(id) = existing
    {
        return Ok(id);
    }

    require_unique_barcode(a_conn, a_item.barcode.as_deref(), None).await?;
    sqlx::query_scalar!(
        r#"
        INSERT INTO items (owner_id, created_by, name, type, unit, barcode)
        VALUES ($1, $1, $2, $3, $4, $5)
        RETURNING id
        "#,
        a_user_id,
        a_item.name,
        a_item.kind as ItemKind,
        a_item.unit as ItemUnit,
        a_item.barcode
    )
    .fetch_one(&mut *a_conn)
    .await
    .map_err(ApiError::from)
}

pub async fn require_unique_barcode(
    a_conn: &mut PgConnection,
    a_barcode: Option<&str>,
    a_except_id: Option<Uuid>,
) -> Result<(), ApiError>
{
    let Some(barcode) = a_barcode
    else
    {
        return Ok(());
    };

    lock_key(a_conn, &format!("barcode:{barcode}")).await?;
    let is_taken = sqlx::query_scalar!(
        r#"
        SELECT EXISTS (
            SELECT 1 FROM items WHERE barcode = $1 AND ($2::uuid IS NULL OR id <> $2)
        ) AS "is_taken!"
        "#,
        barcode,
        a_except_id
    )
    .fetch_one(&mut *a_conn)
    .await?;

    if is_taken
    {
        return Err(ApiError::Conflict("BARCODE_TAKEN"));
    }

    Ok(())
}

pub async fn load_viewer(a_state: &AppState, a_conn: &mut PgConnection, a_user_id: Uuid) -> Result<Viewer, ApiError>
{
    Ok(Viewer {
        user_id: a_user_id,
        is_admin: is_catalog_admin(a_conn, &a_state.cfg.catalog.admin_emails, a_user_id).await?,
    })
}

pub async fn require_item(a_conn: &mut PgConnection, a_id: Uuid) -> Result<(), ApiError>
{
    sqlx::query_scalar!("SELECT id FROM items WHERE id = $1", a_id)
        .fetch_optional(&mut *a_conn)
        .await?
        .map(|_| ())
        .ok_or(ApiError::NotFound)
}

async fn require_unique_name(a_conn: &mut PgConnection, a_name: &str, a_except_id: Option<Uuid>)
    -> Result<(), ApiError>
{
    lock_key(a_conn, &name_lock(a_name)).await?;
    let is_taken = sqlx::query_scalar!(
        r#"
        SELECT EXISTS (
            SELECT 1 FROM items WHERE LOWER(name) = LOWER($1) AND ($2::uuid IS NULL OR id <> $2)
        ) AS "is_taken!"
        "#,
        a_name,
        a_except_id
    )
    .fetch_one(&mut *a_conn)
    .await?;

    if is_taken
    {
        return Err(ApiError::Conflict("ITEM_EXISTS"));
    }

    Ok(())
}

fn name_lock(a_name: &str) -> String
{
    format!("item-name:{}", a_name.to_lowercase())
}

async fn lock_key(a_conn: &mut PgConnection, a_key: &str) -> Result<(), ApiError>
{
    sqlx::query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", a_key)
        .execute(&mut *a_conn)
        .await?;
    Ok(())
}

fn check_net(
    a_unit: ItemUnit,
    a_net_qty: Option<Decimal>,
    a_net_measure: Option<NetMeasure>,
) -> Result<(Option<Decimal>, Option<NetMeasure>), ApiError>
{
    match (a_net_qty, a_net_measure)
    {
        (None, None) => Ok((None, None)),
        (Some(qty), Some(measure)) if a_unit == ItemUnit::Piece =>
        {
            let qty = qty.round_dp(NET_SCALE).normalize();
            if qty <= Decimal::ZERO || qty > Decimal::from(MAX_NET_QTY)
            {
                return Err(ApiError::Validation("net_qty"));
            }
            Ok((Some(qty), Some(measure)))
        }
        _ => Err(ApiError::Validation("net_qty")),
    }
}

async fn require_cat(a_conn: &mut PgConnection, a_cat_id: Option<Uuid>) -> Result<(), ApiError>
{
    let Some(cat_id) = a_cat_id
    else
    {
        return Ok(());
    };
    let is_known = sqlx::query_scalar!(
        r#"SELECT EXISTS(SELECT 1 FROM product_cats WHERE id = $1) AS "known!""#,
        cat_id
    )
    .fetch_one(&mut *a_conn)
    .await?;
    if !is_known
    {
        return Err(ApiError::Validation("cat_id"));
    }
    Ok(())
}

fn check_nutrition(a_nutrition: NutritionDto) -> Result<NutritionDto, ApiError>
{
    let bounded = |a_value: Option<Decimal>, a_max: i64, a_field: &'static str| match a_value
    {
        Some(value) if value < Decimal::ZERO || value > Decimal::from(a_max) => Err(ApiError::Validation(a_field)),
        other => Ok(other.map(|value| value.round_dp(2).normalize())),
    };

    Ok(NutritionDto {
        kcal: bounded(a_nutrition.kcal, MAX_KCAL, "nutrition.kcal")?,
        prot: bounded(a_nutrition.prot, MAX_GRAMS, "nutrition.prot")?,
        fat: bounded(a_nutrition.fat, MAX_GRAMS, "nutrition.fat")?,
        carb: bounded(a_nutrition.carb, MAX_GRAMS, "nutrition.carb")?,
        piece_g: match a_nutrition.piece_g
        {
            Some(value) if value <= Decimal::ZERO || value > Decimal::from(MAX_PIECE_G) =>
            {
                return Err(ApiError::Validation("nutrition.piece_g"))
            }
            other => other.map(|value| value.round_dp(1).normalize()),
        },
    })
}

async fn query_items(
    a_state: &AppState,
    a_conn: &mut PgConnection,
    a_viewer: &Viewer,
    a_filter: &ItemFilter<'_>,
    a_limit: i64,
) -> Result<Vec<DictItemDto>, ApiError>
{
    let rows = sqlx::query_as!(
        ItemRow,
        r#"
        WITH sharers AS (
            SELECT DISTINCT theirs.user_id
            FROM family_mems mine
            JOIN family_mems theirs ON theirs.family_id = mine.family_id
            WHERE mine.user_id = $1 AND theirs.user_id <> $1
        )
        SELECT
            i.id,
            i.name,
            i.type AS "kind: ItemKind",
            i.unit AS "unit: ItemUnit",
            i.barcode,
            i.kcal,
            i.prot,
            i.fat,
            i.carb,
            i.piece_g,
            i.net_qty,
            i.net_measure AS "net_measure: NetMeasure",
            i.cat_id,
            CASE
                WHEN i.owner_id = $1 THEN 'me'
                WHEN i.owner_id IS NULL OR LOWER(ou.email) = ANY($2) THEN 'catalog'
                WHEN i.owner_id IN (SELECT user_id FROM sharers) THEN 'member'
                ELSE 'user'
            END AS "owner_kind!",
            CASE
                WHEN i.owner_id <> $1
                     AND NOT COALESCE(LOWER(ou.email) = ANY($2), FALSE)
                     AND i.owner_id IN (SELECT user_id FROM sharers)
                    THEN ou.first_name || ' ' || ou.last_name
            END AS owner_name,
            (i.owner_id IS NOT DISTINCT FROM $1 OR $3) AS "is_editable!",
            CASE
                WHEN i.owner_id IS NOT DISTINCT FROM $1 OR $3 THEN item_used_by_others(i.id, $1)
                ELSE FALSE
            END AS "is_in_use!"
        FROM items i
        LEFT JOIN users ou ON ou.id = i.owner_id
        WHERE ($4::uuid IS NULL OR i.id = $4)
          AND ($5::text IS NULL OR i.name ILIKE $5 OR i.barcode = $6)
          AND ($7::text IS NULL OR i.barcode = $7)
          AND (NOT $8 OR i.owner_id IS NOT DISTINCT FROM $1)
          AND ($11::item_t IS NULL OR i.type = $11)
          AND (
              $12::uuid IS NULL
              OR i.cat_id IN (
                  WITH RECURSIVE sub AS (
                      SELECT id FROM product_cats WHERE id = $12
                      UNION ALL
                      SELECT c.id FROM product_cats c JOIN sub ON c.parent_id = sub.id
                  )
                  SELECT id FROM sub
              )
          )
        ORDER BY (i.barcode IS NOT NULL AND i.barcode IS NOT DISTINCT FROM $6) DESC,
                 ($9::text IS NOT NULL AND i.name ILIKE $9) DESC,
                 (i.owner_id IS NOT DISTINCT FROM $1) DESC,
                 LOWER(i.name),
                 i.id
        LIMIT $10
        "#,
        a_viewer.user_id,
        &a_state.cfg.catalog.admin_emails,
        a_viewer.is_admin,
        a_filter.id,
        a_filter.pattern,
        a_filter.query_barcode,
        a_filter.barcode,
        a_filter.is_mine,
        a_filter.prefix,
        a_limit,
        a_filter.kind as Option<ItemKind>,
        a_filter.cat_id
    )
    .fetch_all(&mut *a_conn)
    .await?;

    Ok(rows.into_iter().map(DictItemDto::from).collect())
}

async fn load_item(
    a_state: &AppState,
    a_conn: &mut PgConnection,
    a_viewer: &Viewer,
    a_id: Uuid,
) -> Result<DictItemDto, ApiError>
{
    let filter = ItemFilter {
        id: Some(a_id),
        ..ItemFilter::default()
    };
    query_items(a_state, a_conn, a_viewer, &filter, 1)
        .await?
        .into_iter()
        .next()
        .ok_or(ApiError::NotFound)
}

async fn item_scope(a_conn: &mut PgConnection, a_id: Uuid, a_user_id: Uuid) -> Result<Option<ItemScope>, ApiError>
{
    sqlx::query_as!(
        ItemScope,
        r#"
        SELECT
            owner_id,
            name,
            type AS "kind: ItemKind",
            unit AS "unit: ItemUnit",
            barcode,
            piece_g,
            net_qty,
            net_measure AS "net_measure: NetMeasure",
            cat_id,
            item_used_by_others(id, $2) AS "is_used_by_others!"
        FROM items
        WHERE id = $1
        FOR UPDATE
        "#,
        a_id,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await
    .map_err(ApiError::from)
}

async fn require_editable(a_conn: &mut PgConnection, a_viewer: &Viewer, a_id: Uuid) -> Result<ItemScope, ApiError>
{
    let scope = item_scope(a_conn, a_id, a_viewer.user_id)
        .await?
        .ok_or(ApiError::NotFound)?;

    if !a_viewer.is_admin && scope.owner_id != Some(a_viewer.user_id)
    {
        return Err(ApiError::Forbidden);
    }

    Ok(scope)
}

fn aggregate_prices(a_observations: Vec<Observation>, a_target_code: Option<&str>) -> (Vec<ItemPriceDto>, Vec<String>)
{
    let mut groups: HashMap<(String, String), PriceAcc> = HashMap::new();
    let mut missing = BTreeSet::new();

    for observation in a_observations
    {
        let (value, curr_code) = match a_target_code
        {
            None => (observation.unit_price, observation.curr_code),
            Some(code) => match observation.converted
            {
                Some(converted) => (converted, code.to_string()),
                None =>
                {
                    missing.insert(observation.curr_code);
                    continue;
                }
            },
        };

        groups
            .entry((observation.store_key, curr_code.clone()))
            .and_modify(|acc| {
                acc.min_price = acc.min_price.min(value);
                acc.sum += value;
                acc.count += 1;
                acc.is_shared |= observation.is_shared;
                if observation.ts > acc.last_ts
                {
                    acc.last_ts = observation.ts;
                    acc.last_price = value;
                }
            })
            .or_insert(PriceAcc {
                store_name: observation.store_name,
                branch: observation.branch,
                curr_code,
                last_price: value,
                last_ts: observation.ts,
                min_price: value,
                sum: value,
                count: 1,
                is_shared: observation.is_shared,
            });
    }

    let mut prices: Vec<ItemPriceDto> = groups
        .into_values()
        .map(|acc| ItemPriceDto {
            store_name: acc.store_name,
            branch: acc.branch,
            curr_code: acc.curr_code,
            last_price: money(acc.last_price.round_dp(2)),
            min_price: money(acc.min_price.round_dp(2)),
            avg_price: money((acc.sum / Decimal::from(acc.count)).round_dp(2)),
            count: acc.count,
            last_ts: acc.last_ts,
            is_shared: acc.is_shared,
        })
        .collect();

    prices.sort_by(|left, right| {
        left.curr_code
            .cmp(&right.curr_code)
            .then(left.last_price.cmp(&right.last_price))
            .then(left.store_name.cmp(&right.store_name))
            .then(left.branch.cmp(&right.branch))
    });

    (prices, missing.into_iter().collect())
}

async fn load_manual_prices(
    a_conn: &mut PgConnection,
    a_item_id: Uuid,
    a_user_id: Uuid,
    a_only: Option<Uuid>,
) -> Result<Vec<ManualPriceDto>, ApiError>
{
    sqlx::query_as!(
        ManualPriceDto,
        r#"
        SELECT
            ip.id,
            ip.place_id,
            ip.place_addr_id,
            COALESCE(pl.name, ip.merchant_name) AS store_name,
            CASE WHEN pa.id IS NOT NULL THEN addr_label(ci.name, st.name, pa.house_num, pa.zip) END AS branch,
            c.code AS curr_code,
            ip.qty,
            ip.price,
            ip.seen_ts,
            ip.note
        FROM item_prices ip
        JOIN currencies c ON c.id = ip.curr_id
        LEFT JOIN places pl ON pl.id = ip.place_id
        LEFT JOIN place_addrs pa ON pa.id = ip.place_addr_id
        LEFT JOIN streets st ON st.id = pa.street_id
        LEFT JOIN cities ci ON ci.id = pa.city_id
        WHERE ip.item_id = $1 AND ip.owner_id = $2 AND ($3::uuid IS NULL OR ip.id = $3)
        ORDER BY ip.seen_ts DESC
        LIMIT 200
        "#,
        a_item_id,
        a_user_id,
        a_only
    )
    .fetch_all(&mut *a_conn)
    .await
    .map_err(ApiError::from)
}

#[cfg(test)]
mod tests
{
    use std::str::FromStr;

    use super::*;

    fn observation(
        a_store: &str,
        a_code: &str,
        a_price: &str,
        a_converted: Option<&str>,
        a_hours_ago: i64,
    ) -> Observation
    {
        Observation {
            store_key: a_store.to_string(),
            store_name: Some(a_store.to_string()),
            branch: None,
            curr_code: a_code.to_string(),
            unit_price: Decimal::from_str(a_price).unwrap(),
            converted: a_converted.map(|value| Decimal::from_str(value).unwrap()),
            ts: Utc::now() - Duration::hours(a_hours_ago),
            is_shared: a_hours_ago == 1,
        }
    }

    #[test]
    fn latest_price_per_store_is_compared_in_one_currency()
    {
        let rows = vec![
            observation("atb", "UAH", "40", Some("0.88"), 1),
            observation("atb", "UAH", "36", Some("0.80"), 48),
            observation("tesco", "EUR", "1.10", Some("1.10"), 5),
            observation("silpo", "PLN", "5", None, 3),
        ];

        let (by_currency, missing) = aggregate_prices(
            rows.iter()
                .map(|row| observation(&row.store_key, &row.curr_code, &row.unit_price.to_string(), None, 0))
                .collect(),
            None,
        );
        assert_eq!(by_currency.len(), 3);
        assert!(missing.is_empty());

        let (converted, missing) = aggregate_prices(rows, Some("EUR"));
        assert_eq!(missing, vec!["PLN".to_string()]);
        assert_eq!(converted.len(), 2);
        assert_eq!(converted[0].store_name.as_deref(), Some("atb"));
        assert_eq!(converted[0].last_price, Decimal::from_str("0.88").unwrap());
        assert_eq!(converted[0].min_price, Decimal::from_str("0.80").unwrap());
        assert_eq!(converted[0].avg_price, Decimal::from_str("0.84").unwrap());
        assert_eq!(converted[0].count, 2);
        assert!(converted[0].is_shared);
        assert_eq!(converted[1].store_name.as_deref(), Some("tesco"));
        assert!(!converted[1].is_shared);
    }
}
