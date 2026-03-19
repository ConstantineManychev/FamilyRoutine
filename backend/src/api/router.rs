use crate::api::auth_handlers::{handle_user_login, handle_user_registration};
use axum::{
    http::{HeaderValue, Method},
    routing::post,
    Router,
};
use sqlx::PgPool;
use tower_http::cors::{Any, CorsLayer};

fn create_cors_layer() -> CorsLayer {
    let allowed_frontend_origin = std::env::var("FRONTEND_URL")
        .unwrap_or_else(|_| "http://localhost:5173".to_string())
        .parse::<HeaderValue>()
        .expect("INVALID_FRONTEND_URL_FORMAT");

    CorsLayer::new()
        .allow_origin(allowed_frontend_origin)
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::DELETE,
            Method::OPTIONS,
        ])
        .allow_headers(Any)
        .allow_credentials(true)
}

pub fn configure_application_router(database_pool: PgPool) -> Router {
    let security_cors_layer = create_cors_layer();

    Router::new()
        .route("/api/auth/register", post(handle_user_registration))
        .route("/api/auth/login", post(handle_user_login))
        .layer(security_cors_layer)
        .with_state(database_pool)
}