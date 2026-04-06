use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;

#[derive(Debug)]
pub enum ApiError {
    DatabaseError(sqlx::Error),
    Unauthorized,
    CannotLeaveLastAdmin,
    InvalidCredentials,
    ValidationError(String),
    NotFound,
    InternalServerError,
    UserAlreadyExists,
    HashError,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, error_message) = match self {
            ApiError::DatabaseError(_) | ApiError::InternalServerError | ApiError::HashError => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Internal Server Error".to_string(),
            ),
            ApiError::Unauthorized | ApiError::InvalidCredentials => (
                StatusCode::UNAUTHORIZED,
                "Unauthorized".to_string(),
            ),
            ApiError::CannotLeaveLastAdmin => (
                StatusCode::BAD_REQUEST,
                "Cannot leave as the last admin".to_string(),
            ),
            ApiError::ValidationError(msg) => (
                StatusCode::BAD_REQUEST,
                msg,
            ),
            ApiError::NotFound => (
                StatusCode::NOT_FOUND,
                "Resource not found".to_string(),
            ),
            ApiError::UserAlreadyExists => (
                StatusCode::CONFLICT,
                "User already exists".to_string(),
            ),
        };

        let body = Json(json!({
            "error": error_message,
        }));

        (status, body).into_response()
    }
}

impl From<sqlx::Error> for ApiError {
    fn from(err: sqlx::Error) -> Self {
        if let sqlx::Error::Database(db_err) = &err {
            if db_err.is_unique_violation() {
                return Self::UserAlreadyExists;
            }
        }
        ApiError::DatabaseError(err)
    }
}