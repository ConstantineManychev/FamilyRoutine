use crate::api::auth_middleware::AuthenticatedUser;
use crate::domain::errors::ApiError;
use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use shared_schema::{CreateFamMemDto, CreateFamilyRequest, FamDetailDto, FamMemberDto, UpdateFamMemRoleDto, UpdateFamNameDto};
use sqlx::PgPool;
use uuid::Uuid;
use serde::{Deserialize, Serialize};
use ts_rs::TS;

pub async fn create_fam(
    State(db): State<PgPool>,
    user: AuthenticatedUser,
    Json(payload): Json<CreateFamilyRequest>,
) -> Result<Json<FamDetailDto>, ApiError> {
    let mut tx = db.begin().await.map_err(ApiError::DatabaseError)?;

    let fam_id = sqlx::query_scalar!(
        "INSERT INTO families (name) VALUES ($1) RETURNING id",
        payload.name
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::DatabaseError)?;

    sqlx::query!(
        "INSERT INTO family_mems (family_id, user_id, role) VALUES ($1, $2, 'admin')",
        fam_id,
        user.0
    )
    .execute(&mut *tx)
    .await
    .map_err(ApiError::DatabaseError)?;

    for mem in payload.members {
        let target_user_id = sqlx::query_scalar!(
            "SELECT id FROM users WHERE email = $1",
            mem.email
        )
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::DatabaseError)?;

        if let Some(uid) = target_user_id {
            sqlx::query!(
                "INSERT INTO family_mems (family_id, user_id, role) VALUES ($1, $2, $3::text::mem_role_t) ON CONFLICT DO NOTHING",
                fam_id,
                uid,
                mem.role
            )
            .execute(&mut *tx)
            .await
            .map_err(ApiError::DatabaseError)?;
        }
    }

    tx.commit().await.map_err(ApiError::DatabaseError)?;
    fetch_fam_aggregate(&db, fam_id).await
}

