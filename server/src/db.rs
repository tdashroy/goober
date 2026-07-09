//! Database pool setup and migrations.

use std::str::FromStr;

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::SqlitePool;

/// Migrations embedded at compile time from the `migrations/` directory, so the
/// binary can bring a fresh SQLite file up to schema on startup.
pub static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

/// Connect to SQLite at `database_url` (e.g. `sqlite://goober.db`), creating the
/// file if needed, and run migrations. Foreign keys are enforced.
pub async fn connect_and_migrate(database_url: &str) -> Result<SqlitePool, sqlx::Error> {
    let opts = SqliteConnectOptions::from_str(database_url)?
        .create_if_missing(true)
        .foreign_keys(true);

    let pool = SqlitePoolOptions::new().connect_with(opts).await?;
    MIGRATOR.run(&pool).await?;
    Ok(pool)
}

/// A fresh in-memory database with migrations applied. Used by tests so each run
/// starts from a clean, isolated schema with no files on disk.
pub async fn in_memory_pool() -> Result<SqlitePool, sqlx::Error> {
    let opts = SqliteConnectOptions::from_str("sqlite::memory:")?.foreign_keys(true);
    // A single connection keeps the in-memory DB alive for the pool's lifetime.
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(opts)
        .await?;
    MIGRATOR.run(&pool).await?;
    Ok(pool)
}
