use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use shared_schema::{DictItemDto, ItemKind, ItemPriceDto, ItemQuery, ItemUnit, SaveItemRequest};
use sqlx::PgPool;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::domain::errors::ApiError;
use crate::domain::validation::{clean_text, contains_pattern};
use crate::state::AppState;

pub const MAX_ITEM_NAME_LEN: usize = 200;
const DEFAULT_LIST_LIMIT: i64 = 200;
const MAX_LIST_LIMIT: i64 = 500;

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
    let limit = a_query.limit.unwrap_or(DEFAULT_LIST_LIMIT).clamp(1, MAX_LIST_LIMIT);

    let items = sqlx::query_as!(
        DictItemDto,
        r#"
        SELECT id, name, type AS "kind: ItemKind", unit AS "unit: ItemUnit", owner_id IS NOT NULL AS "is_custom!"
        FROM items
        WHERE (owner_id IS NULL OR owner_id = $1)
          AND ($2::text IS NULL OR name ILIKE $2)
        ORDER BY ($3::text IS NOT NULL AND name ILIKE $3) DESC, LOWER(name)
        LIMIT $4
        "#,
        a_user.user_id,
        pattern,
        prefix,
        limit
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
    load_item(&a_state.db, a_id, a_user.user_id).await.map(Json)
}

pub async fn create_item(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SaveItemRequest>,
) -> Result<(StatusCode, Json<DictItemDto>), ApiError>
{
    let name = clean_text(&a_req.name, 1, MAX_ITEM_NAME_LEN, "name")?;

    let id = sqlx::query_scalar!(
        "INSERT INTO items (owner_id, name, type, unit) VALUES ($1, $2, $3, $4) RETURNING id",
        a_user.user_id,
        name,
        a_req.kind as ItemKind,
        a_req.unit as ItemUnit
    )
    .fetch_one(&a_state.db)
    .await?;

    let item = load_item(&a_state.db, id, a_user.user_id).await?;
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
    require_own(&a_state.db, a_id, a_user.user_id).await?;

    sqlx::query!(
        "UPDATE items SET name = $2, type = $3, unit = $4 WHERE id = $1",
        a_id,
        name,
        a_req.kind as ItemKind,
        a_req.unit as ItemUnit
    )
    .execute(&a_state.db)
    .await?;

    load_item(&a_state.db, a_id, a_user.user_id).await.map(Json)
}

pub async fn delete_item(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    require_own(&a_state.db, a_id, a_user.user_id).await?;

    sqlx::query!("DELETE FROM items WHERE id = $1", a_id)
        .execute(&a_state.db)
        .await
        .map_err(|err| match ApiError::from(err)
        {
            ApiError::Validation("reference") => ApiError::Conflict("IN_USE"),
            other => other,
        })?;

    Ok(StatusCode::NO_CONTENT)
}

pub async fn item_prices(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<Json<Vec<ItemPriceDto>>, ApiError>
{
    load_item(&a_state.db, a_id, a_user.user_id).await?;

    let prices = sqlx::query_as!(
        ItemPriceDto,
        r#"
        WITH purchases AS (
            SELECT
                COALESCE(m.name, r.merchant_name) AS merchant_name,
                COALESCE(r.merchant_id::text, LOWER(r.merchant_name)) AS merchant_key,
                c.code AS curr_code,
                ROUND(ri.amount / ri.qty, 2) AS unit_price,
                r.receipt_ts
            FROM receipt_items ri
            JOIN receipts r ON r.id = ri.receipt_id
            JOIN currencies c ON c.id = r.curr_id
            LEFT JOIN merchants m ON m.id = r.merchant_id
            WHERE ri.item_id = $1 AND r.owner_id = $2
        )
        SELECT
            (ARRAY_AGG(merchant_name ORDER BY receipt_ts DESC))[1] AS merchant_name,
            curr_code AS "curr_code!",
            (ARRAY_AGG(unit_price ORDER BY receipt_ts DESC))[1] AS "last_price!",
            MIN(unit_price) AS "min_price!",
            ROUND(AVG(unit_price), 2) AS "avg_price!",
            COUNT(*) AS "purchase_count!",
            MAX(receipt_ts) AS "last_ts!"
        FROM purchases
        GROUP BY merchant_key, curr_code
        ORDER BY curr_code, 3, 1
        "#,
        a_id,
        a_user.user_id
    )
    .fetch_all(&a_state.db)
    .await?;

    Ok(Json(prices))
}

pub async fn require_visible_items(
    a_conn: &mut sqlx::PgConnection,
    a_item_ids: &[Uuid],
    a_user_id: Uuid,
) -> Result<(), ApiError>
{
    let mut ids = a_item_ids.to_vec();
    ids.sort_unstable();
    ids.dedup();

    let visible = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM items WHERE id = ANY($1) AND (owner_id IS NULL OR owner_id = $2)"#,
        &ids,
        a_user_id
    )
    .fetch_one(&mut *a_conn)
    .await?;

    if visible as usize != ids.len()
    {
        return Err(ApiError::Validation("item_id"));
    }

    Ok(())
}

async fn require_own(a_db: &PgPool, a_id: Uuid, a_user_id: Uuid) -> Result<(), ApiError>
{
    let owner = sqlx::query_scalar!("SELECT owner_id FROM items WHERE id = $1", a_id)
        .fetch_optional(a_db)
        .await?
        .ok_or(ApiError::NotFound)?;

    match owner
    {
        Some(owner) if owner == a_user_id => Ok(()),
        Some(_) => Err(ApiError::NotFound),
        None => Err(ApiError::Forbidden),
    }
}

async fn load_item(a_db: &PgPool, a_id: Uuid, a_user_id: Uuid) -> Result<DictItemDto, ApiError>
{
    sqlx::query_as!(
        DictItemDto,
        r#"
        SELECT id, name, type AS "kind: ItemKind", unit AS "unit: ItemUnit", owner_id IS NOT NULL AS "is_custom!"
        FROM items
        WHERE id = $1 AND (owner_id IS NULL OR owner_id = $2)
        "#,
        a_id,
        a_user_id
    )
    .fetch_optional(a_db)
    .await?
    .ok_or(ApiError::NotFound)
}
