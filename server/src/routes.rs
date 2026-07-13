//! HTTP handlers: create/join a group, curate the group's places, request a
//! ride, and read the group's feed.

use std::collections::HashMap;

use axum::extract::{Path, State};
use axum::Json;
use chrono::{DateTime, SecondsFormat, Utc};
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::auth::{generate_token, CurrentMember};
use crate::error::{AppError, AppResult};
use crate::models::{
    AuthResponse, CopyPlacesRequest, CreateGroupRequest, CreateRideRequest, FeedResponse,
    JoinGroupRequest, Member, MemberRef, MemberView, Place, PlaceRequest, PlaceView,
    PlacesResponse, RideView, RosterMember, RosterResponse, MAX_PARTY_SIZE,
};

/// Liveness check — a client can ping this to confirm it can reach the server.
pub async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "status": "ok", "service": "goober-server" }))
}

/// `POST /groups` — create a group and record the caller as its admin.
///
/// Takes the creator's name + phone just like a join, so the creator is a real
/// member (the admin) from the start.
pub async fn create_group(
    State(pool): State<SqlitePool>,
    Json(req): Json<CreateGroupRequest>,
) -> AppResult<Json<AuthResponse>> {
    let group_name = require_field(&req.group_name, "group_name")?;
    let display_name = require_field(&req.name, "name")?;
    let phone = normalize_phone(&req.phone)?;

    let group_id = Uuid::new_v4().to_string();
    let member_id = Uuid::new_v4().to_string();
    let token = generate_token();

    // One transaction: create the group, add the creator as its admin member,
    // then point the group's `created_by` at that member.
    let mut tx = pool.begin().await?;

    sqlx::query!(
        "INSERT INTO groups (id, name, created_by) VALUES (?, ?, NULL)",
        group_id,
        group_name,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query!(
        r#"
        INSERT INTO members (id, group_id, phone, display_name, token, is_admin)
        VALUES (?, ?, ?, ?, ?, 1)
        "#,
        member_id,
        group_id,
        phone,
        display_name,
        token,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query!(
        "UPDATE groups SET created_by = ? WHERE id = ?",
        member_id,
        group_id,
    )
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;

    let member = Member {
        id: member_id,
        group_id: group_id.clone(),
        phone,
        display_name,
        token: token.clone(),
        is_admin: true,
    };

    Ok(Json(AuthResponse {
        token,
        group_id,
        group_name,
        member: MemberView::from(&member),
    }))
}

/// `POST /groups/{group_id}/join` — join with name + phone.
///
/// Re-joining with the same phone re-attaches the existing identity:
/// no duplicate member is created, the display name is refreshed, and the
/// member's existing token is returned so reinstalls recover for free.
pub async fn join_group(
    State(pool): State<SqlitePool>,
    Path(group_id): Path<String>,
    Json(req): Json<JoinGroupRequest>,
) -> AppResult<Json<AuthResponse>> {
    let display_name = require_field(&req.name, "name")?;
    let phone = normalize_phone(&req.phone)?;

    let group = sqlx::query!("SELECT id, name FROM groups WHERE id = ?", group_id)
        .fetch_optional(&pool)
        .await?
        .ok_or(AppError::NotFound("group"))?;

    // Phone is the durable key, unique within a group. One atomic
    // upsert re-attaches an existing identity (keeping its id + token, just
    // refreshing the mutable display name) or creates a new member — so two
    // concurrent joins with the same phone can't race past a check-then-insert
    // into a UNIQUE-constraint 500. The candidate id/token are only used when a
    // fresh row is inserted; on conflict RETURNING yields the existing values.
    let member_id = Uuid::new_v4().to_string();
    let token = generate_token();
    let row = sqlx::query!(
        r#"
        INSERT INTO members (id, group_id, phone, display_name, token, is_admin)
        VALUES (?, ?, ?, ?, ?, 0)
        ON CONFLICT (group_id, phone) DO UPDATE SET display_name = excluded.display_name
        RETURNING id, token, is_admin
        "#,
        member_id,
        group.id,
        phone,
        display_name,
        token,
    )
    .fetch_one(&pool)
    .await?;

    let member = Member {
        id: row.id,
        group_id: group.id.clone(),
        phone,
        display_name,
        token: row.token,
        is_admin: row.is_admin != 0,
    };

    Ok(Json(AuthResponse {
        token: member.token.clone(),
        group_id: group.id,
        group_name: group.name,
        member: MemberView::from(&member),
    }))
}

/// `GET /me` — who the caller is, resolved from their bearer token. Handy for
/// the app to validate a persisted token on boot.
pub async fn me(CurrentMember(member): CurrentMember) -> Json<MemberView> {
    Json(MemberView::from(&member))
}

/// `GET /groups/{group_id}/feed` — the group activity feed: every ride in the
/// group, newest first.
///
/// The feed is deliberately group-wide rather than personal — everyone sees the
/// same board, including rides they're not part of, so the feed answers "who's
/// going where" before you have to ask.
///
/// Authenticated: rejects requests without a valid token, and forbids reading a
/// group the caller does not belong to.
pub async fn feed(
    State(pool): State<SqlitePool>,
    CurrentMember(member): CurrentMember,
    Path(group_id): Path<String>,
) -> AppResult<Json<FeedResponse>> {
    require_group_member(&member, &group_id)?;

    let group = sqlx::query!("SELECT id, name FROM groups WHERE id = ?", group_id)
        .fetch_optional(&pool)
        .await?
        .ok_or(AppError::NotFound("group"))?;

    Ok(Json(FeedResponse {
        rides: load_rides(&pool, &group.id, None).await?,
        group_id: group.id,
        group_name: group.name,
    }))
}

/// `GET /groups/{group_id}/members` — the group roster: everyone the caller can
/// ping for a ride. Any member may read.
pub async fn roster(
    State(pool): State<SqlitePool>,
    CurrentMember(member): CurrentMember,
    Path(group_id): Path<String>,
) -> AppResult<Json<RosterResponse>> {
    require_group_member(&member, &group_id)?;

    let rows = sqlx::query!(
        r#"
        SELECT id, display_name, is_admin
        FROM members
        WHERE group_id = ?
        ORDER BY display_name
        "#,
        group_id,
    )
    .fetch_all(&pool)
    .await?;

    let members = rows
        .into_iter()
        .map(|r| RosterMember {
            id: r.id,
            display_name: r.display_name,
            is_admin: r.is_admin != 0,
        })
        .collect();

    Ok(Json(RosterResponse { group_id, members }))
}

// ----- places -----

/// `GET /groups/{group_id}/places` — the group's curated places.
///
/// Any member of the group may read; a token for another group is forbidden.
pub async fn list_places(
    State(pool): State<SqlitePool>,
    CurrentMember(member): CurrentMember,
    Path(group_id): Path<String>,
) -> AppResult<Json<PlacesResponse>> {
    require_group_member(&member, &group_id)?;
    Ok(Json(places_response(&pool, &group_id).await?))
}

/// `POST /groups/{group_id}/places` — create a place. Admin only.
pub async fn create_place(
    State(pool): State<SqlitePool>,
    CurrentMember(member): CurrentMember,
    Path(group_id): Path<String>,
    Json(req): Json<PlaceRequest>,
) -> AppResult<Json<PlacesResponse>> {
    require_group_admin(&member, &group_id)?;
    let name = require_field(&req.name, "name")?;
    let (lat, lng) = validate_coords(req.lat, req.lng)?;

    let id = Uuid::new_v4().to_string();
    sqlx::query!(
        "INSERT INTO places (id, group_id, name, lat, lng) VALUES (?, ?, ?, ?, ?)",
        id,
        group_id,
        name,
        lat,
        lng,
    )
    .execute(&pool)
    .await?;

    Ok(Json(places_response(&pool, &group_id).await?))
}

/// `PUT /groups/{group_id}/places/{place_id}` — rename and/or move a place.
/// Admin only. Replaces the name and coordinates wholesale.
pub async fn update_place(
    State(pool): State<SqlitePool>,
    CurrentMember(member): CurrentMember,
    Path((group_id, place_id)): Path<(String, String)>,
    Json(req): Json<PlaceRequest>,
) -> AppResult<Json<PlacesResponse>> {
    require_group_admin(&member, &group_id)?;
    let name = require_field(&req.name, "name")?;
    let (lat, lng) = validate_coords(req.lat, req.lng)?;

    // Scope the update by group_id too: an admin can only touch places in their
    // own group, and a stale/foreign place_id yields a clean 404 rather than
    // silently updating nothing.
    let affected = sqlx::query!(
        "UPDATE places SET name = ?, lat = ?, lng = ? WHERE id = ? AND group_id = ?",
        name,
        lat,
        lng,
        place_id,
        group_id,
    )
    .execute(&pool)
    .await?
    .rows_affected();

    if affected == 0 {
        return Err(AppError::NotFound("place"));
    }

    Ok(Json(places_response(&pool, &group_id).await?))
}

/// `DELETE /groups/{group_id}/places/{place_id}` — delete a place. Admin only.
pub async fn delete_place(
    State(pool): State<SqlitePool>,
    CurrentMember(member): CurrentMember,
    Path((group_id, place_id)): Path<(String, String)>,
) -> AppResult<Json<PlacesResponse>> {
    require_group_admin(&member, &group_id)?;

    let affected = sqlx::query!(
        "DELETE FROM places WHERE id = ? AND group_id = ?",
        place_id,
        group_id,
    )
    .execute(&pool)
    .await?
    .rows_affected();

    if affected == 0 {
        return Err(AppError::NotFound("place"));
    }

    Ok(Json(places_response(&pool, &group_id).await?))
}

/// `POST /groups/{group_id}/places/copy` — seed this group's places from another
/// group's list (the "copy last year's places" starting point). Admin only.
///
/// Thin version: copies every place from the source group verbatim under fresh
/// ids, leaving the source untouched, so the admin curates by editing. It
/// appends rather than replacing — the group keeps any places it already has.
pub async fn copy_places(
    State(pool): State<SqlitePool>,
    CurrentMember(member): CurrentMember,
    Path(group_id): Path<String>,
    Json(req): Json<CopyPlacesRequest>,
) -> AppResult<Json<PlacesResponse>> {
    require_group_admin(&member, &group_id)?;

    let from_group_id = require_field(&req.from_group_id, "from_group_id")?;

    sqlx::query!("SELECT id FROM groups WHERE id = ?", from_group_id)
        .fetch_optional(&pool)
        .await?
        .ok_or(AppError::NotFound("group"))?;

    sqlx::query!(
        "SELECT id FROM members WHERE group_id = ? AND phone = ?",
        from_group_id,
        member.phone,
    )
    .fetch_optional(&pool)
    .await?
    .ok_or(AppError::Forbidden)?;

    let source = load_places(&pool, &from_group_id).await?;
    if source.is_empty() {
        return Err(AppError::NotFound("places"));
    }

    // One transaction so a copy either lands whole or not at all.
    let mut tx = pool.begin().await?;
    for place in &source {
        let id = Uuid::new_v4().to_string();
        sqlx::query!(
            "INSERT INTO places (id, group_id, name, lat, lng) VALUES (?, ?, ?, ?, ?)",
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

    Ok(Json(places_response(&pool, &group_id).await?))
}

/// Fetch a group's places ordered by name — the shared read used by both the
/// list endpoint and the copy source.
async fn load_places(pool: &SqlitePool, group_id: &str) -> AppResult<Vec<Place>> {
    let rows = sqlx::query!(
        "SELECT id, group_id, name, lat, lng FROM places WHERE group_id = ? ORDER BY name",
        group_id,
    )
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|r| Place {
            id: r.id,
            group_id: r.group_id,
            name: r.name,
            lat: r.lat,
            lng: r.lng,
        })
        .collect())
}

/// Build the `PlacesResponse` a group's members see and every mutation echoes.
async fn places_response(pool: &SqlitePool, group_id: &str) -> AppResult<PlacesResponse> {
    let places = load_places(pool, group_id).await?;
    Ok(PlacesResponse {
        group_id: group_id.to_string(),
        places: places.iter().map(PlaceView::from).collect(),
    })
}

// ----- rides -----

/// `POST /groups/{group_id}/rides` — request a ride.
///
/// The passenger picks a pickup and dropoff from the group's curated places, a
/// party size, an optional free-text offer, and either "now" or a future time.
/// The request pings a **set** of members: `target_ids` names everyone being
/// asked to drive — one person, or a few. (Broadcasting to "anyone?" is a
/// separate path and is not wired up here.)
///
/// Every id in the body is resolved *within the caller's group*, so a ride can
/// never reach across groups — an id from another group reads as not found.
pub async fn create_ride(
    State(pool): State<SqlitePool>,
    CurrentMember(member): CurrentMember,
    Path(group_id): Path<String>,
    Json(req): Json<CreateRideRequest>,
) -> AppResult<Json<RideView>> {
    require_group_member(&member, &group_id)?;

    let pickup_id = require_group_place(&pool, &group_id, &req.pickup_id).await?;
    let dropoff_id = require_group_place(&pool, &group_id, &req.dropoff_id).await?;
    if pickup_id == dropoff_id {
        return Err(AppError::BadRequest(
            "pickup and dropoff must be different places".to_string(),
        ));
    }

    // The people pinged are a set of roster members, at least one of them, and
    // never the passenger: asking yourself for a ride is a mistake, not a
    // request. Naming the same person twice is a mistake too — the passenger
    // meant to ask someone else — so say so rather than quietly pinging once.
    let mut target_ids: Vec<String> = Vec::new();
    for id in &req.target_ids {
        let id = require_group_member_id(&pool, &group_id, id).await?;
        if id == member.id {
            return Err(AppError::BadRequest(
                "you can't ping yourself for a ride".to_string(),
            ));
        }
        if target_ids.contains(&id) {
            return Err(AppError::BadRequest(
                "you've asked the same person twice".to_string(),
            ));
        }
        target_ids.push(id);
    }
    if target_ids.is_empty() {
        return Err(AppError::BadRequest(
            "pick at least one person to ask".to_string(),
        ));
    }

    if !(1..=MAX_PARTY_SIZE).contains(&req.party_size) {
        return Err(AppError::BadRequest(format!(
            "party_size must be between 1 and {MAX_PARTY_SIZE}"
        )));
    }

    let offer = optional_field(req.offer.as_deref());
    let scheduled_for = optional_field(req.scheduled_for.as_deref())
        .map(|raw| validate_scheduled_for(&raw))
        .transpose()?;

    // Tagged riders are a set: tagging someone twice is the same as once.
    let mut party_ids: Vec<String> = Vec::new();
    for id in &req.party_member_ids {
        let id = require_group_member_id(&pool, &group_id, id).await?;
        if !party_ids.contains(&id) {
            party_ids.push(id);
        }
    }

    // Everyone pinged is being asked to drive, so none of them can also be
    // riding along.
    if party_ids.iter().any(|id| target_ids.contains(id)) {
        return Err(AppError::BadRequest(
            "someone you're asking can't also be riding with you".to_string(),
        ));
    }

    // `party_size` counts the passenger, so the tagged riders are everyone else
    // in the party — tagging more of them than the count leaves room for is a
    // contradiction, not a bigger party.
    if party_ids.len() as i64 > req.party_size - 1 {
        return Err(AppError::BadRequest(format!(
            "party_size {} leaves room for {} other rider(s), but {} were tagged",
            req.party_size,
            req.party_size - 1,
            party_ids.len()
        )));
    }

    let ride_id = Uuid::new_v4().to_string();

    // One transaction so a ride, everyone it pings and its tagged party land
    // together or not at all — a ride with nobody pinged is not a request.
    let mut tx = pool.begin().await?;

    sqlx::query!(
        r#"
        INSERT INTO rides (
            id, group_id, passenger_id, pickup_id, dropoff_id,
            party_size, offer, scheduled_for, status
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'open')
        "#,
        ride_id,
        group_id,
        member.id,
        pickup_id,
        dropoff_id,
        req.party_size,
        offer,
        scheduled_for,
    )
    .execute(&mut *tx)
    .await?;

    for target_member_id in &target_ids {
        sqlx::query!(
            "INSERT INTO ride_targets (ride_id, member_id) VALUES (?, ?)",
            ride_id,
            target_member_id,
        )
        .execute(&mut *tx)
        .await?;
    }

    for party_member_id in &party_ids {
        sqlx::query!(
            "INSERT INTO ride_party_members (ride_id, member_id) VALUES (?, ?)",
            ride_id,
            party_member_id,
        )
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;

    load_rides(&pool, &group_id, Some(&ride_id))
        .await?
        .pop()
        .map(Json)
        .ok_or(AppError::NotFound("ride"))
}

/// Load a group's rides as the feed shows them, newest first — joined to the
/// people and places they name so a client renders a ride from one payload.
///
/// `ride_id` narrows the read to a single ride (used to echo back the ride just
/// created); `None` loads the whole group's feed.
async fn load_rides(
    pool: &SqlitePool,
    group_id: &str,
    ride_id: Option<&str>,
) -> AppResult<Vec<RideView>> {
    let mut targets = load_ride_targets(pool, group_id, ride_id).await?;
    let mut party = load_ride_party(pool, group_id, ride_id).await?;

    let rows = sqlx::query!(
        r#"
        SELECT
            r.id            AS "id!: String",
            r.group_id      AS "group_id!: String",
            r.status        AS "status!: String",
            r.party_size    AS "party_size!: i64",
            r.offer         AS "offer?: String",
            r.scheduled_for AS "scheduled_for?: String",
            r.created_at    AS "created_at!: String",
            passenger.id           AS "passenger_id!: String",
            passenger.display_name AS "passenger_name!: String",
            pickup.id   AS "pickup_id!: String",
            pickup.name AS "pickup_name!: String",
            pickup.lat  AS "pickup_lat!: f64",
            pickup.lng  AS "pickup_lng!: f64",
            dropoff.id   AS "dropoff_id!: String",
            dropoff.name AS "dropoff_name!: String",
            dropoff.lat  AS "dropoff_lat!: f64",
            dropoff.lng  AS "dropoff_lng!: f64"
        FROM rides r
        JOIN members passenger ON passenger.id = r.passenger_id
        JOIN places pickup ON pickup.id = r.pickup_id
        JOIN places dropoff ON dropoff.id = r.dropoff_id
        WHERE r.group_id = ? AND (?2 IS NULL OR r.id = ?2)
        ORDER BY r.created_at DESC, r.id DESC
        "#,
        group_id,
        ride_id,
    )
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|r| RideView {
            targets: targets.remove(&r.id).unwrap_or_default(),
            party: party.remove(&r.id).unwrap_or_default(),
            id: r.id,
            group_id: r.group_id,
            status: r.status,
            passenger: MemberRef {
                id: r.passenger_id,
                display_name: r.passenger_name,
            },
            pickup: PlaceView {
                id: r.pickup_id,
                group_id: group_id.to_string(),
                name: r.pickup_name,
                lat: r.pickup_lat,
                lng: r.pickup_lng,
            },
            dropoff: PlaceView {
                id: r.dropoff_id,
                group_id: group_id.to_string(),
                name: r.dropoff_name,
                lat: r.dropoff_lat,
                lng: r.dropoff_lng,
            },
            party_size: r.party_size,
            offer: r.offer,
            scheduled_for: r.scheduled_for,
            created_at: r.created_at,
        })
        .collect())
}

/// Everyone pinged on each of a group's rides, keyed by ride id. Each ride names
/// at least one, and they come back by name so the feed reads the same to
/// everyone.
async fn load_ride_targets(
    pool: &SqlitePool,
    group_id: &str,
    ride_id: Option<&str>,
) -> AppResult<HashMap<String, Vec<MemberRef>>> {
    let rows = sqlx::query!(
        r#"
        SELECT
            rt.ride_id       AS "ride_id!: String",
            m.id             AS "member_id!: String",
            m.display_name   AS "display_name!: String"
        FROM ride_targets rt
        JOIN rides r ON r.id = rt.ride_id
        JOIN members m ON m.id = rt.member_id
        WHERE r.group_id = ? AND (?2 IS NULL OR r.id = ?2)
        ORDER BY m.display_name
        "#,
        group_id,
        ride_id,
    )
    .fetch_all(pool)
    .await?;

    let mut targets: HashMap<String, Vec<MemberRef>> = HashMap::new();
    for row in rows {
        targets.entry(row.ride_id).or_default().push(MemberRef {
            id: row.member_id,
            display_name: row.display_name,
        });
    }
    Ok(targets)
}

/// The tagged riders on each of a group's rides, keyed by ride id.
async fn load_ride_party(
    pool: &SqlitePool,
    group_id: &str,
    ride_id: Option<&str>,
) -> AppResult<HashMap<String, Vec<MemberRef>>> {
    let rows = sqlx::query!(
        r#"
        SELECT
            rp.ride_id       AS "ride_id!: String",
            m.id             AS "member_id!: String",
            m.display_name   AS "display_name!: String"
        FROM ride_party_members rp
        JOIN rides r ON r.id = rp.ride_id
        JOIN members m ON m.id = rp.member_id
        WHERE r.group_id = ? AND (?2 IS NULL OR r.id = ?2)
        ORDER BY m.display_name
        "#,
        group_id,
        ride_id,
    )
    .fetch_all(pool)
    .await?;

    let mut party: HashMap<String, Vec<MemberRef>> = HashMap::new();
    for row in rows {
        party.entry(row.ride_id).or_default().push(MemberRef {
            id: row.member_id,
            display_name: row.display_name,
        });
    }
    Ok(party)
}

/// Resolve a place id *within a group*, so an id belonging to another group is
/// simply not found rather than usable.
async fn require_group_place(
    pool: &SqlitePool,
    group_id: &str,
    place_id: &str,
) -> AppResult<String> {
    sqlx::query!(
        "SELECT id FROM places WHERE id = ? AND group_id = ?",
        place_id,
        group_id,
    )
    .fetch_optional(pool)
    .await?
    .map(|row| row.id)
    .ok_or(AppError::NotFound("place"))
}

/// Resolve a member id *within a group* — the same group-scoping guard as
/// [`require_group_place`], for the people a ride names.
async fn require_group_member_id(
    pool: &SqlitePool,
    group_id: &str,
    member_id: &str,
) -> AppResult<String> {
    sqlx::query!(
        "SELECT id FROM members WHERE id = ? AND group_id = ?",
        member_id,
        group_id,
    )
    .fetch_optional(pool)
    .await?
    .map(|row| row.id)
    .ok_or(AppError::NotFound("member"))
}

/// Validate a scheduled pickup time: a parseable ISO-8601 instant, in the
/// future. Normalized to UTC seconds ("2027-07-04T18:30:00Z") to match how the
/// rest of the schema stores time.
fn validate_scheduled_for(raw: &str) -> AppResult<String> {
    let parsed = DateTime::parse_from_rfc3339(raw)
        .map_err(|_| {
            AppError::BadRequest("scheduled_for must be an ISO-8601 timestamp".to_string())
        })?
        .with_timezone(&Utc);

    if parsed <= Utc::now() {
        return Err(AppError::BadRequest(
            "scheduled_for must be in the future".to_string(),
        ));
    }

    Ok(parsed.to_rfc3339_opts(SecondsFormat::Secs, true))
}

/// Require that the caller belongs to the group they're addressing. A token for
/// a different group is forbidden, not merely unauthorized.
fn require_group_member(member: &Member, group_id: &str) -> AppResult<()> {
    if member.group_id != group_id {
        return Err(AppError::Forbidden);
    }
    Ok(())
}

/// Require that the caller is the group's admin. Non-admins (and members of
/// other groups) are forbidden — this is the server-side guard that keeps place
/// curation admin-only.
fn require_group_admin(member: &Member, group_id: &str) -> AppResult<()> {
    require_group_member(member, group_id)?;
    if !member.is_admin {
        return Err(AppError::Forbidden);
    }
    Ok(())
}

/// Validate map coordinates: latitude in [-90, 90], longitude in [-180, 180].
fn validate_coords(lat: f64, lng: f64) -> AppResult<(f64, f64)> {
    if !lat.is_finite() || !(-90.0..=90.0).contains(&lat) {
        return Err(AppError::BadRequest(
            "lat must be between -90 and 90".to_string(),
        ));
    }
    if !lng.is_finite() || !(-180.0..=180.0).contains(&lng) {
        return Err(AppError::BadRequest(
            "lng must be between -180 and 180".to_string(),
        ));
    }
    Ok((lat, lng))
}

/// Trim an optional text field. Absent, empty, and whitespace-only all mean
/// "not given" — so a blank offer box is stored as no offer, not as "".
fn optional_field(value: Option<&str>) -> Option<String> {
    let trimmed = value?.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

/// Trim a required text field, erroring if it is empty.
fn require_field(value: &str, field: &'static str) -> AppResult<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        Err(AppError::BadRequest(format!("{field} is required")))
    } else {
        Ok(trimmed.to_string())
    }
}

/// Normalize a phone number so the same number typed with different formatting
/// re-attaches to the same identity. Keeps digits and a single leading `+`;
/// drops spaces, dashes, parens, dots. Errors if nothing usable remains.
fn normalize_phone(raw: &str) -> AppResult<String> {
    let raw = raw.trim();
    let has_plus = raw.starts_with('+');
    let digits: String = raw.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        return Err(AppError::BadRequest("phone is required".to_string()));
    }
    Ok(if has_plus {
        format!("+{digits}")
    } else {
        digits
    })
}
