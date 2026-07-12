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
    load_seed_profile(&pool).await?;
    let app = build_app(pool);

    let listener = tokio::net::TcpListener::bind(bind).await?;
    tracing::info!("goober-server listening on http://{bind} (db: {database_url})");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

/// Load the named seed profile (`SEED_PROFILE=beach-trip`) into the database, so
/// the server boots with a ready-made group, members and places. No variable, no
/// seeding — the server comes up empty exactly as before.
///
/// Seeding hands out fixed bearer tokens for made-up people, so it only exists
/// in a `dev-seed` build. In any other build the whole seed module is compiled
/// out and this function cannot seed anything; it just says so and carries on,
/// which is what makes a stray `SEED_PROFILE` in a production environment inert
/// rather than dangerous.
#[cfg(feature = "dev-seed")]
async fn load_seed_profile(pool: &sqlx::SqlitePool) -> anyhow::Result<()> {
    let Ok(name) = std::env::var("SEED_PROFILE") else {
        return Ok(());
    };
    let name = name.trim();
    if name.is_empty() {
        return Ok(());
    }

    let profile = goober_server::seed::apply(pool, name).await?;
    tracing::info!(
        "seeded profile '{}': group '{}' with {} members and {} places",
        profile.key,
        profile.group_name,
        profile.members.len(),
        profile.places.len(),
    );
    Ok(())
}

#[cfg(not(feature = "dev-seed"))]
async fn load_seed_profile(_pool: &sqlx::SqlitePool) -> anyhow::Result<()> {
    if std::env::var_os("SEED_PROFILE").is_some() {
        tracing::warn!("SEED_PROFILE is set but this build has no seed profiles — ignoring it");
    }
    Ok(())
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
    tracing::info!("shutting down");
}
