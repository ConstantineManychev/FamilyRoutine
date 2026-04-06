use crate::api::auth_middleware::AuthenticatedUser;
use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use ts_rs::TS;
use uuid::Uuid;

#[derive(Debug, Serialize, Deserialize, Clone, TS)]
#[ts(export, export_to = "../bindings/ExMuscleDto.ts")]
pub struct ExMuscleDto {
    pub muscle: String,
    pub pct: f64,
}

#[derive(Debug, Serialize, Deserialize, Clone, TS)]
#[ts(export, export_to = "../bindings/ExDto.ts")]
pub struct ExDto {
    #[ts(type = "string")]
    pub id: Uuid,
    pub name: String,
    pub ex_type: String,
    pub met_val: f64,
    pub is_custom: bool,
    pub weight_type: String,
    pub bw_pct: f64,
    pub muscles: Vec<ExMuscleDto>,
}

pub async fn get_exs(State(db): State<PgPool>) -> Result<Json<Vec<ExDto>>, StatusCode> {
    let exs = sqlx::query!(
        r#"SELECT id, name, type::text as "ex_type!", met_val::float8 as "met_val!", is_custom, weight_type::text as "weight_type!", bw_pct::float8 as "bw_pct!" FROM dict_exs ORDER BY name"#
    )
    .fetch_all(&db)
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let mut res = Vec::new();
    for ex in exs {
        let muscles = sqlx::query_as!(
            ExMuscleDto,
            r#"SELECT muscle::text as "muscle!", pct::float8 as "pct!" FROM dict_ex_muscles WHERE ex_id = $1"#,
            ex.id
        )
        .fetch_all(&db)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

        res.push(ExDto {
            id: ex.id,
            name: ex.name,
            ex_type: ex.ex_type,
            met_val: ex.met_val,
            is_custom: ex.is_custom,
            weight_type: ex.weight_type,
            bw_pct: ex.bw_pct,
            muscles,
        });
    }

    Ok(Json(res))
}

pub async fn get_ex_detail(
    State(db): State<PgPool>,
    Path(id): Path<Uuid>,
) -> Result<Json<ExDto>, StatusCode> {
    let ex = sqlx::query!(
        r#"SELECT id, name, type::text as "ex_type!", met_val::float8 as "met_val!", is_custom, weight_type::text as "weight_type!", bw_pct::float8 as "bw_pct!" FROM dict_exs WHERE id = $1"#,
        id
    )
    .fetch_optional(&db)
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
    .ok_or(StatusCode::NOT_FOUND)?;

    let muscles = sqlx::query_as!(
        ExMuscleDto,
        r#"SELECT muscle::text as "muscle!", pct::float8 as "pct!" FROM dict_ex_muscles WHERE ex_id = $1"#,
        id
    )
    .fetch_all(&db)
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok(Json(ExDto {
        id: ex.id,
        name: ex.name,
        ex_type: ex.ex_type,
        met_val: ex.met_val,
        is_custom: ex.is_custom,
        weight_type: ex.weight_type,
        bw_pct: ex.bw_pct,
        muscles,
    }))
}

pub async fn create_ex(
    State(db): State<PgPool>,
    user: AuthenticatedUser,
    Json(payload): Json<ExDto>,
) -> Result<(StatusCode, Json<ExDto>), StatusCode> {
    if payload.muscles.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }

    let mut tx = db.begin().await.map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let ex_id = sqlx::query_scalar!(
        "INSERT INTO dict_exs (name, type, met_val, is_custom, created_by, weight_type, bw_pct) VALUES ($1, $2::text::ex_type_t, $3::float8, $4, $5, $6::text::ex_weight_type_t, $7::float8) RETURNING id",
        payload.name,
        payload.ex_type,
        payload.met_val,
        true,
        user.0,
        payload.weight_type,
        payload.bw_pct
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    for m in &payload.muscles {
        sqlx::query!(
            "INSERT INTO dict_ex_muscles (ex_id, muscle, pct) VALUES ($1, $2::text::muscle_grp_t, $3::float8)",
            ex_id,
            m.muscle,
            m.pct
        )
        .execute(&mut *tx)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    }

    tx.commit().await.map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let mut created = payload.clone();
    created.id = ex_id;
    created.is_custom = true;

    Ok((StatusCode::CREATED, Json(created)))
}

pub async fn update_ex(
    State(db): State<PgPool>,
    Path(id): Path<Uuid>,
    Json(payload): Json<ExDto>,
) -> Result<Json<ExDto>, StatusCode> {
    if payload.muscles.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }

    let mut tx = db.begin().await.map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    sqlx::query!(
        "UPDATE dict_exs SET name = $1, type = $2::text::ex_type_t, met_val = $3::float8, weight_type = $4::text::ex_weight_type_t, bw_pct = $5::float8 WHERE id = $6",
        payload.name,
        payload.ex_type,
        payload.met_val,
        payload.weight_type,
        payload.bw_pct,
        id
    )
    .execute(&mut *tx)
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    sqlx::query!("DELETE FROM dict_ex_muscles WHERE ex_id = $1", id)
        .execute(&mut *tx)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    for m in &payload.muscles {
        sqlx::query!(
            "INSERT INTO dict_ex_muscles (ex_id, muscle, pct) VALUES ($1, $2::text::muscle_grp_t, $3::float8)",
            id,
            m.muscle,
            m.pct
        )
        .execute(&mut *tx)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    }

    tx.commit().await.map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let mut updated = payload.clone();
    updated.id = id;

    Ok(Json(updated))
}

pub async fn delete_ex(
    State(db): State<PgPool>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, StatusCode> {
    sqlx::query!("DELETE FROM dict_exs WHERE id = $1", id)
        .execute(&db)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok(StatusCode::NO_CONTENT)
}