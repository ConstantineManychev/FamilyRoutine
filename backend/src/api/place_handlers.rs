use std::collections::HashMap;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use shared_schema::{PlaceAddrDto, PlaceDto, SavePlaceRequest, ShareToFamilyRequest};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, AuthUser};
use crate::domain::errors::ApiError;
use crate::domain::validation::{clean_name, clean_optional_text, clean_text};
use crate::security::authz::require_member;
use crate::state::AppState;

const MAX_ADDRS: usize = 20;
const MAX_SHORT_LEN: usize = 50;
const MAX_MERCHANT_LEN: usize = 255;

struct PlaceRow
{
    id: Uuid,
    name: String,
    family_id: Option<Uuid>,
    family_name: Option<String>,
    is_editable: bool,
}

struct PlaceScope
{
    owner_id: Option<Uuid>,
    is_visible: bool,
    is_editable: bool,
}

struct AddrRow
{
    place_id: Uuid,
    addr: PlaceAddrDto,
}

pub async fn list_places(State(a_state): State<AppState>, a_user: AuthUser) -> Result<Json<Vec<PlaceDto>>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let places = sqlx::query_as!(
        PlaceRow,
        r#"
        SELECT
            p.id,
            p.name,
            p.family_id,
            f.name AS "family_name?",
            can_edit_scoped(p.owner_id, p.family_id, p.created_by, $1) AS "is_editable!"
        FROM places p
        LEFT JOIN families f ON f.id = p.family_id
        WHERE p.owner_id = $1 OR p.family_id IN (SELECT family_id FROM family_mems WHERE user_id = $1)
        ORDER BY p.name, f.name NULLS FIRST
        "#,
        a_user.user_id
    )
    .fetch_all(&mut *conn)
    .await?;

    let ids: Vec<Uuid> = places.iter().map(|place| place.id).collect();
    let mut addrs_by_place = load_addrs(&mut conn, &ids).await?;

    let result = places
        .into_iter()
        .map(|place| PlaceDto {
            addrs: addrs_by_place.remove(&place.id).unwrap_or_default(),
            id: place.id,
            name: place.name,
            family_id: place.family_id,
            family_name: place.family_name,
            is_editable: place.is_editable,
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
    let mut conn = a_state.db.acquire().await?;
    load_place(&mut conn, a_id, a_user.user_id).await.map(Json)
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

    if let Some(family_id) = a_req.family_id
    {
        require_member(&mut *tx, family_id, a_user.user_id)
            .await
            .map_err(|_| ApiError::Validation("family_id"))?;
    }
    let owner_id = a_req.family_id.is_none().then_some(a_user.user_id);

    let place_id = sqlx::query_scalar!(
        "INSERT INTO places (name, owner_id, family_id, created_by) VALUES ($1, $2, $3, $4) RETURNING id",
        name,
        owner_id,
        a_req.family_id,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;

    for addr in &addrs
    {
        check_geo_chain(&mut tx, addr).await?;
        insert_addr(&mut tx, place_id, addr).await?;
    }

    let place = load_place(&mut tx, place_id, a_user.user_id).await?;
    tx.commit().await?;
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
    require_editable(&mut tx, a_id, a_user.user_id).await?;

    sqlx::query!("UPDATE places SET name = $2 WHERE id = $1", a_id, name)
        .execute(&mut *tx)
        .await?;

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

    let place = load_place(&mut tx, a_id, a_user.user_id).await?;
    tx.commit().await?;
    Ok(Json(place))
}

pub async fn delete_place(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    require_editable(&mut tx, a_id, a_user.user_id).await?;

    sqlx::query!("DELETE FROM places WHERE id = $1", a_id)
        .execute(&mut *tx)
        .await?;

    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn share_place(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<ShareToFamilyRequest>,
) -> Result<Json<PlaceDto>, ApiError>
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
        "UPDATE places SET owner_id = NULL, family_id = $2 WHERE id = $1",
        a_id,
        a_req.family_id
    )
    .execute(&mut *tx)
    .await?;

    let place = load_place(&mut tx, a_id, a_user.user_id).await?;
    tx.commit().await?;
    Ok(Json(place))
}

pub async fn require_visible_place(
    a_conn: &mut PgConnection,
    a_place_id: Option<Uuid>,
    a_addr_id: Option<Uuid>,
    a_user_id: Uuid,
    a_attached_place_id: Option<Uuid>,
) -> Result<(), ApiError>
{
    let Some(place_id) = a_place_id
    else
    {
        return match a_addr_id
        {
            Some(_) => Err(ApiError::Validation("place_addr_id")),
            None => Ok(()),
        };
    };

    let check = sqlx::query!(
        r#"
        SELECT
            EXISTS (
                SELECT 1 FROM places p
                WHERE p.id = $1 AND (p.id = $4 OR can_see_scoped(p.owner_id, p.family_id, $3))
            ) AS "is_visible!",
            ($2::uuid IS NULL OR EXISTS (SELECT 1 FROM place_addrs a WHERE a.id = $2 AND a.place_id = $1)) AS "is_addr_ok!"
        "#,
        place_id,
        a_addr_id,
        a_user_id,
        a_attached_place_id
    )
    .fetch_one(&mut *a_conn)
    .await?;

    if !check.is_visible
    {
        return Err(ApiError::Validation("place_id"));
    }
    if !check.is_addr_ok
    {
        return Err(ApiError::Validation("place_addr_id"));
    }

    Ok(())
}

pub async fn detach_family_places(
    a_conn: &mut PgConnection,
    a_family_id: Uuid,
    a_fallback_owner: Uuid,
) -> Result<(), ApiError>
{
    sqlx::query!(
        r#"
        UPDATE places p
        SET owner_id = CASE
                WHEN EXISTS (SELECT 1 FROM family_mems fm WHERE fm.family_id = $1 AND fm.user_id = p.created_by)
                    THEN p.created_by
                ELSE $2
            END,
            family_id = NULL
        WHERE p.family_id = $1
        "#,
        a_family_id,
        a_fallback_owner
    )
    .execute(&mut *a_conn)
    .await?;

    Ok(())
}

async fn require_editable(a_conn: &mut PgConnection, a_id: Uuid, a_user_id: Uuid) -> Result<PlaceScope, ApiError>
{
    let scope = sqlx::query_as!(
        PlaceScope,
        r#"
        SELECT
            owner_id,
            can_see_scoped(owner_id, family_id, $2) AS "is_visible!",
            can_edit_scoped(owner_id, family_id, created_by, $2) AS "is_editable!"
        FROM places
        WHERE id = $1
        FOR UPDATE
        "#,
        a_id,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .filter(|scope| scope.is_visible)
    .ok_or(ApiError::NotFound)?;

    if !scope.is_editable
    {
        return Err(ApiError::Forbidden);
    }

    Ok(scope)
}

async fn load_place(a_conn: &mut PgConnection, a_id: Uuid, a_user_id: Uuid) -> Result<PlaceDto, ApiError>
{
    let place = sqlx::query_as!(
        PlaceRow,
        r#"
        SELECT
            p.id,
            p.name,
            p.family_id,
            f.name AS "family_name?",
            can_edit_scoped(p.owner_id, p.family_id, p.created_by, $2) AS "is_editable!"
        FROM places p
        LEFT JOIN families f ON f.id = p.family_id
        WHERE p.id = $1 AND can_see_scoped(p.owner_id, p.family_id, $2)
        "#,
        a_id,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .ok_or(ApiError::NotFound)?;

    let addrs = load_addrs(a_conn, &[place.id])
        .await?
        .remove(&place.id)
        .unwrap_or_default();

    Ok(PlaceDto {
        id: place.id,
        name: place.name,
        family_id: place.family_id,
        family_name: place.family_name,
        is_editable: place.is_editable,
        addrs,
    })
}

async fn load_addrs(
    a_conn: &mut PgConnection,
    a_place_ids: &[Uuid],
) -> Result<HashMap<Uuid, Vec<PlaceAddrDto>>, ApiError>
{
    if a_place_ids.is_empty()
    {
        return Ok(HashMap::new());
    }

    let rows = sqlx::query!(
        r#"
        SELECT
            a.id, a.place_id, a.is_main, a.country_id, a.city_id, a.street_id, a.house_num, a.apt, a.zip, a.merchant_id,
            ci.name || ', ' || st.name || ' ' || a.house_num AS "label!"
        FROM place_addrs a
        JOIN streets st ON st.id = a.street_id
        JOIN cities ci ON ci.id = a.city_id
        WHERE a.place_id = ANY($1)
        ORDER BY a.is_main DESC, a.id
        "#,
        a_place_ids
    )
    .fetch_all(&mut *a_conn)
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
            label: Some(row.label),
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
