use axum::extract::State;
use axum::Json;
use chrono::{Datelike, NaiveDate, Utc};
use shared_schema::{DictMetaDto, EnergyEventType, EnergyGraphQuery, EnergyNodeDto, MealSlot, Sex, UserDto};

use crate::api::extract::{ApiQuery, AuthUser};
use crate::domain::errors::ApiError;
use crate::services::nutrition::{bmr, slot_hour};
use crate::state::AppState;

const DEF_WEIGHT_KG: f64 = 75.0;
const DEF_HEIGHT_CM: f64 = 170.0;

pub async fn get_me(State(a_state): State<AppState>, a_user: AuthUser) -> Result<Json<UserDto>, ApiError>
{
    let user = sqlx::query_as!(
        UserDto,
        r#"SELECT id, email AS "email!", first_name, last_name FROM users WHERE id = $1"#,
        a_user.user_id
    )
    .fetch_optional(&a_state.db)
    .await?
    .ok_or(ApiError::Unauthenticated)?;

    Ok(Json(user))
}

pub async fn get_avail_dicts(_a_user: AuthUser) -> Json<Vec<DictMetaDto>>
{
    let dicts = [
        ("events", "dicts.events"),
        ("exercises", "dicts.exercises"),
        ("items", "dicts.items"),
    ]
    .into_iter()
    .map(|(id, name)| DictMetaDto {
        id: id.into(),
        name: name.into(),
    })
    .collect();

    Json(dicts)
}

pub fn age_on(a_birth_date: NaiveDate, a_date: NaiveDate) -> i32
{
    let mut age = a_date.year() - a_birth_date.year();
    if (a_date.month(), a_date.day()) < (a_birth_date.month(), a_birth_date.day())
    {
        age -= 1;
    }
    age.max(0)
}

pub async fn get_energy_timeline(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<EnergyGraphQuery>,
) -> Result<Json<Vec<EnergyNodeDto>>, ApiError>
{
    let profile = sqlx::query!(
        r#"
        SELECT
            u.birth_date,
            u.sex AS "sex: Sex",
            (
                SELECT v.value::float8 FROM body_values v JOIN body_entries e ON e.id = v.entry_id
                WHERE e.user_id = u.id AND v.metric = 'weight' ORDER BY e.measured_ts DESC LIMIT 1
            ) AS "weight_kg?",
            (
                SELECT v.value::float8 FROM body_values v JOIN body_entries e ON e.id = v.entry_id
                WHERE e.user_id = u.id AND v.metric = 'height' ORDER BY e.measured_ts DESC LIMIT 1
            ) AS "height_cm?"
        FROM users u
        WHERE u.id = $1
        "#,
        a_user.user_id
    )
    .fetch_optional(&a_state.db)
    .await?
    .ok_or(ApiError::NotFound)?;

    let age = f64::from(age_on(profile.birth_date, Utc::now().date_naive()));
    let is_male = profile.sex != Some(Sex::Female);
    let bmr_per_hour = bmr(
        is_male,
        profile.weight_kg.unwrap_or(DEF_WEIGHT_KG),
        profile.height_cm.unwrap_or(DEF_HEIGHT_CM),
        age,
    ) / 24.0;

    let day_start = a_query
        .target_date
        .and_hms_opt(0, 0, 0)
        .ok_or(ApiError::Validation("target_date"))?
        .and_utc();
    let day_end = day_start + chrono::Duration::days(1);

    let meals = sqlx::query!(
        r#"
        SELECT meal AS "meal: MealSlot", SUM(kcal)::float8 AS "kcal!"
        FROM meal_entries
        WHERE user_id = $1 AND eaten_on = $2
        GROUP BY meal
        "#,
        a_user.user_id,
        a_query.target_date
    )
    .fetch_all(&a_state.db)
    .await?;

    let workouts = sqlx::query!(
        r#"
        SELECT started_ts AS start_ts, COALESCE(kcal, 0)::float8 AS "kcal!"
        FROM workout_sessions
        WHERE user_id = $1 AND finished_ts IS NOT NULL AND started_ts >= $2 AND started_ts < $3
        "#,
        a_user.user_id,
        day_start,
        day_end
    )
    .fetch_all(&a_state.db)
    .await?;

    let mut nodes = Vec::with_capacity(24 + meals.len() + workouts.len());

    for hour in 0..24
    {
        nodes.push(EnergyNodeDto {
            ts: day_start + chrono::Duration::hours(hour),
            event_type: EnergyEventType::BmrBase,
            val: -bmr_per_hour,
            cum_val: 0.0,
        });
    }

    nodes.extend(meals.into_iter().map(|meal| EnergyNodeDto {
        ts: day_start + chrono::Duration::hours(slot_hour(meal.meal)),
        event_type: EnergyEventType::Meal,
        val: meal.kcal,
        cum_val: 0.0,
    }));

    nodes.extend(workouts.into_iter().map(|workout| EnergyNodeDto {
        ts: workout.start_ts,
        event_type: EnergyEventType::Workout,
        val: -workout.kcal,
        cum_val: 0.0,
    }));

    nodes.sort_by_key(|node| node.ts);

    let mut running_total = 0.0;
    for node in nodes.iter_mut()
    {
        running_total += node.val;
        node.cum_val = running_total;
    }

    Ok(Json(nodes))
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn age_accounts_for_birthday_not_yet_reached()
    {
        let birth = NaiveDate::from_ymd_opt(1990, 12, 31).unwrap();

        assert_eq!(age_on(birth, NaiveDate::from_ymd_opt(2026, 12, 30).unwrap()), 35);
        assert_eq!(age_on(birth, NaiveDate::from_ymd_opt(2026, 12, 31).unwrap()), 36);
    }
}
