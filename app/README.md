# Goober app

Flutter client for Goober. This is the **walking skeleton**: start a
trip (creates a group with you as admin), persist the returned bearer token, and
render the group's activity feed — empty for now, with a friendly empty state and
the big **"Get a ride"** button (a placeholder at this stage).

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

## Test

```sh
cd app
flutter test        # widget + unit tests, headless — no emulator needed
```

- `test/token_store_test.dart` — bearer-token persistence.
- `test/feed_screen_test.dart` — empty-feed render + "Get a ride" button +
  opening the places screen.
- `test/api_client_test.dart` — request shapes, auth header, error mapping
  (groups + places).
- `test/places_screen_test.dart` — places list, admin-only add/edit/delete/copy
  affordances, add/delete/copy flows, and coordinate validation.
- `test/boot_flow_test.dart` — fresh boot → onboarding → persist token → feed;
  and boot-with-token → straight to feed.

## Structure

- `lib/src/api_client.dart` — HTTP client; `baseUrl` + `http.Client` injected.
- `lib/src/token_store.dart` — `TokenStore` interface, `SharedPreferences` +
  in-memory implementations.
- `lib/src/screens/` — onboarding, feed, and places screens. The places screen
  lists the group's curated places for any member and, for admins, adds
  add/edit/delete plus a thin "copy from another group" starting point.
  Coordinates are entered as plain lat/lng for now; a drop-a-pin map picker is
  deferred.
- `lib/main.dart` — `GooberApp` wires an `ApiClient` + `TokenStore` (both
  injectable) and routes to onboarding or feed based on the persisted token.
