//! HTTP handlers for the walking skeleton: create a group, join a group, and
//! read the (empty) group feed.

use axum::extract::{Path, State};
use axum::Json;
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::auth::{generate_token, CurrentMember};
use crate::error::{AppError, AppResult};
use crate::models::{
    AuthResponse, CreateGroupRequest, FeedResponse, JoinGroupRequest, Member, MemberView,
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
