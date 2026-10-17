use std::collections::HashMap;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, Utc};
use rust_decimal::Decimal;
use shared_schema::{
    CatPriceQuery, CatPricesDto, ItemOwnerKind, ItemUnit, MergeProductCatRequest, NetMeasure, ProductCatDto,
    ProductCatTreeDto, SaveProductCatRequest,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::api::item_handlers::{load_viewer, Viewer};
use crate::domain::errors::ApiError;
use crate::domain::validation::clean_text;
use crate::services::tree::{Forest, TreeError};
use crate::services::unit_price::{rank_prices, PriceObservation};
use crate::state::AppState;

const MAX_CAT_NAME_LEN: usize = 100;
const MAX_CATS_PER_USER: i64 = 500;
const MAX_PRICE_DAYS: i64 = 3650;
const MAX_PRICE_OBSERVATIONS: i64 = 20_000;
const TREE_LOCK: &str = "product-cats";

struct CatRow
{
    id: Uuid,
    parent_id: Option<Uuid>,
    code: Option<String>,
    name: String,
    owner_id: Option<Uuid>,
    is_catalog: bool,
}

struct ItemStats
{
    count: i64,
    is_foreign: bool,
}

struct CatTree
{
    rows: Vec<CatRow>,
    forest: Forest,
    stats: HashMap<Uuid, ItemStats>,
}

struct ObservationRow
{
    item_id: Uuid,
    item_name: String,
    cat_id: Option<Uuid>,
    unit: ItemUnit,
    net_qty: Option<Decimal>,
    net_measure: Option<NetMeasure>,
    curr_code: String,
    unit_price: Decimal,
    converted: Option<Decimal>,
    store_name: Option<String>,
    branch: Option<String>,
    ts: DateTime<Utc>,
}

impl CatTree
{
    fn row(&self, a_id: Uuid) -> Option<&CatRow>
    {
        self.rows.iter().find(|row| row.id == a_id)
    }

    fn is_used_by_others(&self, a_id: Uuid, a_user_id: Uuid) -> bool
    {
        self.forest.subtree(a_id).into_iter().any(|id| {
            let is_foreign_items = self.stats.get(&id).is_some_and(|stats| stats.is_foreign);
            let is_foreign_node = id != a_id && self.row(id).is_some_and(|row| row.owner_id != Some(a_user_id));
            is_foreign_items || is_foreign_node
        })
    }

    fn to_dto(&self, a_row: &CatRow, a_viewer: &Viewer) -> ProductCatDto
    {
        let owner_kind = if a_row.owner_id == Some(a_viewer.user_id)
        {
            ItemOwnerKind::Me
        }
        else if a_row.is_catalog
        {
            ItemOwnerKind::Catalog
        }
        else
        {
            ItemOwnerKind::User
        };
        ProductCatDto {
            id: a_row.id,
            parent_id: a_row.parent_id,
            code: a_row.code.clone(),
            name: a_row.name.clone(),
            depth: self.forest.depth(a_row.id),
            item_count: self.stats.get(&a_row.id).map_or(0, |stats| stats.count),
            owner_kind,
            is_editable: a_viewer.is_admin || a_row.owner_id == Some(a_viewer.user_id),
            is_in_use: self.is_used_by_others(a_row.id, a_viewer.user_id),
        }
    }

    fn node(&self, a_id: Uuid, a_viewer: &Viewer) -> Result<ProductCatDto, ApiError>
    {
        self.row(a_id)
            .map(|row| self.to_dto(row, a_viewer))
            .ok_or(ApiError::NotFound)
    }

    fn require_editable(&self, a_id: Uuid, a_viewer: &Viewer) -> Result<&CatRow, ApiError>
    {
        let row = self.row(a_id).ok_or(ApiError::NotFound)?;
        if a_viewer.is_admin
        {
            return Ok(row);
        }
        if row.owner_id != Some(a_viewer.user_id)
        {
            return Err(ApiError::Forbidden);
        }
        if self.is_used_by_others(a_id, a_viewer.user_id)
        {
            return Err(ApiError::Conflict("CAT_IN_USE"));
        }
        Ok(row)
    }
}

fn tree_error(a_error: TreeError) -> ApiError
{
    match a_error
    {
        TreeError::UnknownNode => ApiError::Validation("parent_id"),
        TreeError::Cycle => ApiError::Validation("cycle"),
        TreeError::TooDeep => ApiError::Validation("depth"),
    }
}

fn name_conflict(a_error: sqlx::Error) -> ApiError
{
    match ApiError::from(a_error)
    {
        ApiError::Conflict("ALREADY_EXISTS") => ApiError::Conflict("CAT_EXISTS"),
        other => other,
    }
}

async fn lock_tree(a_conn: &mut PgConnection) -> Result<(), ApiError>
{
    sqlx::query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", TREE_LOCK)
        .execute(&mut *a_conn)
        .await?;
    Ok(())
}

async fn load_tree(a_state: &AppState, a_conn: &mut PgConnection, a_user_id: Uuid) -> Result<CatTree, ApiError>
{
    let rows = sqlx::query_as!(
        CatRow,
        r#"
        SELECT c.id, c.parent_id, c.code, c.name, c.owner_id,
               (c.owner_id IS NULL OR COALESCE(LOWER(u.email) = ANY($1), FALSE)) AS "is_catalog!"
        FROM product_cats c
        LEFT JOIN users u ON u.id = c.owner_id
        ORDER BY c.parent_id NULLS FIRST, LOWER(c.name), c.id
        "#,
        &a_state.cfg.catalog.admin_emails
    )
    .fetch_all(&mut *a_conn)
    .await?;

    let stats = sqlx::query!(
        r#"
        SELECT cat_id AS "cat_id!", COUNT(*) AS "count!", BOOL_OR(owner_id IS DISTINCT FROM $1) AS "is_foreign!"
        FROM items
        WHERE cat_id IS NOT NULL
        GROUP BY cat_id
        "#,
        a_user_id
    )
    .fetch_all(&mut *a_conn)
    .await?
    .into_iter()
    .map(|row| {
        (
            row.cat_id,
            ItemStats {
                count: row.count,
                is_foreign: row.is_foreign,
            },
        )
    })
    .collect();

    let forest = Forest::new(rows.iter().map(|row| (row.id, row.parent_id)));
    Ok(CatTree { rows, forest, stats })
}

pub async fn list_cats(State(a_state): State<AppState>, a_user: AuthUser) -> Result<Json<ProductCatTreeDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let viewer = load_viewer(&a_state, &mut conn, a_user.user_id).await?;
    let tree = load_tree(&a_state, &mut conn, a_user.user_id).await?;
    Ok(Json(ProductCatTreeDto {
        max_depth: a_state.cfg.catalog.cat_max_depth,
        is_admin: viewer.is_admin,
        nodes: tree.rows.iter().map(|row| tree.to_dto(row, &viewer)).collect(),
    }))
}

