# Goober app

Flutter client for Goober. Start a trip (creates a group with you as admin),
persist the returned bearer token, curate the group's places, and render the
group's shared activity feed. The big **"Get a ride"** button opens the request
flow: pick a pick-up and drop-off from the curated places, say how many are
riding (1–8), offer something if you like, choose **now** or a scheduled time,
and ping one person from the roster. The new request appears in the feed for
the whole group, and the feed keeps itself fresh: it quietly refetches every
30 seconds (swapping new rides in without a spinner; a failed poll leaves the
board alone) and can be pulled to refresh, even from the empty state.

## Run on the Android emulator

1. Start the server (see `../server/README.md`), bound to `0.0.0.0:8080`.
2. Boot an Android emulator, then:

   ```sh
   cd app
   flutter run
   ```

The app talks to the dev machine at `http://10.0.2.2:8080` (the emulator's alias
for the host loopback). Override for a device/other host:

```sh
flutter run --dart-define=GOOBER_API_BASE=http://192.168.1.20:8080
```

Cleartext HTTP is enabled in the **debug** build only (`android/app/src/debug/
AndroidManifest.xml`); production uses HTTPS.

## Launch profiles (dev only)

Against a server that has loaded a seed profile (see `../server/README.md`), the
app can boot **already signed in** as one of the seeded relatives, skipping
onboarding — which is what makes it practical to run two emulators as two people:

```sh
flutter run --dart-define=CLIENT_PROFILE=bob
```

On startup it fetches that person's session from the server and uses the real
token it gets back; from there it is an ordinary client. The profile takes
precedence over any token already on the device, so relaunching as someone else
actually switches person. With no profile the boot flow is untouched, and if the
server has no such person the app falls back to normal onboarding — logging the
underlying error to the device log first (debug builds only), so a broken dev
harness leaves a trace instead of looking exactly like an unseeded one.

**This is an auth bypass, and it is impossible in a release build.** The gate
(`lib/src/dev_login.dart`) is `kDebugMode`, which the compiler folds to a constant
`false` outside debug — the sign-in path is then dead code and is tree-shaken out,
so a release APK built *with* `--dart-define=CLIENT_PROFILE=bob` ignores it and
shows onboarding. It also takes two to tango: the only session it could obtain
comes from a route that exists solely in a dev-seed server build.

## Test

```sh
cd app
flutter test        # widget + unit tests, headless — no emulator needed
```

- `test/token_store_test.dart` — bearer-token persistence.
- `test/feed_screen_test.dart` — empty-feed render, ride cards (route, party
  size, offer, timing), auto-refresh and pull-to-refresh behavior, "Get a ride"
  opening the request flow, and the labeled app-bar entries: Places for every
  member, Admin for admins only, and where each leads.
- `test/request_ride_screen_test.dart` — the request flow: route, party size,
  offer, now-or-scheduled, the direct ping to one member, and recovery when a
  request is rejected or the server is unreachable.
- `test/places_screen_test.dart` — the read-only places list: it shows the
  group's places and offers nobody, admin included, a way to change them.
- `test/manage_places_screen_test.dart` — the admin's places management: the
  add/delete/copy flows and coordinate validation.
- `test/admin_screen_test.dart` — the admin screen names its actions, says the
  area is admin-only, and "Manage places" opens places management.
- `test/api_client_test.dart` — request shapes, auth header, error mapping
  (groups + places + rides).
- `test/boot_flow_test.dart` — fresh boot → onboarding → persist token → feed;
  and boot-with-token → straight to feed.

## Structure

- `lib/src/api_client.dart` — HTTP client; `baseUrl` + `http.Client` injected.
- `lib/src/token_store.dart` — `TokenStore` interface, `SharedPreferences` +
  in-memory implementations.
- `lib/src/time_format.dart` — small dependency-free formatters for ride times
  ("6:30 PM" today, "Sat 4 Jul, 6:30 PM" otherwise) and days ("Today",
  "Tomorrow", "Sat 4 Jul").
- `lib/src/screens/` — onboarding, feed, request-ride, places, places-management,
  and admin screens. The feed's app bar carries two labeled entries: **Places**
  (every member) and **Admin** (admins only). The request-ride screen schedules a
  ride by asking for the *time*, with the day defaulting to today and changeable
  beside it; it takes injectable `pickScheduledTime` / `pickScheduledDay`
  callbacks so tests can drive scheduling without the platform pickers. The
  places screen is a read-only list of the group's curated places — what a member
  consults to know where they can be taken — while add/edit/delete and the thin
  "copy from another group" starting point live on the management screen, reached
  from the admin screen. Coordinates are entered as plain lat/lng for now; a
  drop-a-pin map picker is deferred. The admin screen gathers the admin-only
  actions in one labeled list ("Manage places" today); new admin features become
  entries there rather than shortcuts elsewhere.
- `lib/main.dart` — `GooberApp` wires an `ApiClient` + `TokenStore` (both
  injectable) and routes to onboarding or feed based on the persisted token.
