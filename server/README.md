# Goober server

Rust backend for Goober — `axum` + SQLite via `sqlx`. This is the **walking
skeleton**: create a group, join with name + phone, bearer-token auth,
and an empty group feed. Runs **locally over HTTP** — cloud deployment over HTTPS
comes later.

## Endpoints

| Method | Path                         | Auth   | Purpose |
|--------|------------------------------|--------|---------|
| GET    | `/health`                    | –      | Liveness check |
| POST   | `/groups`                    | –      | Create a group; caller becomes its admin |
| POST   | `/groups/{group_id}/join`    | –      | Join with name + phone; re-attaches by phone |
| GET    | `/me`                        | bearer | The caller's identity |
| GET    | `/groups/{group_id}/feed`    | bearer | Group activity feed (empty for now) |
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
binary and run on startup). The skeleton has just `groups` + `members`; rides,
places, messages, etc. arrive later.
