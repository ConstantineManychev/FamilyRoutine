use std::collections::HashMap;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use shared_schema::{PlaceAddrDto, PlaceDto, SavePlaceRequest};
use sqlx::{PgConnection, PgPool};
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, AuthUser};
use crate::domain::errors::ApiError;
use crate::domain::validation::{clean_name, clean_optional_text, clean_text};
use crate::state::AppState;

const MAX_ADDRS: usize = 20;
const MAX_SHORT_LEN: usize = 50;
const MAX_MERCHANT_LEN: usize = 255;

struct PlaceRow
{
    id: Uuid,
    name: String,
}

struct AddrRow
{
    place_id: Uuid,
    addr: PlaceAddrDto,
}

pub async fn list_places(State(a_state): State<AppState>, a_user: AuthUser) -> Result<Json<Vec<PlaceDto>>, ApiError>
{
    let places = sqlx::query_as!(
        PlaceRow,
        "SELECT id, name FROM places WHERE owner_id = $1 ORDER BY name",
        a_user.user_id
    )
    .fetch_all(&a_state.db)
    .await?;

    let ids: Vec<Uuid> = places.iter().map(|place| place.id).collect();
    let mut addrs_by_place = load_addrs(&a_state.db, &ids).await?;

    let result = places
        .into_iter()
        .map(|place| PlaceDto {
            addrs: addrs_by_place.remove(&place.id).unwrap_or_default(),
            id: place.id,
            name: place.name,
        })
        .collect();

    Ok(Json(result))
}

