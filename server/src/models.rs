//! Domain rows and the JSON shapes the API speaks.
//!
//! A **Group** is one trip/leaderboard/trophy cycle, a **Member** is a person
//! in a group keyed by their phone number.

use serde::{Deserialize, Serialize};

/// A member row as stored in SQLite. `is_admin` is an INTEGER in SQLite; we
/// expose it as a bool at the edges.
#[derive(Debug, Clone)]
pub struct Member {
    pub id: String,
    pub group_id: String,
    pub phone: String,
    pub display_name: String,
    pub token: String,
    pub is_admin: bool,
}

/// Public view of a member (never includes the bearer token).
#[derive(Debug, Serialize)]
pub struct MemberView {
    pub id: String,
    pub group_id: String,
    pub display_name: String,
    pub phone: String,
    pub is_admin: bool,
}

impl From<&Member> for MemberView {
    fn from(m: &Member) -> Self {
        MemberView {
            id: m.id.clone(),
            group_id: m.group_id.clone(),
            display_name: m.display_name.clone(),
            phone: m.phone.clone(),
            is_admin: m.is_admin,
        }
    }
}

// ----- request bodies -----

/// Create a new group. The caller becomes the group's admin.
#[derive(Debug, Deserialize)]
pub struct CreateGroupRequest {
    /// Trip name, e.g. "Beach 2027".
    pub group_name: String,
    /// The creator's display name.
    pub name: String,
    /// The creator's phone number — their durable identity key.
    pub phone: String,
}

/// Join an existing group. Re-joining with the same phone re-attaches identity.
#[derive(Debug, Deserialize)]
pub struct JoinGroupRequest {
    pub name: String,
    pub phone: String,
}

// ----- response bodies -----

/// Returned by both create-group and join-group: the bearer token the app
/// persists, plus who/where the caller now is.
#[derive(Debug, Serialize)]
pub struct AuthResponse {
    /// Random bearer token — send as `Authorization: Bearer <token>` from here on.
    pub token: String,
    pub group_id: String,
    pub group_name: String,
    pub member: MemberView,
}

/// The group activity feed. Empty in the walking skeleton — rides come later
/// — but the shape is here so the app can render its empty state.
#[derive(Debug, Serialize)]
pub struct FeedResponse {
    pub group_id: String,
    pub group_name: String,
    pub rides: Vec<serde_json::Value>,
}
