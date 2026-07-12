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

/// Dev-only seed profiles and the sign-in-as-a-seeded-person route they enable.
/// Compiled in only under the `dev-seed` feature, which is off by default — a
/// production build contains none of it.
#[cfg(feature = "dev-seed")]
pub mod seed;

use axum::routing::{get, post, put};
use axum::Router;
use sqlx::SqlitePool;

/// Build the axum application. The `SqlitePool` is the router's state, which the
/// [`CurrentMember`](crate::auth::CurrentMember) extractor reads for auth.
pub fn build_app(pool: SqlitePool) -> Router {
    let app = Router::new()
        .route("/health", get(routes::health))
        .route("/groups", post(routes::create_group))
        .route("/groups/{group_id}/join", post(routes::join_group))
        .route("/groups/{group_id}/feed", get(routes::feed))
        .route(
            "/groups/{group_id}/places",
            get(routes::list_places).post(routes::create_place),
        )
        .route("/groups/{group_id}/places/copy", post(routes::copy_places))
        .route(
            "/groups/{group_id}/places/{place_id}",
            put(routes::update_place).delete(routes::delete_place),
        )
        .route("/me", get(routes::me));

    // The dev sign-in route exists only in a dev-seed build; there is no URL to
    // call in a production binary.
    #[cfg(feature = "dev-seed")]
    let app = app.route("/dev/session/{member_key}", get(seed::dev_session));

    app.with_state(pool)
}
