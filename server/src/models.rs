//! Domain rows and the JSON shapes the API speaks.
//!
//! A **Group** is one trip/leaderboard/trophy cycle, a **Member** is a person
//! in a group keyed by their phone number, a **Place** is one of the group's
//! curated named locations (a house or landmark) with map coordinates, and a
//! **Ride** is a passenger's request to be driven from one place to another.

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

/// The group activity feed: every ride in the group, newest first. Shared by the
/// whole group — spectating is half the fun — so anyone in the group sees the
/// same list.
#[derive(Debug, Serialize)]
pub struct FeedResponse {
    pub group_id: String,
    pub group_name: String,
    pub rides: Vec<RideView>,
}

/// One entry in the group roster. The roster is a group-visible surface, so —
/// like [`MemberRef`] on the feed — it carries no phone numbers; only your own
/// record (auth responses, `GET /me`) includes a phone.
#[derive(Debug, Serialize)]
pub struct RosterMember {
    pub id: String,
    pub display_name: String,
    pub is_admin: bool,
}

/// The group roster: everyone the passenger can ping for a ride.
#[derive(Debug, Serialize)]
pub struct RosterResponse {
    pub group_id: String,
    pub members: Vec<RosterMember>,
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

// ----- rides -----

/// Party size when the passenger doesn't say otherwise: "just me".
pub const DEFAULT_PARTY_SIZE: i64 = 1;

/// The most people one request can claim. Enforced in the handler rather than
/// the schema, so the cap can change without a migration.
pub const MAX_PARTY_SIZE: i64 = 8;

/// Ask for a ride from one curated place to another.
///
/// Timing is either **now** (`scheduled_for` absent/null) or a future time. The
/// request pings a **set** of members: `target_ids` names everyone being asked
/// to drive — one person, or a few.
#[derive(Debug, Deserialize)]
pub struct CreateRideRequest {
    /// Where the passenger is getting picked up — a place in their group.
    pub pickup_id: String,
    /// Where they're going — a different place in their group.
    pub dropoff_id: String,
    /// The members being pinged to drive: a set, with at least one in it. The
    /// passenger is not one of them, and naming the same person twice is a
    /// mistake rather than two pings.
    #[serde(default)]
    pub target_ids: Vec<String>,
    /// How many people are riding, including the passenger. An exact count:
    /// defaults to 1, capped at [`MAX_PARTY_SIZE`].
    #[serde(default = "default_party_size")]
    pub party_size: i64,
    /// Free-text thank-you — cookies, a favor, or cash. Optional; blank is None.
    #[serde(default)]
    pub offer: Option<String>,
    /// A future ISO-8601 time to be picked up at. Absent/null means "now".
    #[serde(default)]
    pub scheduled_for: Option<String>,
    /// Optionally, which other members are riding along. They are the party
    /// *besides* the passenger, so there can be at most `party_size - 1` of
    /// them, and nobody being pinged — they're being asked to drive — is one of
    /// them.
    #[serde(default)]
    pub party_member_ids: Vec<String>,
}

fn default_party_size() -> i64 {
    DEFAULT_PARTY_SIZE
}

/// A person as they appear inside a ride — just enough to show a name. The feed
/// is a public board, so it carries no phone numbers.
#[derive(Debug, Serialize)]
pub struct MemberRef {
    pub id: String,
    pub display_name: String,
}

/// A ride as the group's feed shows it: who asked, who was pinged, the route,
/// the party, the offer, and when it's wanted for.
#[derive(Debug, Serialize)]
pub struct RideView {
    pub id: String,
    pub group_id: String,
    /// `open` today; a driver accepting/arriving/delivering comes later.
    pub status: String,
    pub passenger: MemberRef,
    /// Everyone who was pinged, by name — always at least one. Sorted by name so
    /// the feed reads the same to everyone.
    pub targets: Vec<MemberRef>,
    pub pickup: PlaceView,
    pub dropoff: PlaceView,
    pub party_size: i64,
    /// The other riders the passenger tagged, if any. May be shorter than
    /// `party_size` — tagging is optional.
    pub party: Vec<MemberRef>,
    pub offer: Option<String>,
    /// `None` means "now"; otherwise the time the ride is wanted for.
    pub scheduled_for: Option<String>,
    pub created_at: String,
}
