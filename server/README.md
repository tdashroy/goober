# Goober server

Rust backend for Goober — `axum` + SQLite via `sqlx`. Create a group, join with
name + phone, bearer-token auth, curate the group's places, request a ride, and
read the group's shared feed. Runs **locally over HTTP** — cloud deployment over
HTTPS comes later.

## Endpoints

| Method | Path                         | Auth   | Purpose |
|--------|------------------------------|--------|---------|
| GET    | `/health`                    | –      | Liveness check |
| POST   | `/groups`                    | –      | Create a group; caller becomes its admin |
| POST   | `/groups/{group_id}/join`    | –      | Join with name + phone; re-attaches by phone |
| GET    | `/me`                        | bearer | The caller's identity |
| GET    | `/groups/{group_id}/feed`    | bearer | Group activity feed: the group's rides, newest first |
| GET    | `/groups/{group_id}/members` | bearer | The group roster — who you can ping for a ride |
| POST   | `/groups/{group_id}/rides`   | bearer | Request a ride (direct ping to one member) |
| GET    | `/groups/{group_id}/places`  | bearer | The group's curated places (any member) |
| POST   | `/groups/{group_id}/places`  | admin  | Create a place (`name`, `lat`, `lng`) |
| PUT    | `/groups/{group_id}/places/{place_id}` | admin | Rename / move a place |
| DELETE | `/groups/{group_id}/places/{place_id}` | admin | Delete a place |
| POST   | `/groups/{group_id}/places/copy` | admin | Copy places in from another group (`from_group_id`) |

`POST /groups` and `/join` return `{ token, group_id, group_name, member }`. Send
the token as `Authorization: Bearer <token>` on every authenticated request.

**Places:** a group's curated named locations (houses + landmarks) with map
coordinates. Any member may read them; only the group's admin may create, rename,
delete, or copy — enforced server-side (non-admin mutations are rejected).
Places are scoped to their group. The read and every mutation return the group's
full current list as `{ group_id, places: [{ id, group_id, name, lat, lng }] }`
so a client refreshes from one response.

**Rides:** a passenger requests a ride from one curated place to another, for a
party of 1 to 8 ("just me" by default; anything outside that range is a `400`),
with an optional free-text `offer` (cookies, a favor, or cash — never processed,
it's just text) and either **now** (`scheduled_for` omitted/null) or a future
ISO-8601 time. The request is a **direct ping** to a set of members:
`target_ids` names everyone being asked to drive — one person, or a few, so the
passenger can ask whoever might be free. At least one is required; the passenger
can't be among them, and naming the same person twice is a `400`. The passenger
may also tag which members are riding along (`party_member_ids`) — a tag list,
not a headcount, so it can be shorter than `party_size`, and nobody being asked
to drive can be on it.

Everything is group-scoped: every id in the body is resolved *within the caller's
group*, so an id from another group reads as `404`, and a token from another
group is `403`. A new request is `open` and immediately appears in that group's
feed — which is shared, not personal: everyone in the group sees every ride, with
its route, party size, and offer.

**Roster:** `GET /groups/{group_id}/members` returns every member of the group
(the caller included — the app's ping picker filters you out) as
`{ group_id, members: [{ id, display_name, is_admin }] }`. Like the feed, it's a
group-visible surface, so it carries no phone numbers — only your own record
(the `member` in `POST /groups`/`join` responses and `GET /me`) includes a phone.

**Identity:** the phone number is the durable identity key; the display
name is a mutable label. Re-joining with the same phone re-attaches the same
member (no duplicate) and returns their existing token — reinstall recovery for
free. No passwords/email/SMS (family trust model).

## Run it

```sh
cd server
cp .env.example .env          # optional; defaults are fine for local dev
DATABASE_URL="sqlite://goober-dev.db" GOOBER_BIND="0.0.0.0:8080" cargo run
```

The server creates the SQLite file and runs migrations on startup. Binding
`0.0.0.0` lets the Android emulator reach it at `http://10.0.2.2:8080`.

## Seed profiles (dev only)

Testing a group app against an empty database means creating a group and joining
as several people before anything is interesting. A **seed profile** is a
ready-made world the server loads at startup instead — a group, its members, its
places, all with fixed identities so a client can be pointed at one of them by
name:

```sh
SEED_PROFILE=beach-trip cargo run --features dev-seed
```

Seeding is idempotent: rows are written by stable ids, so booting again refreshes
that world rather than duplicating it, and tokens already in a client's hands keep
working. With no `SEED_PROFILE` the server boots empty as usual.

Profiles hand out valid bearer tokens for made-up people, so they live behind the
**`dev-seed` Cargo feature, which is off by default**. A plain `cargo build` — and
a plain build of the Docker image — contains no seed data, no fixed tokens, and no
`GET /dev/session/{person}` route; `SEED_PROFILE` there is ignored with a warning.
The profiles themselves are in `src/seed.rs`.

## Test

```sh
cargo test        # unit + integration tests, no live DB or server needed
```

Integration tests (`tests/api.rs`) drive the real `axum` router in-process against
a fresh in-memory SQLite database — no network, no files.

## sqlx offline cache

Queries are compile-time checked with `sqlx::query!`. The `.sqlx/` directory holds
the committed offline cache, and `.cargo/config.toml` sets `SQLX_OFFLINE=true`, so
`cargo build`/`cargo test` never need a live database.

**After changing any `query!` macro, regenerate the cache against a real DB:**

```sh
DATABASE_URL="sqlite://$(pwd)/goober-dev.db" cargo sqlx prepare -- --features dev-seed --all-targets
```

(The extra cargo arguments make sure the queries behind the `dev-seed` feature are
cached too — without them their entries would be dropped and a dev-seed build
would fail to compile offline.)

(Requires `sqlx-cli` built with the sqlite driver:
`cargo install sqlx-cli --no-default-features --features sqlite,rustls`.)
Commit the regenerated `.sqlx/` files.

## Migrations

Schema lives in `migrations/` and is applied via `sqlx migrate` (embedded in the
binary and run on startup): `groups` + `members`, `places`, and `rides` +
`ride_party_members`. Messages, IOUs and points arrive later.

Times are stored as ISO-8601 UTC strings (`2027-07-04T18:30:00Z`) so they sort
lexicographically, compare with SQLite's date functions, and parse directly in
the client.
