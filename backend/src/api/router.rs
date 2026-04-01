use crate::api::auth_handlers::{handle_user_login, handle_user_logout, handle_user_registration};
use crate::api::fam_handlers::{
    add_fam_member, create_fam, delete_fam, get_fam_details, leave_fam, remove_fam_member,
    update_fam_member, update_fam_name,
};
use axum::routing::put;
use crate::api::user_handlers::{get_avail_dicts, get_curr_user, get_user_fams};
use axum::{
    http::{
        header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE},
        HeaderName, HeaderValue, Method,
    },
    routing::{delete, get, post},
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
        .expose_headers([HeaderName::from_static("x-auth-token")])
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
        .route("/api/auth/logout", post(handle_user_logout))
        .route("/api/user/me", get(get_curr_user))
        .route("/api/dicts", get(get_avail_dicts))
        .route("/api/families", get(get_user_fams).post(create_fam))
        .route("/api/families/:id", get(get_fam_details).delete(delete_fam).put(update_fam_name))
        .route("/api/families/:id/leave", delete(leave_fam))
        .route("/api/families/:id/members", post(add_fam_member))
        .route("/api/families/:id/members/:user_id", put(update_fam_member).delete(remove_fam_member))
        .layer(build_cors())
        .with_state(db)
}