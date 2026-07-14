# Goober — agent guide

Goober is a family-only "Uber for golf carts" for a yearly 4th-of-July beach trip. **`PRD.md` is the product + design source of truth — read it before writing code.** `README.md` covers the stack and layout; `pitch.html` is the family-facing vision.

## Agent skills

### Issue tracker

Issues live in the `tdashroy/goober` GitHub repo (via the `gh` CLI); external PRs are **not** a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles map 1:1 to identically-named GitHub labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root (created lazily; `PRD.md` is the interim glossary). See `docs/agents/domain.md`.

## Conventions

- **No references to issues, the PRD, or the tracker in code, comments, or commit
  messages.** Describe *what* the code does and *why* in place — the output must
  stand on its own. Read the issue/PRD for context, but don't cite issue numbers,
  "the PRD", or tracker labels in committed artifacts.
- **Admin-only features hang off the Admin screen** (`app/lib/src/screens/admin_screen.dart`),
  reached from the labeled admin entry point in the feed's app bar. Add a new
  admin feature as an entry in that screen's action list rather than giving it
  its own shortcut elsewhere — a bare, unlabeled shortcut reads as neither
  "administration" nor "admin-only" and members should never be shown a control
  they cannot use. Client-side gating is for clarity only; the server enforces
  admin permissions regardless.
- **Gating a feature to admins must not take it away from members.** Where
  members need to *see* what an admin curates — the group's places being the
  first case — give them a plain read-only view of it and keep the editing on the
  admin screen, rather than hiding the data behind the admin door. Two screens
  over one flagged screen: a viewer everyone opens (no management affordances at
  all, not even disabled ones) and a management screen only admins reach.

## Development

Monorepo: `server/` (Rust: axum + SQLite via sqlx) and `app/` (Flutter). Both run
locally with no cloud host (deploy comes later). Per-project run/test details are
in `server/README.md` and `app/README.md`.

- **Server tests:** `cd server && cargo test` — integration tests drive the axum
  router in-process against in-memory SQLite (no live DB/server needed).
- **App tests:** `cd app && flutter test` — headless widget/unit tests (no
  emulator needed). Inject `ApiClient` + `TokenStore` for testability.
- **sqlx compile-time queries:** `query!`/`query_as!` are checked against the
  committed `.sqlx/` offline cache; `server/.cargo/config.toml` sets
  `SQLX_OFFLINE=true` so builds never need a database. After changing any query
  macro, regenerate with `DATABASE_URL=sqlite://$(pwd)/goober-dev.db cargo sqlx
  prepare -- --features dev-seed --all-targets` and commit `.sqlx/` (the extra
  args keep the feature-gated seed queries in the cache). Needs `sqlx-cli` built
  with the sqlite driver.
- **Schema:** `sqlx migrate` from `server/migrations/`; migrations run on startup.
  Times are stored as ISO-8601 UTC strings (`2027-07-04T18:30:00Z`) so they sort
  lexicographically and parse directly in the client.
- **Dev testing harness:** `make scenario SEED=beach-trip USERS=bob,grandma` boots
  a seeded server plus one emulator per person, each already signed in as them.
  Both halves are dev-only and must stay impossible in a release build — the
  server seed sits behind the `dev-seed` cargo feature (off by default), the
  client auto-login behind `kDebugMode`. See `docs/dev-container.md`.
- **Local wiring:** server binds `0.0.0.0:8080`; the Android emulator reaches the
  host at `http://10.0.2.2:8080`. Cleartext HTTP is allowed in the debug manifest
  only (`app/android/app/src/debug/AndroidManifest.xml`).
- **JSON is UTF-8, and Dart's `http` won't assume that.** axum sends
  `application/json` with no `charset`, and for a charset-less *response* `http`
  falls back to **latin1** — which mangles every non-ASCII byte (a "🍪 cookies"
  offer, an accented name). `ApiClient` therefore decodes `resp.bodyBytes` as
  UTF-8 rather than reading `resp.body`. Mock responses in tests must be built
  the same way the server sends them — `http.Response.bytes(utf8.encode(json),
  200)` — or `http.Response(String, ...)` will throw on an emoji. (Request bodies
  are fine: `http` defaults *those* to UTF-8.)
- **Widget tests and lazy lists:** a `ListView` only builds what fits the 800×600
  test viewport, so fields below the fold aren't found. Give such a test a tall
  surface (`tester.binding.setSurfaceSize`) rather than scrolling step by step.

### Containerized dev environment

No host Flutter/Android toolchain needed — `docker/` + `docker-compose.yml` run
the whole stack. See `docs/dev-container.md`. Key points:

- **Build order matters:** the build/test and emulator images `FROM
  goober-base:latest`, so build the base first — `make base` (Compose does not
  order `FROM` dependencies). `make up` runs the headless default stack (just the
  server); `make emulator` is opt-in (behind the `emulator` compose profile) and
  builds the app + launches the emulator as a native window on the host desktop;
  `make test` is the CI-parity check. Builds and tests never need a display.
- The Flutter SDK in the base image is pinned to a stable release *tag*
  (`FLUTTER_VERSION`), chosen to satisfy `app/pubspec.yaml`'s Dart constraint.
  Pin a tag, not a bare commit — a detached commit reports `0.0.0-unknown` and
  pub rejects it against the SDK constraint.
- **App→server hop inside the emulator:** the guest's `10.0.2.2` is the *emulator*
  container, not the server, so the emulator container runs a `socat` bridge from
  its `:8080` to `server:8080`. Don't expect Compose DNS names to resolve inside
  the Android guest.
- **Never boot the emulator `-read-only`.** It leaves the Android guest with no
  IPv4 default route, so every `connect()` from the guest fails with
  `ENETUNREACH` — the app can't reach `10.0.2.2:8080`, its seeded sign-in fails,
  and `make scenario` silently comes up on onboarding instead of signed in. The
  flag looks tempting for running several emulators at once, but it buys nothing
  here: the AVD is baked into the image, so each container already boots its own
  private writable copy and there is no shared AVD to protect. The entrypoint
  pings `10.0.2.2` after boot and shouts if the guest can't reach the server, so
  this can't go unnoticed again.
- The emulator container is **privileged** with `/dev/kvm` and `/dev/dri` mapped
  in and the host X socket (`/tmp/.X11-unix`) mounted; it runs with `DISPLAY=:0`
  so its Qt window renders through the host X server as a native desktop window.
  KVM gives CPU accel and `/dev/dri` gives hardware GL (`-gpu host`, falling back
  to `swiftshader_indirect`). The host must `xhost +local:` once to allow it.
