//! Domain rows and the JSON shapes the API speaks.
//!
//! A **Group** is one trip/leaderboard/trophy cycle, a **Member** is a person
//! in a group keyed by their phone number, and a **Place** is one of the group's
//! curated named locations (a house or landmark) with map coordinates.

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

// ----- places -----

/// A place row as stored in SQLite. Belongs to exactly one group.
#[derive(Debug, Clone)]
pub struct Place {
    pub id: String,
    pub group_id: String,
    pub name: String,
    pub lat: f64,
    pub lng: f64,
}

/// Public view of a place — the JSON shape returned to clients.
#[derive(Debug, Serialize)]
pub struct PlaceView {
    pub id: String,
    pub group_id: String,
    pub name: String,
    pub lat: f64,
    pub lng: f64,
}

impl From<&Place> for PlaceView {
    fn from(p: &Place) -> Self {
        PlaceView {
            id: p.id.clone(),
            group_id: p.group_id.clone(),
            name: p.name.clone(),
            lat: p.lat,
            lng: p.lng,
        }
    }
}

/// Create or move-and-rename a place. Used by both create and update: a create
/// takes all three, an update replaces the name and coordinates wholesale (the
/// admin can rename and/or drop the pin somewhere new in one edit).
#[derive(Debug, Deserialize)]
pub struct PlaceRequest {
    pub name: String,
    pub lat: f64,
    pub lng: f64,
}

/// Seed a group's places from another group's list — the "copy last year's
/// places" starting point, so the admin curates by editing rather than
/// re-entering everything. Thin version: copies every place from the source
/// group verbatim (new ids), leaving the source untouched.
#[derive(Debug, Deserialize)]
pub struct CopyPlacesRequest {
    /// The group to copy places from (e.g. last year's trip).
    pub from_group_id: String,
}

/// The group's curated places. Returned to any member, and echoed back after a
/// mutation so the client can refresh its list from a single response.
#[derive(Debug, Serialize)]
pub struct PlacesResponse {
    pub group_id: String,
    pub places: Vec<PlaceView>,
}
