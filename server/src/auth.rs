//! Bearer-token auth (family trust model: no passwords/email/SMS).
//!
//! On join we mint a random token and store it on the member row. Every
//! authenticated request carries `Authorization: Bearer <token>`; the
//! [`CurrentMember`] extractor resolves that token to a member or rejects the
//! request with 401.

use axum::extract::{FromRef, FromRequestParts};
use axum::http::request::Parts;
use rand::RngCore;
use sqlx::SqlitePool;

use crate::error::AppError;
use crate::models::Member;

/// Generate a fresh random bearer token: 32 bytes of OS randomness, hex-encoded.
/// 256 bits is far more than the family-trust threat model needs, but it's cheap
/// and unguessable.
pub fn generate_token() -> String {
    let mut bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// An authenticated member, resolved from the request's bearer token.
///
/// Use it as a handler argument (`member: CurrentMember`) to require auth — the
/// extractor returns [`AppError::Unauthorized`] if the header is missing,
/// malformed, or names a token no member holds.
#[derive(Debug, Clone)]
pub struct CurrentMember(pub Member);

impl<S> FromRequestParts<S> for CurrentMember
where
    SqlitePool: FromRef<S>,
    S: Send + Sync,
{
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        let token = bearer_token(parts).ok_or(AppError::Unauthorized)?;
        let pool = SqlitePool::from_ref(state);

        let row = sqlx::query!(
            r#"
            SELECT id, group_id, phone, display_name, token, is_admin
            FROM members
            WHERE token = ?
            "#,
            token
        )
        .fetch_optional(&pool)
        .await?
        .ok_or(AppError::Unauthorized)?;

        Ok(CurrentMember(Member {
            id: row.id,
            group_id: row.group_id,
            phone: row.phone,
            display_name: row.display_name,
            token: row.token,
            is_admin: row.is_admin != 0,
        }))
    }
}

/// Pull the token out of an `Authorization: Bearer <token>` header.
fn bearer_token(parts: &Parts) -> Option<String> {
    let header = parts.headers.get(axum::http::header::AUTHORIZATION)?;
    let value = header.to_str().ok()?;
    let token = value
        .strip_prefix("Bearer ")
        .or_else(|| value.strip_prefix("bearer "))?;
    let token = token.trim();
    if token.is_empty() {
        None
    } else {
        Some(token.to_string())
    }
}
