mod api;
mod domain;
mod infrastructure;
mod services;

use crate::api::router::configure_application_router;
use crate::infrastructure::database::{establish_connection_pool, run_migrations};
use std::net::SocketAddr;
use tokio::net::TcpListener;

async fn initialize_application_environment() {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt::init();
}

#[tokio::main]
async fn main() {
    initialize_application_environment().await;

    let database_pool = establish_connection_pool().await;
    run_migrations(&database_pool).await;

    let application_router = configure_application_router(database_pool);

    let server_address = SocketAddr::from(([0, 0, 0, 0], 3000));
    tracing::info!("SERVER_INITIALIZED_AT_{}", server_address);

    let tcp_listener = TcpListener::bind(server_address).await.unwrap();
    
    axum::serve(tcp_listener, application_router).await.unwrap();
}