use std::collections::{BTreeSet, HashMap};

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, Utc};
use rust_decimal::Decimal;
use shared_schema::{
    DictItemDto, ItemKind, ItemPriceDto, ItemPriceQuery, ItemPricesDto, ItemQuery, ItemUnit, ManualPriceDto,
    MergeItemRequest, SaveItemRequest, SaveManualPriceRequest, ShareToFamilyRequest,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::api::place_handlers::require_visible_place;
use crate::domain::errors::ApiError;
use crate::domain::validation::{
    check_money, check_qty, clean_barcode, clean_optional_text, clean_text, contains_pattern, money,
};
use crate::security::authz::require_member;
use crate::state::AppState;

pub const MAX_ITEM_NAME_LEN: usize = 200;
const DEFAULT_LIST_LIMIT: i64 = 200;
const MAX_LIST_LIMIT: i64 = 500;
const MAX_STORE_NAME_LEN: usize = 100;
const MAX_PRICE_NOTE_LEN: usize = 200;
const MAX_MANUAL_PRICES_PER_ITEM: i64 = 500;
const MAX_OBSERVATIONS: i64 = 5000;
const MAX_PRICE_AGE_DAYS: i64 = 3650;

struct ItemScope
{
    owner_id: Option<Uuid>,
    family_id: Option<Uuid>,
    unit: ItemUnit,
    is_visible: bool,
    is_editable: bool,
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

    let items = sqlx::query_as!(
        DictItemDto,
        r#"
        SELECT
            i.id,
            i.name,
            i.type AS "kind: ItemKind",
            i.unit AS "unit: ItemUnit",
            i.barcode,
            (i.owner_id IS NOT NULL OR i.family_id IS NOT NULL) AS "is_custom!",
            i.family_id,
            f.name AS "family_name?",
            can_edit_scoped(i.owner_id, i.family_id, i.created_by, $1) AS "is_editable!"
        FROM items i
        LEFT JOIN families f ON f.id = i.family_id
        WHERE (i.owner_id = $1
               OR (i.owner_id IS NULL AND i.family_id IS NULL)
               OR i.family_id IN (SELECT family_id FROM family_mems WHERE user_id = $1))
          AND ($2::text IS NULL OR i.name ILIKE $2 OR i.barcode = $5)
          AND ($6::text IS NULL OR i.barcode = $6)
        ORDER BY (i.barcode IS NOT NULL AND i.barcode = $5) DESC,
                 ($3::text IS NOT NULL AND i.name ILIKE $3) DESC,
                 LOWER(i.name),
                 f.name NULLS FIRST
        LIMIT $4
        "#,
        a_user.user_id,
        pattern,
        prefix,
        limit,
        query_barcode,
        barcode
    )
    .fetch_all(&a_state.db)
    .await?;

    Ok(Json(items))
}

pub async fn get_item(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<Json<DictItemDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    load_item(&mut conn, a_id, a_user.user_id).await.map(Json)
}

pub async fn create_item(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SaveItemRequest>,
) -> Result<(StatusCode, Json<DictItemDto>), ApiError>
{
    let name = clean_text(&a_req.name, 1, MAX_ITEM_NAME_LEN, "name")?;
    let barcode = clean_barcode(a_req.barcode.as_deref())?;
    let mut tx = a_state.db.begin().await?;

    if let Some(family_id) = a_req.family_id
    {
        require_member(&mut *tx, family_id, a_user.user_id)
            .await
            .map_err(|_| ApiError::Validation("family_id"))?;
    }
    let owner_id = a_req.family_id.is_none().then_some(a_user.user_id);

    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO items (owner_id, family_id, created_by, name, type, unit, barcode)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        RETURNING id
        "#,
        owner_id,
        a_req.family_id,
        a_user.user_id,
        name,
        a_req.kind as ItemKind,
        a_req.unit as ItemUnit,
        barcode
    )
    .fetch_one(&mut *tx)
    .await?;

    let item = load_item(&mut tx, id, a_user.user_id).await?;
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
    let mut tx = a_state.db.begin().await?;
    require_editable(&mut tx, a_id, a_user.user_id).await?;

    sqlx::query!(
        "UPDATE items SET name = $2, type = $3, unit = $4, barcode = $5 WHERE id = $1",
        a_id,
        name,
        a_req.kind as ItemKind,
        a_req.unit as ItemUnit,
        barcode
    )
    .execute(&mut *tx)
    .await?;

    let item = load_item(&mut tx, a_id, a_user.user_id).await?;
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
    require_editable(&mut tx, a_id, a_user.user_id).await?;

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

pub async fn share_item(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<ShareToFamilyRequest>,
) -> Result<Json<DictItemDto>, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let scope = require_editable(&mut tx, a_id, a_user.user_id).await?;
    if scope.owner_id != Some(a_user.user_id)
    {
        return Err(ApiError::Validation("family_id"));
    }

    require_member(&mut *tx, a_req.family_id, a_user.user_id)
        .await
        .map_err(|_| ApiError::Validation("family_id"))?;

    sqlx::query!(
        "UPDATE items SET owner_id = NULL, family_id = $2 WHERE id = $1",
        a_id,
        a_req.family_id
    )
    .execute(&mut *tx)
    .await?;

    let item = load_item(&mut tx, a_id, a_user.user_id).await?;
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
    let source = require_editable(&mut tx, a_id, a_user.user_id).await?;
    let target = item_scope(&mut tx, a_req.target_id, a_user.user_id)
        .await?
        .filter(|scope| scope.is_visible)
        .ok_or(ApiError::Validation("target_id"))?;

    let is_same_scope = source.family_id.is_none() || source.family_id == target.family_id;
    if source.unit != target.unit || !is_same_scope
    {
        return Err(ApiError::Validation("target_id"));
    }

    let is_blocked = sqlx::query_scalar!(
        r#"
        WITH users_of_source AS (
            SELECT r.owner_id AS user_id
            FROM receipt_items ri JOIN receipts r ON r.id = ri.receipt_id
            WHERE ri.item_id = $1
            UNION
            SELECT owner_id FROM item_prices WHERE item_id = $1
        )
        SELECT EXISTS (
            SELECT 1 FROM users_of_source u, items t
            WHERE t.id = $2
              AND NOT (t.owner_id IS NULL AND t.family_id IS NULL)
              AND NOT can_see_scoped(t.owner_id, t.family_id, u.user_id)
        ) AS "is_blocked!"
        "#,
        a_id,
        a_req.target_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if is_blocked
    {
        return Err(ApiError::Conflict("IN_USE"));
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
    sqlx::query!("DELETE FROM items WHERE id = $1", a_id)
        .execute(&mut *tx)
        .await?;

    let item = load_item(&mut tx, a_req.target_id, a_user.user_id).await?;
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
    load_item(&mut conn, a_id, a_user.user_id).await?;

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

    let matched_items = sqlx::query_scalar!(
        r#"
        SELECT COUNT(*) AS "count!"
        FROM items i, items t
        WHERE t.id = $1
          AND (i.id = t.id OR (t.barcode IS NOT NULL AND i.barcode = t.barcode AND i.unit = t.unit))
          AND ((i.owner_id IS NULL AND i.family_id IS NULL) OR can_see_scoped(i.owner_id, i.family_id, $2))
        "#,
        a_id,
        a_user.user_id
    )
    .fetch_one(&mut *conn)
    .await?;

    let observations = sqlx::query_as!(
        Observation,
        r#"
        WITH target AS (
            SELECT id, barcode, unit FROM items WHERE id = $1
        ),
        product AS (
            SELECT i.id, i.family_id
            FROM items i, target t
            WHERE (i.id = t.id OR (t.barcode IS NOT NULL AND i.barcode = t.barcode AND i.unit = t.unit))
              AND ((i.owner_id IS NULL AND i.family_id IS NULL) OR can_see_scoped(i.owner_id, i.family_id, $2))
        ),
        sharers AS (
            SELECT fm.family_id, fm.user_id
            FROM family_mems fm
            WHERE fm.is_prices_shared
              AND fm.family_id IN (SELECT family_id FROM family_mems WHERE user_id = $2)
        ),
        obs AS (
            SELECT r.owner_id, r.place_id, r.place_addr_id, r.merchant_id, r.merchant_name, r.curr_id,
                   ri.amount / ri.qty AS unit_price, r.receipt_ts AS ts
            FROM receipt_items ri
            JOIN receipts r ON r.id = ri.receipt_id
            JOIN product p ON p.id = ri.item_id
            WHERE r.owner_id = $2
               OR EXISTS (SELECT 1 FROM sharers s WHERE s.family_id = p.family_id AND s.user_id = r.owner_id)
            UNION ALL
            SELECT ip.owner_id, ip.place_id, ip.place_addr_id, NULL::uuid, ip.merchant_name, ip.curr_id,
                   ip.price / ip.qty, ip.seen_ts
            FROM item_prices ip
            JOIN product p ON p.id = ip.item_id
            WHERE ip.owner_id = $2
               OR EXISTS (SELECT 1 FROM sharers s WHERE s.family_id = p.family_id AND s.user_id = ip.owner_id)
        )
        SELECT
            CASE
                WHEN o.place_id IS NOT NULL THEN 'p:' || o.place_id::text || ':' || COALESCE(o.place_addr_id::text, '')
                WHEN o.merchant_id IS NOT NULL THEN 'm:' || o.merchant_id::text
                WHEN o.merchant_name IS NOT NULL THEN 'n:' || LOWER(o.merchant_name)
                ELSE 'none'
            END AS "store_key!",
            COALESCE(pl.name, m.name, o.merchant_name) AS store_name,
            CASE WHEN pa.id IS NOT NULL THEN ci.name || ', ' || st.name || ' ' || pa.house_num END AS branch,
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

    Ok(Json(ItemPricesDto {
        prices,
        missing_rates,
        matched_items,
    }))
}

pub async fn list_manual_prices(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<Json<Vec<ManualPriceDto>>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    load_item(&mut conn, a_id, a_user.user_id).await?;
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
    load_item(&mut tx, a_id, a_user.user_id).await?;
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

pub async fn require_visible_items(
    a_conn: &mut PgConnection,
    a_item_ids: &[Uuid],
    a_user_id: Uuid,
    a_receipt_id: Option<Uuid>,
) -> Result<(), ApiError>
{
    let mut ids = a_item_ids.to_vec();
    ids.sort_unstable();
    ids.dedup();

    let visible = sqlx::query_scalar!(
        r#"
        SELECT COUNT(*) AS "count!"
        FROM items i
        WHERE i.id = ANY($1)
          AND ((i.owner_id IS NULL AND i.family_id IS NULL)
               OR can_see_scoped(i.owner_id, i.family_id, $2)
               OR EXISTS (SELECT 1 FROM receipt_items ri WHERE ri.receipt_id = $3 AND ri.item_id = i.id))
        "#,
        &ids,
        a_user_id,
        a_receipt_id
    )
    .fetch_one(&mut *a_conn)
    .await?;

    if visible as usize != ids.len()
    {
        return Err(ApiError::Validation("item_id"));
    }

    Ok(())
}

pub async fn detach_family_items(
    a_conn: &mut PgConnection,
    a_family_id: Uuid,
    a_fallback_owner: Uuid,
) -> Result<(), ApiError>
{
    sqlx::query!(
        r#"
        WITH heirs AS (
            SELECT
                i.id,
                CASE
                    WHEN EXISTS (SELECT 1 FROM family_mems fm WHERE fm.family_id = $1 AND fm.user_id = i.created_by)
                        THEN i.created_by
                    ELSE $2
                END AS heir_id
            FROM items i
            WHERE i.family_id = $1
        )
        UPDATE items i
        SET owner_id = h.heir_id,
            family_id = NULL,
            name = CASE
                WHEN EXISTS (SELECT 1 FROM items p WHERE p.owner_id = h.heir_id AND LOWER(p.name) = LOWER(i.name))
                    THEN LEFT(i.name, 170) || ' (' || LEFT(f.name, 25) || ')'
                ELSE i.name
            END,
            barcode = CASE
                WHEN EXISTS (SELECT 1 FROM items p WHERE p.owner_id = h.heir_id AND p.barcode = i.barcode)
                    THEN NULL
                ELSE i.barcode
            END
        FROM heirs h, families f
        WHERE i.id = h.id AND f.id = $1
        "#,
        a_family_id,
        a_fallback_owner
    )
    .execute(&mut *a_conn)
    .await?;

    Ok(())
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
            CASE WHEN pa.id IS NOT NULL THEN ci.name || ', ' || st.name || ' ' || pa.house_num END AS branch,
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

async fn item_scope(a_conn: &mut PgConnection, a_id: Uuid, a_user_id: Uuid) -> Result<Option<ItemScope>, ApiError>
{
    sqlx::query_as!(
        ItemScope,
        r#"
        SELECT
            owner_id,
            family_id,
            unit AS "unit: ItemUnit",
            ((owner_id IS NULL AND family_id IS NULL) OR can_see_scoped(owner_id, family_id, $2)) AS "is_visible!",
            can_edit_scoped(owner_id, family_id, created_by, $2) AS "is_editable!"
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

async fn require_editable(a_conn: &mut PgConnection, a_id: Uuid, a_user_id: Uuid) -> Result<ItemScope, ApiError>
{
    let scope = item_scope(a_conn, a_id, a_user_id)
        .await?
        .filter(|scope| scope.is_visible)
        .ok_or(ApiError::NotFound)?;

    if !scope.is_editable
    {
        return Err(ApiError::Forbidden);
    }

    Ok(scope)
}

async fn load_item(a_conn: &mut PgConnection, a_id: Uuid, a_user_id: Uuid) -> Result<DictItemDto, ApiError>
{
    sqlx::query_as!(
        DictItemDto,
        r#"
        SELECT
            i.id,
            i.name,
            i.type AS "kind: ItemKind",
            i.unit AS "unit: ItemUnit",
            i.barcode,
            (i.owner_id IS NOT NULL OR i.family_id IS NOT NULL) AS "is_custom!",
            i.family_id,
            f.name AS "family_name?",
            can_edit_scoped(i.owner_id, i.family_id, i.created_by, $2) AS "is_editable!"
        FROM items i
        LEFT JOIN families f ON f.id = i.family_id
        WHERE i.id = $1
          AND ((i.owner_id IS NULL AND i.family_id IS NULL) OR can_see_scoped(i.owner_id, i.family_id, $2))
        "#,
        a_id,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .ok_or(ApiError::NotFound)
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
