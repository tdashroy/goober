# 🥜 Goober

**An "Uber for golf carts" — for one family, one beach, every 4th of July.**

Every year the family scatters across a few rental houses near the grandparents' beach
house and shares a handful of golf carts, coordinating pickups by phone/text tag. Goober
replaces that with two taps: a shared live feed, ping-a-cousin (or broadcast) ride
requests, a barter/IOU board, a points competition, and a traveling trophy — the
**Golden Goober**.

It is a native app for **both iPhone and Android**, family-only and invite-only. It is
also a deliberate learning project (Flutter, Rust, local-first sync).

---

## 📄 Start here

- **[`PRD.md`](./PRD.md)** — the complete product + design spec, with the reasoning behind
  every decision. **This is the source of truth. Read it first.**
- **[`pitch.html`](./pitch.html)** — the family-facing pitch page with visual mockups of the
  five core flows. Open in a browser. (Vision, not spec.)

> **For AI coding assistants:** read `PRD.md` in full before writing any code. It records
> what was decided *and what was explicitly rejected*, so you don't re-litigate settled calls.

---

## 🧱 Planned stack

| Layer | Choice |
|---|---|
| App | **Flutter / Dart** (one codebase, both platforms) |
| iOS builds (from Linux, no Mac) | **Codemagic** cloud CI → TestFlight |
| Backend | **Rust** — `axum` + **SQLite** (`sqlx`) |
| Realtime | **Server-Sent Events (SSE)** |
| Push | **FCM** (transport only; bridges APNs) |
| Hosting | **Fly.io** (Docker + persistent volume) |
| Offline | **Local-first** — device SQLite cache, optimistic writes, sync-on-reconnect; server authoritative for ride claims |

## 📁 Repo layout (as it grows)

```
goober/
├── PRD.md              # spec + rationale (source of truth)
├── pitch.html          # family pitch page (mockups)
├── README.md
├── app/                # Flutter app    — see app/README.md
├── server/             # Rust backend   — see server/README.md
├── docker/             # container build files for the dev environment
├── docker-compose.yml  # server + emulator + test stack
├── Makefile            # convenience targets (base, up, test, …)
└── docs/               # guides — e.g. docs/dev-container.md
```

## 🚀 Run it locally

Everything runs on the dev machine — no cloud host.

```sh
# 1. Backend (Rust): serves on http://localhost:8080
cd server && cargo run

# 2. App (Flutter): boot an Android emulator, then
cd app && flutter run     # talks to the server at http://10.0.2.2:8080
```

Tests: `cargo test` in `server/`, `flutter test` in `app/` (both headless).
Details in [`server/README.md`](./server/README.md) and [`app/README.md`](./app/README.md).

### …or without installing the toolchain

Prefer not to install Flutter/Android/Rust locally? A Docker setup builds, tests,
and **runs** the whole stack. Builds, tests, and the server are fully headless;
the Android emulator is opt-in and appears as a native window on your desktop:

```sh
make base && make up      # headless default stack: just the server
make test                 # analyze + headless tests, no host toolchain
make emulator             # opt-in: app on an emulator, as a native desktop window
make scenario             # a whole trip, seeded: one emulator per relative, each signed in
```

Goober is a group app, so testing it by hand means being several people at once.
`make scenario` does that for you: it boots the server with a ready-made trip —
a group, relatives, places — and opens one emulator window per person, each
already signed in as them. It is dev-only and, by construction, impossible in a
release build.

Full guide: [`docs/dev-container.md`](./docs/dev-container.md). The default stack
needs only Docker; the emulator additionally needs `/dev/kvm`, `/dev/dri`, and a
local display.

## 🗺️ Status

**Built so far:** create/join a group, bearer-token auth, admin-curated group
places (any member views the list; the admin adds, edits, deletes, or copies from
another group), an admin screen gathering the admin-only actions behind a labeled
entry in the feed, and **requesting a ride** — pick a route from the curated places,
say how many are coming, offer something (or not), ask for it now or schedule it,
and ping one person from the roster. The new request lands in the group's shared
activity feed, which everyone sees. All running locally end to end.

Still to come: the rest of the ride lifecycle (claiming, "I'm here", "delivered"),
broadcast ("anyone?") requests, SSE, push, points, and cloud deploy. Suggested
build order lives in the PRD. Next real deployment target: **July 4, 2027**.
