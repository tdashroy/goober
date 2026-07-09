//! Integration tests for the walking-skeleton API.
//!
//! These drive the real axum `Router` in-process via `tower::ServiceExt::oneshot`
//! against a fresh in-memory SQLite database — no live server, no disk, no
//! network. This is the "testable without a deployed server" requirement made
//! concrete.

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use axum::Router;
use goober_server::{build_app, db};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;

/// Build a router backed by a clean in-memory DB.
async fn test_app() -> Router {
    let pool = db::in_memory_pool().await.expect("migrate in-memory db");
    build_app(pool)
}

/// Send a request and return (status, parsed-json-body).
async fn send(app: &Router, req: Request<Body>) -> (StatusCode, Value) {
    let resp = app.clone().oneshot(req).await.expect("request");
    let status = resp.status();
    let bytes = resp.into_body().collect().await.expect("body").to_bytes();
    let body: Value = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).expect("json body")
    };
    (status, body)
}

fn post_json(path: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(path)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn get_with_token(path: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(path)
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

/// Create a group and return the parsed AuthResponse body.
async fn create_group(app: &Router, group_name: &str, name: &str, phone: &str) -> Value {
    let (status, body) = send(
        app,
        post_json(
            "/groups",
            json!({ "group_name": group_name, "name": name, "phone": phone }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "create_group failed: {body}");
    body
}

// --- acceptance: a group can be created and its creator is recorded as admin ---

#[tokio::test]
async fn create_group_records_creator_as_admin() {
    let app = test_app().await;
    let body = create_group(&app, "Beach 2027", "Troy", "555-111-2222").await;

    assert!(!body["token"].as_str().unwrap().is_empty());
    assert_eq!(body["group_name"], "Beach 2027");
    assert_eq!(body["member"]["display_name"], "Troy");
    assert_eq!(body["member"]["is_admin"], true);
    // Phone is normalized to digits.
    assert_eq!(body["member"]["phone"], "5551112222");
    // The bearer token is never echoed inside the member view.
    assert!(body["member"].get("token").is_none());
}

// --- acceptance: join with name + phone returns a persistable bearer token ---

#[tokio::test]
async fn join_returns_token_and_non_admin_member() {
    let app = test_app().await;
    let group = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let group_id = group["group_id"].as_str().unwrap();

    let (status, body) = send(
        &app,
        post_json(
            &format!("/groups/{group_id}/join"),
            json!({ "name": "Wendel", "phone": "555-333-4444" }),
        ),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    let token = body["token"].as_str().unwrap();
    assert!(!token.is_empty());
    assert_ne!(token, group["token"].as_str().unwrap());
    assert_eq!(body["member"]["display_name"], "Wendel");
    assert_eq!(body["member"]["is_admin"], false);
}

// --- acceptance: re-joining with the same phone re-attaches (no duplicate) ---

#[tokio::test]
async fn rejoin_same_phone_reattaches_identity() {
    let app = test_app().await;
    let group = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let group_id = group["group_id"].as_str().unwrap().to_string();

    let (_, first) = send(
        &app,
        post_json(
            &format!("/groups/{group_id}/join"),
            json!({ "name": "Wendel", "phone": "555-333-4444" }),
        ),
    )
    .await;

    // Same phone, different formatting, updated display name.
    let (status, second) = send(
        &app,
        post_json(
            &format!("/groups/{group_id}/join"),
            json!({ "name": "Fireworks Champ", "phone": "5553334444" }),
        ),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    // Same member id — no duplicate — and the same token comes back.
    assert_eq!(first["member"]["id"], second["member"]["id"]);
    assert_eq!(first["token"], second["token"]);
    // Display name is a mutable label and was updated.
    assert_eq!(second["member"]["display_name"], "Fireworks Champ");

    // And the roster truly has no duplicate: creator + Wendel = 2 members.
    // We assert this indirectly — a fresh join with a *new* phone must produce
    // a new id distinct from both.
    let (_, third) = send(
        &app,
        post_json(
            &format!("/groups/{group_id}/join"),
            json!({ "name": "Emily", "phone": "555-999-0000" }),
        ),
    )
    .await;
    assert_ne!(third["member"]["id"], first["member"]["id"]);
}

// --- acceptance: authenticated requests need a valid token; others rejected ---

#[tokio::test]
async fn feed_requires_valid_token() {
    let app = test_app().await;
    let group = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let group_id = group["group_id"].as_str().unwrap();
    let token = group["token"].as_str().unwrap();

    // No token → 401.
    let (status, _) = send(
        &app,
        Request::builder()
            .uri(format!("/groups/{group_id}/feed"))
            .body(Body::empty())
            .unwrap(),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // Bogus token → 401.
    let (status, _) = send(
        &app,
        get_with_token(&format!("/groups/{group_id}/feed"), "not-a-real-token"),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // Valid token → 200 with an empty feed.
    let (status, body) = send(
        &app,
        get_with_token(&format!("/groups/{group_id}/feed"), token),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["group_name"], "Beach 2027");
    assert_eq!(body["rides"], json!([]));
}

#[tokio::test]
async fn cannot_read_another_groups_feed() {
    let app = test_app().await;
    let a = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let b = create_group(&app, "Lake 2027", "Todd", "5559998888").await;

    // A's token against B's feed → 403.
    let (status, _) = send(
        &app,
        get_with_token(
            &format!("/groups/{}/feed", b["group_id"].as_str().unwrap()),
            a["token"].as_str().unwrap(),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn me_returns_identity_for_valid_token() {
    let app = test_app().await;
    let group = create_group(&app, "Beach 2027", "Troy", "5551112222").await;

    let (status, body) = send(
        &app,
        get_with_token("/me", group["token"].as_str().unwrap()),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["display_name"], "Troy");
    assert_eq!(body["is_admin"], true);
}

#[tokio::test]
async fn join_missing_fields_is_rejected() {
    let app = test_app().await;
    let group = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let group_id = group["group_id"].as_str().unwrap();

    // Empty name.
    let (status, _) = send(
        &app,
        post_json(
            &format!("/groups/{group_id}/join"),
            json!({ "name": "   ", "phone": "5551234567" }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Phone with no digits.
    let (status, _) = send(
        &app,
        post_json(
            &format!("/groups/{group_id}/join"),
            json!({ "name": "Bob", "phone": "()-" }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn join_unknown_group_is_404() {
    let app = test_app().await;
    let (status, _) = send(
        &app,
        post_json(
            "/groups/does-not-exist/join",
            json!({ "name": "Bob", "phone": "5551234567" }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn health_is_ok() {
    let app = test_app().await;
    let (status, body) = send(
        &app,
        Request::builder()
            .uri("/health")
            .body(Body::empty())
            .unwrap(),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["status"], "ok");
}