pub async fn get_place(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<Json<PlaceDto>, ApiError>
{
    load_place(&a_state.db, a_id, a_user.user_id).await.map(Json)
}

pub async fn create_place(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SavePlaceRequest>,
) -> Result<(StatusCode, Json<PlaceDto>), ApiError>
{
    let name = clean_name(&a_req.name, "name")?;
    let addrs = clean_addrs(a_req.addrs)?;

    let mut tx = a_state.db.begin().await?;

    let place_id = sqlx::query_scalar!(
        "INSERT INTO places (name, owner_id) VALUES ($1, $2) RETURNING id",
        name,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;

    for addr in &addrs
    {
        check_geo_chain(&mut tx, addr).await?;
        insert_addr(&mut tx, place_id, addr).await?;
    }

    tx.commit().await?;

    let place = load_place(&a_state.db, place_id, a_user.user_id).await?;
    Ok((StatusCode::CREATED, Json(place)))
}

pub async fn update_place(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SavePlaceRequest>,
) -> Result<Json<PlaceDto>, ApiError>
{
    let name = clean_name(&a_req.name, "name")?;
    let addrs = clean_addrs(a_req.addrs)?;

    let mut tx = a_state.db.begin().await?;

    let result = sqlx::query!(
        "UPDATE places SET name = $3 WHERE id = $1 AND owner_id = $2",
        a_id,
        a_user.user_id,
        name
    )
    .execute(&mut *tx)
    .await?;

    if result.rows_affected() == 0
    {
        return Err(ApiError::NotFound);
    }

    let kept_ids: Vec<Uuid> = addrs.iter().filter_map(|addr| addr.id).collect();

    sqlx::query!(
        "DELETE FROM place_addrs WHERE place_id = $1 AND NOT (id = ANY($2))",
        a_id,
        &kept_ids
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query!("UPDATE place_addrs SET is_main = FALSE WHERE place_id = $1", a_id)
        .execute(&mut *tx)
        .await?;

    for addr in &addrs
    {
        check_geo_chain(&mut tx, addr).await?;

        match addr.id
        {
            None => insert_addr(&mut tx, a_id, addr).await?,
            Some(addr_id) =>
            {
                let updated = sqlx::query!(
                    r#"
                    UPDATE place_addrs
                    SET is_main = $3, country_id = $4, city_id = $5, street_id = $6,
                        house_num = $7, apt = $8, zip = $9, merchant_id = $10
                    WHERE id = $1 AND place_id = $2
                    "#,
                    addr_id,
                    a_id,
                    addr.is_main,
                    addr.country_id,
                    addr.city_id,
                    addr.street_id,
                    addr.house_num,
                    addr.apt,
                    addr.zip,
                    addr.merchant_id
                )
                .execute(&mut *tx)
                .await?;

                if updated.rows_affected() == 0
                {
                    return Err(ApiError::Validation("addrs.id"));
                }
            }
        }
    }

    tx.commit().await?;

    load_place(&a_state.db, a_id, a_user.user_id).await.map(Json)
}

pub async fn delete_place(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let result = sqlx::query!(
        "DELETE FROM places WHERE id = $1 AND owner_id = $2",
        a_id,
        a_user.user_id
    )
    .execute(&a_state.db)
    .await?;

    if result.rows_affected() == 0
    {
        return Err(ApiError::NotFound);
    }

    Ok(StatusCode::NO_CONTENT)
}

async fn load_place(a_db: &PgPool, a_id: Uuid, a_owner_id: Uuid) -> Result<PlaceDto, ApiError>
{
    let place = sqlx::query_as!(
        PlaceRow,
        "SELECT id, name FROM places WHERE id = $1 AND owner_id = $2",
        a_id,
        a_owner_id
    )
    .fetch_optional(a_db)
    .await?
    .ok_or(ApiError::NotFound)?;

    let addrs = load_addrs(a_db, &[place.id])
        .await?
        .remove(&place.id)
        .unwrap_or_default();

    Ok(PlaceDto {
        id: place.id,
        name: place.name,
        addrs,
    })
}

async fn load_addrs(a_db: &PgPool, a_place_ids: &[Uuid]) -> Result<HashMap<Uuid, Vec<PlaceAddrDto>>, ApiError>
{
    if a_place_ids.is_empty()
    {
        return Ok(HashMap::new());
    }

    let rows = sqlx::query!(
        r#"
        SELECT id, place_id, is_main, country_id, city_id, street_id, house_num, apt, zip, merchant_id
        FROM place_addrs
        WHERE place_id = ANY($1)
        ORDER BY is_main DESC, id
        "#,
        a_place_ids
    )
    .fetch_all(a_db)
    .await?;

    let mut grouped: HashMap<Uuid, Vec<PlaceAddrDto>> = HashMap::new();

    for row in rows.into_iter().map(|row| AddrRow {
        place_id: row.place_id,
        addr: PlaceAddrDto {
            id: Some(row.id),
            is_main: row.is_main,
            country_id: row.country_id,
            city_id: row.city_id,
            street_id: row.street_id,
            house_num: row.house_num,
            apt: row.apt,
            zip: row.zip,
            merchant_id: row.merchant_id,
        },
    })
    {
        grouped.entry(row.place_id).or_default().push(row.addr);
    }

    Ok(grouped)
}

fn clean_addrs(a_addrs: Vec<PlaceAddrDto>) -> Result<Vec<PlaceAddrDto>, ApiError>
{
    if a_addrs.len() > MAX_ADDRS || a_addrs.iter().filter(|addr| addr.is_main).count() > 1
    {
        return Err(ApiError::Validation("addrs"));
    }

    let mut seen_ids = Vec::new();

    a_addrs
        .into_iter()
        .map(|addr| {
            if let Some(id) = addr.id
            {
                if seen_ids.contains(&id)
                {
                    return Err(ApiError::Validation("addrs.id"));
                }
                seen_ids.push(id);
            }

            Ok(PlaceAddrDto {
                house_num: clean_text(&addr.house_num, 1, MAX_SHORT_LEN, "house_num")?,
                apt: clean_optional_text(addr.apt.as_deref(), MAX_SHORT_LEN, "apt")?,
                zip: clean_text(&addr.zip, 1, MAX_SHORT_LEN, "zip")?,
                merchant_id: clean_optional_text(addr.merchant_id.as_deref(), MAX_MERCHANT_LEN, "merchant_id")?,
                ..addr
            })
        })
        .collect()
}

async fn check_geo_chain(a_conn: &mut PgConnection, a_addr: &PlaceAddrDto) -> Result<(), ApiError>
{
    let is_consistent = sqlx::query_scalar!(
        r#"
        SELECT EXISTS (
            SELECT 1 FROM streets s JOIN cities c ON c.id = s.city_id
            WHERE s.id = $3 AND c.id = $2 AND c.country_id = $1
        ) AS "is_consistent!"
        "#,
        a_addr.country_id,
        a_addr.city_id,
        a_addr.street_id
    )
    .fetch_one(&mut *a_conn)
    .await?;

    if !is_consistent
    {
        return Err(ApiError::Validation("addrs.geo"));
    }

    Ok(())
}

async fn insert_addr(a_conn: &mut PgConnection, a_place_id: Uuid, a_addr: &PlaceAddrDto) -> Result<(), ApiError>
{
    sqlx::query!(
        r#"
        INSERT INTO place_addrs (place_id, is_main, country_id, city_id, street_id, house_num, apt, zip, merchant_id)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        "#,
        a_place_id,
        a_addr.is_main,
        a_addr.country_id,
        a_addr.city_id,
        a_addr.street_id,
        a_addr.house_num,
        a_addr.apt,
        a_addr.zip,
        a_addr.merchant_id
    )
    .execute(&mut *a_conn)
    .await?;

    Ok(())
}
