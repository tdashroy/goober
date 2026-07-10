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
