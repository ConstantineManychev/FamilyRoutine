use crate::domain::errors::ApiError;
use crate::services::password_manager::{generate_password_hash, verify_password_hash};
use serde_json::{json, Value};
use shared_schema::{CreateUserRequest, LoginRequest, UserResponse};
use sqlx::PgPool;

pub async fn register_new_user(
    database_pool: &PgPool,
    request_data: CreateUserRequest,
) -> Result<Value, ApiError> {
    let secured_password = generate_password_hash(&request_data.password)?;

    let database_record = sqlx::query!(
        r#"
        INSERT INTO users (first_name, last_name, email, password_hash, birth_date, username, is_verified)
        VALUES ($1, $2, $3, $4, $5, $3, FALSE)
        RETURNING id
        "#,
        request_data.first_name,
        request_data.last_name,
        request_data.email,
        secured_password,
        request_data.birth_date,
    )
    .fetch_one(database_pool)
    .await?;

    Ok(json!({
        "id": database_record.id,
        "message": "USER_REGISTERED_SUCCESSFULLY"
    }))
}

pub async fn authenticate_user(
    database_pool: &PgPool,
    request_data: LoginRequest,
) -> Result<UserResponse, ApiError> {
    let user_database_record = sqlx::query!(
        r#"
        SELECT id, email, password_hash, first_name, last_name, birth_date, created_at 
        FROM users 
        WHERE email = $1
        "#,
        request_data.email
    )
    .fetch_optional(database_pool)
    .await?
    .ok_or(ApiError::InvalidCredentials)?;

    verify_password_hash(&request_data.password, &user_database_record.password_hash)?;

    Ok(UserResponse {
        id: user_database_record.id,
        username: user_database_record.email.clone(),
        email: user_database_record.email,
        first_name: user_database_record.first_name,
        last_name: user_database_record.last_name,
        birth_date: user_database_record.birth_date,
        created_at: user_database_record.created_at,
    })
}