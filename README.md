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

## 🧱 Planned stack (see `PRD.md` §13)

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
├── PRD.md          # spec + rationale (source of truth)
├── pitch.html      # family pitch page (mockups)
├── README.md
├── app/            # Flutter app            (to be created)
└── server/         # Rust backend           (to be created)
```

## 🗺️ Status

Design complete; implementation not yet started. Suggested build order is in `PRD.md` §15.
Next real deployment target: **July 4, 2027**.
