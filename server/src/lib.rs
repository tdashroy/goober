//! Goober backend.
//!
//! Scope so far: create a group (creator = admin), join a group with name +
//! phone (re-attach by phone), bearer-token auth on every authenticated request,
//! the group's curated places, requesting a ride as a direct ping to a set of
//! members, the group-visible feed of those rides, the ride lifecycle the people
//! pinged drive — answering the ping, claiming the ride, arriving, delivering —
//! with every step audited, and a live SSE stream that pushes each of those feed
//! changes to open clients. Push and points come later.
//!
//! The app is built by [`build_app`] from a [`SqlitePool`], so tests can drive
//! the exact same router against a throwaway database without a live server.

pub mod auth;
pub mod db;
pub mod error;
pub mod hub;
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

use crate::hub::AppState;

/// Build the axum application. The router's state is an [`AppState`] — the
/// `SqlitePool` the [`CurrentMember`](crate::auth::CurrentMember) extractor reads
/// for auth, plus the [`FeedHub`](crate::hub::FeedHub) the write paths publish
/// feed deltas to and the SSE stream subscribes from.
pub fn build_app(pool: SqlitePool) -> Router {
    let app = Router::new()
        .route("/health", get(routes::health))
        .route("/groups", post(routes::create_group))
        .route("/groups/{group_id}/join", post(routes::join_group))
        .route("/groups/{group_id}/feed", get(routes::feed))
        .route("/groups/{group_id}/feed/stream", get(routes::feed_stream))
        .route("/groups/{group_id}/members", get(routes::roster))
        .route("/groups/{group_id}/rides", post(routes::create_ride))
        .route(
            "/groups/{group_id}/rides/{ride_id}/actions",
            post(routes::ride_action),
        )
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

    app.with_state(AppState::new(pool))
}
