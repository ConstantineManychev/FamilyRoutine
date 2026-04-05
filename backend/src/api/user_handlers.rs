use crate::api::auth_middleware::AuthenticatedUser;
use crate::domain::errors::ApiError;
use axum::{extract::State, Json};
use serde::Serialize;
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Serialize)]
pub struct DictMetaDto {
    pub id: String,
    pub name: String,
}

#[derive(Serialize, sqlx::FromRow)]
pub struct ProfileDto {
    pub first_name: String,
    pub last_name: String,
}

#[derive(Debug, Serialize)]
pub struct FamListDto {
    pub id: Uuid,
    pub name: String,
    pub role: String,
    pub member_count: i64,
}

pub async fn get_curr_user(
    State(db): State<PgPool>,
    user: AuthenticatedUser,
) -> Result<Json<ProfileDto>, ApiError> {
    let profile = sqlx::query_as!(
        ProfileDto,
        "SELECT first_name, last_name FROM users WHERE id = $1",
        user.0
    )
    .fetch_optional(&db)
    .await
    .map_err(ApiError::DatabaseError)?
    .ok_or(ApiError::Unauthorized)?;

    Ok(Json(profile))
}

pub async fn get_user_fams(
    State(db): State<PgPool>,
    user: AuthenticatedUser,
) -> Result<Json<Vec<FamListDto>>, ApiError> {
    let fams = sqlx::query_as!(
        FamListDto,
        r#"
        SELECT 
            f.id, 
            f.name, 
            fm.role::text as "role!",
            (SELECT COUNT(*) FROM family_mems WHERE family_id = f.id) as "member_count!"
        FROM families f
        JOIN family_mems fm ON f.id = fm.family_id
        WHERE fm.user_id = $1
        "#,
        user.0
    )
    .fetch_all(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    Ok(Json(fams))
}

pub async fn get_avail_dicts(
    State(_db): State<PgPool>,
    _user: AuthenticatedUser,
) -> Result<Json<Vec<DictMetaDto>>, ApiError> {
    let dicts = vec![
        DictMetaDto { id: "events".into(), name: "dicts.events".into() },
        DictMetaDto { id: "exercises".into(), name: "dicts.exercises".into() },
        DictMetaDto { id: "items".into(), name: "dicts.items".into() },
    ];
    
    Ok(Json(dicts))
}