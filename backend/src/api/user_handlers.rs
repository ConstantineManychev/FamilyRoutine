use axum::{extract::State, Json};
use serde::Serialize;
use sqlx::PgPool;
use uuid::Uuid;
use crate::domain::errors::ApiError;

#[derive(Serialize, sqlx::FromRow)]
pub struct ProfileDto {
    pub first_name: String,
    pub last_name: String,
}

#[derive(Serialize, sqlx::FromRow)]
pub struct FamilyDto {
    pub id: Uuid,
    pub name: String,
}

pub async fn get_curr_user(
    State(db): State<PgPool>,
) -> Result<Json<ProfileDto>, ApiError> {
    let user = sqlx::query_as!(
        ProfileDto,
        "SELECT first_name, last_name FROM users LIMIT 1"
    )
    .fetch_one(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    Ok(Json(user))
}

pub async fn get_user_fams(
    State(db): State<PgPool>,
) -> Result<Json<Vec<FamilyDto>>, ApiError> {
    let fams = sqlx::query_as!(
        FamilyDto,
        r#"
        SELECT f.id, f.name 
        FROM families f
        JOIN family_mems fm ON f.id = fm.family_id
        LIMIT 10
        "#
    )
    .fetch_all(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    Ok(Json(fams))
}