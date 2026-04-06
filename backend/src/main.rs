mod api;
mod domain;
mod infrastructure;
mod services;

use crate::api::router::configure_application_router;
use crate::infrastructure::database::{establish_connection_pool, run_migrations};
use std::net::SocketAddr;
use tokio::net::TcpListener;

async fn init_env() {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt::init();
}

#[tokio::main]
async fn main() {
    init_env().await;

    let db_pool = establish_connection_pool().await;
    run_migrations(&db_pool).await;

    let app_router = configure_application_router(db_pool);
    let addr = SocketAddr::from(([0, 0, 0, 0], 3000));
    
    tracing::info!("SERVER_INITIALIZED_AT_{}", addr);

    let listener = TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app_router).await.unwrap();
}