use axum::extract::rejection::{JsonRejection, PathRejection, QueryRejection};
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;

#[derive(Debug)]
pub enum ApiError
{
    Validation(&'static str),
    Unauthenticated,
    InvalidCredentials,
    Forbidden,
    NotFound,
    Conflict(&'static str),
    TooManyRequests(u64),
    Internal(String),
}

impl ApiError
{
    pub fn internal(a_context: impl std::fmt::Display) -> Self
    {
        Self::Internal(a_context.to_string())
    }

    fn status_and_code(&self) -> (StatusCode, &'static str)
    {
        match self
        {
            Self::Validation(_) => (StatusCode::BAD_REQUEST, "VALIDATION"),
            Self::Unauthenticated => (StatusCode::UNAUTHORIZED, "UNAUTHENTICATED"),
            Self::InvalidCredentials => (StatusCode::UNAUTHORIZED, "INVALID_CREDENTIALS"),
            Self::Forbidden => (StatusCode::FORBIDDEN, "FORBIDDEN"),
            Self::NotFound => (StatusCode::NOT_FOUND, "NOT_FOUND"),
            Self::Conflict(code) => (StatusCode::CONFLICT, code),
            Self::TooManyRequests(_) => (StatusCode::TOO_MANY_REQUESTS, "TOO_MANY_REQUESTS"),
            Self::Internal(_) => (StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL"),
        }
    }
}

impl IntoResponse for ApiError
{
    fn into_response(self) -> Response
    {
        let (status, code) = self.status_and_code();

        let body = match &self
        {
            Self::Validation(field) => json!({ "code": code, "field": field }),
            Self::Internal(context) =>
            {
                tracing::error!("internal error: {context}");
                json!({ "code": code })
            }
            _ => json!({ "code": code }),
        };

        let mut response = (status, Json(body)).into_response();

        if let Self::TooManyRequests(retry_after) = self
        {
            if let Ok(value) = HeaderValue::from_str(&retry_after.to_string())
            {
                response.headers_mut().insert(header::RETRY_AFTER, value);
            }
        }

        response
    }
}

impl From<sqlx::Error> for ApiError
{
    fn from(a_err: sqlx::Error) -> Self
    {
        if let sqlx::Error::RowNotFound = a_err
        {
            return Self::NotFound;
        }

        if let sqlx::Error::Database(db_err) = &a_err
        {
            match db_err.code().as_deref()
            {
                Some("23505") => return Self::Conflict("ALREADY_EXISTS"),
                Some("23503") => return Self::Validation("reference"),
                Some("23514") => return Self::Validation("constraint"),
                Some("22001") => return Self::Validation("length"),
                _ =>
                {}
            }
        }

        Self::Internal(format!("database: {a_err}"))
    }
}

impl From<JsonRejection> for ApiError
{
    fn from(_: JsonRejection) -> Self
    {
        Self::Validation("body")
    }
}

impl From<PathRejection> for ApiError
{
    fn from(_: PathRejection) -> Self
    {
        Self::Validation("path")
    }
}

impl From<QueryRejection> for ApiError
{
    fn from(_: QueryRejection) -> Self
    {
        Self::Validation("query")
    }
}
