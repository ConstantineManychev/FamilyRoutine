use std::collections::HashMap;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use shared_schema::{DictExDto, ExMuscGrpDto, ExType, MuscGrpType, SaveExRequest, WeightType};
use sqlx::{PgConnection, PgPool};
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, AuthUser};
use crate::domain::errors::ApiError;
use crate::domain::validation::clean_name;
use crate::state::AppState;

const MIN_MET: f64 = 0.5;
const MAX_MET: f64 = 30.0;

struct ExRow
{
    id: Uuid,
    name: String,
    ex_type: ExType,
    met_val: f64,
    weight_type: WeightType,
    bw_pct: f64,
    is_custom: bool,
}

pub async fn list_exercises(State(a_state): State<AppState>, a_user: AuthUser)
    -> Result<Json<Vec<DictExDto>>, ApiError>
{
    let rows = sqlx::query_as!(
        ExRow,
        r#"
        SELECT id, name, type AS "ex_type: ExType", met_val::float8 AS "met_val!",
               weight_type AS "weight_type: WeightType", bw_pct::float8 AS "bw_pct!", is_custom
        FROM dict_exs
        WHERE is_custom = FALSE OR created_by = $1
        ORDER BY name
        "#,
        a_user.user_id
    )
    .fetch_all(&a_state.db)
    .await?;

    let ids: Vec<Uuid> = rows.iter().map(|row| row.id).collect();
    let mut groups = load_groups(&a_state.db, &ids).await?;

    let result = rows
        .into_iter()
        .map(|row| {
            let musc_grps = groups.remove(&row.id).unwrap_or_default();
            to_dto(row, musc_grps)
        })
        .collect();

    Ok(Json(result))
}

