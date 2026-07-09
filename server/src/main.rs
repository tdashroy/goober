//! Goober server binary. Runs locally over plain HTTP;
//! cloud deployment over HTTPS comes later.

use std::net::SocketAddr;

use goober_server::{build_app, db};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    // Where the SQLite file lives. Defaults to a file next to the binary's CWD.
    let database_url =
        std::env::var("DATABASE_URL").unwrap_or_else(|_| "sqlite://goober.db".to_string());
    // Bind address. Default binds all interfaces so the Android emulator can
    // reach the host at 10.0.2.2 during local dev.
    let bind: SocketAddr = std::env::var("GOOBER_BIND")
        .unwrap_or_else(|_| "0.0.0.0:8080".to_string())
        .parse()?;

    let pool = db::connect_and_migrate(&database_url).await?;
    let app = build_app(pool);

    let listener = tokio::net::TcpListener::bind(bind).await?;
    tracing::info!("goober-server listening on http://{bind} (db: {database_url})");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
    tracing::info!("shutting down");
}
