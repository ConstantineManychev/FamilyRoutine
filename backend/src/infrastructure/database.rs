use sqlx::postgres::{PgPool, PgPoolOptions};
use std::env;

pub async fn establish_connection_pool() -> PgPool {
    let database_url = env::var("DATABASE_URL").expect("DATABASE_URL_ENVIRONMENT_VARIABLE_NOT_FOUND");
    
    PgPoolOptions::new()
        .max_connections(5)
        .connect(&database_url)
        .await
        .expect("DATABASE_CONNECTION_POOL_CREATION_FAILED")
}

pub async fn run_migrations(database_pool: &PgPool) {
    sqlx::migrate!("./migrations")
        .run(database_pool)
        .await
        .expect("DATABASE_MIGRATION_EXECUTION_FAILED");
}