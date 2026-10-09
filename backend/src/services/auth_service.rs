use shared_schema::{RegisterRequest, UserDto};
use uuid::Uuid;

use crate::domain::errors::ApiError;
use crate::domain::validation::{check_birth_date, check_password, clean_name, normalize_email};
use crate::state::AppState;

pub async fn register(a_state: &AppState, a_req: RegisterRequest) -> Result<Uuid, ApiError>
{
    let first_name = clean_name(&a_req.first_name, "first_name")?;
    let last_name = clean_name(&a_req.last_name, "last_name")?;
    let email = normalize_email(&a_req.email)?;
    check_password(&a_req.password)?;
    check_birth_date(a_req.birth_date)?;

    let password_hash = a_state.passwords.hash(a_req.password).await?;

    let user_id = sqlx::query_scalar!(
        r#"
        INSERT INTO users (first_name, last_name, email, username, password_hash, birth_date, is_pwd_peppered)
        VALUES ($1, $2, $3, $3, $4, $5, TRUE)
        RETURNING id
        "#,
        first_name,
        last_name,
        email,
        password_hash,
        a_req.birth_date
    )
    .fetch_one(&a_state.db)
    .await
    .map_err(|err| match ApiError::from(err)
    {
        ApiError::Conflict(_) => ApiError::Conflict("EMAIL_TAKEN"),
        other => other,
    })?;

    Ok(user_id)
}

pub async fn authenticate(a_state: &AppState, a_email: &str, a_password: String) -> Result<UserDto, ApiError>
{
    let Ok(email) = normalize_email(a_email)
    else
    {
        a_state.passwords.burn_time(a_password).await;
        return Err(ApiError::InvalidCredentials);
    };

    let row = sqlx::query!(
        "SELECT id, email, first_name, last_name, password_hash, is_pwd_peppered FROM users WHERE email = $1",
        email
    )
    .fetch_optional(&a_state.db)
    .await?;

    let Some(user) = row
    else
    {
        a_state.passwords.burn_time(a_password).await;
        return Err(ApiError::InvalidCredentials);
    };

    let is_valid = a_state
        .passwords
        .verify(a_password.clone(), user.password_hash, user.is_pwd_peppered)
        .await?;

    if !is_valid
    {
        return Err(ApiError::InvalidCredentials);
    }

    if !user.is_pwd_peppered
    {
        let upgraded_hash = a_state.passwords.hash(a_password).await?;
        sqlx::query!(
            "UPDATE users SET password_hash = $2, is_pwd_peppered = TRUE WHERE id = $1",
            user.id,
            upgraded_hash
        )
        .execute(&a_state.db)
        .await?;
    }

    Ok(UserDto {
        id: user.id,
        email: user.email,
        first_name: user.first_name,
        last_name: user.last_name,
    })
}
