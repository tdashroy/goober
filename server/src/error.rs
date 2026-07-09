//! Application error type that maps cleanly to HTTP responses.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;

/// Every fallible handler returns this. It carries an HTTP status plus a
/// human-readable message and renders itself as a small JSON error body.
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("{0}")]
    BadRequest(String),

    /// Missing or invalid bearer token.
    #[error("missing or invalid token")]
    Unauthorized,

    /// Authenticated, but not allowed to touch this resource.
    #[error("forbidden")]
    Forbidden,

    #[error("{0} not found")]
    NotFound(&'static str),

    /// Any database error bubbles up as a 500 — we never leak SQL detail to the client.
    #[error("database error")]
    Db(#[from] sqlx::Error),
}

impl AppError {
    fn status(&self) -> StatusCode {
        match self {
            AppError::BadRequest(_) => StatusCode::BAD_REQUEST,
            AppError::Unauthorized => StatusCode::UNAUTHORIZED,
            AppError::Forbidden => StatusCode::FORBIDDEN,
            AppError::NotFound(_) => StatusCode::NOT_FOUND,
            AppError::Db(_) => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let status = self.status();
        if status == StatusCode::INTERNAL_SERVER_ERROR {
            // Log the real error server-side; return a generic message to the client.
            tracing::error!(error = %self, "request failed");
        }
        (status, Json(json!({ "error": self.to_string() }))).into_response()
    }
}

pub type AppResult<T> = Result<T, AppError>;
