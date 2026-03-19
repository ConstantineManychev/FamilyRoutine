use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;

#[derive(Debug)]
pub enum ApiError {
    InternalServerError,
    DatabaseError(sqlx::Error),
    HashError,
    InvalidCredentials,
    UserAlreadyExists,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status_code, error_code) = match self {
            Self::InternalServerError => (StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL_SERVER_ERROR"),
            Self::DatabaseError(_) => (StatusCode::INTERNAL_SERVER_ERROR, "DATABASE_ERROR"),
            Self::HashError => (StatusCode::INTERNAL_SERVER_ERROR, "PASSWORD_HASH_ERROR"),
            Self::InvalidCredentials => (StatusCode::UNAUTHORIZED, "INVALID_CREDENTIALS"),
            Self::UserAlreadyExists => (StatusCode::BAD_REQUEST, "USER_ALREADY_EXISTS"),
        };

        let response_body = Json(json!({ "error": error_code }));
        (status_code, response_body).into_response()
    }
}

impl From<sqlx::Error> for ApiError {
    fn from(database_error: sqlx::Error) -> Self {
        if let sqlx::Error::Database(specific_database_error) = &database_error {
            if specific_database_error.is_unique_violation() {
                return Self::UserAlreadyExists;
            }
        }
        Self::DatabaseError(database_error)
    }
}