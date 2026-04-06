use crate::api::auth_middleware::AuthenticatedUser;
use crate::domain::errors::ApiError;
use axum::{
    extract::{Path, Query, State},
    Json,
};
use chrono::{Datelike, TimeZone, Utc};
use serde::Serialize;
use shared_schema::{EnergyEventType, EnergyGraphReq, EnergyNodeDto};
use sqlx::PgPool;
use uuid::Uuid;

const DEF_WEIGHT: f64 = 75.0;
const DEF_HEIGHT: f64 = 170.0;
const M_BMR_CONST: f64 = 5.0;
const F_BMR_CONST: f64 = -161.0;

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
        DictMetaDto {
            id: "events".into(),
            name: "dicts.events".into(),
        },
        DictMetaDto {
            id: "exercises".into(),
            name: "dicts.exercises".into(),
        },
        DictMetaDto {
            id: "items".into(),
            name: "dicts.items".into(),
        },
    ];

    Ok(Json(dicts))
}

fn calc_bmr(w: f64, h: f64, age: f64, is_male: bool) -> f64 {
    let base = (10.0 * w) + (6.25 * h) - (5.0 * age);
    if is_male {
        base + M_BMR_CONST
    } else {
        base + F_BMR_CONST
    }
}

pub async fn get_energy_timeline(
    State(db): State<PgPool>,
    Path(uid): Path<Uuid>,
    Query(req): Query<EnergyGraphReq>,
) -> Result<Json<Vec<EnergyNodeDto>>, ApiError> {
    let user_data = sqlx::query!(
        r#"
        SELECT 
            u.birth_date, 
            u.gender, 
            b.weight::float8 AS "weight_kg", 
            b.height::float8 AS "height_cm"
        FROM users u
        LEFT JOIN body_snaps b ON u.id = b.user_id
        WHERE u.id = $1
        ORDER BY b.rec_ts DESC
        LIMIT 1
        "#,
        uid
    )
    .fetch_one(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    let age_yrs = (Utc::now().year() - user_data.birth_date.year()) as f64;
    let w = user_data.weight_kg.unwrap_or(DEF_WEIGHT);
    let h = user_data.height_cm.unwrap_or(DEF_HEIGHT);
    let is_male = user_data.gender.as_deref() != Some("female");

    let bmr = calc_bmr(w, h, age_yrs, is_male);
    let bmr_per_hr = bmr / 24.0;

    let day_start = req.target_date.and_hms_opt(0, 0, 0).unwrap_or_default().and_utc();
    let day_end = req.target_date.and_hms_opt(23, 59, 59).unwrap_or_default().and_utc();

    let meals = sqlx::query!(
        r#"
        SELECT consumed_ts, total_kcal::float8 AS "kcal!" 
        FROM user_meals 
        WHERE user_id = $1 AND consumed_ts >= $2 AND consumed_ts <= $3
        "#,
        uid,
        day_start,
        day_end
    )
    .fetch_all(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    let workouts = sqlx::query!(
        r#"
        SELECT start_ts, kcal_burned::float8 AS "kcal!" 
        FROM user_workouts 
        WHERE user_id = $1 AND start_ts >= $2 AND start_ts <= $3
        "#,
        uid,
        day_start,
        day_end
    )
    .fetch_all(&db)
    .await
    .map_err(ApiError::DatabaseError)?;

    let mut nodes = Vec::with_capacity(24 + meals.len() + workouts.len());

    for hr in 0..=23 {
        let hr_ts = req.target_date.and_hms_opt(hr, 0, 0).unwrap_or_default().and_utc();
        nodes.push(EnergyNodeDto {
            ts: hr_ts,
            event_type: EnergyEventType::BmrBase,
            val: -bmr_per_hr,
            cum_val: 0.0,
        });
    }

    for m in meals {
        nodes.push(EnergyNodeDto {
            ts: m.consumed_ts,
            event_type: EnergyEventType::Meal,
            val: m.kcal,
            cum_val: 0.0,
        });
    }

    for w in workouts {
        nodes.push(EnergyNodeDto {
            ts: w.start_ts,
            event_type: EnergyEventType::Workout,
            val: -w.kcal,
            cum_val: 0.0,
        });
    }

    nodes.sort_unstable_by_key(|n| n.ts);

    let mut running_total = 0.0;
    for node in nodes.iter_mut() {
        running_total += node.val;
        node.cum_val = running_total;
    }

    Ok(Json(nodes))
}