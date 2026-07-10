//! HTTP handlers for the walking skeleton: create a group, join a group, and
//! read the (empty) group feed.

use axum::extract::{Path, State};
use axum::Json;
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::auth::{generate_token, CurrentMember};
use crate::error::{AppError, AppResult};
use crate::models::{
    AuthResponse, CopyPlacesRequest, CreateGroupRequest, FeedResponse, JoinGroupRequest, Member,
    MemberView, Place, PlaceRequest, PlaceView, PlacesResponse,
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

/// `GET /groups/{group_id}/feed` — the group activity feed.
///
/// Authenticated: rejects requests without a valid token, and forbids reading a
/// group the caller does not belong to. Rides come later, so `rides` is
/// always empty here — the app renders its friendly empty state from this.
pub async fn feed(
    State(pool): State<SqlitePool>,
    CurrentMember(member): CurrentMember,
    Path(group_id): Path<String>,
) -> AppResult<Json<FeedResponse>> {
    if member.group_id != group_id {
        return Err(AppError::Forbidden);
    }

    let group = sqlx::query!("SELECT id, name FROM groups WHERE id = ?", group_id)
        .fetch_optional(&pool)
        .await?
        .ok_or(AppError::NotFound("group"))?;

    Ok(Json(FeedResponse {
        group_id: group.id,
        group_name: group.name,
        rides: Vec::new(),
    }))
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
