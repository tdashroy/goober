//! Dev-only seed profiles: named, ready-made worlds the server can load at boot.
//!
//! A profile is a group, its members, and its places, all with **fixed** ids and
//! bearer tokens. Fixed identities are the point: a client can be pointed at a
//! seeded person by name (`bob`) and sign in as them without anyone typing a
//! phone number, which is what makes a two-emulator, two-user session a single
//! command.
//!
//! Seeding is **idempotent** — every row is written by its stable id with an
//! upsert, so booting against an already-seeded database refreshes the world in
//! place instead of duplicating it.
//!
//! # Why this can never ship
//!
//! This module hands out valid bearer tokens for made-up people, so it exists
//! only when the crate is compiled with the `dev-seed` feature. The feature is
//! off by default: a production build has no seed data, no `dev_token`, and no
//! `/dev/session` route compiled into the binary at all — `SEED_PROFILE` is
//! inert there. `docker/server.Dockerfile` only turns the feature on when the
//! dev stack passes `SERVER_FEATURES=dev-seed` as a build argument.

use axum::extract::{Path, State};
use axum::Json;
use sqlx::SqlitePool;

use crate::error::{AppError, AppResult};
use crate::models::{AuthResponse, Member, MemberView};

/// A seeded person. `key` is the short handle a client profile names
/// (`CLIENT_PROFILE=bob`) and is what their fixed token is derived from, so it
/// must be unique across every profile.
#[derive(Debug)]
pub struct SeedMember {
    pub key: &'static str,
    pub display_name: &'static str,
    pub phone: &'static str,
    pub is_admin: bool,
}

/// A seeded place — a house or a landmark, with the coordinates an admin would
/// have dropped a pin on.
#[derive(Debug)]
pub struct SeedPlace {
    pub key: &'static str,
    pub name: &'static str,
    pub lat: f64,
    pub lng: f64,
}

/// A named world: one group, its members, its places. `key` doubles as the
/// group's id, so the group a profile creates is addressable by name too.
#[derive(Debug)]
pub struct SeedProfile {
    pub key: &'static str,
    pub group_name: &'static str,
    pub members: &'static [SeedMember],
    pub places: &'static [SeedPlace],
}

/// The family beach trip: a grandmother running the trip as admin, three
/// relatives along for the ride, and the handful of places everyone actually
/// goes. Coordinates sit on a real stretch of barrier-island coast so the places
/// spread out sensibly on a map.
const BEACH_TRIP: SeedProfile = SeedProfile {
    key: "beach-trip",
    group_name: "Beach 2027",
    members: &[
        SeedMember {
            key: "grandma",
            display_name: "Grandma Jo",
            phone: "+15550100001",
            is_admin: true,
        },
        SeedMember {
            key: "bob",
            display_name: "Uncle Bob",
            phone: "+15550100002",
            is_admin: false,
        },
        SeedMember {
            key: "jen",
            display_name: "Cousin Jen",
            phone: "+15550100003",
            is_admin: false,
        },
        SeedMember {
            key: "pete",
            display_name: "Pete (teenager, drives)",
            phone: "+15550100004",
            is_admin: false,
        },
    ],
    places: &[
        SeedPlace {
            key: "grandmas",
            name: "Grandma's",
            lat: 34.6646,
            lng: -77.0603,
        },
        SeedPlace {
            key: "blue-house",
            name: "The Blue House",
            lat: 34.6671,
            lng: -77.0668,
        },
        SeedPlace {
            key: "pier",
            name: "The Pier",
            lat: 34.6598,
            lng: -77.0521,
        },
        SeedPlace {
            key: "ice-cream-shack",
            name: "Ice Cream Shack",
            lat: 34.6702,
            lng: -77.0742,
        },
    ],
};

/// Every profile the server knows how to seed.
pub const PROFILES: &[&SeedProfile] = &[&BEACH_TRIP];

/// Look up a profile by name (the value of `SEED_PROFILE`).
pub fn profile(name: &str) -> Option<&'static SeedProfile> {
    PROFILES.iter().copied().find(|p| p.key == name)
}

/// The fixed bearer token a seeded person holds. Deriving it from the member key
/// rather than storing it anywhere is what lets a client ask for "bob" and get a
/// working session without the two sides sharing a config file.
pub fn dev_token(member_key: &str) -> String {
    format!("devseed-{member_key}")
}

