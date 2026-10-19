use std::collections::HashMap;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, DurationRound, NaiveTime, Utc};
use chrono_tz::Tz;
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;
use shared_schema::{
    EnergyDayDto, EnergyDayQuery, EnergyMarkDto, EnergyPersonDto, EnergyPointDto, SetEnergyMarkRequest,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::api::nutrition_handlers::load_norm;
use crate::api::profile_handlers::group_people;
use crate::domain::errors::ApiError;
use crate::security::profile_access::{acting_for, require_editor};
use crate::services::energy::{carried_value, energy_curve, CurveInput, EnergyReset, FoodEvent, WorkoutSpan};
use crate::services::planner::{local_date, parse_zone, resolve_local};
use crate::state::AppState;

const MAX_PAST_DAYS: i64 = 400;
const MAX_RANGE_DAYS: i64 = 31;
const MAX_MARKS_PER_PERSON: i64 = 2000;
const MAX_MARK_KCAL: i64 = 100_000;
const MARK_FUTURE_MINUTES: i64 = 60;

struct Start
{
    from: DateTime<Utc>,
    value: f64,
}

async fn food_sum(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_after: DateTime<Utc>,
    a_is_inclusive: bool,
    a_before: DateTime<Utc>,
) -> Result<f64, ApiError>
{
    Ok(sqlx::query_scalar!(
        r#"
        SELECT COALESCE(SUM(me.kcal), 0)::float8 AS "kcal!"
        FROM meal_entries me
        LEFT JOIN status_marks m ON m.id = me.status_mark_id
        WHERE me.user_id = $1
          AND (COALESCE(m.start_ts, me.created_ts) > $2 OR ($3 AND COALESCE(m.start_ts, me.created_ts) = $2))
          AND COALESCE(m.start_ts, me.created_ts) < $4
        "#,
        a_user_id,
        a_after,
        a_is_inclusive,
        a_before
    )
    .fetch_one(&mut *a_conn)
    .await?)
}

async fn workout_spans(
    a_conn: &mut PgConnection,
    a_ids: &[Uuid],
    a_from: DateTime<Utc>,
    a_to: DateTime<Utc>,
) -> Result<HashMap<Uuid, Vec<WorkoutSpan>>, ApiError>
{
    let mut spans: HashMap<Uuid, Vec<WorkoutSpan>> = HashMap::new();
    for row in sqlx::query!(
        r#"
        SELECT user_id, started_ts, finished_ts AS "finished_ts!", kcal::float8 AS "kcal!"
        FROM workout_sessions
        WHERE user_id = ANY($1) AND finished_ts IS NOT NULL AND kcal IS NOT NULL
          AND started_ts < $3 AND finished_ts > $2
        "#,
        a_ids,
        a_from,
        a_to
    )
    .fetch_all(&mut *a_conn)
    .await?
    {
        spans.entry(row.user_id).or_default().push(WorkoutSpan {
            start: row.started_ts,
            end: row.finished_ts,
            kcal: row.kcal,
        });
    }
    Ok(spans)
}

async fn start_of(
    a_conn: &mut PgConnection,
    a_zone: Tz,
    a_user_id: Uuid,
    a_window_start: DateTime<Utc>,
    a_daily_burn: Option<f64>,
) -> Result<Option<Start>, ApiError>
{
    let anchor = sqlx::query!(
        r#"
        SELECT ts, kcal::float8 AS "kcal!"
        FROM energy_marks
        WHERE user_id = $1 AND ts <= $2
        ORDER BY ts DESC
        LIMIT 1
        "#,
        a_user_id,
        a_window_start
    )
    .fetch_optional(&mut *a_conn)
    .await?;
    let (since, base, is_inclusive) = match anchor
    {
        Some(anchor) => (anchor.ts, anchor.kcal, false),
        None =>
        {
            let first = sqlx::query_scalar!(
                r#"
                SELECT LEAST(
                    (SELECT MIN(COALESCE(m.start_ts, me.created_ts))
                     FROM meal_entries me LEFT JOIN status_marks m ON m.id = me.status_mark_id
                     WHERE me.user_id = $1),
                    (SELECT MIN(started_ts) FROM workout_sessions
                     WHERE user_id = $1 AND finished_ts IS NOT NULL AND kcal IS NOT NULL),
                    (SELECT MIN(ts) FROM energy_marks WHERE user_id = $1)
                ) AS first
                "#,
                a_user_id
            )
            .fetch_one(&mut *a_conn)
            .await?;
            let Some(first) = first
            else
            {
                return Ok(None);
            };
            let origin = resolve_local(a_zone, local_date(a_zone, first), NaiveTime::MIN);
            if origin >= a_window_start
            {
                return Ok(Some(Start {
                    from: origin,
                    value: 0.0,
                }));
            }
            (origin, 0.0, true)
        }
    };
    let eaten = food_sum(a_conn, a_user_id, since, is_inclusive, a_window_start).await?;
    let spans = workout_spans(a_conn, &[a_user_id], since, a_window_start).await?;
    Ok(Some(Start {
        from: a_window_start,
        value: carried_value(
            base,
            since,
            a_window_start,
            a_daily_burn,
            eaten,
            spans.get(&a_user_id).map(Vec::as_slice).unwrap_or_default(),
        ),
    }))
}

pub async fn energy_day(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<EnergyDayQuery>,
) -> Result<Json<EnergyDayDto>, ApiError>
{
    let zone = parse_zone(&a_query.tz).ok_or(ApiError::Validation("tz"))?;
    let days = a_query.days.unwrap_or(1);
    if !(1..=MAX_RANGE_DAYS).contains(&days)
    {
        return Err(ApiError::Validation("days"));
    }
    let now = Utc::now();
    let today = local_date(zone, now);
    let first_day = a_query.date - Duration::days(days - 1);
    if a_query.date > today + Duration::days(1) || first_day < today - Duration::days(MAX_PAST_DAYS)
    {
        return Err(ApiError::Validation("date"));
    }
    let window_start = resolve_local(zone, first_day, NaiveTime::MIN);
    let window_end = resolve_local(zone, a_query.date + Duration::days(1), NaiveTime::MIN);
    let until = now.min(window_end);

    let mut conn = a_state.db.acquire().await?;
    let people = group_people(&mut conn, a_user.user_id).await?;
    let ids: Vec<Uuid> = people.iter().map(|person| person.id).collect();

    let mut foods: HashMap<Uuid, Vec<FoodEvent>> = HashMap::new();
    for row in sqlx::query!(
        r#"
        SELECT me.user_id, COALESCE(m.start_ts, me.created_ts) AS "ts!", me.kcal::float8 AS "kcal!"
        FROM meal_entries me
        LEFT JOIN status_marks m ON m.id = me.status_mark_id
        WHERE me.user_id = ANY($1)
          AND COALESCE(m.start_ts, me.created_ts) >= $2 AND COALESCE(m.start_ts, me.created_ts) < $3
        "#,
        &ids,
        window_start,
        window_end
    )
    .fetch_all(&mut *conn)
    .await?
    {
        foods.entry(row.user_id).or_default().push(FoodEvent {
            ts: row.ts,
            kcal: row.kcal,
        });
    }
    let workouts = workout_spans(&mut conn, &ids, window_start, window_end).await?;
    let mut marks: HashMap<Uuid, Vec<EnergyMarkDto>> = HashMap::new();
    for row in sqlx::query!(
        r#"
        SELECT id, user_id, ts, kcal::float8 AS "kcal!"
        FROM energy_marks
        WHERE user_id = ANY($1) AND ts > $2 AND ts <= $3
        ORDER BY ts
        "#,
        &ids,
        window_start,
        window_end
    )
    .fetch_all(&mut *conn)
    .await?
    {
        marks.entry(row.user_id).or_default().push(EnergyMarkDto {
            id: row.id,
            ts: row.ts,
            kcal: row.kcal,
        });
    }

    let mut dtos = Vec::with_capacity(people.len());
    for person in people
    {
        let (norm, _) = load_norm(&mut conn, person.id, a_query.date, window_end).await?;
        let daily_burn = norm.and_then(|norm| norm.maintenance_kcal);
        let burn = daily_burn.and_then(|kcal| kcal.to_f64());
        let person_marks = marks.remove(&person.id).unwrap_or_default();
        let resets: Vec<EnergyReset> = person_marks
            .iter()
            .map(|mark| EnergyReset {
                ts: mark.ts,
                kcal: mark.kcal,
            })
            .collect();
        let start = start_of(&mut conn, zone, person.id, window_start, burn).await?;
        let start_value = start.as_ref().map_or(0.0, |start| start.value);
        let curve = start.map(|start| {
            energy_curve(CurveInput {
                from: start.from,
                until,
                start_value: start.value,
                daily_burn: burn,
                foods: foods.get(&person.id).map(Vec::as_slice).unwrap_or_default(),
                workouts: workouts.get(&person.id).map(Vec::as_slice).unwrap_or_default(),
                resets: &resets,
            })
        });
        dtos.push(EnergyPersonDto {
            is_me: person.is_me,
            person_id: person.id,
            first_name: person.first_name,
            last_name: person.last_name,
            is_managed: person.is_managed,
            can_edit: person.can_edit,
            daily_burn,
            eaten: whole(curve.as_ref().map_or(0.0, |curve| curve.eaten)),
            burned_base: whole(curve.as_ref().map_or(0.0, |curve| curve.burned_base)),
            burned_workouts: whole(curve.as_ref().map_or(0.0, |curve| curve.burned_workouts)),
            start_kcal: whole(start_value),
            balance: whole(curve.as_ref().map_or(start_value, |curve| curve.value)),
            points: curve
                .map(|curve| {
                    curve
                        .points
                        .into_iter()
                        .map(|(ts, kcal)| EnergyPointDto { ts, kcal })
                        .collect()
                })
                .unwrap_or_default(),
            marks: person_marks,
        });
    }

    Ok(Json(EnergyDayDto {
        date: a_query.date,
        days,
        day_start: window_start,
        day_end: window_end,
        people: dtos,
    }))
}

pub async fn set_mark(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SetEnergyMarkRequest>,
) -> Result<(StatusCode, Json<EnergyMarkDto>), ApiError>
{
    let now = Utc::now();
    let ts = a_req
        .ts
        .duration_trunc(Duration::minutes(1))
        .map_err(|_| ApiError::Validation("ts"))?;
    if ts > now + Duration::minutes(MARK_FUTURE_MINUTES) || ts < now - Duration::days(MAX_PAST_DAYS)
    {
        return Err(ApiError::Validation("ts"));
    }
    let kcal = a_req.kcal.round_dp(1);
    if kcal.abs() > Decimal::from(MAX_MARK_KCAL)
    {
        return Err(ApiError::Validation("kcal"));
    }
    let mut tx = a_state.db.begin().await?;
    let person_id = acting_for(&mut tx, a_user.user_id, a_req.person_id).await?;
    let count = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM energy_marks WHERE user_id = $1"#,
        person_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if count >= MAX_MARKS_PER_PERSON
    {
        return Err(ApiError::Conflict("TOO_MANY_MARKS"));
    }
    let row = sqlx::query!(
        r#"
        INSERT INTO energy_marks (user_id, ts, kcal, set_by) VALUES ($1, $2, $3, $4)
        ON CONFLICT (user_id, ts) DO UPDATE SET kcal = EXCLUDED.kcal, set_by = EXCLUDED.set_by, created_ts = NOW()
        RETURNING id, ts, kcal::float8 AS "kcal!"
        "#,
        person_id,
        ts,
        kcal,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok((
        StatusCode::CREATED,
        Json(EnergyMarkDto {
            id: row.id,
            ts: row.ts,
            kcal: row.kcal,
        }),
    ))
}

pub async fn delete_mark(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let owner_id = sqlx::query_scalar!("SELECT user_id FROM energy_marks WHERE id = $1", a_id)
        .fetch_optional(&mut *conn)
        .await?
        .ok_or(ApiError::NotFound)?;
    require_editor(&mut conn, a_user.user_id, owner_id).await?;
    sqlx::query!("DELETE FROM energy_marks WHERE id = $1", a_id)
        .execute(&mut *conn)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

fn whole(a_value: f64) -> i64
{
    a_value.round() as i64
}