pub async fn create_cat(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SaveProductCatRequest>,
) -> Result<(StatusCode, Json<ProductCatDto>), ApiError>
{
    let name = clean_text(&a_req.name, 1, MAX_CAT_NAME_LEN, "name")?;
    let mut tx = a_state.db.begin().await?;
    lock_tree(&mut tx).await?;
    let viewer = load_viewer(&a_state, &mut tx, a_user.user_id).await?;
    let tree = load_tree(&a_state, &mut tx, a_user.user_id).await?;
    tree.forest
        .check_add(a_req.parent_id, a_state.cfg.catalog.cat_max_depth)
        .map_err(tree_error)?;

    let count = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM product_cats WHERE created_by = $1"#,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if count >= MAX_CATS_PER_USER
    {
        return Err(ApiError::Conflict("TOO_MANY_CATS"));
    }

    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO product_cats (parent_id, name, owner_id, created_by)
        VALUES ($1, $2, $3, $3)
        RETURNING id
        "#,
        a_req.parent_id,
        name,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(name_conflict)?;

    let tree = load_tree(&a_state, &mut tx, a_user.user_id).await?;
    let created = tree.node(id, &viewer)?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(created)))
}

pub async fn update_cat(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SaveProductCatRequest>,
) -> Result<Json<ProductCatDto>, ApiError>
{
    let name = clean_text(&a_req.name, 1, MAX_CAT_NAME_LEN, "name")?;
    let mut tx = a_state.db.begin().await?;
    lock_tree(&mut tx).await?;
    let viewer = load_viewer(&a_state, &mut tx, a_user.user_id).await?;
    let tree = load_tree(&a_state, &mut tx, a_user.user_id).await?;
    tree.require_editable(a_id, &viewer)?;
    tree.forest
        .check_move(a_id, a_req.parent_id, a_state.cfg.catalog.cat_max_depth)
        .map_err(tree_error)?;

    sqlx::query!(
        "UPDATE product_cats SET name = $2, parent_id = $3, updated_ts = NOW() WHERE id = $1",
        a_id,
        name,
        a_req.parent_id
    )
    .execute(&mut *tx)
    .await
    .map_err(name_conflict)?;

    let tree = load_tree(&a_state, &mut tx, a_user.user_id).await?;
    let updated = tree.node(a_id, &viewer)?;
    tx.commit().await?;
    Ok(Json(updated))
}

