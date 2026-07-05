# Goober — Product Requirements & Design Doc

> **What this is:** A silly-but-real family app: an "Uber for golf carts" for a yearly
> 4th-of-July beach trip where relatives spread across several rental houses and share a
> handful of golf carts. Today they coordinate rides by phone/text tag. Goober replaces
> that with two taps, a shared live feed, a points competition, and a traveling trophy.
>
> **Audience for this doc:** whoever builds it (the author, solo) — and any AI coding
> assistant helping. It is written to be read cold, with no prior context. It captures
> every decision made during design, *and the reasoning*, so future-you doesn't re-litigate
> settled questions.
>
> **Companion file:** `pitch.html` in this folder is the family-facing pitch page with
> visual mockups of all five core flows. Open it in a browser. It is marketing/vision, not
> spec — this doc is the source of truth.

---

## 0. TL;DR of the big decisions

| Decision | Choice | Why (short) |
|---|---|---|
| Name | **Goober** (not "Guber") | Zero strangers to confuse → clarity is worthless; "goober" = lovable goofball = the vibe. |
| Frontend | **Flutter / Dart** | Delight-first custom UI, one codebase both platforms, friend uses it. |
| iOS builds (no Mac) | **Codemagic cloud CI → TestFlight** | Author is on Linux; Apple toolchain needs macOS, Codemagic rents it. |
| Backend | **Rust: axum + SQLite (sqlx)** | Explicit learning goal; small well-scoped server. |
| Realtime | **Server-Sent Events (SSE)** | Simpler than WebSockets; fits "everyone watches the feed." |
| Push | **FCM** (transport only) | Flutter push = FCM (bridges APNs). Rust server POSTs to FCM. No Firestore/Functions. |
| Hosting | **Fly.io** (Docker + volume for SQLite) | Cheap, HTTPS, learn-cloud piece. |
| Local-first | **Level B**: device SQLite cache + optimistic writes + sync-on-reconnect; **server authoritative for claims** | Beach wifi is spotty; CRDTs can't enforce "exactly one claimer." |
| Identity | **Phone number = durable ID**, display name mutable, **no passwords** | Family trust model; phone also enables Call button + reinstall recovery. |
| Money | **Optional** — offers are free text (cookies, favors, or cash) | Not a payment app; barter is the fun. No money processing. |
| Timeline | Next real use = **July 4, 2027** (~1 year runway) | Optimize for learning + delight, not ship-speed. |

**Explicitly rejected (do not revisit without new reason):** Firebase-as-backend (no
learning, black box), Branch.io deep-link SDK (overkill + tracking for ~2 first-timers/yr),
bare native Swift+Kotlin (needs a Mac, two codebases, kills the project), continuous phone
GPS tracking in v1 (battery + background-permission hell), invented spendable currency
(causes family disputes), night-owl points bonus (don't gamify late driving when drinks are
involved).

---

## 1. Users, scope, and groups

- **Users:** the author's extended family only. Invite-only. No public signup, no discovery,
  no marketing, no App Store listing.
- **Group = one trip = one leaderboard = one trophy cycle.** "Beach 2026" is a group.
  "Beach 2027" is a fresh group next year. Points and IOUs are scoped to a group and reset
  automatically each year simply by starting a new group. Old groups are the yearly archive.
- **v1: a single admin (the author).** Model it so that **whoever creates a group is that
  group's admin** — that makes the future "anyone can start their own group" free. For v1 the
  creator just happens to always be the author.
- Assume roughly 10–30 members per group.

---

## 2. Core concept & the home screen

