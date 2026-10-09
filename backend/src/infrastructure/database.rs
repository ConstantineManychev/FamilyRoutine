use std::time::Duration;

use sqlx::migrate::Migrator;
use sqlx::postgres::{PgPool, PgPoolOptions};

pub static MIGRATOR: Migrator = sqlx::migrate!("./migrations");

const LEGACY_BASELINE_VERSION: i64 = 1;

pub async fn connect(a_database_url: &str) -> Result<PgPool, sqlx::Error>
{
    PgPoolOptions::new()
        .max_connections(10)
        .acquire_timeout(Duration::from_secs(5))
        .connect(a_database_url)
        .await
}

pub async fn run_migrations(a_db: &PgPool) -> Result<(), sqlx::Error>
{
    baseline_legacy_schema(a_db).await?;
    MIGRATOR.run(a_db).await?;
    Ok(())
}

async fn baseline_legacy_schema(a_db: &PgPool) -> Result<(), sqlx::Error>
{
    let is_legacy_schema = sqlx::query_scalar::<_, bool>(
        "SELECT to_regclass('public.users') IS NOT NULL AND to_regclass('public._sqlx_migrations') IS NULL",
    )
    .fetch_one(a_db)
    .await?;

    if !is_legacy_schema
    {
        return Ok(());
    }

    let Some(baseline) = MIGRATOR
        .iter()
        .find(|migration| migration.version == LEGACY_BASELINE_VERSION)
    else
    {
        return Ok(());
    };

    tracing::warn!(
        "existing schema without migration history detected, recording migration {LEGACY_BASELINE_VERSION} as applied"
    );

    let mut tx = a_db.begin().await?;

    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS _sqlx_migrations (
            version BIGINT PRIMARY KEY,
            description TEXT NOT NULL,
            installed_on TIMESTAMPTZ NOT NULL DEFAULT now(),
            success BOOLEAN NOT NULL,
            checksum BYTEA NOT NULL,
            execution_time BIGINT NOT NULL
        )
        "#,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        "INSERT INTO _sqlx_migrations (version, description, success, checksum, execution_time) VALUES ($1, $2, TRUE, $3, 0)",
    )
    .bind(baseline.version)
    .bind(baseline.description.as_ref())
    .bind(baseline.checksum.as_ref())
    .execute(&mut *tx)
    .await?;

    tx.commit().await
}
