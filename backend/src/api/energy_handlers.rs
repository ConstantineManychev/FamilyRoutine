use std::collections::HashMap;

use axum::extract::State;
use axum::Json;
use chrono::{Duration, NaiveTime, Utc};
use rust_decimal::prelude::ToPrimitive;
use shared_schema::{EnergyDayDto, EnergyDayQuery, EnergyPersonDto, EnergyPointDto};
use uuid::Uuid;

use crate::api::extract::{ApiQuery, AuthUser};
use crate::api::nutrition_handlers::load_norm;
use crate::api::profile_handlers::group_people;
use crate::domain::errors::ApiError;
use crate::services::energy::{energy_curve, FoodEvent, WorkoutSpan};
use crate::services::planner::{local_date, parse_zone, resolve_local};
use crate::state::AppState;

const MAX_PAST_DAYS: i64 = 400;

pub async fn energy_day(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<EnergyDayQuery>,
) -> Result<Json<EnergyDayDto>, ApiError>
{
    let zone = parse_zone(&a_query.tz).ok_or(ApiError::Validation("tz"))?;
    let now = Utc::now();
    let today = local_date(zone, now);
    if a_query.date > today + Duration::days(1) || a_query.date < today - Duration::days(MAX_PAST_DAYS)
    {
        return Err(ApiError::Validation("date"));
    }
    let day_start = resolve_local(zone, a_query.date, NaiveTime::MIN);
    let day_end = resolve_local(zone, a_query.date + Duration::days(1), NaiveTime::MIN);

    let mut conn = a_state.db.acquire().await?;
    let people = group_people(&mut conn, a_user.user_id).await?;
    let ids: Vec<Uuid> = people.iter().map(|person| person.id).collect();

    let mut foods: HashMap<Uuid, Vec<FoodEvent>> = HashMap::new();
    for row in sqlx::query!(
        r#"
        SELECT me.user_id, COALESCE(m.start_ts, me.created_ts) AS "ts!", me.kcal::float8 AS "kcal!"
        FROM meal_entries me
        LEFT JOIN status_marks m ON m.id = me.status_mark_id
        WHERE me.user_id = ANY($1) AND me.eaten_on = $2
        "#,
        &ids,
        a_query.date
    )
    .fetch_all(&mut *conn)
    .await?
    {
        foods.entry(row.user_id).or_default().push(FoodEvent {
            ts: row.ts,
            kcal: row.kcal,
        });
    }

    let mut workouts: HashMap<Uuid, Vec<WorkoutSpan>> = HashMap::new();
    for row in sqlx::query!(
        r#"
        SELECT user_id, started_ts, finished_ts AS "finished_ts!", kcal::float8 AS "kcal!"
        FROM workout_sessions
        WHERE user_id = ANY($1) AND finished_ts IS NOT NULL AND kcal IS NOT NULL
          AND started_ts < $3 AND finished_ts > $2
        "#,
        &ids,
        day_start,
        day_end
    )
    .fetch_all(&mut *conn)
    .await?
    {
        workouts.entry(row.user_id).or_default().push(WorkoutSpan {
            start: row.started_ts,
            end: row.finished_ts,
            kcal: row.kcal,
        });
    }

    let mut dtos = Vec::with_capacity(people.len());
    for person in people
    {
        let (norm, _) = load_norm(&mut conn, person.id, a_query.date, day_end).await?;
        let daily_burn = norm.and_then(|norm| norm.maintenance_kcal);
        let curve = energy_curve(
            day_start,
            day_end,
            now,
            daily_burn.and_then(|kcal| kcal.to_f64()),
            foods.get(&person.id).map(Vec::as_slice).unwrap_or_default(),
            workouts.get(&person.id).map(Vec::as_slice).unwrap_or_default(),
        );
        dtos.push(EnergyPersonDto {
            is_me: person.is_me,
            person_id: person.id,
            first_name: person.first_name,
            last_name: person.last_name,
            is_managed: person.is_managed,
            can_edit: person.can_edit,
            daily_burn,
            eaten: whole(curve.eaten),
            burned_base: whole(curve.burned_base),
            burned_workouts: whole(curve.burned_workouts),
            balance: whole(curve.balance()),
            points: curve
                .points
                .into_iter()
                .map(|(ts, kcal)| EnergyPointDto { ts, kcal })
                .collect(),
        });
    }

    Ok(Json(EnergyDayDto {
        date: a_query.date,
        day_start,
        day_end,
        people: dtos,
    }))
}

fn whole(a_value: f64) -> i64
{
    a_value.round() as i64
}
