# Goober — agent guide

Goober is a family-only "Uber for golf carts" for a yearly 4th-of-July beach trip. **`PRD.md` is the product + design source of truth — read it before writing code.** `README.md` covers the stack and layout; `pitch.html` is the family-facing vision.

## Agent skills

### Issue tracker

Issues live in the `tdashroy/goober` GitHub repo (via the `gh` CLI); external PRs are **not** a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles map 1:1 to identically-named GitHub labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root (created lazily; `PRD.md` is the interim glossary). See `docs/agents/domain.md`.

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
  prepare` and commit `.sqlx/`. Needs `sqlx-cli` built with the sqlite driver.
- **Schema:** `sqlx migrate` from `server/migrations/`; migrations run on startup.
- **Local wiring:** server binds `0.0.0.0:8080`; the Android emulator reaches the
  host at `http://10.0.2.2:8080`. Cleartext HTTP is allowed in the debug manifest
  only (`app/android/app/src/debug/AndroidManifest.xml`).

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
- The emulator container is **privileged** with `/dev/kvm` and `/dev/dri` mapped
  in and the host X socket (`/tmp/.X11-unix`) mounted; it runs with `DISPLAY=:0`
  so its Qt window renders through the host X server as a native desktop window.
  KVM gives CPU accel and `/dev/dri` gives hardware GL (`-gpu host`, falling back
  to `swiftshader_indirect`). The host must `xhost +local:` once to allow it.