pub async fn delete_cat(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    lock_tree(&mut tx).await?;
    let viewer = load_viewer(&a_state, &mut tx, a_user.user_id).await?;
    let tree = load_tree(&a_state, &mut tx, a_user.user_id).await?;
    let parent_id = tree.require_editable(a_id, &viewer)?.parent_id;
    if !tree.forest.children(a_id).is_empty()
    {
        return Err(ApiError::Conflict("CAT_HAS_CHILDREN"));
    }

    sqlx::query!("UPDATE items SET cat_id = $2 WHERE cat_id = $1", a_id, parent_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query!("DELETE FROM product_cats WHERE id = $1", a_id)
        .execute(&mut *tx)
        .await?;

    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn merge_cat(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<MergeProductCatRequest>,
) -> Result<Json<ProductCatDto>, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    lock_tree(&mut tx).await?;
    let viewer = load_viewer(&a_state, &mut tx, a_user.user_id).await?;
    if !viewer.is_admin
    {
        return Err(ApiError::Forbidden);
    }
    let tree = load_tree(&a_state, &mut tx, a_user.user_id).await?;
    if tree.row(a_id).is_none()
    {
        return Err(ApiError::NotFound);
    }
    if a_id == a_req.target_id || tree.row(a_req.target_id).is_none()
    {
        return Err(ApiError::Validation("target_id"));
    }
    tree.forest
        .check_merge(a_id, a_req.target_id, a_state.cfg.catalog.cat_max_depth)
        .map_err(tree_error)?;

    let mut pending = vec![(a_id, a_req.target_id)];
    let mut merged = Vec::new();
    while let Some((source, target)) = pending.pop()
    {
        sqlx::query!("UPDATE items SET cat_id = $2 WHERE cat_id = $1", source, target)
            .execute(&mut *tx)
            .await?;
        let children = sqlx::query!(
            r#"
            SELECT child.id, twin.id AS "twin_id?"
            FROM product_cats child
            LEFT JOIN product_cats twin ON twin.parent_id = $2 AND LOWER(twin.name) = LOWER(child.name)
            WHERE child.parent_id = $1
            "#,
            source,
            target
        )
        .fetch_all(&mut *tx)
        .await?;
        for child in children
        {
            match child.twin_id
            {
                Some(twin) => pending.push((child.id, twin)),
                None =>
                {
                    sqlx::query!(
                        "UPDATE product_cats SET parent_id = $2, updated_ts = NOW() WHERE id = $1",
                        child.id,
                        target
                    )
                    .execute(&mut *tx)
                    .await?;
                }
            }
        }
        merged.push(source);
    }
    for source in merged.into_iter().rev()
    {
        sqlx::query!("DELETE FROM product_cats WHERE id = $1", source)
            .execute(&mut *tx)
            .await?;
    }

    let tree = load_tree(&a_state, &mut tx, a_user.user_id).await?;
    let target = tree.node(a_req.target_id, &viewer)?;
    tx.commit().await?;
    Ok(Json(target))
}

pub async fn cat_prices(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiQuery(a_query): ApiQuery<CatPriceQuery>,
) -> Result<Json<CatPricesDto>, ApiError>
{
    let days = a_query.days.unwrap_or(MAX_PRICE_DAYS);
    if !(1..=MAX_PRICE_DAYS).contains(&days)
    {
        return Err(ApiError::Validation("days"));
    }
    let since = Utc::now() - Duration::days(days);
    let mut conn = a_state.db.acquire().await?;
    let is_known = sqlx::query_scalar!(
        r#"SELECT EXISTS(SELECT 1 FROM product_cats WHERE id = $1) AS "known!""#,
        a_id
    )
    .fetch_one(&mut *conn)
    .await?;
    if !is_known
    {
        return Err(ApiError::NotFound);
    }

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

    let rows = sqlx::query_as!(
        ObservationRow,
        r#"
        WITH RECURSIVE sub AS (
            SELECT id FROM product_cats WHERE id = $1
            UNION ALL
            SELECT c.id FROM product_cats c JOIN sub ON c.parent_id = sub.id
        ),
        cat_items AS (
            SELECT i.id, i.name, i.cat_id, i.unit, i.net_qty, i.net_measure
            FROM items i
            WHERE i.cat_id IN (SELECT id FROM sub)
        ),
        sharers AS (
            SELECT DISTINCT theirs.user_id
            FROM family_mems mine
            JOIN family_mems theirs ON theirs.family_id = mine.family_id
            WHERE mine.user_id = $2 AND theirs.user_id <> $2
        ),
        obs AS (
            SELECT ri.item_id, r.place_id, r.place_addr_id, r.merchant_id, r.merchant_name, r.curr_id,
                   ri.amount / ri.qty AS unit_price, r.receipt_ts AS ts
            FROM receipt_items ri
            JOIN receipts r ON r.id = ri.receipt_id
            WHERE ri.item_id IN (SELECT id FROM cat_items)
              AND ri.qty > 0
              AND (r.owner_id = $2 OR r.owner_id IN (SELECT user_id FROM sharers))
            UNION ALL
            SELECT ip.item_id, ip.place_id, ip.place_addr_id, NULL::uuid, ip.merchant_name, ip.curr_id,
                   ip.price / ip.qty, ip.seen_ts
            FROM item_prices ip
            WHERE ip.item_id IN (SELECT id FROM cat_items)
              AND ip.qty > 0
              AND (ip.owner_id = $2 OR ip.owner_id IN (SELECT user_id FROM sharers))
        )
        SELECT
            ci.id AS "item_id!",
            ci.name AS "item_name!",
            ci.cat_id,
            ci.unit AS "unit!: ItemUnit",
            ci.net_qty,
            ci.net_measure AS "net_measure: NetMeasure",
            c.code AS curr_code,
            o.unit_price AS "unit_price!",
            CASE
                WHEN $3::uuid IS NULL THEN NULL
                ELSE o.unit_price * uah_rate(o.curr_id, o.ts::date) / NULLIF(uah_rate($3, o.ts::date), 0)
            END AS converted,
            COALESCE(pl.name, m.name, o.merchant_name) AS store_name,
            CASE WHEN pa.id IS NOT NULL THEN addr_label(ci2.name, st.name, pa.house_num, pa.zip) END AS branch,
            o.ts AS "ts!"
        FROM obs o
        JOIN cat_items ci ON ci.id = o.item_id
        JOIN currencies c ON c.id = o.curr_id
        LEFT JOIN places pl ON pl.id = o.place_id
        LEFT JOIN place_addrs pa ON pa.id = o.place_addr_id
        LEFT JOIN streets st ON st.id = pa.street_id
        LEFT JOIN cities ci2 ON ci2.id = pa.city_id
        LEFT JOIN merchants m ON m.id = o.merchant_id
        WHERE o.ts >= $4 AND ($5::uuid IS NULL OR o.place_id = $5)
        ORDER BY o.ts DESC
        LIMIT $6
        "#,
        a_id,
        a_user.user_id,
        target.as_ref().map(|currency| currency.id),
        since,
        a_query.place_id,
        MAX_PRICE_OBSERVATIONS
    )
    .fetch_all(&mut *conn)
    .await?;

    let mut missing_rates = false;
    let target_code = target.map(|currency| currency.code);
    let observations = rows
        .into_iter()
        .filter_map(|row| {
            let (curr_code, unit_price) = match target_code.as_deref()
            {
                None => (row.curr_code, row.unit_price),
                Some(code) => match row.converted
                {
                    Some(converted) => (code.to_string(), converted),
                    None =>
                    {
                        missing_rates = true;
                        return None;
                    }
                },
            };
            Some(PriceObservation {
                item_id: row.item_id,
                item_name: row.item_name,
                cat_id: row.cat_id,
                unit: row.unit,
                net_qty: row.net_qty,
                net_measure: row.net_measure,
                curr_code,
                unit_price,
                store: row.store_name,
                branch: row.branch,
                ts: row.ts,
            })
        })
        .collect();

    let (rows, unmeasured) = rank_prices(observations);
    Ok(Json(CatPricesDto {
        rows,
        unmeasured,
        missing_rates,
    }))
}
