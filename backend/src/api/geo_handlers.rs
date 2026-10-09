use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use shared_schema::{CityDto, CountryDto, GeoNameRequest, StreetDto};
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, AuthUser};
use crate::domain::errors::ApiError;
use crate::domain::validation::clean_name;
use crate::state::AppState;

pub async fn list_countries(
    State(a_state): State<AppState>,
    _a_user: AuthUser,
) -> Result<Json<Vec<CountryDto>>, ApiError>
{
    let countries = sqlx::query_as!(CountryDto, "SELECT id, code, name FROM countries ORDER BY name")
        .fetch_all(&a_state.db)
        .await?;

    Ok(Json(countries))
}

pub async fn list_cities(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_country_id): ApiPath<Uuid>,
) -> Result<Json<Vec<CityDto>>, ApiError>
{
    let cities = sqlx::query_as!(
        CityDto,
        r#"
        SELECT id, country_id, name, COALESCE(created_by = $2, FALSE) AS "is_editable!"
        FROM cities
        WHERE country_id = $1
        ORDER BY name
        "#,
        a_country_id,
        a_user.user_id
    )
    .fetch_all(&a_state.db)
    .await?;

    Ok(Json(cities))
}

pub async fn create_city(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_country_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<GeoNameRequest>,
) -> Result<(StatusCode, Json<CityDto>), ApiError>
{
    let name = clean_name(&a_req.name, "name")?;

    let city = sqlx::query_as!(
        CityDto,
        r#"
        INSERT INTO cities (country_id, name, created_by)
        VALUES ($1, $2, $3)
        ON CONFLICT (country_id, name) DO UPDATE SET name = EXCLUDED.name
        RETURNING id, country_id, name, COALESCE(created_by = $3, FALSE) AS "is_editable!"
        "#,
        a_country_id,
        name,
        a_user.user_id
    )
    .fetch_one(&a_state.db)
    .await?;

    Ok((StatusCode::CREATED, Json(city)))
}

pub async fn update_city(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<GeoNameRequest>,
) -> Result<Json<CityDto>, ApiError>
{
    let name = clean_name(&a_req.name, "name")?;
    require_city_owner(&a_state, a_id, a_user.user_id).await?;

    let city = sqlx::query_as!(
        CityDto,
        r#"
        UPDATE cities SET name = $2 WHERE id = $1
        RETURNING id, country_id, name, TRUE AS "is_editable!"
        "#,
        a_id,
        name
    )
    .fetch_one(&a_state.db)
    .await?;

    Ok(Json(city))
}

pub async fn delete_city(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    require_city_owner(&a_state, a_id, a_user.user_id).await?;

    sqlx::query!("DELETE FROM cities WHERE id = $1", a_id)
        .execute(&a_state.db)
        .await
        .map_err(in_use)?;

    Ok(StatusCode::NO_CONTENT)
}

pub async fn list_streets(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_city_id): ApiPath<Uuid>,
) -> Result<Json<Vec<StreetDto>>, ApiError>
{
    let streets = sqlx::query_as!(
        StreetDto,
        r#"
        SELECT id, city_id, name, COALESCE(created_by = $2, FALSE) AS "is_editable!"
        FROM streets
        WHERE city_id = $1
        ORDER BY name
        "#,
        a_city_id,
        a_user.user_id
    )
    .fetch_all(&a_state.db)
    .await?;

    Ok(Json(streets))
}

pub async fn create_street(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_city_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<GeoNameRequest>,
) -> Result<(StatusCode, Json<StreetDto>), ApiError>
{
    let name = clean_name(&a_req.name, "name")?;

    let street = sqlx::query_as!(
        StreetDto,
        r#"
        INSERT INTO streets (city_id, name, created_by)
        VALUES ($1, $2, $3)
        ON CONFLICT (city_id, name) DO UPDATE SET name = EXCLUDED.name
        RETURNING id, city_id, name, COALESCE(created_by = $3, FALSE) AS "is_editable!"
        "#,
        a_city_id,
        name,
        a_user.user_id
    )
    .fetch_one(&a_state.db)
    .await?;

    Ok((StatusCode::CREATED, Json(street)))
}

pub async fn update_street(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<GeoNameRequest>,
) -> Result<Json<StreetDto>, ApiError>
{
    let name = clean_name(&a_req.name, "name")?;
    require_street_owner(&a_state, a_id, a_user.user_id).await?;

    let street = sqlx::query_as!(
        StreetDto,
        r#"
        UPDATE streets SET name = $2 WHERE id = $1
        RETURNING id, city_id, name, TRUE AS "is_editable!"
        "#,
        a_id,
        name
    )
    .fetch_one(&a_state.db)
    .await?;

    Ok(Json(street))
}

pub async fn delete_street(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    require_street_owner(&a_state, a_id, a_user.user_id).await?;

    sqlx::query!("DELETE FROM streets WHERE id = $1", a_id)
        .execute(&a_state.db)
        .await
        .map_err(in_use)?;

    Ok(StatusCode::NO_CONTENT)
}

async fn require_city_owner(a_state: &AppState, a_id: Uuid, a_user_id: Uuid) -> Result<(), ApiError>
{
    let row = sqlx::query!(
        r#"
        SELECT
            COALESCE(c.created_by = $2, FALSE) AS "is_owner!",
            EXISTS (
                SELECT 1 FROM place_addrs pa JOIN places p ON p.id = pa.place_id
                WHERE pa.city_id = c.id AND p.owner_id IS DISTINCT FROM $2
            ) AS "is_used_by_others!",
            EXISTS (
                SELECT 1 FROM streets s WHERE s.city_id = c.id AND s.created_by IS DISTINCT FROM $2
            ) AS "has_foreign_streets!"
        FROM cities c
        WHERE c.id = $1
        "#,
        a_id,
        a_user_id
    )
    .fetch_optional(&a_state.db)
    .await?
    .ok_or(ApiError::NotFound)?;

    if !row.is_owner || row.is_used_by_others || row.has_foreign_streets
    {
        return Err(ApiError::Forbidden);
    }

    Ok(())
}

async fn require_street_owner(a_state: &AppState, a_id: Uuid, a_user_id: Uuid) -> Result<(), ApiError>
{
    let row = sqlx::query!(
        r#"
        SELECT
            COALESCE(s.created_by = $2, FALSE) AS "is_owner!",
            EXISTS (
                SELECT 1 FROM place_addrs pa JOIN places p ON p.id = pa.place_id
                WHERE pa.street_id = s.id AND p.owner_id IS DISTINCT FROM $2
            ) AS "is_used_by_others!"
        FROM streets s
        WHERE s.id = $1
        "#,
        a_id,
        a_user_id
    )
    .fetch_optional(&a_state.db)
    .await?
    .ok_or(ApiError::NotFound)?;

    if !row.is_owner || row.is_used_by_others
    {
        return Err(ApiError::Forbidden);
    }

    Ok(())
}

fn in_use(a_err: sqlx::Error) -> ApiError
{
    match ApiError::from(a_err)
    {
        ApiError::Validation("reference") => ApiError::Conflict("IN_USE"),
        other => other,
    }
}