pub async fn get_exercise(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<Json<DictExDto>, ApiError>
{
    load_exercise(&a_state.db, a_id, a_user.user_id).await.map(Json)
}

pub async fn create_exercise(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SaveExRequest>,
) -> Result<(StatusCode, Json<DictExDto>), ApiError>
{
    let req = clean_request(a_req)?;
    let mut tx = a_state.db.begin().await?;

    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO dict_exs (name, type, met_val, weight_type, bw_pct, is_custom, created_by)
        VALUES ($1, $2, $3::float8::numeric, $4, $5::float8::numeric, TRUE, $6)
        RETURNING id
        "#,
        req.name,
        req.ex_type as ExType,
        req.met_val,
        req.weight_type as WeightType,
        req.bw_pct,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;

    insert_groups(&mut tx, id, &req.musc_grps).await?;
    tx.commit().await?;

    let ex = load_exercise(&a_state.db, id, a_user.user_id).await?;
    Ok((StatusCode::CREATED, Json(ex)))
}

pub async fn update_exercise(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SaveExRequest>,
) -> Result<Json<DictExDto>, ApiError>
{
    let req = clean_request(a_req)?;
    require_own_custom(&a_state.db, a_id, a_user.user_id).await?;

    let mut tx = a_state.db.begin().await?;

    sqlx::query!(
        r#"
        UPDATE dict_exs
        SET name = $2, type = $3, met_val = $4::float8::numeric, weight_type = $5, bw_pct = $6::float8::numeric
        WHERE id = $1
        "#,
        a_id,
        req.name,
        req.ex_type as ExType,
        req.met_val,
        req.weight_type as WeightType,
        req.bw_pct
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query!("DELETE FROM ex_musc_grps WHERE ex_id = $1", a_id)
        .execute(&mut *tx)
        .await?;

    insert_groups(&mut tx, a_id, &req.musc_grps).await?;
    tx.commit().await?;

    load_exercise(&a_state.db, a_id, a_user.user_id).await.map(Json)
}

pub async fn delete_exercise(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    require_own_custom(&a_state.db, a_id, a_user.user_id).await?;

    sqlx::query!("DELETE FROM dict_exs WHERE id = $1", a_id)
        .execute(&a_state.db)
        .await
        .map_err(|err| match ApiError::from(err)
        {
            ApiError::Validation("reference") => ApiError::Conflict("IN_USE"),
            other => other,
        })?;

    Ok(StatusCode::NO_CONTENT)
}

fn to_dto(a_row: ExRow, a_musc_grps: Vec<ExMuscGrpDto>) -> DictExDto
{
    DictExDto {
        id: a_row.id,
        name: a_row.name,
        ex_type: a_row.ex_type,
        met_val: a_row.met_val,
        weight_type: a_row.weight_type,
        bw_pct: a_row.bw_pct,
        is_custom: a_row.is_custom,
        musc_grps: a_musc_grps,
    }
}

fn clean_request(a_req: SaveExRequest) -> Result<SaveExRequest, ApiError>
{
    let name = clean_name(&a_req.name, "name")?;

    if !a_req.met_val.is_finite() || !(MIN_MET..=MAX_MET).contains(&a_req.met_val)
    {
        return Err(ApiError::Validation("met_val"));
    }

    let bw_pct = match a_req.weight_type
    {
        WeightType::External => 0.0,
        WeightType::Hybrid | WeightType::Bodyweight => a_req.bw_pct,
    };

    if !bw_pct.is_finite() || !(0.0..=100.0).contains(&bw_pct)
    {
        return Err(ApiError::Validation("bw_pct"));
    }

    if a_req.musc_grps.is_empty()
    {
        return Err(ApiError::Validation("musc_grps"));
    }

    let mut seen: Vec<MuscGrpType> = Vec::with_capacity(a_req.musc_grps.len());
    for group in &a_req.musc_grps
    {
        let is_pct_valid = group.pct.is_finite() && group.pct > 0.0 && group.pct <= 100.0;
        if !is_pct_valid || seen.contains(&group.grp)
        {
            return Err(ApiError::Validation("musc_grps"));
        }
        seen.push(group.grp);
    }

    Ok(SaveExRequest { name, bw_pct, ..a_req })
}

async fn require_own_custom(a_db: &PgPool, a_id: Uuid, a_user_id: Uuid) -> Result<(), ApiError>
{
    let ownership = sqlx::query!("SELECT is_custom, created_by FROM dict_exs WHERE id = $1", a_id)
        .fetch_optional(a_db)
        .await?
        .ok_or(ApiError::NotFound)?;

    match (ownership.is_custom, ownership.created_by)
    {
        (true, Some(owner)) if owner == a_user_id => Ok(()),
        (true, _) => Err(ApiError::NotFound),
        (false, _) => Err(ApiError::Forbidden),
    }
}

async fn load_exercise(a_db: &PgPool, a_id: Uuid, a_user_id: Uuid) -> Result<DictExDto, ApiError>
{
    let row = sqlx::query_as!(
        ExRow,
        r#"
        SELECT id, name, type AS "ex_type: ExType", met_val::float8 AS "met_val!",
               weight_type AS "weight_type: WeightType", bw_pct::float8 AS "bw_pct!", is_custom
        FROM dict_exs
        WHERE id = $1 AND (is_custom = FALSE OR created_by = $2)
        "#,
        a_id,
        a_user_id
    )
    .fetch_optional(a_db)
    .await?
    .ok_or(ApiError::NotFound)?;

    let musc_grps = load_groups(a_db, &[row.id]).await?.remove(&row.id).unwrap_or_default();
    Ok(to_dto(row, musc_grps))
}

async fn load_groups(a_db: &PgPool, a_ids: &[Uuid]) -> Result<HashMap<Uuid, Vec<ExMuscGrpDto>>, ApiError>
{
    if a_ids.is_empty()
    {
        return Ok(HashMap::new());
    }

    let rows = sqlx::query!(
        r#"
        SELECT ex_id AS "ex_id!", grp AS "grp: MuscGrpType", pct::float8 AS "pct!"
        FROM ex_musc_grps
        WHERE ex_id = ANY($1)
        ORDER BY pct DESC
        "#,
        a_ids
    )
    .fetch_all(a_db)
    .await?;

    let mut grouped: HashMap<Uuid, Vec<ExMuscGrpDto>> = HashMap::new();
    for row in rows
    {
        grouped.entry(row.ex_id).or_default().push(ExMuscGrpDto {
            grp: row.grp,
            pct: row.pct,
        });
    }

    Ok(grouped)
}

async fn insert_groups(a_conn: &mut PgConnection, a_ex_id: Uuid, a_groups: &[ExMuscGrpDto]) -> Result<(), ApiError>
{
    for group in a_groups
    {
        sqlx::query!(
            "INSERT INTO ex_musc_grps (ex_id, grp, pct) VALUES ($1, $2, $3::float8::numeric)",
            a_ex_id,
            group.grp as MuscGrpType,
            group.pct
        )
        .execute(&mut *a_conn)
        .await?;
    }

    Ok(())
}
