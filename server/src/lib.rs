//! Goober backend — walking skeleton.
//!
//! Scope: create a group (creator = admin), join a group with name + phone
//! (re-attach by phone), bearer-token auth on every authenticated request, and
//! an empty group feed the Flutter app renders. Rides/SSE/push/points come
//! later and are deliberately absent.
//!
//! The app is built by [`build_app`] from a [`SqlitePool`], so tests can drive
//! the exact same router against a throwaway database without a live server.

pub mod auth;
pub mod db;
pub mod error;
pub mod models;
pub mod routes;

use axum::routing::{get, post};
use axum::Router;
use sqlx::SqlitePool;

/// Build the axum application. The `SqlitePool` is the router's state, which the
/// [`CurrentMember`](crate::auth::CurrentMember) extractor reads for auth.
pub fn build_app(pool: SqlitePool) -> Router {
    Router::new()
        .route("/health", get(routes::health))
        .route("/groups", post(routes::create_group))
        .route("/groups/{group_id}/join", post(routes::join_group))
        .route("/groups/{group_id}/feed", get(routes::feed))
        .route("/me", get(routes::me))
        .with_state(pool)
}
