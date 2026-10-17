use axum::extract::State;
use axum::Json;
use chrono::{Datelike, NaiveDate};
use shared_schema::{DictMetaDto, UserDto};

use crate::api::extract::AuthUser;
use crate::domain::errors::ApiError;
use crate::state::AppState;

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
