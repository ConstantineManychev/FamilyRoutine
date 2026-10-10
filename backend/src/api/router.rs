use std::time::Duration;

use axum::extract::DefaultBodyLimit;
use axum::http::header::{ACCEPT, AUTHORIZATION, CACHE_CONTROL, CONTENT_TYPE};
use axum::http::{HeaderName, HeaderValue, Method};
use axum::routing::{get, post, put};
use axum::Router;
use tower_http::cors::CorsLayer;
use tower_http::set_header::SetResponseHeaderLayer;
use tower_http::timeout::TimeoutLayer;
use tower_http::trace::TraceLayer;

use crate::api::{
    auth_handlers, bank_handlers, ex_handlers, fam_handlers, geo_handlers, item_handlers, place_handlers,
    receipt_handlers, stats_handlers, tx_handlers, user_handlers, wallet_handlers,
};
use crate::domain::errors::ApiError;
use crate::security::session::CSRF_HEADER;
use crate::state::AppState;

const MAX_BODY_BYTES: usize = 64 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

pub fn build_router(a_state: AppState) -> Router
{
    let api = Router::new()
        .route("/auth/register", post(auth_handlers::register))
        .route("/auth/login", post(auth_handlers::login))
        .route("/auth/logout", post(auth_handlers::logout))
        .route("/auth/logout-all", post(auth_handlers::logout_all))
        .route("/user/me", get(user_handlers::get_me))
        .route("/user/energy-timeline", get(user_handlers::get_energy_timeline))
        .route("/dicts", get(user_handlers::get_avail_dicts))
        .route(
            "/dicts/exercises",
            get(ex_handlers::list_exercises).post(ex_handlers::create_exercise),
        )
        .route(
            "/dicts/exercises/:id",
            get(ex_handlers::get_exercise)
                .put(ex_handlers::update_exercise)
                .delete(ex_handlers::delete_exercise),
        )
        .route(
            "/dicts/items",
            get(item_handlers::list_items).post(item_handlers::create_item),
        )
        .route(
            "/dicts/items/:id",
            get(item_handlers::get_item)
                .put(item_handlers::update_item)
                .delete(item_handlers::delete_item),
        )
        .route("/dicts/items/:id/prices", get(item_handlers::item_prices))
        .route(
            "/families",
            get(fam_handlers::list_families).post(fam_handlers::create_family),
        )
        .route(
            "/families/:id",
            get(fam_handlers::get_family)
                .put(fam_handlers::rename_family)
                .delete(fam_handlers::delete_family),
        )
        .route("/families/:id/leave", post(fam_handlers::leave_family))
        .route("/families/:id/transfer", post(fam_handlers::transfer_ownership))
        .route(
            "/families/:id/members/:user_id",
            put(fam_handlers::update_member_role).delete(fam_handlers::remove_member),
        )
        .route(
            "/families/:id/invites",
            get(fam_handlers::list_family_invites).post(fam_handlers::create_invite),
        )
        .route(
            "/families/:id/invites/:invite_id",
            axum::routing::delete(fam_handlers::revoke_family_invite),
        )
        .route("/invites/accept", post(fam_handlers::accept_invite))
        .route("/currencies", get(wallet_handlers::list_currencies))
        .route("/banks/connections", get(bank_handlers::list_connections))
        .route(
            "/banks/connections/:id",
            axum::routing::delete(bank_handlers::delete_connection),
        )
        .route("/banks/connections/:id/sync", post(bank_handlers::request_sync))
        .route("/banks/monobank", post(bank_handlers::connect_monobank))
        .route("/banks/enable-banking/aspsps", get(bank_handlers::list_aspsps))
        .route("/banks/enable-banking/start", post(bank_handlers::start_bank_auth))
        .route(
            "/banks/enable-banking/complete",
            post(bank_handlers::complete_bank_auth),
        )
        .route(
            "/transactions",
            get(tx_handlers::list_transactions).post(tx_handlers::create_transaction),
        )
        .route(
            "/transactions/:id",
            put(tx_handlers::update_transaction).delete(tx_handlers::delete_transaction),
        )
        .route("/transfers", post(tx_handlers::create_transfer))
        .route("/transfers/:id", axum::routing::delete(tx_handlers::delete_transfer))
        .route("/merchants", get(tx_handlers::list_merchants))
        .route(
            "/receipts",
            get(receipt_handlers::list_receipts).post(receipt_handlers::create_receipt),
        )
        .route(
            "/receipts/:id",
            get(receipt_handlers::get_receipt)
                .put(receipt_handlers::update_receipt)
                .delete(receipt_handlers::delete_receipt),
        )
        .route("/stats/cashflow", get(stats_handlers::cashflow))
        .route("/stats/categories", get(stats_handlers::categories))
        .route(
            "/wallets",
            get(wallet_handlers::list_wallets).post(wallet_handlers::create_wallet),
        )
        .route(
            "/wallets/:id",
            get(wallet_handlers::get_wallet)
                .put(wallet_handlers::update_wallet)
                .delete(wallet_handlers::delete_wallet),
        )
        .route("/wallets/:id/archive", put(wallet_handlers::archive_wallet))
        .route("/geo/countries", get(geo_handlers::list_countries))
        .route(
            "/geo/countries/:id/cities",
            get(geo_handlers::list_cities).post(geo_handlers::create_city),
        )
        .route(
            "/geo/cities/:id",
            put(geo_handlers::update_city).delete(geo_handlers::delete_city),
        )
        .route(
            "/geo/cities/:id/streets",
            get(geo_handlers::list_streets).post(geo_handlers::create_street),
        )
        .route(
            "/geo/streets/:id",
            put(geo_handlers::update_street).delete(geo_handlers::delete_street),
        )
        .route(
            "/places",
            get(place_handlers::list_places).post(place_handlers::create_place),
        )
        .route(
            "/places/:id",
            get(place_handlers::get_place)
                .put(place_handlers::update_place)
                .delete(place_handlers::delete_place),
        )
        .fallback(|| async { ApiError::NotFound });

    let router = Router::new()
        .route("/", get(|| async { "FamilyRoutine API" }))
        .route("/health", get(|| async { "ok" }))
        .nest("/api", api)
        .fallback(|| async { ApiError::NotFound })
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
        .layer(TimeoutLayer::new(REQUEST_TIMEOUT))
        .layer(SetResponseHeaderLayer::overriding(
            CACHE_CONTROL,
            HeaderValue::from_static("no-store"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            HeaderName::from_static("x-content-type-options"),
            HeaderValue::from_static("nosniff"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            HeaderName::from_static("x-frame-options"),
            HeaderValue::from_static("DENY"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            HeaderName::from_static("referrer-policy"),
            HeaderValue::from_static("no-referrer"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            HeaderName::from_static("content-security-policy"),
            HeaderValue::from_static("default-src 'none'; frame-ancestors 'none'"),
        ));

    let router = if a_state.cfg.is_cookie_secure
    {
        router.layer(SetResponseHeaderLayer::overriding(
            HeaderName::from_static("strict-transport-security"),
            HeaderValue::from_static("max-age=31536000; includeSubDomains"),
        ))
    }
    else
    {
        router
    };

    let router = match build_cors(&a_state)
    {
        Some(cors) => router.layer(cors),
        None => router,
    };

    router.layer(TraceLayer::new_for_http()).with_state(a_state)
}

fn build_cors(a_state: &AppState) -> Option<CorsLayer>
{
    if a_state.cfg.allowed_origins.is_empty()
    {
        return None;
    }

    Some(
        CorsLayer::new()
            .allow_origin(a_state.cfg.allowed_origins.clone())
            .allow_methods([Method::GET, Method::POST, Method::PUT, Method::DELETE])
            .allow_headers([
                AUTHORIZATION,
                ACCEPT,
                CONTENT_TYPE,
                HeaderName::from_static(CSRF_HEADER),
            ])
            .allow_credentials(true)
            .max_age(Duration::from_secs(600)),
    )
}