- **Front door = a live, group-visible activity feed** + a big **"Get a ride"** button on top.
  Opening the app shows the whole scene ("Emily → Todd, Pier → Grandma's, on my way"; "Wendel
  needs a ride, anyone?"). Half the time the feed answers your question before you ask.
- Tapping **"Get a ride"** takes you to a **roster** (people + an "Anyone" broadcast option) to
  choose who to ping. The roster is a means to an end, not the home screen.
- **Every ride request and its chat thread is visible to the whole group** (spectating is half
  the fun and doubles as passive coordination — nobody double-drives). **Only the two
  participants can post** in a thread; everyone else can read.

---

## 3. The ride lifecycle (state machine)

There are **two ways a ride enters the system**, mirror images of each other:

### 3a. Passenger-initiated (the main flow)
1. **Request** — passenger creates it: pickup place → dropoff place, party size, optional
   offer, and **now** or **scheduled** for a future time. Sent as a **direct ping** to one
   person, or a **broadcast** ("anyone?").
2. **"On my way"** — a driver accepts. On accept, capture a **one-shot GPS fix** (see §6) to
   determine the driver's origin for the cross-house bonus.
3. **"I'm here"** — driver marks arrival at pickup; this **pings the passenger** ("your ride's
   out front"). Also refreshes the driver's map position.
4. **"Delivered 🎉"** — **either** the driver **or** the passenger closes the ride. This banks
   the points (see §7).

- **Contest 🚩** — the passenger can contest a closure **at any time** (even later). A contest
  pings the other party, **pauses/reverses the banked points**, and reopens the thread to sort
  it out. No formal arbitration — social pressure + the public feed handle honesty.

### 3b. Driver-initiated (spontaneous rides)
- A driver can **start a trip on their own** and **tag the passengers** (from the roster), to
  claim points for a ride nobody requested ("hop in, I'm headed that way").
- Because nobody opted in, points are **pending until each tagged passenger confirms** ("Did
  Bob drive you from the pier? ✅"). Confirm → banks (bankable forever, can confirm days later).

**Asymmetry (intentional):** passenger-initiated *defaults to trust* (contest to undo);
driver-initiated *defaults to pending* (confirm to bank). Closes the point-farming loophole
without adding friction to honest rides.

### Ping responses (the 4 structured buttons + chat)
When pinged directly, the driver picks from a small menu, **not** a binary yes/no:
1. **"On my way"** (accept).
2. **"Can't right now"** (decline).
3. **"I don't have a cart"** — with an **optional tappable lead**: "…but *Susan* took it."
   Tapping the lead lets the requester re-ping that person in one tap. (Lead is a person tap,
   not free text, so the app can act on it.)
4. **"Someone else will come"** — accept-by-delegation, naming (tappable) who's actually
   driving.
- Plus a **chat thread** on every request: **group-readable, participant-writable**. All the
  nuance ("she's near the pier, sending her your way") lives here.

### Broadcast behavior
- Lands in the feed as an open request. **Anyone can claim with one tap; first claim wins.**
  The claim is announced in the feed so two people don't both drive out. On claim it becomes a
  normal participant thread.
- Requester can **cancel** ("nvm, got a ride").

### Lifecycle timing (everything auto-cleans — "people forget" is a design value)
- **Unclaimed "now" request:** auto-closes after **30 min** ("nobody grabbed this — still need
  a ride?" with one-tap re-post).
- **Scheduled request:** stays open until claimed or until its scheduled time passes unclaimed
  (then auto-closes with a nudge).
- **Reminders** (for scheduled, once claimed): at **T-15 min** and **T-0** (at the time), sent
  to **both** the driver and the requester (prevents the driver forgetting *and* the requester
  standing at the pier unsure).
- **Effective pickup time:** for a scheduled ride it's the scheduled time; for a "now" ride
  it's the moment of acceptance.
- **Accepted rides expire 30 min after the effective pickup time** — but expiry only removes
  them from the **public feed**. They **persist privately for the driver + passenger**, who can
  still close/bank them **at any point in the future** (people forget to hit Delivered). This
  gives each person a private "unsettled rides" list.

**Ride statuses:** `open` → `accepted`(on the way) → `arrived`(I'm here) → `delivered`(closed).
Plus `cancelled`, `expired` (public-hidden, privately bankable), `contested`. Driver-initiated:
`pending_confirmation` → `delivered` / `disputed`.

---

## 4. Party size & who's riding
- **Passenger sets party size** when requesting (default **"just me" = 1**; options 1/2/3/4+),
  and may **optionally tag which members** are in the party (from the roster).
- Party size shows in the feed (so a driver knows if one cart fits everyone).
- **Driver can adjust party size at "Delivered"** if reality differed; the adjusted number is
  what's used for points.

---

## 5. Places & the map
- Locations are a **curated list of named places** (houses + landmarks: "Grandma's", "The
  Pier", "Ice Cream Shack", "Dune St. Rental", "Sandbar"). **The admin curates them** each year
  (offer "copy places from last year's group" → 1 tap + edits).
- Each place has **coordinates** (admin drops a pin on a map when creating it), so places can be
  shown on a **map view with a pin per place**.
- When requesting, the user can pick pickup/dropoff **from the list OR by tapping the map** (map
  helps people who forget house names but know "the one just north of Grandma's").
- Optional **"📍 use my location"** shortcut when requesting: take a one-shot GPS fix and **snap
  to the nearest named place** (still allow manual pick for scheduled/remote requests).
- **No live user tracking.** The map shows fixed, curated pins only. (See §6 for the one
  exception: ride-scoped one-shot fixes.)

---

## 6. GPS (deliberately minimal in v1)
- **One-shot GPS fix at "On my way"** (`geolocator` `getCurrentPosition()`), **foreground /
  "while using the app" permission only** — negligible battery, no background modes, no
  persistent notification. Snap the coordinate to the **nearest named place** to get the
  driver's **origin** automatically (zero taps).
- **Cross-house bonus** = origin place ≠ pickup place (see §7).
- **Light live position:** while the driver has the app **foregrounded**, update their position
  on the map; also refresh on the "On my way" and "I'm here" taps. When the phone is pocketed
  the map shows **last known position** (honest — not a fake live blue dot). No background
  location in v1.
- **Deferred to future:** continuous live tracking / a real-time moving map. When wanted, the
  right tool is a **GPS tracker mounted on each cart** (sidesteps phone background-location and
  battery entirely, tracks the cart regardless of driver), **not** phone background GPS.

---

## 7. Goober Points (the competition)
- **Base: 1 point per passenger** delivered (rewards the person doing the big multi-rider haul).
- **Cross-house bonus: +1** when the driver traveled from a **different house** to do the
  pickup (origin place ≠ pickup place, from the §6 one-shot GPS). Rationale: same-house shuffles
  are trivial; coming from another house is real effort.
- **No night bonus** (family-friendly; do not incentivize late-night driving with alcohol
  around).
- **Build the points engine as a pluggable set of bonus rules** so more bonuses can be added
  later without a rewrite.
- Points are **earned only** (no spending, no currency). Points are awarded on close/confirm and
  can be reversed by a contest.
- **The gamification is the incentive to close rides out** — you *want* your points, so you'll
  remember to tap "Delivered." Expired-but-unclosed rides score nothing until closed.

---

## 8. Barter / the IOU board
- **Offers are free text** attached to a request ("🍪 cookies", "I'll owe you", or actual cash —
  money is allowed, just optional). Quick-tap emoji suggestions + free text.
- **The app tracks offers** as a ledger of outstanding promises. It cannot net them (a beer
  isn't a cookie), so it's a **list of IOUs**, each with a **"mark as paid ✅"** tap.
- Surfaced as an **end-of-trip "who owes whom" board** (also viewable all week).
- **Two separate scorekeeping systems** — keep them distinct in code and UI:
  - **IOU board** = qualitative promises (cookies/beers/favors/cash). Light-hearted.
  - **Goober Points** = quantitative, earned by driving, feeds the leaderboard + trophy.

---

## 9. Leaderboard, end-of-trip, trophy
- **Leaderboard is always visible** (a tab): live points ranking for the current group, plus the
  outstanding IOUs. The running competition is half the fun.
- **Admin taps "End the trip 🏆"** to trigger the ceremony: freeze the board, crown the champion
  (most rides/points that week), show a fun summary.
- **The Golden Goober** is a **physical traveling trophy** (a real silly object the author buys);
  the app just **names the champion and remembers past champions** — a cross-group/cross-year
  **Hall of Fame**. The app does not model the physical object.

---

## 10. Notifications
- **Push-first** (real push, not just in-app), with a distinct loud sound. Use iOS
  **Time-Sensitive** notifications to pierce most Focus modes. **Never claim "delivered"** in UI
  — say "pinged" (no app can guarantee an un-ignorable alert).
- **Call button** (see §11) is an ever-present **manual** fallback. **No timed auto-nudge to
  call** — "if you need it, you'll call."
- **Proposed notification inventory** (lightly discussed — refine during build):
  - You were pinged (direct request) — loud/Time-Sensitive.
  - Your broadcast was claimed (and by whom).
  - Someone responded to your ping (on my way / can't / no cart+lead / someone else).
  - Driver tapped "I'm here" → passenger.
  - Scheduled reminders **T-15** and **T-0** → both parties.
  - Ride delivered / points banked.
  - Ride contested 🚩 → other party.
  - Driver-initiated ride needs your confirmation → each tagged passenger.
  - Your request expired unclaimed → requester nudge.
  - (Admin) trip ended / "You won the Golden Goober 🏆".

---

## 11. Identity & auth
- **Phone number is the durable identity key.** **Display name is a mutable label** on top of it
  (people can rename to "Fireworks Champ" all week; points/IOUs/threads attach to the phone-ID
  underneath).
- **No passwords, no email, no SMS verification** (family trust model). On join: enter/confirm
  **name + phone**; the server stores it and returns a **random token** the app keeps; every
  request carries the token.
- Phone number also provides **free account recovery** (reinstall / new phone → re-enter same
  number → server re-attaches identity, points, IOUs) — a device-random-ID would lose this.
- **Auto-reading the phone number is impossible on iOS and unreliable on Android** — do **not**
  attempt it. Use a **phone-typed input field so OS autofill offers the number as a one-tap
  QuickType suggestion.** One-time, near-one-tap.
- **Call button** = a **`tel:` deep link** handoff to the OS dialer with the number pre-filled.
  No in-app voice. Note: iOS cannot auto-place a call (always drops the user on the dialer with
  the number filled → one tap to dial); make the uniform behavior "opens dialer, you tap call."

---

## 12. Onboarding & invite links
- **Pre-provisioned invites.** The admin keeps a **roster** (name + phone per person; carries
  over year-to-year like places). Each person gets a **unique personalized link** carrying an
  **opaque token** (e.g. `goober.app/join/x7k2`) — **not** their raw info in the URL.
- Tapping the link opens the app, exchanges the token with the server, and shows a **confirm
  screen**: "Joining as *Wendel, ⋯1234* — right? ✅ / edit." (Confirm, don't silently submit —
  correctness + privacy. A forwarded link leaks nothing because the number isn't in it.)
- **Blank fallback link** for anyone not on the roster or who'd rather type it.
- **Deep links:** use native **Universal Links (iOS) / App Links (Android)**, with the
  `.well-known/apple-app-site-association` and `assetlinks.json` files **self-hosted on the Rust
  backend's own domain** (free, no third party).
- **First-time-installer caveat:** native links **don't carry the token through a store install**.
  So pre-fill works flawlessly for anyone who **already has the app** (from year 2 on, most of
  the family). First-timers land on the blank form — solution: a one-line instruction, **"install,
  then tap my link again"** (second tap works because the app is present).
- **Do NOT use Firebase Dynamic Links (shut down 2025) or Branch.io** (a marketing-attribution
  SDK — overkill and privacy-hostile for a family app; would fire for ~2 first-timers/year and
  might not even match on modern iOS).

---

## 13. Tech stack (detail)

### Frontend — Flutter / Dart
- One codebase, both platforms; custom playful UI (personality > platform-native look).
- **Dev loop on Linux:** develop/hot-reload against an **Android emulator** (iOS Simulator can't
  run on Linux). Verify iOS periodically via cloud builds → TestFlight.
- Local DB: **`drift`** (SQLite) for the local-first cache. GPS: **`geolocator`**. Push:
  **`firebase_messaging`** (FCM). Deep links: **`app_links`** (or `uni_links`).

### iOS shipping without a Mac — Codemagic
- **Codemagic** (`codemagic.yaml` + App Store Connect API key) spins up a cloud macOS box,
  builds + code-signs the `.ipa`, manages signing certs, uploads to **TestFlight**. Free tier
  (~500 build-min/mo) is plenty.
- **Apple Developer account: $99/yr** is unavoidable. Android: free / **$25 one-time** Play
  (or just share the APK / Play internal testing).

### Backend — Rust
- **`axum`** web framework, **Tokio** async.
- **SQLite via `sqlx`** — single-file DB, no separate server. On Fly.io use a **persistent
  volume** (consider Litestream for backups). Upgrade to Postgres only if ever needed.
- **Realtime = Server-Sent Events (SSE):** server streams feed deltas to open apps; the app
  POSTs actions over plain REST. Simpler than WebSockets, fits the read-heavy shared feed.
- **A background Tokio task** wakes ~every minute to fire the 30-min expirations and the
  T-15/T-0 reminders.
- **Push:** the server POSTs to **FCM HTTP v1** to send notifications (FCM bridges to APNs for
  iOS). Only the messaging piece of Firebase is used — no Firestore, no Functions.
- **Auth:** issue a random bearer token on join; store name+phone; token on every request.
- **Hosting:** **Fly.io** (Docker container + volume, HTTPS included). Also serves the
  `.well-known` deep-link files on the app's domain.

### Local-first — Level B (with C as a stretch)
- **B (v1):** device-side SQLite cache (`drift`) for instant reads + offline viewing;
  **optimistic writes** (tap "claim" → UI updates immediately → server confirms or says "too
  late, Bob got it" → UI reconciles); **sync-on-reconnect** — the SSE channel streams server
  deltas down, the client flushes queued writes on reconnect. **Hand-roll this** (it's the point
  — great Rust + local-first learning). **The server stays authoritative for the claim race**
  (first-claim-wins is a uniqueness invariant; CRDTs provably can't enforce it without
  coordination, and push needs a server anyway).
- **C (stretch, after core works):** use **Automerge** (Rust core, fits the stack) as a CRDT for
  the **chat threads only** (append-heavy, benign merges). Keep CRDTs **away from claims/points**.
- **Do NOT adopt** PowerSync / ElectricSQL / Zero — they bring their own sync servers (mostly
  Postgres-tied) and would replace the Rust backend that is the whole learning goal (Zero
  doesn't even support Flutter).

---

## 14. Data model (sketch — refine during build)

- **Group**(`id`, `name`, `created_by`, `created_at`, `ended_at?`)
- **Member**(`id`, `group_id`, `phone` [durable key], `display_name`, `device_token`,
  `invite_token`, `is_admin`, `home_place_id?`)
- **Place**(`id`, `group_id`, `name`, `lat`, `lng`)
- **Ride**(`id`, `group_id`, `initiator` [passenger|driver], `requester_id?`, `driver_id?`,
  `pickup_place_id`, `dropoff_place_id`, `party_size`, `party_member_ids[]`, `offer_text?`,
  `scheduled_for?` (null = now), `status`, `origin_place_id?`, `cross_house_bonus` (bool),
  `points_awarded` (int), `contested` (bool), `created_at`, `accepted_at?`, `arrived_at?`,
  `delivered_at?`, `expires_at?`, `closed_by?`)
- **RideEvent**(`id`, `ride_id`, `type`, `by_member_id`, `at`) — status history / audit.
- **Message**(`id`, `ride_id`, `sender_id`, `body`, `at`) — thread; group-readable,
  participant-writable.
- **Iou** — derived from `Ride.offer_text` (`ride_id`, `from_member`, `to_member`, `text`,
  `settled` bool, `settled_at?`).
- Points/leaderboard = computed: sum of `points_awarded` per driver per group (exclude contested).

---

## 15. Suggested build order (learning-friendly, incremental)
1. **Rust backend skeleton:** axum + SQLite; join/auth token; Group + Member; admin Places CRUD.
2. **Flutter skeleton:** join flow (deep link + confirm screen + blank fallback); Feed screen
   reading from the server.
3. **Ride requests** (direct + broadcast) + the 4 responses + status transitions; **SSE** feed
   updates.
4. **Push** (FCM) wiring for pings/responses/"I'm here".
5. **Local-first B:** drift cache + optimistic writes + reconnect sync.
6. **Points + leaderboard + IOU board + end-of-trip ceremony + Hall of Fame.**
7. **One-shot GPS origin** + cross-house bonus + the places **map view**.
8. **Scheduling + reminders** (Tokio background task).
9. **Polish**, wire up **Codemagic → TestFlight**, distribute to the family.
- **Stretch:** Automerge CRDT threads (C); cart-mounted GPS tracker + live map.

---

## 16. Non-goals (v1)
- No public/stranger access, no discovery, no App Store listing.
- No payment processing (offers are free text; money is just one thing you can offer).
- No continuous/background GPS or live moving-cart map (future, via cart hardware).
- No per-person cart ownership tracking. (Future: track which **house** a cart is at.)
- No multi-tenant admin UI beyond a single admin creating groups.
- No scale/perf concerns beyond ~30 users per group.

---

## 17. Open questions / lightly-touched (decide during build)
- **Full notification inventory & copy** — §10 is a proposed list; finalize triggers, sounds,
  and grouping during build.
- **Carts-tracked-by-house** future feature — decided it's easier to track which *house* a cart
  is at than which *person* has it; mechanics undesigned (deferred).
- **Reminders/notification exact wording**, empty-feed states, and error copy.
- Backups for the SQLite volume (Litestream?) — confirm before the trip.

---

## 18. Design/brand notes (from the pitch page)
- **Palette (sunny boardwalk):** sand paper `#FBF6EA`, ocean-teal ink `#123B45`, golf-cart teal
  `#17A88C`, marigold `#FFBB2E` (points/trophy), coral `#FF6F5B`, sky `#8FD3E8` (maps).
- **Type:** rounded display face (`ui-rounded` where available) over a system body stack;
  tabular figures for all points/leaderboard numbers.
- **Voice:** playful, warm, family-first. No jargon in user-facing copy.
- Mascot: a friendly golf cart carrying a little peanut. Favicon 🥜.
- **Family cast used in mockups** (real names): Troy, Victoria, Todd, Susan, Bert, Bob, Angie,
  Joe, Emily, Anthony, Brett, Allison, Jamie, Drew, Leslie, Tony, Nancy, Cathy, Mary, Wendel.
