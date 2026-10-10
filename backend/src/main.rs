use std::net::SocketAddr;
use std::path::Path;
use std::time::Duration;

use backend::banking;
use backend::config::AppConfig;
use backend::infrastructure::database;
use backend::security::session;
use backend::{build_router, AppState};
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

const MAINTENANCE_PERIOD: Duration = Duration::from_secs(600);

#[tokio::main]
async fn main()
{
    let env_dir = dotenvy::dotenv()
        .ok()
        .and_then(|env_file| env_file.parent().map(Path::to_path_buf));

    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info,sqlx=warn")))
        .init();

    let cfg = match AppConfig::from_env(env_dir.as_deref())
    {
        Ok(cfg) => cfg,
        Err(err) =>
        {
            tracing::error!("configuration error: {err}");
            std::process::exit(1);
        }
    };

    let db = match database::connect(&cfg.database_url).await
    {
        Ok(db) => db,
        Err(err) =>
        {
            tracing::error!("database connection failed: {err}");
            std::process::exit(1);
        }
    };

    if let Err(err) = database::run_migrations(&db).await
    {
        tracing::error!("database migration failed: {err}");
        std::process::exit(1);
    }

    let bind_addr = cfg.bind_addr;
    let state = match AppState::new(db, cfg)
    {
        Ok(state) => state,
        Err(err) =>
        {
            tracing::error!("startup failed: {err}");
            std::process::exit(1);
        }
    };

    spawn_maintenance(state.clone());
    banking::sync::spawn(state.clone());

    let listener = match TcpListener::bind(bind_addr).await
    {
        Ok(listener) => listener,
        Err(err) =>
        {
            tracing::error!("failed to bind {bind_addr}: {err}");
            std::process::exit(1);
        }
    };

    tracing::info!("listening on {bind_addr}");

    let app = build_router(state).into_make_service_with_connect_info::<SocketAddr>();

    if let Err(err) = axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
    {
        tracing::error!("server error: {err}");
        std::process::exit(1);
    }
}

fn spawn_maintenance(a_state: AppState)
{
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(MAINTENANCE_PERIOD);
        loop
        {
            ticker.tick().await;
            if let Err(err) = session::purge_expired(&a_state.db).await
            {
                tracing::warn!("session purge failed: {err:?}");
            }
            a_state.limiter.purge();
        }
    });
}

async fn shutdown_signal()
{
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };

    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut signal) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            signal.recv().await;
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
}