#[derive(Debug, thiserror::Error)]
pub enum SeedError {
    #[error("unknown seed profile '{0}' (known: {known})", known = known_profiles())]
    UnknownProfile(String),
    #[error(transparent)]
    Db(#[from] sqlx::Error),
}

fn known_profiles() -> String {
    PROFILES
        .iter()
        .map(|p| p.key)
        .collect::<Vec<_>>()
        .join(", ")
}

/// Load `profile_name` into the database, creating the group, its members (each
/// with their fixed token) and its places.
///
/// Safe to run on every boot: each row is written by its stable id, so a second
/// run overwrites the same rows rather than adding new ones, and members keep
/// the tokens any running client already holds.
pub async fn apply(
    pool: &SqlitePool,
    profile_name: &str,
) -> Result<&'static SeedProfile, SeedError> {
    let profile =
        profile(profile_name).ok_or_else(|| SeedError::UnknownProfile(profile_name.to_string()))?;

    // One transaction, so a seeded world is never half-visible to a client that
    // is already polling the server.
    let mut tx = pool.begin().await?;

    let group_id = profile.key;
    sqlx::query!(
        r#"
        INSERT INTO groups (id, name, created_by) VALUES (?, ?, NULL)
        ON CONFLICT (id) DO UPDATE SET name = excluded.name
        "#,
        group_id,
        profile.group_name,
    )
    .execute(&mut *tx)
    .await?;

    for member in profile.members {
        let id = member_id(profile, member.key);
        let token = dev_token(member.key);
        let is_admin = i64::from(member.is_admin);
        sqlx::query!(
            r#"
            INSERT INTO members (id, group_id, phone, display_name, token, is_admin)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET
                phone = excluded.phone,
                display_name = excluded.display_name,
                token = excluded.token,
                is_admin = excluded.is_admin
            "#,
            id,
            group_id,
            member.phone,
            member.display_name,
            token,
            is_admin,
        )
        .execute(&mut *tx)
        .await?;
    }

    // Point the group at its admin, mirroring what create-group does for a real
    // group. The first admin in the profile is the one who "created" the trip.
    if let Some(admin) = profile.members.iter().find(|m| m.is_admin) {
        let admin_id = member_id(profile, admin.key);
        sqlx::query!(
            "UPDATE groups SET created_by = ? WHERE id = ?",
            admin_id,
            group_id,
        )
        .execute(&mut *tx)
        .await?;
    }

    for place in profile.places {
        let id = format!("{}-{}", profile.key, place.key);
        sqlx::query!(
            r#"
            INSERT INTO places (id, group_id, name, lat, lng) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET
                name = excluded.name,
                lat = excluded.lat,
                lng = excluded.lng
            "#,
            id,
            group_id,
            place.name,
            place.lat,
            place.lng,
        )
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    Ok(profile)
}

/// The fixed row id of a seeded member.
fn member_id(profile: &SeedProfile, member_key: &str) -> String {
    format!("{}-{}", profile.key, member_key)
}

/// `GET /dev/session/{member_key}` — the session a seeded person would have got
/// by joining: their token, their group, and who they are.
///
/// This is the auto-sign-in endpoint the dev client profiles call. It only ever
/// resolves a *seeded* member — it looks the caller up by the fixed token that
/// [`dev_token`] derives, so it cannot mint a session for a real person who
/// joined normally. The route is only mounted when the `dev-seed` feature is
/// compiled in, so a production server has no such URL.
pub async fn dev_session(
    State(pool): State<SqlitePool>,
    Path(member_key): Path<String>,
) -> AppResult<Json<AuthResponse>> {
    let token = dev_token(&member_key);
    let row = sqlx::query!(
        r#"
        SELECT m.id, m.group_id, m.phone, m.display_name, m.token, m.is_admin, g.name AS group_name
        FROM members m
        JOIN groups g ON g.id = m.group_id
        WHERE m.token = ?
        "#,
        token
    )
    .fetch_optional(&pool)
    .await?
    .ok_or(AppError::NotFound("seeded member"))?;

    let member = Member {
        id: row.id,
        group_id: row.group_id.clone(),
        phone: row.phone,
        display_name: row.display_name,
        token: row.token,
        is_admin: row.is_admin != 0,
    };

    Ok(Json(AuthResponse {
        token: member.token.clone(),
        group_id: row.group_id,
        group_name: row.group_name,
        member: MemberView::from(&member),
    }))
}
