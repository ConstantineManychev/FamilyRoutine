use crate::domain::errors::ApiError;
use crate::services::auth_service::{authenticate_user, register_new_user};
use axum::{extract::State, http::StatusCode, Json};
use serde_json::Value;
use shared_schema::{CreateUserRequest, LoginRequest, UserResponse};
use sqlx::PgPool;

pub async fn handle_user_registration(
    State(database_pool): State<PgPool>,
    Json(registration_payload): Json<CreateUserRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let registration_result = register_new_user(&database_pool, registration_payload).await?;
    Ok((StatusCode::CREATED, Json(registration_result)))
}

pub async fn handle_user_login(
    State(database_pool): State<PgPool>,
    Json(login_payload): Json<LoginRequest>,
) -> Result<(StatusCode, Json<UserResponse>), ApiError> {
    let authenticated_user_data = authenticate_user(&database_pool, login_payload).await?;
    Ok((StatusCode::OK, Json(authenticated_user_data)))
}

pub async fn handle_user_logout() -> StatusCode {
    StatusCode::OK
}