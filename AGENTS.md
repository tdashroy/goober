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
