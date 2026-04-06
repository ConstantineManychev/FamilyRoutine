pub mod api;
pub mod domain;
pub mod infrastructure;
pub mod services;

use crate::api::router::configure_application_router;
use dotenvy::dotenv;
use sqlx::postgres::PgPoolOptions;
use tokio::net::TcpListener;

#[tokio::main]
async fn main() {
    dotenv().ok();

    let db_url = std::env::var("DATABASE_URL").expect("DATABASE_URL not found in .env");

    let db_pool = PgPoolOptions::new()
        .max_connections(5)
        .connect(&db_url)
        .await
        .expect("Failed to connect to Postgres");

    let app_router = configure_application_router(db_pool);

    let addr = "0.0.0.0:3000";
    let listener = TcpListener::bind(addr).await.expect("Failed to bind TCP listener");
    
    axum::serve(listener, app_router)
        .await
        .expect("Failed to serve application");
}