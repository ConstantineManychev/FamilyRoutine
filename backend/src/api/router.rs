use crate::api::auth_handlers::{handle_user_login, handle_user_registration};
use axum::{
    http::{
        header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE},
        HeaderValue, Method,
    },
    routing::{get, post},
    Router,
};
use sqlx::PgPool;
use tower_http::cors::CorsLayer;

fn build_cors() -> CorsLayer {
    let origin = std::env::var("FRONTEND_URL")
        .unwrap_or_else(|_| "http://localhost:5173".into())
        .parse::<HeaderValue>()
        .expect("INVALID_ORIGIN");

    CorsLayer::new()
        .allow_origin(origin)
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::DELETE,
            Method::OPTIONS,
        ])
        .allow_headers([AUTHORIZATION, ACCEPT, CONTENT_TYPE])
        .allow_credentials(true)
}

async fn handle_health_check() -> &'static str {
    "API_IS_RUNNING"
}

pub fn configure_application_router(db: PgPool) -> Router {
    Router::new()
        .route("/", get(handle_health_check))
        .route("/api/auth/register", post(handle_user_registration))
        .route("/api/auth/login", post(handle_user_login))
        .layer(build_cors())
        .with_state(db)
}