# Containerized dev environment

Build, test, and **run** the full Goober app — Flutter client on an Android
emulator plus the Rust server — without installing the Flutter or Android
toolchain on your machine. Everything runs in Docker.

The emulator runs *inside* a container, but its GUI is drawn as a **native window
on your desktop** (through your host X server) — no browser, no VNC. Builds and
tests are fully headless and never touch a display; only the (opt-in) emulator
needs one.

## What you get

| Piece | Container | How you use it | Needs a display? |
|---|---|---|---|
| Rust `axum` + SQLite server | `server` | `http://localhost:8080` | No |
| Static analysis + headless tests | `test` | `make test` | No |
| Debug APK build (feeds the emulator) | `apk-builder` | runs on `make emulator`, then exits | No |
| Android emulator with the app installed | `emulator` | native window on your desktop | **Yes** |
| Interactive Flutter hot-reload loop | `dev` | `make dev` (attaches to a running emulator) | via the emulator |
| Several emulators, each as a different person | `emulator`, `emulator-2`, … | `make scenario` (see [the dev testing harness](#the-dev-testing-harness)) | **Yes** |

The `server` and `test` pieces are the **default, headless stack**. The
`apk-builder` and `emulator` pieces are **opt-in** behind the `emulator` compose
profile, so a machine with no display can still build, test, and run the server
with the default `make up` stack untouched.

All four share one **base image** (`docker/base.Dockerfile`) that holds the
Flutter SDK, Android SDK, and JDK 17, so the toolchain is installed once.

### One Compose project per checkout — go through `make`

Compose names its containers and its named volumes after a **project**, and left
to itself it takes that name from the directory it runs in. Every clone and every
worktree of this repo is a directory called `goober`, so out of the box they all
shared *one* stack — one server database, one APK volume, one set of emulator
containers. That bites in ways that look like unrelated bugs: a branch boots onto
a database some other branch has already migrated and the server refuses to start
against it, or a run inherits an emulator with another branch's app still
installed.

So the `Makefile` derives the project name from the **absolute path of the working
directory** (`goober-<checksum of $PWD>`) and exports it, which scopes every
compose invocation — `up`, `emulator`, `scenario`, `dev`, `test`, `down`, `logs`,
`clean` — to that directory alone. Two consequences worth knowing:

- Re-running in the **same** directory reuses that directory's own containers,
  volumes and build caches, so repeat runs stay fast.
- A **different** checkout gets its own set. It cannot see or reuse yours, and its
  `make down` / `make clean` cannot destroy yours.

The corollary: **run the stack through `make`, not a bare `docker compose`.** A
raw `docker compose` in the checkout falls back to the directory-name project and
lands outside the one `make` manages. If you need the raw command, take the name
with you: `docker compose -p "$(make -s project)" ps`.

#### The one thing a project cannot isolate: the host port

The server is published on host port **8080**, and a host port belongs to the
machine, not to a Compose project. Two checkouts running **at the same time** will
fight over it — the second one's server fails to start with `Bind for
0.0.0.0:8080 failed: port is already allocated`. So tell them apart by hand:

```sh
make scenario PORT=8081     # in the second checkout
```

Only *host* access moves. The emulators reach the server over the Compose network
on its container port, so they neither know nor care which host port it is
published on — a `PORT=` scenario boots exactly like any other. (Running the
checkouts one after another needs none of this; the collision is only while both
are up.)

Upgrading an existing machine? Checkouts from before this change left their
containers and volumes behind under the old shared `goober` project, which `make
clean` no longer reaches. Sweep them once with:

```sh
docker compose -p goober down -v --remove-orphans
```

### Persisted build caches

The first `flutter build apk` in a build/test container installs the Android
**NDK** and **CMake** (auto-downloaded into `$ANDROID_SDK_ROOT/{ndk,cmake}`, ~2-3
min) and fills the **Gradle** and **pub** caches. Those live in the container
filesystem, so without help a fresh container — after `make down`, on a new build
image, or a new machine — reinstalls them every time.

To avoid that, the `apk-builder` and `test` services mount named volumes at the
specific cache directories, so a fresh container reuses them and does the fast
incremental build instead:

| Volume | Mount | Holds |
|---|---|---|
| `android-ndk` | `$ANDROID_SDK_ROOT/ndk` | auto-installed Android NDK |
| `android-cmake` | `$ANDROID_SDK_ROOT/cmake` | auto-installed CMake |
| `gradle-cache` | `/home/dev/.gradle` | Gradle build cache + deps |
| `pub-cache` | `$PUB_CACHE` (`/opt/pub-cache`) | Dart/Flutter packages |
| `android-config` | `/home/dev/.android` | the debug keystore — see below |

Measured effect: a cold APK build on empty volumes ~**200s** (NDK installs once),
then a fresh container reusing the volumes ~**40s** with no NDK reinstall.

Two details make this safe: the volumes mount at the specific cache *subdirs* so
they never shadow the platform-tools/platforms/build-tools baked into the base
image's `$ANDROID_SDK_ROOT`; and the mount points are pre-created owned by the
unprivileged `dev` user in `docker/build-test.Dockerfile`, so a fresh (otherwise
root-owned) volume is seeded writable by the build user. The caches survive `make
down` and are cleared by `make clean`.

### The debug keystore is persisted too, and that is not an optimization

A fifth volume, `android-config`, holds `/home/dev/.android` — where the **debug
keystore** every debug APK is signed with lives. It is persisted for correctness,
not speed.

The Android build mints that keystore on demand when it is missing, and it lives
in the build container's home directory. A recreated `apk-builder` container
therefore used to sign each run's APK with a **brand-new key**. Meanwhile the
emulators keep their AVD *writable* across a run (they must — booting
`-read-only` breaks guest networking), so a container reused by a later `make
scenario` still has the previous run's app installed. Android will not update an
installed app with one signed by a different key: `adb install` fails with
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`, the entrypoint dies, and the emulator
container exits — a `make scenario` that only worked after a `make clean`.

So: `docker/build-apks.sh` creates the keystore exactly **once**, on the persisted
volume, with the stock debug parameters, and every later build reuses it. The key
is stable, the install is an ordinary update, and reruns need no teardown. As a
backstop, `docker/emulator-entrypoint.sh` treats a refused install as recoverable
— it uninstalls the app from the AVD and installs again — so an AVD carrying an
app signed by a key that no longer exists cannot wedge a boot either. `make clean`
removes this volume in the same sweep that removes the emulator containers, so the
key and the apps installed against it are only ever discarded together.

This is strictly the **debug/dev-seed** signing path — the harness builds
`--debug` only, and nothing here touches release signing.

## Host requirements

- **Docker** with the Compose plugin (tested on Docker 27.4 / Compose v2.32).
- For the **default stack** (server, build, test): nothing else. No display, no
  KVM, no GPU.
- For the **opt-in emulator** (native window on your desktop):
  - **`/dev/kvm`** present and usable — CPU acceleration. `ls -l /dev/kvm`.
  - **`/dev/dri`** present — host GPU for hardware GL. `ls -l /dev/dri`.
  - A local **X server** you can draw to. On a Wayland session this is
    **XWayland** (`DISPLAY=:0`, socket at `/tmp/.X11-unix/X0`) — already running
    under GNOME/KDE Wayland. Pure-Wayland-only sessions without XWayland are not
    supported for the container-native window; use the [native-host
    fallback](#fallback-native-host-emulator) instead.
  - One-time host authorization so the container may draw to your X server
    (below).

The emulator container runs **privileged** with `/dev/kvm` and `/dev/dri` mapped
in, so the process inside (running as root) can use KVM and the GPU regardless of
host group ownership of those devices — you do **not** need to join the `kvm`,
`video`, or `render` groups for this setup.

## First run

The base image is large (Flutter + Android SDK + a system image) and the first
build downloads a lot; expect the initial build to take a while.

```sh
# 1. Build the shared toolchain image (needed once; rerun if base changes).
make base

# 2a. Headless default stack — just the server. No display needed.
make up

# 2b. …or the full thing with the emulator as a native window (see below).
make emulator
```

## Run the server (headless default stack)

```sh
make up            # server only, built and started
```

This starts **only the server** (reachable at `http://localhost:8080`). It needs
no display, no KVM, and no GPU — it is what runs on a remote/headless host or in
CI. The emulator is *not* part of this stack.

## Run the app in the emulator (native window)

This is the primary, container-native path: the emulator process runs in a
container, but its Qt window appears as a **normal window on your desktop**.

**One-time host authorization.** The container connects to your X server over the
mounted socket. Allow local clients to connect once per login session:

```sh
xhost +local:      # allow local (non-network) clients — includes the container
```

Revoke it again when you are done if you like: `xhost -local:`. (A tighter
alternative that avoids opening it to all local users is an xauth cookie; see
[Troubleshooting](#troubleshooting).)

**Launch it:**

```sh
make emulator      # server + APK build + emulator, built and started
```

On `make emulator`, Compose:

1. builds and starts **server**, waiting until its `/health` check passes;
2. runs **apk-builder** to produce the debug APK into a shared volume;
3. starts **emulator**, which boots Android (KVM-accelerated), opens its window
   on your desktop, installs the APK, and launches the app.

Watch progress with `make logs`. The
emulator prints `boot completed` and then `ready` once the app is up; the window
appears on your desktop during boot.

The emulated device runs at a compact 540×1140 @ 240dpi (a normal phone layout)
so the window is a comfortable size, and it uses the classic **3-button
navigation bar** (Back / Home / Recents) rather than gesture navigation, so you
can always click your way back out of any screen.

### GPU backend

The emulator defaults to **hardware GL** (`-gpu host`) via `/dev/dri`. If the
window is glitchy or GL fails to initialize in your environment, fall back to
software GL — KVM still gives CPU acceleration either way:

```sh
EMULATOR_GPU=swiftshader_indirect make emulator
```

The entrypoint logs the chosen backend and, at startup, whether it can reach your
X server and what GL renderer `/dev/dri` provides. After boot it also checks that
the Android guest can reach the server through the `socat` bridge and logs
`guest reaches the server ✓`, or a loud multi-line `WARNING` banner if it cannot
(retrying for `SERVER_REACH_TIMEOUT` seconds, default 60, while the server
starts).

## Hot-reload dev loop (`make dev`)

`make emulator` is the clean-boot path: it builds a fresh debug APK, installs it,
and launches the app. Great for a first run, but a full rebuild+reinstall on every
code change is slow. Once the emulator is up, `make dev` gives you Flutter's fast
inner loop instead — an interactive `flutter run` **attached to the running
emulator**, so a code change reloads in well under a second with app state
preserved.

```sh
make emulator      # in one terminal: server + APK build + emulator window (keep running)
make dev           # in another: drops you into `flutter run` on that emulator
```

`make dev` drops you straight into the `flutter run` session. Its key commands:

| Key | Action |
|---|---|
| `r` | **Hot reload** — recompile changed code and rebuild the widget tree, keeping app state. |
| `R` | **Hot restart** — restart the app from `main()` (drops state); use when a change can't hot-reload (e.g. `main`, global state, native code). |
| `q` | **Quit** — stop `flutter run` and terminate the app on the device. |

Edit a Dart file under `app/lib/`, switch to the `make dev` terminal, press `r`,
and the change appears on the emulator. A full `flutter build apk` is **not** run —
only the changed libraries are recompiled and sent, e.g.:

```
Performing hot reload...
Reloaded 1 of 902 libraries in 550ms (compile: 42 ms, reload: 231 ms, reassemble: 173 ms).
```

The app reaches the server exactly as under `make emulator`: `flutter run` builds
with `--dart-define=GOOBER_API_BASE=http://10.0.2.2:8080`, and the emulator
container's `socat` bridge forwards `10.0.2.2:8080 → server:8080`.

### How `make dev` reaches the emulator

`flutter run` runs in the **build/test image** — no Flutter on the host — but it
needs to (a) see the emulator as an adb device, (b) install/launch the app, and
(c) connect to the app's **Dart VM service** over an adb port-forward to drive hot
reload. The emulator runs in a *different* container with its own adb server, so
the naive setup would leave the VM-service forward on the emulator container's
loopback where `flutter run` can't reach it.

The `dev` service sidesteps all of that by **joining the emulator container's
network namespace** (`network_mode: "service:emulator"` in `docker-compose.yml`).
The two containers then share one loopback, so the emulator's adb server
(`127.0.0.1:5037`), the adb `forward` ports `flutter run` allocates, and the Dart
VM service it connects to are all on the same `127.0.0.1` — `flutter run
-d emulator-5554` just works, with no adb-over-TCP bridging or shared-adb-server
port plumbing. Verify from inside the loop's container that a device is present:
`adb devices` lists `emulator-5554`.

Because it attaches to the *running* emulator, `make dev` requires `make emulator`
to be up first; if no emulator is running there is no netns to join and the
command errors out — start `make emulator` and retry.

### Auto-reload on save, and why the loop is manual

The loop is **press-`r`**, by design and by two independent constraints:

1. The `flutter run` **CLI has no watch/poll mode** — it does not reload on save in
   any environment; reload-on-save is an IDE-integration feature, not a CLI flag
   (`flutter run --help` has no `--watch`/`--poll`). The CLI's programmatic
   equivalents are `--pid-file` + `SIGUSR1` (reload) / `SIGUSR2` (restart).
2. Even an IDE watcher would not help here: on Linux, **inotify file-change events
   do not cross the host→container bind mount**, so a save on the host is invisible
   to a watcher inside the container. (A watcher running *inside* the container, or
   one using CPU-heavy **polling** instead of inotify, would see it — but that
   burns CPU continuously and buys nothing over pressing `r`.)

So: edit on the host, press `r` in the `make dev` terminal. Manual reload works
regardless of the bind-mount limitation, which is exactly why it's the loop.

## The dev testing harness

Goober is a *group* app: almost nothing interesting happens with one person on
one screen. Testing it by hand used to mean starting a trip, typing a name and a
phone number, adding places, then somehow being a second relative as well. The
harness collapses that into one command:

```sh
make scenario                                    # the beach trip, as Bob, Grandma and Jen
make scenario SEED=beach-trip USERS=bob,pete     # pick the world and the people
```

That gives you a **server already holding a whole trip** and **one emulator window
per person, each already signed in as them**. No login screens, no typing, no
coordinating two identities by hand. Everything below is **dev-only and cannot
exist in a shipped build** — see [the guardrails](#guardrails-none-of-this-can-ship).

### The three pieces

**1. A seeded server.** `SEED=beach-trip` names a *seed profile*
(`server/src/seed.rs`): a ready-made world the server loads into its database at
startup. `beach-trip` is a group ("Beach 2027") with four relatives — Grandma Jo
(the trip's admin), Uncle Bob, Cousin Jen, and Pete — and four places: Grandma's,
The Blue House, The Pier, and the Ice Cream Shack. Its people have **fixed
identities**, which is what lets a client sign in as one of them by name.

Seeding is **idempotent**: every row is written by a stable id, so booting again
against the same database refreshes that world instead of duplicating it, and
tokens a running client already holds keep working. Name no profile and the
server boots empty, exactly as it always did.

You can seed without the emulator at all — handy for poking at the API:

```sh
SEED_PROFILE=beach-trip make up
curl -s localhost:8080/dev/session/bob                                  # Bob's session + token
curl -s -H 'Authorization: Bearer devseed-bob' localhost:8080/groups/beach-trip/places
```

**2. Several emulators side by side.** `USERS=bob,grandma,jen` — the default —
runs one emulator per person: the `emulator` service plus a generated `emulator-2`
and `emulator-3` (and `-4`, …). Each
draws its own native window, each bridges to the same server through its own
`socat` hop, and each boots **its own private copy** of the AVD baked into the
image — nothing is shared across containers, so no instance can lock or write
state that the others trip over.

The generated services live in `docker-compose.scenario.yml`
(`docker/gen-scenario.sh` writes it; it is gitignored — how many people you want
is not a fact about the repo). `make down` and `make clean` sweep them up with
`--remove-orphans`, so teardown does not need to know how many you ran.

**3. Client launch profiles.** A client profile is a compile-time define —
`--dart-define=CLIENT_PROFILE=bob` — that makes the app boot **already signed in
as Bob** instead of showing onboarding. On startup it asks the server for that
seeded person's session (`GET /dev/session/bob`) and uses the real bearer token it
gets back, so from that point on the app is a completely ordinary client. The
profile wins over any token already on the device, so relaunching an emulator as
a different relative really does switch relative.

Because the profile is compiled in, "several people at once" means several APKs:
`apk-builder` builds one per name in `USERS` (`app-debug-bob.apk`,
`app-debug-grandma.apk`, `app-debug-jen.apk`), and each emulator installs its own. Each window shows a
corner banner with the person's name so you can tell them apart at a glance.

If the server isn't seeded (or isn't up yet), the app falls back to the normal
login flow rather than stranding itself. In a debug build it also logs the
underlying error to the device log, so a broken harness leaves a trace instead of
looking exactly like an unseeded one.

### Guardrails: none of this can ship

Auto-sign-in is an **auth bypass**, so it is gated twice over, and *both* gates
are compile-time — not a runtime flag someone can flip:

- **The app must be a debug build.** `DevLogin.fromEnvironment()`
  (`app/lib/src/dev_login.dart`) returns `null` unless `kDebugMode`, which the
  Dart compiler folds to a constant `false` in a release build — the sign-in path
  becomes dead code and is tree-shaken away. A release APK built *with*
  `--dart-define=CLIENT_PROFILE=bob` shows the ordinary onboarding screen, and its
  compiled `libapp.so` contains neither the `dev/session` route nor the
  `CLIENT_PROFILE` define.
- **The server must be built with its `dev-seed` feature.** The seed profiles, the
  fixed tokens, and the `/dev/session/{person}` route only exist under that Cargo
  feature, which is **off by default**. The dev stack turns it on by passing
  `SERVER_FEATURES=dev-seed` as a build argument (`docker-compose.yml`); a plain
  build of `docker/server.Dockerfile` — what a deploy would produce — has none of
  it. `SEED_PROFILE` on such a server logs "this build has no seed profiles" and
  is ignored, the route 404s, and a seeded token 401s. The strings aren't even in
  the binary.

So a seeded, auto-signed-in session needs a debug app *and* a dev-seed server. A
production server offers nothing for a tampered client to call, and a production
app has no code that would call it.

Build a production-shaped server yourself to see it:

```sh
SERVER_FEATURES= SEED_PROFILE=beach-trip make up     # warns and ignores the seed
```

### What is where

| Piece | Lives in |
|---|---|
| Seed profiles (the worlds, the people, the places) | `server/src/seed.rs` |
| Server feature gate | `server/Cargo.toml` (`dev-seed`), `docker/server.Dockerfile` |
| Client profile + its debug-only gate | `app/lib/src/dev_login.dart` |
| One APK per person | `docker/build-apks.sh` |
| One emulator service per person | `docker/gen-scenario.sh` |

## Run the tests (no host Flutter, no display)

```sh
make test          # analyze + headless tests, in a throwaway container
```

This runs `flutter analyze` and the headless widget/unit tests in the build/test
container — no display, no emulator. It is the same image a future CI job uses.

## How the app reaches the server

The app's default base URL is `http://10.0.2.2:8080`. Inside the Android guest,
`10.0.2.2` is the emulator's alias for **its** host — which is the `emulator`
container, not the server. The emulator container therefore runs a small TCP
forwarder (`socat`) that bridges its own `:8080` to the `server` service over the
Compose network. So the hop is:

```
app (guest)  →  10.0.2.2:8080  →  emulator container :8080  →  socat  →  server:8080
```

The APK is built with `--dart-define=GOOBER_API_BASE=http://10.0.2.2:8080` to
make this explicit (it is also the compiled-in default).

## Common commands

```sh
make base          # (re)build the shared toolchain image
make up            # headless default stack: server only
make emulator      # server + APK build + emulator as a native window
make scenario      # seeded server + one emulator per person, each signed in
make dev           # interactive flutter run hot-reload loop on a running emulator
make test          # analyze + headless tests
make logs          # follow logs
make down          # stop the stack (takes any extra scenario emulators with it)
make clean         # stop and remove volumes (APK, server DB, build caches)
make project       # print this checkout's Compose project name
```

Any target takes `PORT=` to publish the server somewhere other than `8080` —
needed only when two checkouts run at once.

`down` and `clean` act only on **this checkout's** stack — see [one Compose
project per checkout](#one-compose-project-per-checkout--go-through-make).

`make scenario` takes `SEED=` (which world) and `USERS=` (which people, one
emulator each); it defaults to `SEED=beach-trip USERS=bob,grandma,jen`.

Docker output is **plain and append-only by default** (no in-place redraw), so
the terminal stays calm. Prefix any target with `VERBOSE=1` (e.g. `VERBOSE=1 make
emulator`) to restore Docker's animated build progress and live status table.

Port: server on `8080` by default, `PORT=` to move it. (No viewer port — the
emulator is a native window.)

## Troubleshooting

- **Emulator never reaches `boot completed`** — almost always `/dev/kvm`. Confirm
  `ls -l /dev/kvm` exists on the host and that virtualization is enabled.
- **`cannot reach host X server` in the logs / no window appears** — the host has
  not authorized the container. Run `xhost +local:` on the host and relaunch. On
  a Wayland session, confirm XWayland is active (`echo $DISPLAY` → `:0`, and
  `/tmp/.X11-unix/X0` exists).
- **Prefer not to open X to all local users** — instead of `xhost +local:`, mount
  an xauth cookie: extract your display's cookie with
  `xauth extract - "$DISPLAY"` into a file, bind-mount it into the container, and
  point `XAUTHORITY` at it. `xhost +local:` is simpler and is the documented
  default.
- **Window appears but rendering is glitchy** — switch to software GL:
  `EMULATOR_GPU=swiftshader_indirect make emulator`.
- **App shows a connection error** — check the `server` container is healthy
  (`docker compose -p "$(make -s project)" ps`) and that `make logs` shows the
  socat bridge line.
- **App boots to onboarding (`Start your beach trip`) instead of signed in as its
  seeded person** — the guest can't reach the server, so the seeded sign-in
  failed. `make logs` shows the entrypoint's `WARNING` banner about `10.0.2.2`.
  Confirm the `server` container is up and `socat` is bridging (`/tmp/socat.log`),
  and make sure the emulator is **not** booted `-read-only` — that flag leaves the
  guest with no IPv4 default route.

## Fallback: native-host emulator

The container-native window above is the default and works on this project's
Linux + KVM + XWayland hosts. It is **not** possible when:

- you are on a **remote or headless host** with no local display, or
- you are on **macOS or Windows** — Docker Desktop runs Linux containers in a VM
  and cannot pass `/dev/kvm` **and** your host display into a container.

In those cases, run the emulator **directly on the host** and keep only the
**server** in Docker (`make up` — the headless default stack). The host emulator
talks to the containerized server through the same `10.0.2.2` hop, because
`10.0.2.2` on a host-run emulator already means "the machine running the
emulator," which is where the server's port is published.

### 1. Install the SDK + emulator on the host

Install the Android command-line tools and, with `sdkmanager`, the emulator and a
system image (matching the container's `android-35` / `x86_64` on Intel, or the
`arm64-v8a` image on Apple Silicon):

```sh
# after installing Android command-line tools and setting ANDROID_SDK_ROOT:
sdkmanager --licenses
sdkmanager "platform-tools" "emulator" \
           "system-images;android-35;google_apis;x86_64"   # arm64-v8a on Apple Silicon
```

You also need a Flutter SDK on the host to build/install the app
(`flutter --version` should satisfy `app/pubspec.yaml`'s Dart constraint; the
container pins `3.44.5`).

### 2. Create the AVD

```sh
avdmanager create avd -n goober \
  -k "system-images;android-35;google_apis;x86_64" -d pixel_6
```

### 3. Start the server in Docker, the emulator on the host

```sh
make up            # server on http://localhost:8080 (headless container)
emulator -avd goober -gpu auto        # native host emulator (auto GL)
```

On macOS/Windows the host emulator is hardware-accelerated by the OS hypervisor
(Hypervisor.framework / WHPX), so no `/dev/kvm` passthrough is involved.

### 4. Build and install the app into the host emulator

```sh
cd app
flutter pub get
flutter run --dart-define=GOOBER_API_BASE=http://10.0.2.2:8080
```

Because the emulator now runs on the host, its `10.0.2.2` points at the host
loopback, where Docker publishes the server's `:8080` — no `socat` bridge needed.
On a **remote** headless host, publish or tunnel the server's `8080` to wherever
the emulator runs and set `GOOBER_API_BASE` accordingly.