pub async fn get_fam_details(
    State(db): State<PgPool>,
    Path(fam_id): Path<Uuid>,
    user: AuthenticatedUser,
) -> Result<Json<FamDetailDto>, ApiError> {
    let is_mem = sqlx::query_scalar!(
        "SELECT EXISTS(SELECT 1 FROM family_mems WHERE family_id = $1 AND user_id = $2)",
        fam_id,
        user.0
    )
    .fetch_one(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    if !is_mem.unwrap_or(false) {
        return Err(ApiError::Unauthorized);
    }
    fetch_fam_aggregate(&db, fam_id).await
}

pub async fn delete_fam(
    State(db): State<PgPool>,
    Path(fam_id): Path<Uuid>,
    user: AuthenticatedUser,
) -> Result<StatusCode, ApiError> {
    let role = sqlx::query_scalar!(
        "SELECT role::text FROM family_mems WHERE family_id = $1 AND user_id = $2",
        fam_id,
        user.0
    )
    .fetch_optional(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    if role.flatten().as_deref() != Some("admin") {
        return Err(ApiError::Unauthorized);
    }

    let mut tx = db.begin().await.map_err(ApiError::DatabaseError)?;
    
    sqlx::query!("DELETE FROM family_mems WHERE family_id = $1", fam_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::DatabaseError)?;
        
    sqlx::query!("DELETE FROM families WHERE id = $1", fam_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::DatabaseError)?;
        
    tx.commit().await.map_err(ApiError::DatabaseError)?;

    Ok(StatusCode::NO_CONTENT)
}

pub async fn leave_fam(
    State(db): State<PgPool>,
    Path(fam_id): Path<Uuid>,
    user: AuthenticatedUser,
) -> Result<StatusCode, ApiError> {
    let mut tx = db.begin().await.map_err(ApiError::DatabaseError)?;

    let stats = sqlx::query!(
        r#"
        SELECT 
            COUNT(*) as "total!", 
            SUM(CASE WHEN role::text = 'admin' THEN 1 ELSE 0 END) as "admins!",
            MAX(CASE WHEN user_id = $2 THEN role::text ELSE NULL END) as "user_role"
        FROM family_mems 
        WHERE family_id = $1
        "#,
        fam_id,
        user.0
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::DatabaseError)?;

    let user_role = stats.user_role.ok_or(ApiError::Unauthorized)?;

    if stats.total == 1 {
        sqlx::query!("DELETE FROM family_mems WHERE family_id = $1", fam_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::DatabaseError)?;
            
        sqlx::query!("DELETE FROM families WHERE id = $1", fam_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::DatabaseError)?;
    } else {
        if user_role == "admin" && stats.admins == 1 {
            return Err(ApiError::CannotLeaveLastAdmin);
        }
        
        sqlx::query!(
            "DELETE FROM family_mems WHERE family_id = $1 AND user_id = $2",
            fam_id,
            user.0
        )
        .execute(&mut *tx)
        .await
        .map_err(ApiError::DatabaseError)?;
    }

    tx.commit().await.map_err(ApiError::DatabaseError)?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn update_fam_name(
    State(db): State<PgPool>,
    Path(fam_id): Path<Uuid>,
    user: AuthenticatedUser,
    Json(payload): Json<UpdateFamNameDto>,
) -> Result<StatusCode, ApiError> {
    let role = sqlx::query_scalar!(
        "SELECT role::text FROM family_mems WHERE family_id = $1 AND user_id = $2",
        fam_id,
        user.0
    )
    .fetch_optional(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    if role.flatten().as_deref() != Some("admin") {
        return Err(ApiError::Unauthorized);
    }

    sqlx::query!("UPDATE families SET name = $2 WHERE id = $1", fam_id, payload.name)
        .execute(&db)
        .await
        .map_err(ApiError::DatabaseError)?;

    Ok(StatusCode::NO_CONTENT)
}

pub async fn add_fam_member(
    State(db): State<PgPool>,
    Path(fam_id): Path<Uuid>,
    user: AuthenticatedUser,
    Json(payload): Json<CreateFamMemDto>,
) -> Result<StatusCode, ApiError> {
    let role = sqlx::query_scalar!(
        "SELECT role::text FROM family_mems WHERE family_id = $1 AND user_id = $2",
        fam_id,
        user.0
    )
    .fetch_optional(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    if role.flatten().as_deref() != Some("admin") {
        return Err(ApiError::Unauthorized);
    }

    let target_uid = sqlx::query_scalar!(
        "SELECT id FROM users WHERE email = $1",
        payload.email
    )
    .fetch_optional(&db)
    .await
    .map_err(ApiError::DatabaseError)?
    .ok_or(ApiError::InvalidCredentials)?;

    sqlx::query!(
        "INSERT INTO family_mems (family_id, user_id, role) VALUES ($1, $2, $3::text::mem_role_t) ON CONFLICT DO NOTHING",
        fam_id,
        target_uid,
        payload.role
    )
    .execute(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    Ok(StatusCode::CREATED)
}

pub async fn update_fam_member(
    State(db): State<PgPool>,
    Path((fam_id, target_user_id)): Path<(Uuid, Uuid)>,
    user: AuthenticatedUser,
    Json(payload): Json<UpdateFamMemRoleDto>,
) -> Result<StatusCode, ApiError> {
    let role = sqlx::query_scalar!(
        "SELECT role::text FROM family_mems WHERE family_id = $1 AND user_id = $2",
        fam_id,
        user.0
    )
    .fetch_optional(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    if role.flatten().as_deref() != Some("admin") {
        return Err(ApiError::Unauthorized);
    }

    if payload.role != "admin" {
        let stats = sqlx::query!(
            r#"
            SELECT 
                SUM(CASE WHEN role::text = 'admin' THEN 1 ELSE 0 END) as "admins!",
                (SELECT role::text FROM family_mems WHERE family_id = $1 AND user_id = $2) as "target_role"
            FROM family_mems 
            WHERE family_id = $1
            "#,
            fam_id,
            target_user_id
        )
        .fetch_one(&db)
        .await
        .map_err(ApiError::DatabaseError)?;

        if stats.target_role.as_deref() == Some("admin") && stats.admins == 1 {
            return Err(ApiError::CannotLeaveLastAdmin);
        }
    }

    sqlx::query!(
        "UPDATE family_mems SET role = $3::text::mem_role_t WHERE family_id = $1 AND user_id = $2",
        fam_id,
        target_user_id,
        payload.role
    )
    .execute(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    Ok(StatusCode::NO_CONTENT)
}

pub async fn remove_fam_member(
    State(db): State<PgPool>,
    Path((fam_id, target_user_id)): Path<(Uuid, Uuid)>,
    user: AuthenticatedUser,
) -> Result<StatusCode, ApiError> {
    let role = sqlx::query_scalar!(
        "SELECT role::text FROM family_mems WHERE family_id = $1 AND user_id = $2",
        fam_id,
        user.0
    )
    .fetch_optional(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    if role.flatten().as_deref() != Some("admin") {
        return Err(ApiError::Unauthorized);
    }

    let stats = sqlx::query!(
        r#"
        SELECT 
            SUM(CASE WHEN role::text = 'admin' THEN 1 ELSE 0 END) as "admins!",
            (SELECT role::text FROM family_mems WHERE family_id = $1 AND user_id = $2) as "target_role"
        FROM family_mems 
        WHERE family_id = $1
        "#,
        fam_id,
        target_user_id
    )
    .fetch_one(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    if stats.target_role.as_deref() == Some("admin") && stats.admins == 1 {
        return Err(ApiError::CannotLeaveLastAdmin);
    }

    sqlx::query!(
        "DELETE FROM family_mems WHERE family_id = $1 AND user_id = $2",
        fam_id,
        target_user_id
    )
    .execute(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    Ok(StatusCode::NO_CONTENT)
}

async fn fetch_fam_aggregate(db: &PgPool, fam_id: Uuid) -> Result<Json<FamDetailDto>, ApiError> {
    let fam_name = sqlx::query_scalar!("SELECT name FROM families WHERE id = $1", fam_id)
        .fetch_one(db)
        .await
        .map_err(ApiError::DatabaseError)?;

    let mems = sqlx::query_as!(
        FamMemberDto,
        r#"
        SELECT u.id, u.first_name, u.last_name, fm.role::text as "role!"
        FROM users u
        JOIN family_mems fm ON u.id = fm.user_id
        WHERE fm.family_id = $1
        "#,
        fam_id
    )
    .fetch_all(db)
    .await
    .map_err(ApiError::DatabaseError)?;

    Ok(Json(FamDetailDto {
        id: fam_id,
        name: fam_name,
        members: mems,
    }))

    
}

#[derive(Deserialize)]
pub struct FamBudgetReq {
    pub target_curr_code: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, TS)]
#[ts(export, export_to = "../bindings/FamBudgetDto.ts")]
pub struct FamBudgetDto {
    pub curr_code: String,
    pub total_balance: f64,
}

pub async fn get_fam_budget(
    State(_db): State<PgPool>,
    Path(_fam_id): Path<Uuid>,
) -> Result<Json<()>, ApiError> {
    Ok(Json(()))
}

pub async fn get_fam_timeline(
    State(_db): State<PgPool>,
    Path(_fam_id): Path<Uuid>,
) -> Result<Json<()>, ApiError> {
    Ok(Json(()))
}