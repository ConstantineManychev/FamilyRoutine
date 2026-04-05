use crate::domain::errors::ApiError;
use axum::{extract::{Path, State}, http::StatusCode, Json};
use shared_schema::{PlaceAddrDto, PlaceDto};
use sqlx::PgPool;
use uuid::Uuid;

pub async fn get_places(State(db): State<PgPool>) -> Result<Json<Vec<PlaceDto>>, ApiError> {
    let places_db = sqlx::query!("SELECT id, name FROM places ORDER BY name").fetch_all(&db).await.map_err(ApiError::DatabaseError)?;
    let mut res = Vec::new();

    for p in places_db {
        let addrs = sqlx::query_as!(
            PlaceAddrDto,
            "SELECT id, is_main, country_id, city_id, street_id, house_num, apt, zip, merchant_id FROM place_addrs WHERE place_id = $1 ORDER BY is_main DESC",
            p.id
        )
        .fetch_all(&db)
        .await
        .map_err(ApiError::DatabaseError)?;

        res.push(PlaceDto { id: p.id, name: p.name, addrs });
    }

    Ok(Json(res))
}

pub async fn get_place_detail(State(db): State<PgPool>, Path(id): Path<Uuid>) -> Result<Json<PlaceDto>, ApiError> {
    let place_db = sqlx::query!("SELECT id, name FROM places WHERE id = $1", id)
        .fetch_optional(&db)
        .await
        .map_err(ApiError::DatabaseError)?
        .ok_or(ApiError::Unauthorized)?;

    let addrs = sqlx::query_as!(
        PlaceAddrDto,
        "SELECT id, is_main, country_id, city_id, street_id, house_num, apt, zip, merchant_id FROM place_addrs WHERE place_id = $1 ORDER BY is_main DESC",
        id
    )
    .fetch_all(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    Ok(Json(PlaceDto { id: place_db.id, name: place_db.name, addrs }))
}

pub async fn create_place(State(db): State<PgPool>, Json(payload): Json<PlaceDto>) -> Result<(StatusCode, Json<PlaceDto>), ApiError> {
    let mut tx = db.begin().await.map_err(ApiError::DatabaseError)?;

    let place_id = sqlx::query_scalar!("INSERT INTO places (name) VALUES ($1) RETURNING id", payload.name)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::DatabaseError)?;

    for a in &payload.addrs {
        sqlx::query!(
            "INSERT INTO place_addrs (place_id, is_main, country_id, city_id, street_id, house_num, apt, zip, merchant_id) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
            place_id, a.is_main, a.country_id, a.city_id, a.street_id, a.house_num, a.apt, a.zip, a.merchant_id
        )
        .execute(&mut *tx)
        .await
        .map_err(ApiError::DatabaseError)?;
    }

    tx.commit().await.map_err(ApiError::DatabaseError)?;
    
    let mut created_place = payload.clone();
    created_place.id = place_id;
    Ok((StatusCode::CREATED, Json(created_place)))
}

pub async fn update_place(State(db): State<PgPool>, Path(id): Path<Uuid>, Json(payload): Json<PlaceDto>) -> Result<Json<PlaceDto>, ApiError> {
    let mut tx = db.begin().await.map_err(ApiError::DatabaseError)?;
    
    sqlx::query!("UPDATE places SET name = $1 WHERE id = $2", payload.name, id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::DatabaseError)?;

    sqlx::query!("DELETE FROM place_addrs WHERE place_id = $1", id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::DatabaseError)?;

    for a in &payload.addrs {
        sqlx::query!(
            "INSERT INTO place_addrs (place_id, is_main, country_id, city_id, street_id, house_num, apt, zip, merchant_id) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
            id, a.is_main, a.country_id, a.city_id, a.street_id, a.house_num, a.apt, a.zip, a.merchant_id
        )
        .execute(&mut *tx)
        .await
        .map_err(ApiError::DatabaseError)?;
    }

    tx.commit().await.map_err(ApiError::DatabaseError)?;
    
    let mut updated_place = payload.clone();
    updated_place.id = id;
    Ok(Json(updated_place))
}

pub async fn delete_place(State(db): State<PgPool>, Path(id): Path<Uuid>) -> Result<StatusCode, ApiError> {
    sqlx::query!("DELETE FROM places WHERE id = $1", id)
        .execute(&db)
        .await
        .map_err(ApiError::DatabaseError)?;

    Ok(StatusCode::NO_CONTENT)
}