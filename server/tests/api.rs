//! Integration tests for the API.
//!
//! These drive the real axum `Router` in-process via `tower::ServiceExt::oneshot`
//! against a fresh in-memory SQLite database — no live server, no disk, no
//! network. This is the "testable without a deployed server" requirement made
//! concrete.

use std::time::Duration;

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use axum::response::Response;
use axum::Router;
use goober_server::{build_app, db};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use sqlx::SqlitePool;
use tokio::time::timeout;
use tower::ServiceExt;

/// Build a router backed by a clean in-memory DB.
async fn test_app() -> Router {
    test_app_with_pool().await.0
}

/// The same router, keeping the pool — for the one thing the API deliberately
/// doesn't hand back: a ride's audit trail, which is written for posterity
/// rather than for the feed.
async fn test_app_with_pool() -> (Router, SqlitePool) {
    let pool = db::in_memory_pool().await.expect("migrate in-memory db");
    (build_app(pool.clone()), pool)
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

fn body_with_token(method: &str, path: &str, token: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(path)
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn delete_with_token(path: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("DELETE")
        .uri(path)
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

/// Join a group and return the parsed AuthResponse body (a non-admin member).
async fn join_group(app: &Router, group_id: &str, name: &str, phone: &str) -> Value {
    let (status, body) = send(
        app,
        post_json(
            &format!("/groups/{group_id}/join"),
            json!({ "name": name, "phone": phone }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "join failed: {body}");
    body
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

// --- acceptance: admin can create, rename, and delete places ---

#[tokio::test]
async fn admin_can_create_rename_and_delete_places() {
    let app = test_app().await;
    let admin = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let group_id = admin["group_id"].as_str().unwrap();
    let token = admin["token"].as_str().unwrap();

    // Create a place.
    let (status, body) = send(
        &app,
        body_with_token(
            "POST",
            &format!("/groups/{group_id}/places"),
            token,
            json!({ "name": "The Pier", "lat": 38.9, "lng": -75.1 }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "create failed: {body}");
    assert_eq!(body["places"].as_array().unwrap().len(), 1);
    let place = &body["places"][0];
    let place_id = place["id"].as_str().unwrap().to_string();
    assert_eq!(place["name"], "The Pier");
    assert_eq!(place["lat"], 38.9);
    assert_eq!(place["lng"], -75.1);
    assert_eq!(place["group_id"], group_id);

    // Rename (and move) it.
    let (status, body) = send(
        &app,
        body_with_token(
            "PUT",
            &format!("/groups/{group_id}/places/{place_id}"),
            token,
            json!({ "name": "The Fishing Pier", "lat": 39.0, "lng": -75.2 }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "update failed: {body}");
    let place = &body["places"][0];
    assert_eq!(place["id"], place_id);
    assert_eq!(place["name"], "The Fishing Pier");
    assert_eq!(place["lat"], 39.0);
    assert_eq!(place["lng"], -75.2);

    // Delete it.
    let (status, body) = send(
        &app,
        delete_with_token(&format!("/groups/{group_id}/places/{place_id}"), token),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "delete failed: {body}");
    assert_eq!(body["places"], json!([]));
}

// --- acceptance: places are scoped to the group and returned to members ---

#[tokio::test]
async fn members_can_view_places_scoped_to_their_group() {
    let app = test_app().await;
    let admin = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let group_id = admin["group_id"].as_str().unwrap();
    let admin_token = admin["token"].as_str().unwrap();

    // Admin adds two places (created out of alphabetical order to prove sorting).
    for (name, lat, lng) in [("The Pier", 38.9, -75.1), ("Grandma's", 38.8, -75.0)] {
        let (status, _) = send(
            &app,
            body_with_token(
                "POST",
                &format!("/groups/{group_id}/places"),
                admin_token,
                json!({ "name": name, "lat": lat, "lng": lng }),
            ),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }

    // A non-admin member of the same group can read the list.
    let member = join_group(&app, group_id, "Wendel", "5553334444").await;
    let (status, body) = send(
        &app,
        get_with_token(
            &format!("/groups/{group_id}/places"),
            member["token"].as_str().unwrap(),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let names: Vec<&str> = body["places"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["name"].as_str().unwrap())
        .collect();
    // Returned to the member, ordered by name.
    assert_eq!(names, vec!["Grandma's", "The Pier"]);
}

#[tokio::test]
async fn places_are_isolated_between_groups() {
    let app = test_app().await;
    let a = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let b = create_group(&app, "Lake 2027", "Todd", "5559998888").await;
    let a_id = a["group_id"].as_str().unwrap();
    let b_id = b["group_id"].as_str().unwrap();

    // A place in group A.
    send(
        &app,
        body_with_token(
            "POST",
            &format!("/groups/{a_id}/places"),
            a["token"].as_str().unwrap(),
            json!({ "name": "The Pier", "lat": 38.9, "lng": -75.1 }),
        ),
    )
    .await;

    // Group B's list does not include it.
    let (status, body) = send(
        &app,
        get_with_token(
            &format!("/groups/{b_id}/places"),
            b["token"].as_str().unwrap(),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["places"], json!([]));

    // A's admin cannot read B's places with A's token.
    let (status, _) = send(
        &app,
        get_with_token(
            &format!("/groups/{b_id}/places"),
            a["token"].as_str().unwrap(),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

// --- acceptance: server rejects place mutations from non-admins ---

#[tokio::test]
async fn non_admins_cannot_mutate_places() {
    let app = test_app().await;
    let admin = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let group_id = admin["group_id"].as_str().unwrap();

    // Admin seeds a place so there's something to attempt to change/delete.
    let (_, seeded) = send(
        &app,
        body_with_token(
            "POST",
            &format!("/groups/{group_id}/places"),
            admin["token"].as_str().unwrap(),
            json!({ "name": "The Pier", "lat": 38.9, "lng": -75.1 }),
        ),
    )
    .await;
    let place_id = seeded["places"][0]["id"].as_str().unwrap().to_string();

    let member = join_group(&app, group_id, "Wendel", "5553334444").await;
    let member_token = member["token"].as_str().unwrap();

    // Create → 403.
    let (status, _) = send(
        &app,
        body_with_token(
            "POST",
            &format!("/groups/{group_id}/places"),
            member_token,
            json!({ "name": "Sneaky Spot", "lat": 1.0, "lng": 1.0 }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // Update → 403.
    let (status, _) = send(
        &app,
        body_with_token(
            "PUT",
            &format!("/groups/{group_id}/places/{place_id}"),
            member_token,
            json!({ "name": "Renamed", "lat": 2.0, "lng": 2.0 }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // Delete → 403.
    let (status, _) = send(
        &app,
        delete_with_token(
            &format!("/groups/{group_id}/places/{place_id}"),
            member_token,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // The place is still there, untouched, when the admin looks.
    let (status, body) = send(
        &app,
        get_with_token(
            &format!("/groups/{group_id}/places"),
            admin["token"].as_str().unwrap(),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["places"].as_array().unwrap().len(), 1);
    assert_eq!(body["places"][0]["name"], "The Pier");
}

#[tokio::test]
async fn place_mutations_require_a_token() {
    let app = test_app().await;
    let admin = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let group_id = admin["group_id"].as_str().unwrap();

    // No Authorization header → 401.
    let (status, _) = send(
        &app,
        post_json(
            &format!("/groups/{group_id}/places"),
            json!({ "name": "The Pier", "lat": 38.9, "lng": -75.1 }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn place_coordinates_are_validated() {
    let app = test_app().await;
    let admin = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let group_id = admin["group_id"].as_str().unwrap();
    let token = admin["token"].as_str().unwrap();

    // Latitude out of range.
    let (status, _) = send(
        &app,
        body_with_token(
            "POST",
            &format!("/groups/{group_id}/places"),
            token,
            json!({ "name": "Nowhere", "lat": 200.0, "lng": 0.0 }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Empty name.
    let (status, _) = send(
        &app,
        body_with_token(
            "POST",
            &format!("/groups/{group_id}/places"),
            token,
            json!({ "name": "   ", "lat": 38.9, "lng": -75.1 }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn updating_a_missing_place_is_404() {
    let app = test_app().await;
    let admin = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let group_id = admin["group_id"].as_str().unwrap();

    let (status, _) = send(
        &app,
        body_with_token(
            "PUT",
            &format!("/groups/{group_id}/places/does-not-exist"),
            admin["token"].as_str().unwrap(),
            json!({ "name": "Ghost", "lat": 0.0, "lng": 0.0 }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

// --- acceptance: copy places from another group as a starting point ---

#[tokio::test]
async fn admin_can_copy_places_from_another_group() {
    let app = test_app().await;
    // Last year's group, with a curated list.
    let last_year = create_group(&app, "Beach 2026", "Troy", "5551112222").await;
    let last_year_id = last_year["group_id"].as_str().unwrap();
    for (name, lat, lng) in [("Grandma's", 38.8, -75.0), ("The Pier", 38.9, -75.1)] {
        send(
            &app,
            body_with_token(
                "POST",
                &format!("/groups/{last_year_id}/places"),
                last_year["token"].as_str().unwrap(),
                json!({ "name": name, "lat": lat, "lng": lng }),
            ),
        )
        .await;
    }

    // This year's fresh group.
    let this_year = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let this_year_id = this_year["group_id"].as_str().unwrap();
    let this_year_token = this_year["token"].as_str().unwrap();

    let (status, body) = send(
        &app,
        body_with_token(
            "POST",
            &format!("/groups/{this_year_id}/places/copy"),
            this_year_token,
            json!({ "from_group_id": last_year_id }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "copy failed: {body}");

    let places = body["places"].as_array().unwrap();
    assert_eq!(places.len(), 2);
    let names: Vec<&str> = places.iter().map(|p| p["name"].as_str().unwrap()).collect();
    assert_eq!(names, vec!["Grandma's", "The Pier"]);
    // Copies belong to this year's group with fresh ids.
    assert_eq!(places[0]["group_id"], this_year_id);

    // The source group is untouched.
    let (_, source) = send(
        &app,
        get_with_token(
            &format!("/groups/{last_year_id}/places"),
            last_year["token"].as_str().unwrap(),
        ),
    )
    .await;
    assert_eq!(source["places"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn non_admin_cannot_copy_places() {
    let app = test_app().await;
    let admin = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let group_id = admin["group_id"].as_str().unwrap();
    let member = join_group(&app, group_id, "Wendel", "5553334444").await;

    let (status, _) = send(
        &app,
        body_with_token(
            "POST",
            &format!("/groups/{group_id}/places/copy"),
            member["token"].as_str().unwrap(),
            json!({ "from_group_id": group_id }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn cannot_copy_places_from_a_group_the_caller_is_not_in() {
    let app = test_app().await;
    // Source group owned by a different person, with a curated list.
    let source = create_group(&app, "Beach 2026", "Alice", "5551110000").await;
    let source_id = source["group_id"].as_str().unwrap();
    send(
        &app,
        body_with_token(
            "POST",
            &format!("/groups/{source_id}/places"),
            source["token"].as_str().unwrap(),
            json!({ "name": "Grandma's", "lat": 38.8, "lng": -75.0 }),
        ),
    )
    .await;

    // A different admin who never joined the source group.
    let this_year = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let this_year_id = this_year["group_id"].as_str().unwrap();

    let (status, _) = send(
        &app,
        body_with_token(
            "POST",
            &format!("/groups/{this_year_id}/places/copy"),
            this_year["token"].as_str().unwrap(),
            json!({ "from_group_id": source_id }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn cannot_copy_places_from_an_unknown_group() {
    let app = test_app().await;
    let this_year = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let this_year_id = this_year["group_id"].as_str().unwrap();

    let (status, _) = send(
        &app,
        body_with_token(
            "POST",
            &format!("/groups/{this_year_id}/places/copy"),
            this_year["token"].as_str().unwrap(),
            json!({ "from_group_id": "no-such-group" }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn cannot_copy_places_from_a_group_with_no_places() {
    let app = test_app().await;
    // Same person creates both groups, so they are a member of the source,
    // but the source has no places yet.
    let last_year = create_group(&app, "Beach 2026", "Troy", "5551112222").await;
    let last_year_id = last_year["group_id"].as_str().unwrap();
    let this_year = create_group(&app, "Beach 2027", "Troy", "5551112222").await;
    let this_year_id = this_year["group_id"].as_str().unwrap();

    let (status, _) = send(
        &app,
        body_with_token(
            "POST",
            &format!("/groups/{this_year_id}/places/copy"),
            this_year["token"].as_str().unwrap(),
            json!({ "from_group_id": last_year_id }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

// ----- rides -----

/// A group ready to request a ride in: an admin (Troy), two other members
/// (Wendel, Emily), and two curated places (The Pier, Grandma's).
struct RideFixture {
    group_id: String,
    /// The admin, who plays the passenger in most tests.
    passenger_token: String,
    passenger_id: String,
    /// The member being pinged to drive.
    driver_id: String,
    driver_token: String,
    /// A third member — a bystander who still sees the shared feed, and who can
    /// be pinged alongside the driver when a ride asks more than one person.
    rider_id: String,
    rider_token: String,
    pickup_id: String,
    dropoff_id: String,
}

async fn ride_fixture(app: &Router) -> RideFixture {
    let admin = create_group(app, "Beach 2027", "Troy", "5551112222").await;
    let group_id = admin["group_id"].as_str().unwrap().to_string();
    let passenger_token = admin["token"].as_str().unwrap().to_string();

    let driver = join_group(app, &group_id, "Wendel", "5553334444").await;
    let rider = join_group(app, &group_id, "Emily", "5559990000").await;

    RideFixture {
        pickup_id: create_place(app, &group_id, &passenger_token, "The Pier", 38.9, -75.1).await,
        dropoff_id: create_place(app, &group_id, &passenger_token, "Grandma's", 38.8, -75.0).await,
        passenger_id: admin["member"]["id"].as_str().unwrap().to_string(),
        driver_id: driver["member"]["id"].as_str().unwrap().to_string(),
        driver_token: driver["token"].as_str().unwrap().to_string(),
        rider_id: rider["member"]["id"].as_str().unwrap().to_string(),
        rider_token: rider["token"].as_str().unwrap().to_string(),
        group_id,
        passenger_token,
    }
}

/// Create a place as the group's admin and return its id.
async fn create_place(
    app: &Router,
    group_id: &str,
    token: &str,
    name: &str,
    lat: f64,
    lng: f64,
) -> String {
    let (status, body) = send(
        app,
        body_with_token(
            "POST",
            &format!("/groups/{group_id}/places"),
            token,
            json!({ "name": name, "lat": lat, "lng": lng }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "create_place failed: {body}");
    body["places"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["name"] == name)
        .unwrap_or_else(|| panic!("place {name} missing from {body}"))["id"]
        .as_str()
        .unwrap()
        .to_string()
}

/// Request a ride, returning (status, body), so tests can assert on rejections
/// as well as the happy path.
async fn request_ride(
    app: &Router,
    group_id: &str,
    token: &str,
    body: Value,
) -> (StatusCode, Value) {
    send(
        app,
        body_with_token("POST", &format!("/groups/{group_id}/rides"), token, body),
    )
    .await
}

async fn fetch_feed(app: &Router, group_id: &str, token: &str) -> Value {
    let (status, body) = send(
        app,
        get_with_token(&format!("/groups/{group_id}/feed"), token),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "feed failed: {body}");
    body
}

// --- acceptance: a passenger requests a ride, pinging the members they chose,
// --- and it lands in the group's shared feed with its route, party size, and
// --- offer ---

#[tokio::test]
async fn passenger_can_request_a_ride_as_a_direct_ping() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    let (status, ride) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id],
            "party_size": 3,
            "offer": "🍪 cookies",
        }),
    )
    .await;

    assert_eq!(status, StatusCode::OK, "request failed: {ride}");
    assert_eq!(ride["status"], "open");
    assert_eq!(ride["group_id"], f.group_id);
    assert_eq!(ride["passenger"]["id"], f.passenger_id);
    assert_eq!(ride["passenger"]["display_name"], "Troy");
    // Pinging one person is a set of one.
    assert_eq!(ride["targets"].as_array().unwrap().len(), 1);
    assert_eq!(ride["targets"][0]["id"], f.driver_id);
    assert_eq!(ride["targets"][0]["display_name"], "Wendel");
    assert_eq!(ride["pickup"]["name"], "The Pier");
    assert_eq!(ride["dropoff"]["name"], "Grandma's");
    assert_eq!(ride["party_size"], 3);
    assert_eq!(ride["offer"], "🍪 cookies");
    // No time given means "now".
    assert!(ride["scheduled_for"].is_null());
    // The feed is a public board — it carries names, not phone numbers.
    assert!(ride["passenger"].get("phone").is_none());

    // It shows up in the shared feed for the whole group, including a member who
    // is neither the passenger nor the person pinged.
    for token in [&f.passenger_token, &f.driver_token] {
        let feed = fetch_feed(&app, &f.group_id, token).await;
        let rides = feed["rides"].as_array().unwrap();
        assert_eq!(rides.len(), 1, "feed should show the open request: {feed}");
        assert_eq!(rides[0]["id"], ride["id"]);
        assert_eq!(rides[0]["pickup"]["name"], "The Pier");
        assert_eq!(rides[0]["dropoff"]["name"], "Grandma's");
        assert_eq!(rides[0]["party_size"], 3);
        assert_eq!(rides[0]["offer"], "🍪 cookies");
        assert_eq!(rides[0]["status"], "open");
    }
}

// --- acceptance: a ping names a set of members — one person, or a few — and the
// --- feed shows everyone who was asked ---

#[tokio::test]
async fn passenger_can_ping_several_people_at_once() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    let (status, ride) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id, f.rider_id],
        }),
    )
    .await;

    assert_eq!(status, StatusCode::OK, "request failed: {ride}");
    // Everyone asked comes back, by name — whoever gets there first can take it.
    let names: Vec<&str> = ride["targets"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["display_name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["Emily", "Wendel"]);

    // The whole set survives into the shared feed.
    let feed = fetch_feed(&app, &f.group_id, &f.passenger_token).await;
    let feed_names: Vec<&str> = feed["rides"][0]["targets"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["display_name"].as_str().unwrap())
        .collect();
    assert_eq!(feed_names, ["Emily", "Wendel"]);
}

#[tokio::test]
async fn a_ping_names_at_least_one_person_and_names_nobody_twice() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    // Pinging nobody is not a request — a broadcast is a different thing, and
    // isn't built. An empty set and no set at all read the same way.
    for body in [
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [],
        }),
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
        }),
    ] {
        let (status, body) = request_ride(&app, &f.group_id, &f.passenger_token, body).await;
        assert_eq!(
            status,
            StatusCode::BAD_REQUEST,
            "a ride with nobody pinged was accepted: {body}"
        );
    }

    // Asking the same person twice is a slip, not two pings.
    let (status, _) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id, f.driver_id],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "a duplicate ping was kept");

    // Nor can the passenger be anywhere in the set, even alongside someone real.
    let (status, _) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id, f.passenger_id],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "the passenger was pinged");

    // A stranger in the set is not found, however many real people join them.
    let (status, _) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id, "no-such-member"],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "a non-member was pinged");
}

// --- acceptance: party size defaults to 1 ("just me") and is an exact, capped count ---

#[tokio::test]
async fn party_size_defaults_to_one_and_accepts_exact_counts_up_to_the_cap() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    // Omitted → "just me".
    let (status, ride) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "request failed: {ride}");
    assert_eq!(ride["party_size"], 1);

    // Every exact count up to the cap is accepted.
    for size in 1..=goober_server::models::MAX_PARTY_SIZE {
        let (status, ride) = request_ride(
            &app,
            &f.group_id,
            &f.passenger_token,
            json!({
                "pickup_id": f.pickup_id,
                "dropoff_id": f.dropoff_id,
                "target_ids": [f.driver_id],
                "party_size": size,
            }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "party size {size} rejected: {ride}");
        assert_eq!(ride["party_size"], size);
    }

    // A party of nobody is not a ride, and neither is one past the cap.
    for size in [0, goober_server::models::MAX_PARTY_SIZE + 1] {
        let (status, _) = request_ride(
            &app,
            &f.group_id,
            &f.passenger_token,
            json!({
                "pickup_id": f.pickup_id,
                "dropoff_id": f.dropoff_id,
                "target_ids": [f.driver_id],
                "party_size": size,
            }),
        )
        .await;
        assert_eq!(
            status,
            StatusCode::BAD_REQUEST,
            "party size {size} accepted"
        );
    }
}

// --- acceptance: timing is either "now" or a future scheduled time ---

#[tokio::test]
async fn a_ride_can_be_scheduled_for_a_future_time() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    // A time zone offset is normalized to UTC, so the stored/echoed instant is
    // canonical however the client wrote it.
    let (status, ride) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id],
            "scheduled_for": "2099-07-04T14:30:00-04:00",
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "request failed: {ride}");
    assert_eq!(ride["scheduled_for"], "2099-07-04T18:30:00Z");

    let feed = fetch_feed(&app, &f.group_id, &f.passenger_token).await;
    assert_eq!(feed["rides"][0]["scheduled_for"], "2099-07-04T18:30:00Z");
}

#[tokio::test]
async fn a_scheduled_time_must_parse_and_be_in_the_future() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    for when in ["2020-07-04T18:30:00Z", "next tuesday", ""] {
        let (status, body) = request_ride(
            &app,
            &f.group_id,
            &f.passenger_token,
            json!({
                "pickup_id": f.pickup_id,
                "dropoff_id": f.dropoff_id,
                "target_ids": [f.driver_id],
                "scheduled_for": when,
            }),
        )
        .await;

        if when.is_empty() {
            // A blank time is not a bad time — it just means "now".
            assert_eq!(status, StatusCode::OK, "blank time rejected: {body}");
            assert!(body["scheduled_for"].is_null());
        } else {
            assert_eq!(status, StatusCode::BAD_REQUEST, "accepted {when}: {body}");
        }
    }
}

// --- acceptance: an offer is optional free text ---

#[tokio::test]
async fn an_offer_is_optional_free_text() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    // Cash is allowed — it's just text, the app doesn't process payments.
    let (status, ride) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id],
            "offer": "  $5 and a beer  ",
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "request failed: {ride}");
    assert_eq!(ride["offer"], "$5 and a beer");

    // A blank offer is no offer, not an empty string.
    let (status, ride) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id],
            "offer": "   ",
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "request failed: {ride}");
    assert!(ride["offer"].is_null());
}

// --- acceptance: the passenger may tag who else is riding along ---

#[tokio::test]
async fn passenger_can_tag_who_is_riding_along() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    // Tagging the same person twice is the same as tagging them once.
    let (status, ride) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id],
            "party_size": 2,
            "party_member_ids": [f.rider_id, f.rider_id],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "request failed: {ride}");
    assert_eq!(ride["party"].as_array().unwrap().len(), 1);
    assert_eq!(ride["party"][0]["id"], f.rider_id);
    assert_eq!(ride["party"][0]["display_name"], "Emily");

    // The tags survive into the feed.
    let feed = fetch_feed(&app, &f.group_id, &f.passenger_token).await;
    assert_eq!(feed["rides"][0]["party"][0]["display_name"], "Emily");

    // Tagging is optional — a ride with nobody tagged has an empty party.
    let (_, ride) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id],
        }),
    )
    .await;
    assert_eq!(ride["party"], json!([]));
}

// --- acceptance: the tagged riders must be a party that could actually exist —
// --- no more of them than the party size allows, and never the driver ---

#[tokio::test]
async fn tagged_riders_fit_the_party_size_and_exclude_the_person_being_asked() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;
    let fourth = join_group(&app, &f.group_id, "Nora", "5552223333").await;
    let fourth_id = fourth["member"]["id"].as_str().unwrap().to_string();

    // `party_size` counts the passenger, so a party of 2 has room for exactly
    // one other rider.
    let (status, ride) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id],
            "party_size": 2,
            "party_member_ids": [f.rider_id],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "request failed: {ride}");
    assert_eq!(ride["party"].as_array().unwrap().len(), 1);

    // One more rider than the count leaves room for is a contradiction — as is
    // tagging anyone at all when it's "just me".
    for body in [
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id],
            "party_size": 2,
            "party_member_ids": [f.rider_id, fourth_id],
        }),
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id],
            "party_size": 1,
            "party_member_ids": [f.rider_id],
        }),
    ] {
        let (status, _) = request_ride(&app, &f.group_id, &f.passenger_token, body).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "over-count party accepted");
    }

    // Everyone pinged is being asked to drive, not to ride along — and that holds
    // for each of them when several are asked.
    for targets in [
        json!([f.driver_id]),
        json!([f.driver_id, fourth_id]),
        json!([fourth_id, f.driver_id]),
    ] {
        let (status, _) = request_ride(
            &app,
            &f.group_id,
            &f.passenger_token,
            json!({
                "pickup_id": f.pickup_id,
                "dropoff_id": f.dropoff_id,
                "target_ids": targets,
                "party_size": 3,
                "party_member_ids": [f.rider_id, f.driver_id],
            }),
        )
        .await;
        assert_eq!(
            status,
            StatusCode::BAD_REQUEST,
            "someone being asked was tagged as a rider"
        );
    }
}

// --- acceptance: a request is validated — real places, a real person to ping,
// --- and a route that actually goes somewhere ---

#[tokio::test]
async fn a_request_needs_two_different_places_and_someone_else_to_ping() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    // Going nowhere.
    let (status, _) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.pickup_id,
            "target_ids": [f.driver_id],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Asking yourself for a ride.
    let (status, _) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.passenger_id],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // A place that doesn't exist.
    let (status, _) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": "no-such-place",
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // A person who doesn't exist.
    let (status, _) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": ["no-such-member"],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

// --- acceptance: rides are scoped to the group ---

#[tokio::test]
async fn rides_cannot_reach_across_groups() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    // A separate group with its own member and its own place.
    let other = create_group(&app, "Lake 2027", "Todd", "5557778888").await;
    let other_group_id = other["group_id"].as_str().unwrap().to_string();
    let other_token = other["token"].as_str().unwrap().to_string();
    let other_member_id = other["member"]["id"].as_str().unwrap().to_string();
    let other_place_id =
        create_place(&app, &other_group_id, &other_token, "The Dock", 41.0, -85.0).await;

    // Another group's place can't be a stop on this group's ride.
    let (status, _) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": other_place_id,
            "target_ids": [f.driver_id],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // Nor can another group's member be pinged, or be tagged as riding along.
    for body in [
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [other_member_id],
        }),
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id],
            "party_member_ids": [other_member_id],
        }),
    ] {
        let (status, _) = request_ride(&app, &f.group_id, &f.passenger_token, body).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }

    // A real ride in one group is invisible in the other's feed.
    let (status, _) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let other_feed = fetch_feed(&app, &other_group_id, &other_token).await;
    assert_eq!(other_feed["rides"], json!([]));

    // And a token from one group can't request a ride in the other.
    let (status, _) = request_ride(
        &app,
        &other_group_id,
        &f.passenger_token,
        json!({
            "pickup_id": other_place_id,
            "dropoff_id": other_place_id,
            "target_ids": [other_member_id],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn requesting_a_ride_requires_a_token() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    let (status, _) = send(
        &app,
        post_json(
            &format!("/groups/{}/rides", f.group_id),
            json!({
                "pickup_id": f.pickup_id,
                "dropoff_id": f.dropoff_id,
                "target_ids": [f.driver_id],
            }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

// --- acceptance: the feed lists the group's rides, newest first ---

#[tokio::test]
async fn the_feed_lists_every_ride_in_the_group() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    // Two requests from different passengers.
    let (_, first) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id],
        }),
    )
    .await;
    let (_, second) = request_ride(
        &app,
        &f.group_id,
        &f.driver_token,
        json!({
            "pickup_id": f.dropoff_id,
            "dropoff_id": f.pickup_id,
            "target_ids": [f.passenger_id],
        }),
    )
    .await;

    let feed = fetch_feed(&app, &f.group_id, &f.passenger_token).await;
    let rides = feed["rides"].as_array().unwrap();
    assert_eq!(rides.len(), 2);

    // Both are there, and each keeps its own route and passenger.
    let ids: Vec<&str> = rides.iter().map(|r| r["id"].as_str().unwrap()).collect();
    assert!(ids.contains(&first["id"].as_str().unwrap()));
    assert!(ids.contains(&second["id"].as_str().unwrap()));

    let second_in_feed = rides
        .iter()
        .find(|r| r["id"] == second["id"])
        .expect("second ride in feed");
    assert_eq!(second_in_feed["passenger"]["display_name"], "Wendel");
    assert_eq!(second_in_feed["pickup"]["name"], "Grandma's");
    assert_eq!(second_in_feed["dropoff"]["name"], "The Pier");
}

// --- acceptance: the roster is the list of people you can ping ---

#[tokio::test]
async fn the_roster_lists_the_groups_members() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    let (status, body) = send(
        &app,
        get_with_token(
            &format!("/groups/{}/members", f.group_id),
            &f.passenger_token,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "roster failed: {body}");

    let members = body["members"].as_array().unwrap();
    let names: Vec<&str> = members
        .iter()
        .map(|m| m["display_name"].as_str().unwrap())
        .collect();
    assert_eq!(names, vec!["Emily", "Troy", "Wendel"]);

    // The roster is group-visible, so like the feed it never carries phone
    // numbers or tokens — just who you can ping and whether they're the admin.
    for m in members {
        assert!(m["is_admin"].is_boolean(), "roster entry: {m}");
        assert!(m.get("phone").is_none(), "roster leaked a phone: {m}");
        assert!(m.get("token").is_none(), "roster leaked a token: {m}");
    }

    // Another group's token can't read this roster.
    let other = create_group(&app, "Lake 2027", "Todd", "5557778888").await;
    let (status, _) = send(
        &app,
        get_with_token(
            &format!("/groups/{}/members", f.group_id),
            other["token"].as_str().unwrap(),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
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

// ----- the ride lifecycle -----

/// Take a step on a ride, returning (status, body) so tests can assert on the
/// steps that are refused as well as the ones that are taken.
async fn ride_action(
    app: &Router,
    group_id: &str,
    ride_id: &str,
    token: &str,
    body: Value,
) -> (StatusCode, Value) {
    send(
        app,
        body_with_token(
            "POST",
            &format!("/groups/{group_id}/rides/{ride_id}/actions"),
            token,
            body,
        ),
    )
    .await
}

/// Ask for a ride, pinging the given members, and return its id.
async fn open_ride(app: &Router, f: &RideFixture, target_ids: &[&str]) -> String {
    let (status, ride) = request_ride(
        app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": target_ids,
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "request failed: {ride}");
    ride["id"].as_str().unwrap().to_string()
}

/// A ride's audit trail, oldest step first, as (kind, who took it, who it named).
/// Ordered by insertion rather than by timestamp, which only has whole-second
/// resolution — a whole ride can happen inside one second in a test.
async fn ride_events(pool: &SqlitePool, ride_id: &str) -> Vec<(String, String, Option<String>)> {
    sqlx::query_as::<_, (String, String, Option<String>)>(
        "SELECT kind, actor_id, person_id FROM ride_events WHERE ride_id = ? ORDER BY rowid",
    )
    .bind(ride_id)
    .fetch_all(pool)
    .await
    .expect("ride events")
}

/// Find a ride on the group's feed.
async fn feed_ride(app: &Router, group_id: &str, token: &str, ride_id: &str) -> Value {
    let feed = fetch_feed(app, group_id, token).await;
    feed["rides"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == ride_id)
        .unwrap_or_else(|| panic!("ride {ride_id} missing from {feed}"))
        .clone()
}

// --- acceptance: a pinged member says "on my way", drives out, and the ride
// --- walks open -> accepted -> arrived -> delivered, with every step audited ---

#[tokio::test]
async fn driver_accepts_arrives_and_delivers() {
    let (app, pool) = test_app_with_pool().await;
    let f = ride_fixture(&app).await;
    let ride_id = open_ride(&app, &f, &[&f.driver_id]).await;

    // "On my way" — the person pinged claims the ride and becomes its driver.
    let (status, ride) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.driver_token,
        json!({ "action": "on_my_way" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "accept failed: {ride}");
    assert_eq!(ride["status"], "accepted");
    assert_eq!(ride["driver"]["id"], f.driver_id);
    assert_eq!(ride["driver"]["display_name"], "Wendel");
    assert_eq!(ride["responses"][0]["member"]["id"], f.driver_id);
    assert_eq!(ride["responses"][0]["response"], "on_my_way");

    // "I'm here" — the driver is at the pickup.
    let (status, ride) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.driver_token,
        json!({ "action": "arrived" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "arrive failed: {ride}");
    assert_eq!(ride["status"], "arrived");

    // "Delivered" — the ride is closed.
    let (status, ride) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.driver_token,
        json!({ "action": "delivered" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "deliver failed: {ride}");
    assert_eq!(ride["status"], "delivered");

    // The whole group watches it happen on the shared board.
    let seen = feed_ride(&app, &f.group_id, &f.rider_token, &ride_id).await;
    assert_eq!(seen["status"], "delivered");
    assert_eq!(seen["driver"]["display_name"], "Wendel");

    // And the ride's history is on the record, in the order it happened.
    let events = ride_events(&pool, &ride_id).await;
    assert_eq!(
        events,
        vec![
            ("requested".to_string(), f.passenger_id.clone(), None),
            ("on_my_way".to_string(), f.driver_id.clone(), None),
            ("arrived".to_string(), f.driver_id.clone(), None),
            ("delivered".to_string(), f.driver_id.clone(), None),
        ]
    );
}

// --- acceptance: several people are pinged, and the first to accept claims the
// --- ride — the rest find it taken ---

#[tokio::test]
async fn the_first_pinged_member_to_accept_claims_the_ride() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;
    let ride_id = open_ride(&app, &f, &[&f.driver_id, &f.rider_id]).await;

    let (status, ride) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.driver_token,
        json!({ "action": "on_my_way" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "accept failed: {ride}");
    assert_eq!(ride["driver"]["id"], f.driver_id);

    // The other person pinged is too late: the ride is already somebody's.
    let (status, body) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.rider_token,
        json!({ "action": "on_my_way" }),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "second accept: {body}");

    // Being too late doesn't take the ride off the first driver.
    let seen = feed_ride(&app, &f.group_id, &f.passenger_token, &ride_id).await;
    assert_eq!(seen["status"], "accepted");
    assert_eq!(seen["driver"]["id"], f.driver_id);

    // Nor can they say anything else about it now — it's off the market.
    let (status, body) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.rider_token,
        json!({ "action": "cant_right_now" }),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "late answer: {body}");
}

// --- acceptance: only the people pinged may answer a ride ---

#[tokio::test]
async fn a_member_who_was_not_pinged_cannot_accept() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;
    // Emily is in the group and sees the ride on the feed, but wasn't asked.
    let ride_id = open_ride(&app, &f, &[&f.driver_id]).await;

    for action in ["on_my_way", "cant_right_now"] {
        let (status, body) = ride_action(
            &app,
            &f.group_id,
            &ride_id,
            &f.rider_token,
            json!({ "action": action }),
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{action}: {body}");
    }

    let seen = feed_ride(&app, &f.group_id, &f.passenger_token, &ride_id).await;
    assert_eq!(seen["status"], "open");
    assert!(seen["driver"].is_null());
    assert!(seen["responses"].as_array().unwrap().is_empty());
}

// --- acceptance: the steps only happen in order — no arriving before accepting,
// --- no delivering before arriving ---

#[tokio::test]
async fn a_ride_cannot_skip_a_step() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;
    let ride_id = open_ride(&app, &f, &[&f.driver_id]).await;

    // Nobody has claimed it, so nobody is at the pickup and nobody has driven.
    for action in ["arrived", "delivered"] {
        let (status, body) = ride_action(
            &app,
            &f.group_id,
            &ride_id,
            &f.driver_token,
            json!({ "action": action }),
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT, "{action} while open: {body}");
    }

    let (status, _) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.driver_token,
        json!({ "action": "on_my_way" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // Claimed, but the driver is still on the road: there's been no hand-off.
    let (status, body) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.driver_token,
        json!({ "action": "delivered" }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::CONFLICT,
        "deliver before arrive: {body}"
    );

    let (status, _) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.driver_token,
        json!({ "action": "arrived" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // Arriving twice is a step out of order too.
    let (status, body) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.driver_token,
        json!({ "action": "arrived" }),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "arrive twice: {body}");

    let (status, _) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.driver_token,
        json!({ "action": "delivered" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // And a delivered ride is finished for good.
    let (status, body) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.driver_token,
        json!({ "action": "delivered" }),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "deliver twice: {body}");
}

// --- acceptance: the driver isn't the only one who can close a ride — the
// --- passenger can too, from the other side of the same hand-off ---

#[tokio::test]
async fn the_passenger_can_deliver_the_ride_too() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;
    let ride_id = open_ride(&app, &f, &[&f.driver_id]).await;

    for action in ["on_my_way", "arrived"] {
        let (status, body) = ride_action(
            &app,
            &f.group_id,
            &ride_id,
            &f.driver_token,
            json!({ "action": action }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{action}: {body}");
    }

    // A bystander is not part of the ride and cannot close it.
    let (status, body) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.rider_token,
        json!({ "action": "delivered" }),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "bystander deliver: {body}");

    let (status, ride) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.passenger_token,
        json!({ "action": "delivered" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "passenger deliver failed: {ride}");
    assert_eq!(ride["status"], "delivered");
}

// --- acceptance: only the driver marks the arrival ---

#[tokio::test]
async fn only_the_driver_marks_the_arrival() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;
    let ride_id = open_ride(&app, &f, &[&f.driver_id]).await;

    let (status, _) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.driver_token,
        json!({ "action": "on_my_way" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // The passenger can't say the cart is out front — only the person in it can.
    for token in [&f.passenger_token, &f.rider_token] {
        let (status, body) = ride_action(
            &app,
            &f.group_id,
            &ride_id,
            token,
            json!({ "action": "arrived" }),
        )
        .await;
        assert_eq!(
            status,
            StatusCode::FORBIDDEN,
            "arrive by non-driver: {body}"
        );
    }
}

// --- acceptance: a "no" is not a dead end — "can't right now", "no cart" and
// --- "someone else will come" each record what was said, and the last two hand
// --- the passenger a person to ask next ---

#[tokio::test]
async fn a_declining_member_records_their_answer_and_the_person_they_name() {
    let (app, pool) = test_app_with_pool().await;
    let f = ride_fixture(&app).await;
    // Susan is nobody's target — she's just the person who has the cart.
    let susan = join_group(&app, &f.group_id, "Susan", "5557778888").await;
    let susan_id = susan["member"]["id"].as_str().unwrap().to_string();

    let ride_id = open_ride(&app, &f, &[&f.driver_id, &f.rider_id]).await;

    // "I don't have a cart — but Susan took it."
    let (status, ride) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.driver_token,
        json!({ "action": "no_cart", "person_id": susan_id }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "no_cart failed: {ride}");
    // A "no" leaves the ride where it was: the other person pinged may still come.
    assert_eq!(ride["status"], "open");
    assert!(ride["driver"].is_null());
    assert_eq!(ride["responses"][0]["member"]["display_name"], "Wendel");
    assert_eq!(ride["responses"][0]["response"], "no_cart");
    assert_eq!(ride["responses"][0]["person"]["id"], susan_id);
    assert_eq!(ride["responses"][0]["person"]["display_name"], "Susan");

    // "Someone else will come" names who is actually driving — but doesn't claim
    // the ride, because Susan hasn't been asked yet.
    let (status, ride) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.rider_token,
        json!({ "action": "someone_else", "person_id": susan_id }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "someone_else failed: {ride}");
    assert_eq!(ride["status"], "open");
    assert!(ride["driver"].is_null());

    // Both answers are on the feed, by name, for the passenger to act on.
    let seen = feed_ride(&app, &f.group_id, &f.passenger_token, &ride_id).await;
    let responses = seen["responses"].as_array().unwrap();
    assert_eq!(responses.len(), 2);
    // Emily sorts before Wendel.
    assert_eq!(responses[0]["member"]["display_name"], "Emily");
    assert_eq!(responses[0]["response"], "someone_else");
    assert_eq!(responses[0]["person"]["display_name"], "Susan");
    assert_eq!(responses[1]["member"]["display_name"], "Wendel");
    assert_eq!(responses[1]["response"], "no_cart");

    // A plain "can't right now" replaces Wendel's earlier answer and names nobody.
    let (status, ride) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.driver_token,
        json!({ "action": "cant_right_now" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "cant_right_now failed: {ride}");
    let responses = ride["responses"].as_array().unwrap();
    assert_eq!(
        responses.len(),
        2,
        "answering again replaces the old answer"
    );
    assert_eq!(responses[1]["member"]["display_name"], "Wendel");
    assert_eq!(responses[1]["response"], "cant_right_now");
    assert!(responses[1]["person"].is_null());

    // Every answer is on the record, including the one that was overwritten.
    let events = ride_events(&pool, &ride_id).await;
    assert_eq!(
        events,
        vec![
            ("requested".to_string(), f.passenger_id.clone(), None),
            (
                "no_cart".to_string(),
                f.driver_id.clone(),
                Some(susan_id.clone())
            ),
            (
                "someone_else".to_string(),
                f.rider_id.clone(),
                Some(susan_id.clone())
            ),
            ("cant_right_now".to_string(), f.driver_id.clone(), None),
        ]
    );
}

// --- acceptance: the person an answer names is a member of the group, not a
// --- sentence — that's what makes them tappable ---

#[tokio::test]
async fn the_person_an_answer_names_must_be_someone_you_could_ping() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;
    let ride_id = open_ride(&app, &f, &[&f.driver_id]).await;

    let cases = [
        // "Someone else will come" is no use without a name.
        (json!({ "action": "someone_else" }), StatusCode::BAD_REQUEST),
        // Naming yourself, or the person waiting for the ride, is a mis-tap.
        (
            json!({ "action": "someone_else", "person_id": f.driver_id }),
            StatusCode::BAD_REQUEST,
        ),
        (
            json!({ "action": "no_cart", "person_id": f.passenger_id }),
            StatusCode::BAD_REQUEST,
        ),
        // The other answers name nobody.
        (
            json!({ "action": "on_my_way", "person_id": f.rider_id }),
            StatusCode::BAD_REQUEST,
        ),
        // And a name has to be a person in the group.
        (
            json!({ "action": "no_cart", "person_id": "nobody" }),
            StatusCode::NOT_FOUND,
        ),
    ];

    for (body, expected) in cases {
        let (status, resp) =
            ride_action(&app, &f.group_id, &ride_id, &f.driver_token, body.clone()).await;
        assert_eq!(status, expected, "{body} gave {resp}");
    }

    // "I don't have a cart" on its own is fine — you needn't know who has it.
    let (status, ride) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.driver_token,
        json!({ "action": "no_cart" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "bare no_cart failed: {ride}");
    assert_eq!(ride["responses"][0]["response"], "no_cart");
    assert!(ride["responses"][0]["person"].is_null());
}

// --- acceptance: someone tagged as riding along can't be named as the one who
// --- would drive — a lead has to be a person the passenger could actually ask ---

#[tokio::test]
async fn a_tagged_rider_cannot_be_named_as_the_substitute_driver() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    // Emily is tagged as riding along with the passenger.
    let (status, ride) = request_ride(
        &app,
        &f.group_id,
        &f.passenger_token,
        json!({
            "pickup_id": f.pickup_id,
            "dropoff_id": f.dropoff_id,
            "target_ids": [f.driver_id],
            "party_size": 2,
            "party_member_ids": [f.rider_id],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "request failed: {ride}");
    let ride_id = ride["id"].as_str().unwrap().to_string();

    // So neither "no cart" nor "someone else will come" may point at her — she
    // can't drive the cart she'd be riding in.
    for action in ["no_cart", "someone_else"] {
        let (status, resp) = ride_action(
            &app,
            &f.group_id,
            &ride_id,
            &f.driver_token,
            json!({ "action": action, "person_id": f.rider_id }),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{action} gave {resp}");
        assert_eq!(
            resp["error"],
            "they're riding with the passenger — name somebody who could drive"
        );
    }
}

// --- acceptance: a ride belongs to its group, and taking a step on it needs a
// --- token from that group ---

#[tokio::test]
async fn a_ride_cannot_be_moved_along_from_outside_its_group() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;
    let ride_id = open_ride(&app, &f, &[&f.driver_id]).await;

    let outsider = create_group(&app, "Lake 2027", "Mallory", "5550001111").await;
    let outsider_token = outsider["token"].as_str().unwrap();

    let (status, _) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        outsider_token,
        json!({ "action": "on_my_way" }),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // And an unknown ride is not found, even for a member of the group.
    let (status, _) = ride_action(
        &app,
        &f.group_id,
        "no-such-ride",
        &f.driver_token,
        json!({ "action": "on_my_way" }),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

// ----- the live feed stream (SSE) -----

/// Open the group's SSE feed stream without draining it — the streaming body is
/// held open, so it is read one event at a time with [`next_stream_event`]
/// rather than collected like an ordinary response.
async fn open_stream(app: &Router, group_id: &str, token: &str) -> Response {
    app.clone()
        .oneshot(get_with_token(
            &format!("/groups/{group_id}/feed/stream"),
            token,
        ))
        .await
        .expect("open stream")
}

/// Pull the next Server-Sent Event off a stream body as (event name, parsed data
/// JSON). Reads frames until it has a blank-line-terminated event, so it doesn't
/// matter how the bytes are chunked. Times out rather than hanging if nothing
/// arrives.
async fn next_stream_event(body: &mut Body) -> (String, Value) {
    let mut buf = String::new();
    while !buf.contains("\n\n") {
        let frame = timeout(Duration::from_secs(2), body.frame())
            .await
            .expect("timed out waiting for an SSE event")
            .expect("stream ended before an event arrived")
            .expect("stream frame error");
        if let Ok(bytes) = frame.into_data() {
            buf.push_str(&String::from_utf8_lossy(&bytes));
        }
    }

    let mut event = String::new();
    let mut data = String::new();
    for line in buf.lines() {
        if let Some(rest) = line.strip_prefix("event:") {
            event = rest.trim().to_string();
        } else if let Some(rest) = line.strip_prefix("data:") {
            data.push_str(rest.trim_start());
        }
    }
    let value = if data.is_empty() {
        Value::Null
    } else {
        serde_json::from_str(&data).expect("SSE data is JSON")
    };
    (event, value)
}

/// Assert that no delta reaches this stream within a short window — used to prove
/// a stream scoped to one group stays silent for another group's activity.
async fn expect_no_stream_event(body: &mut Body) {
    let got = timeout(Duration::from_millis(500), body.frame()).await;
    assert!(
        got.is_err(),
        "a delta reached a stream it should not have: {got:?}"
    );
}

// --- acceptance: a subscriber receives a delta after a mutation, carrying the
// --- ride as the feed now shows it — new request, then each lifecycle step ---

#[tokio::test]
async fn a_subscriber_receives_a_delta_after_each_mutation() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    // A bystander who is only watching the board opens the live stream.
    let resp = open_stream(&app, &f.group_id, &f.rider_token).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let mut body = resp.into_body();

    // The passenger asks for a ride over REST, as always...
    let ride_id = open_ride(&app, &f, &[&f.driver_id]).await;

    // ...and it arrives on the watcher's stream as a `ride` delta, carrying the
    // whole ride the way the feed shows it.
    let (event, data) = next_stream_event(&mut body).await;
    assert_eq!(event, "ride");
    assert_eq!(data["ride"]["id"], ride_id);
    assert_eq!(data["ride"]["status"], "open");
    assert_eq!(data["ride"]["pickup"]["name"], "The Pier");

    // The driver claims it — the lifecycle step is a delta too, with the new
    // status and driver.
    let (status, _) = ride_action(
        &app,
        &f.group_id,
        &ride_id,
        &f.driver_token,
        json!({ "action": "on_my_way" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (event, data) = next_stream_event(&mut body).await;
    assert_eq!(event, "ride");
    assert_eq!(data["ride"]["id"], ride_id);
    assert_eq!(data["ride"]["status"], "accepted");
    assert_eq!(data["ride"]["driver"]["display_name"], "Wendel");
}

// --- acceptance: the stream is scoped and authenticated exactly like the feed —
// --- a non-member can't open it, and never sees another group's deltas ---

#[tokio::test]
async fn the_stream_is_scoped_to_the_group() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    // A separate group, with its own member and its own places.
    let other = create_group(&app, "Lake 2027", "Mallory", "5550001111").await;
    let other_id = other["group_id"].as_str().unwrap().to_string();
    let other_token = other["token"].as_str().unwrap().to_string();
    let other_driver = join_group(&app, &other_id, "Nate", "5550002222").await;
    let other_driver_id = other_driver["member"]["id"].as_str().unwrap().to_string();
    let other_pickup = create_place(&app, &other_id, &other_token, "The Dock", 41.0, -85.0).await;
    let other_dropoff =
        create_place(&app, &other_id, &other_token, "The Marina", 41.1, -85.1).await;

    // A token from another group can't open this group's stream — same 403 the
    // plain feed gives.
    let resp = open_stream(&app, &f.group_id, &other_token).await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // No token at all is a 401.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/groups/{}/feed/stream", f.group_id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    // A member watches their own group's stream...
    let resp = open_stream(&app, &f.group_id, &f.rider_token).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let mut body = resp.into_body();

    // ...and a ride requested in the *other* group never reaches it.
    let (status, _) = request_ride(
        &app,
        &other_id,
        &other_token,
        json!({
            "pickup_id": other_pickup,
            "dropoff_id": other_dropoff,
            "target_ids": [other_driver_id],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    expect_no_stream_event(&mut body).await;

    // But a ride in the watcher's own group does — proving the stream is live,
    // not merely silent.
    let ride_id = open_ride(&app, &f, &[&f.driver_id]).await;
    let (event, data) = next_stream_event(&mut body).await;
    assert_eq!(event, "ride");
    assert_eq!(data["ride"]["id"], ride_id);
}

// --- acceptance: two subscribers in the same group both see a mutation, which
// --- is what lets two devices reflect each other's activity live ---

#[tokio::test]
async fn every_subscriber_in_the_group_sees_a_delta() {
    let app = test_app().await;
    let f = ride_fixture(&app).await;

    // Two different people in the group each open the stream — two devices.
    let mut first = open_stream(&app, &f.group_id, &f.passenger_token)
        .await
        .into_body();
    let mut second = open_stream(&app, &f.group_id, &f.driver_token)
        .await
        .into_body();

    let ride_id = open_ride(&app, &f, &[&f.driver_id]).await;

    for body in [&mut first, &mut second] {
        let (event, data) = next_stream_event(body).await;
        assert_eq!(event, "ride");
        assert_eq!(data["ride"]["id"], ride_id);
    }
}
