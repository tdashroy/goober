//! Tests for the dev seed profiles and the sign-in-as-a-seeded-person route.
//!
//! Like the API tests, these drive the real router against a fresh in-memory
//! database, so what they prove is what a seeded server actually serves.

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use axum::Router;
use goober_server::{build_app, db, seed};
use http_body_util::BodyExt;
use serde_json::Value;
use sqlx::SqlitePool;
use tower::ServiceExt;

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

fn get(path: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(path)
        .body(Body::empty())
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

async fn seeded_pool() -> SqlitePool {
    let pool = db::in_memory_pool().await.expect("migrate in-memory db");
    seed::apply(&pool, "beach-trip").await.expect("seed");
    pool
}

async fn count(pool: &SqlitePool, table: &str) -> i64 {
    sqlx::query_scalar::<_, i64>(&format!("SELECT COUNT(*) FROM {table}"))
        .fetch_one(pool)
        .await
        .expect("count")
}

#[tokio::test]
async fn seeding_builds_the_named_world() {
    let pool = seeded_pool().await;

    assert_eq!(count(&pool, "groups").await, 1);
    assert_eq!(count(&pool, "members").await, 4);
    assert_eq!(count(&pool, "places").await, 4);

    let app = build_app(pool);

    // Every seeded person can use the API with their fixed token, and lands in
    // the seeded group.
    let (status, me) = send(&app, get_with_token("/me", &seed::dev_token("bob"))).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(me["display_name"], "Uncle Bob");
    assert_eq!(me["group_id"], "beach-trip");
    assert_eq!(me["is_admin"], false);

    // The trip's admin is an admin.
    let (_, grandma) = send(&app, get_with_token("/me", &seed::dev_token("grandma"))).await;
    assert_eq!(grandma["display_name"], "Grandma Jo");
    assert_eq!(grandma["is_admin"], true);

    // The group's feed and places are readable by a seeded member — this is the
    // world the app renders.
    let (status, feed) = send(
        &app,
        get_with_token("/groups/beach-trip/feed", &seed::dev_token("bob")),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(feed["group_name"], "Beach 2027");

    let (status, places) = send(
        &app,
        get_with_token("/groups/beach-trip/places", &seed::dev_token("jen")),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let names: Vec<&str> = places["places"]
        .as_array()
        .expect("places array")
        .iter()
        .map(|p| p["name"].as_str().expect("name"))
        .collect();
    assert!(names.contains(&"Grandma's"), "got {names:?}");
    assert!(names.contains(&"The Pier"), "got {names:?}");
}

#[tokio::test]
async fn seeding_twice_does_not_duplicate_the_world() {
    let pool = seeded_pool().await;
    seed::apply(&pool, "beach-trip").await.expect("re-seed");
    seed::apply(&pool, "beach-trip").await.expect("re-seed");

    assert_eq!(count(&pool, "groups").await, 1);
    assert_eq!(count(&pool, "members").await, 4);
    assert_eq!(count(&pool, "places").await, 4);

    // A token a client is already holding still works after a re-seed.
    let app = build_app(pool);
    let (status, _) = send(&app, get_with_token("/me", &seed::dev_token("bob"))).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn an_unknown_profile_is_an_error_not_a_silent_no_op() {
    let pool = db::in_memory_pool().await.expect("migrate in-memory db");
    let err = seed::apply(&pool, "no-such-trip").await.unwrap_err();
    assert!(err.to_string().contains("no-such-trip"), "got {err}");
    assert_eq!(count(&pool, "groups").await, 0);
}

#[tokio::test]
async fn the_dev_session_route_signs_a_client_in_as_a_seeded_person() {
    let app = build_app(seeded_pool().await);

    let (status, session) = send(&app, get("/dev/session/grandma")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(session["token"], seed::dev_token("grandma"));
    assert_eq!(session["group_id"], "beach-trip");
    assert_eq!(session["group_name"], "Beach 2027");
    assert_eq!(session["member"]["display_name"], "Grandma Jo");
    assert_eq!(session["member"]["is_admin"], true);

    // The token it hands back is a real one: it authenticates the group's feed.
    let token = session["token"].as_str().expect("token");
    let (status, _) = send(&app, get_with_token("/groups/beach-trip/feed", token)).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn the_dev_session_route_only_knows_seeded_people() {
    // Nobody seeded at all: even a well-formed request resolves to no one.
    let app = build_app(db::in_memory_pool().await.expect("migrate in-memory db"));
    let (status, _) = send(&app, get("/dev/session/bob")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // Seeded, but asking for someone who is not in the profile.
    let app = build_app(seeded_pool().await);
    let (status, _) = send(&app, get("/dev/session/nobody")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}
