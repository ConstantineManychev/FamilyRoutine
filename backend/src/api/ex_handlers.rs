use crate::api::auth_middleware::AuthenticatedUser;
use crate::domain::errors::ApiError;
use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use shared_schema::{DictExDto, ExMuscGrpDto, MutateExDto};
use sqlx::PgPool;
use uuid::Uuid;

pub async fn get_exs(State(db): State<PgPool>) -> Result<Json<Vec<DictExDto>>, ApiError> {
    let exs = sqlx::query!(
        r#"SELECT id, name, type::text as "type_!", met_val::float8 as "met_val!", is_custom FROM dict_exs ORDER BY name"#
    )
    .fetch_all(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    let mut res = Vec::with_capacity(exs.len());

    for ex in exs {
        let grp_data = sqlx::query!(
            r#"SELECT grp::text as "grp!", pct::float8 as "pct!" FROM ex_musc_grps WHERE ex_id = $1"#,
            ex.id
        )
        .fetch_all(&db)
        .await
        .map_err(ApiError::DatabaseError)?;

        let musc_grps = grp_data.into_iter().map(|g| ExMuscGrpDto {
            grp: serde_json::from_str(&format!("\"{}\"", g.grp)).unwrap(),
            pct: g.pct,
        }).collect();

        res.push(DictExDto {
            id: ex.id,
            name: ex.name,
            type_: ex.type_,
            met_val: ex.met_val,
            is_custom: ex.is_custom,
            musc_grps,
        });
    }

    Ok(Json(res))
}

pub async fn get_ex_detail(
    State(db): State<PgPool>,
    Path(id): Path<Uuid>,
) -> Result<Json<DictExDto>, ApiError> {
    get_ex_by_id(&db, id).await
}

pub async fn create_ex(
    State(db): State<PgPool>,
    user: AuthenticatedUser,
    Json(payload): Json<MutateExDto>,
) -> Result<(StatusCode, Json<DictExDto>), ApiError> {
    if payload.musc_grps.is_empty() {
        return Err(ApiError::ValidationError("err_no_musc_grp".into()));
    }

    let mut tx = db.begin().await.map_err(ApiError::DatabaseError)?;

    let ex_id = sqlx::query_scalar!(
        "INSERT INTO dict_exs (name, type, met_val, is_custom, created_by) VALUES ($1, $2::text::ex_type_t, $3::numeric, true, $4) RETURNING id",
        payload.name,
        payload.type_,
        payload.met_val as f64, // Явно указываем тип
        user.0
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::DatabaseError)?;

    for mg in &payload.musc_grps {
        let grp_str = serde_json::to_string(&mg.grp).unwrap().replace("\"", "");
       sqlx::query!(
            "INSERT INTO ex_musc_grps (ex_id, grp, pct) VALUES ($1, $2::text::musc_grp_t, $3::numeric)",
            ex_id,
            grp_str,
            mg.pct as f64
        )
        .execute(&mut *tx)
        .await
        .map_err(ApiError::DatabaseError)?;
    }

    tx.commit().await.map_err(ApiError::DatabaseError)?;

    let ex_dto = get_ex_by_id(&db, ex_id).await?.0;
    Ok((StatusCode::CREATED, Json(ex_dto)))
}

pub async fn update_ex(
    State(db): State<PgPool>,
    Path(id): Path<Uuid>,
    user: AuthenticatedUser,
    Json(payload): Json<MutateExDto>,
) -> Result<Json<DictExDto>, ApiError> {
    if payload.musc_grps.is_empty() {
        return Err(ApiError::ValidationError("err_no_musc_grp".into()));
    }

    let is_owner = sqlx::query_scalar!(
        "SELECT EXISTS(SELECT 1 FROM dict_exs WHERE id = $1 AND created_by = $2 AND is_custom = true)",
        id,
        user.0
    )
    .fetch_one(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    if !is_owner.unwrap_or(false) {
        return Err(ApiError::Unauthorized);
    }

    let mut tx = db.begin().await.map_err(ApiError::DatabaseError)?;

    sqlx::query!(
        "UPDATE dict_exs SET name = $2, type = $3::text::ex_type_t, met_val = $4::numeric WHERE id = $1",
        id,
        payload.name,
        payload.type_,
        payload.met_val as f64
    )
    .execute(&mut *tx)
    .await
    .map_err(ApiError::DatabaseError)?;

    sqlx::query!("DELETE FROM ex_musc_grps WHERE ex_id = $1", id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::DatabaseError)?;

    for mg in &payload.musc_grps {
        let grp_str = serde_json::to_string(&mg.grp).unwrap().replace("\"", "");
        sqlx::query!(
            "INSERT INTO ex_musc_grps (ex_id, grp, pct) VALUES ($1, $2::text::musc_grp_t, $3::numeric)",
            id,
            grp_str,
            mg.pct as f64
        )
        .execute(&mut *tx)
        .await
        .map_err(ApiError::DatabaseError)?;
    }

    tx.commit().await.map_err(ApiError::DatabaseError)?;

    get_ex_by_id(&db, id).await
}

pub async fn delete_ex(
    State(db): State<PgPool>,
    Path(id): Path<Uuid>,
    user: AuthenticatedUser,
) -> Result<StatusCode, ApiError> {
    let is_owner = sqlx::query_scalar!(
        "SELECT EXISTS(SELECT 1 FROM dict_exs WHERE id = $1 AND created_by = $2 AND is_custom = true)",
        id,
        user.0
    )
    .fetch_one(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    if !is_owner.unwrap_or(false) {
        return Err(ApiError::Unauthorized);
    }

    sqlx::query!("DELETE FROM dict_exs WHERE id = $1", id)
        .execute(&db)
        .await
        .map_err(ApiError::DatabaseError)?;

    Ok(StatusCode::NO_CONTENT)
}

async fn get_ex_by_id(db: &PgPool, id: Uuid) -> Result<Json<DictExDto>, ApiError> {
    let ex_data = sqlx::query!(
        r#"SELECT id, name, type::text as "type_!", met_val::float8 as "met_val!", is_custom FROM dict_exs WHERE id = $1"#,
        id
    )
    .fetch_optional(db)
    .await
    .map_err(ApiError::DatabaseError)?
    .ok_or(ApiError::NotFound)?;

    let grp_data = sqlx::query!(
        r#"SELECT grp::text as "grp!", pct::float8 as "pct!" FROM ex_musc_grps WHERE ex_id = $1"#,
        id
    )
    .fetch_all(db)
    .await
    .map_err(ApiError::DatabaseError)?;

    let musc_grps = grp_data.into_iter().map(|g| ExMuscGrpDto {
        grp: serde_json::from_str(&format!("\"{}\"", g.grp)).unwrap(),
        pct: g.pct,
    }).collect();

    Ok(Json(DictExDto {
        id: ex_data.id,
        name: ex_data.name,
        type_: ex_data.type_,
        met_val: ex_data.met_val,
        is_custom: ex_data.is_custom,
        musc_grps,
    }))
}