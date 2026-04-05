use crate::domain::errors::ApiError;
use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::Deserialize;
use shared_schema::{CityDto, CountryDto, StreetDto};
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Deserialize)]
pub struct GeoNamePayload {
    pub name: String,
}

pub async fn get_countries(State(db): State<PgPool>) -> Result<Json<Vec<CountryDto>>, ApiError> {
    let res = sqlx::query_as!(
        CountryDto,
        "SELECT id, code, name FROM countries ORDER BY name"
    )
    .fetch_all(&db)
    .await
    .map_err(ApiError::DatabaseError)?;
    Ok(Json(res))
}

pub async fn get_cities(
    State(db): State<PgPool>,
    Path(country_id): Path<Uuid>,
) -> Result<Json<Vec<CityDto>>, ApiError> {
    let res = sqlx::query_as!(
        CityDto,
        "SELECT id, country_id, name FROM cities WHERE country_id = $1 ORDER BY name",
        country_id
    )
    .fetch_all(&db)
    .await
    .map_err(ApiError::DatabaseError)?;
    Ok(Json(res))
}

pub async fn create_city(
    State(db): State<PgPool>,
    Path(country_id): Path<Uuid>,
    Json(payload): Json<GeoNamePayload>,
) -> Result<(StatusCode, Json<CityDto>), ApiError> {
    let res = sqlx::query_as!(
        CityDto,
        "INSERT INTO cities (country_id, name) VALUES ($1, $2) RETURNING id, country_id, name",
        country_id,
        payload.name
    )
    .fetch_one(&db)
    .await
    .map_err(ApiError::DatabaseError)?;
    Ok((StatusCode::CREATED, Json(res)))
}

pub async fn update_city(
    State(db): State<PgPool>,
    Path(id): Path<Uuid>,
    Json(payload): Json<GeoNamePayload>,
) -> Result<Json<CityDto>, ApiError> {
    let res = sqlx::query_as!(
        CityDto,
        "UPDATE cities SET name = $1 WHERE id = $2 RETURNING id, country_id, name",
        payload.name,
        id
    )
    .fetch_optional(&db)
    .await
    .map_err(ApiError::DatabaseError)?
    .ok_or(ApiError::Unauthorized)?;
    Ok(Json(res))
}

pub async fn delete_city(
    State(db): State<PgPool>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    sqlx::query!("DELETE FROM cities WHERE id = $1", id)
        .execute(&db)
        .await
        .map_err(ApiError::DatabaseError)?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn get_streets(
    State(db): State<PgPool>,
    Path(city_id): Path<Uuid>,
) -> Result<Json<Vec<StreetDto>>, ApiError> {
    let res = sqlx::query_as!(
        StreetDto,
        "SELECT id, city_id, name FROM streets WHERE city_id = $1 ORDER BY name",
        city_id
    )
    .fetch_all(&db)
    .await
    .map_err(ApiError::DatabaseError)?;
    Ok(Json(res))
}

pub async fn create_street(
    State(db): State<PgPool>,
    Path(city_id): Path<Uuid>,
    Json(payload): Json<GeoNamePayload>,
) -> Result<(StatusCode, Json<StreetDto>), ApiError> {
    let res = sqlx::query_as!(
        StreetDto,
        "INSERT INTO streets (city_id, name) VALUES ($1, $2) RETURNING id, city_id, name",
        city_id,
        payload.name
    )
    .fetch_one(&db)
    .await
    .map_err(ApiError::DatabaseError)?;
    Ok((StatusCode::CREATED, Json(res)))
}

pub async fn update_street(
    State(db): State<PgPool>,
    Path(id): Path<Uuid>,
    Json(payload): Json<GeoNamePayload>,
) -> Result<Json<StreetDto>, ApiError> {
    let res = sqlx::query_as!(
        StreetDto,
        "UPDATE streets SET name = $1 WHERE id = $2 RETURNING id, city_id, name",
        payload.name,
        id
    )
    .fetch_optional(&db)
    .await
    .map_err(ApiError::DatabaseError)?
    .ok_or(ApiError::Unauthorized)?;
    Ok(Json(res))
}

pub async fn delete_street(
    State(db): State<PgPool>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    sqlx::query!("DELETE FROM streets WHERE id = $1", id)
        .execute(&db)
        .await
        .map_err(ApiError::DatabaseError)?;
    Ok(StatusCode::NO_CONTENT)
}