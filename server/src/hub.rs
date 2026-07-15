//! In-memory fan-out of feed deltas: one broadcast channel per group.
//!
//! The write paths (create a ride, act on one) [`publish`](FeedHub::publish) a
//! delta to the group's channel; every open feed stream for that group is a
//! [`subscribe`](FeedHub::subscribe)r and receives it. Nothing is persisted here
//! — the stream is a live overlay on top of the REST feed, which stays the
//! source of truth — so a fresh process simply starts with no subscribers.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use axum::extract::FromRef;
use sqlx::SqlitePool;
use tokio::sync::broadcast;

use crate::models::FeedDelta;

/// How many yet-unread deltas a subscriber may fall behind before the channel
/// starts dropping the oldest ones for them. A subscriber that laps this isn't
/// lost: the stream turns the lag into a "resync" nudge and the client refetches
/// the whole board, so the buffer only has to absorb an ordinary burst.
const CHANNEL_CAPACITY: usize = 64;

/// The live-feed fan-out. Cheap to clone — it is an `Arc` around the per-group
/// channel map — so it lives in the router state and every handler shares one.
#[derive(Clone, Default)]
pub struct FeedHub {
    channels: Arc<Mutex<HashMap<String, broadcast::Sender<FeedDelta>>>>,
}

impl FeedHub {
    /// Subscribe to a group's deltas, creating the channel on the first listener
    /// for that group.
    pub fn subscribe(&self, group_id: &str) -> broadcast::Receiver<FeedDelta> {
        let mut channels = self.channels.lock().expect("feed hub mutex");
        channels
            .entry(group_id.to_string())
            .or_insert_with(|| broadcast::channel(CHANNEL_CAPACITY).0)
            .subscribe()
    }

    /// Publish a delta to every current subscriber of the group. If nobody is
    /// watching — no channel, or one with no receivers — it is a no-op: a client
    /// that connects later gets the current state from its REST refetch, not from
    /// a delta it was never around for.
    pub fn publish(&self, group_id: &str, delta: FeedDelta) {
        let channels = self.channels.lock().expect("feed hub mutex");
        if let Some(sender) = channels.get(group_id) {
            let _ = sender.send(delta);
        }
    }
}

/// The router state: the database pool plus the live-feed hub. Both are cheap to
/// clone (a pool handle and an `Arc`), and the `FromRef` impls let each handler
/// extract just the half it needs — existing handlers keep taking
/// `State<SqlitePool>`, the stream and the write paths reach for `State<FeedHub>`.
#[derive(Clone)]
pub struct AppState {
    pub pool: SqlitePool,
    pub hub: FeedHub,
}

impl AppState {
    pub fn new(pool: SqlitePool) -> Self {
        Self {
            pool,
            hub: FeedHub::default(),
        }
    }
}

impl FromRef<AppState> for SqlitePool {
    fn from_ref(state: &AppState) -> Self {
        state.pool.clone()
    }
}

impl FromRef<AppState> for FeedHub {
    fn from_ref(state: &AppState) -> Self {
        state.hub.clone()
    }
}
