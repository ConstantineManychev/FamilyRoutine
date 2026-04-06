use crate::api::auth_handlers::{handle_user_login, handle_user_logout, handle_user_registration};
use crate::api::fam_handlers::{
    add_fam_member, create_fam, delete_fam, get_fam_budget, get_fam_details, get_fam_timeline,
    leave_fam, remove_fam_member, update_fam_member, update_fam_name,
};
use crate::api::geo_handlers::{
    create_city, create_street, delete_city, delete_street, get_cities, get_countries, get_streets,
    update_city, update_street,
};
use crate::api::place_handlers::{
    create_place, delete_place, get_place_detail, get_places, update_place,
};
use crate::api::user_handlers::{get_avail_dicts, get_curr_user, get_energy_timeline, get_user_fams};
use crate::api::wallet_handlers::{
    archive_wallet, create_wallet, delete_wallet, get_currencies, get_wallet_detail, get_wallets,
    update_wallet,
};
use axum::{
    http::{
        header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE},
        HeaderName, HeaderValue, Method,
    },
    routing::{delete, get, post, put},
    Router,
};
use sqlx::PgPool;
use tower_http::cors::CorsLayer;
use crate::api::ex_handlers::{create_ex, delete_ex, get_ex_detail, get_exs, update_ex};


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
        .route("/api/users/:id/energy-timeline", get(get_energy_timeline))
        .route("/api/dicts", get(get_avail_dicts))
        .route("/api/dicts/exercises", get(get_exs).post(create_ex))
        .route("/api/dicts/exercises/:id", get(get_ex_detail).put(update_ex).delete(delete_ex))
        .route("/api/families", get(get_user_fams).post(create_fam))
        .route("/api/families/:id", get(get_fam_details).delete(delete_fam).put(update_fam_name))
        .route("/api/families/:id/leave", delete(leave_fam))
        .route("/api/families/:id/members", post(add_fam_member))
        .route("/api/families/:id/members/:user_id", put(update_fam_member).delete(remove_fam_member))
        .route("/api/families/:id/budget", get(get_fam_budget))
        .route("/api/families/:id/timeline", get(get_fam_timeline))
        .route("/api/currencies", get(get_currencies))
        .route("/api/wallets", get(get_wallets).post(create_wallet))
        .route("/api/wallets/:id", get(get_wallet_detail).put(update_wallet).delete(delete_wallet))
        .route("/api/wallets/:id/archive", put(archive_wallet))
        .route("/api/geo/countries", get(get_countries))
        .route("/api/geo/countries/:id/cities", get(get_cities).post(create_city))
        .route("/api/geo/cities/:id", put(update_city).delete(delete_city))
        .route("/api/geo/cities/:id/streets", get(get_streets).post(create_street))
        .route("/api/geo/streets/:id", put(update_street).delete(delete_street))
        .route("/api/places", get(get_places).post(create_place))
        .route("/api/exercises", get(get_exs).post(create_ex))
        .route("/api/exercises/:id", get(get_ex_detail).put(update_ex).delete(delete_ex))
        .route("/api/places/:id", get(get_place_detail).put(update_place).delete(delete_place))
        .layer(build_cors())
        .with_state(db)
}