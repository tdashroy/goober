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
| Static analysis + headless tests | `test` | `docker compose run --rm test` | No |
| Debug APK build (feeds the emulator) | `apk-builder` | runs on `make emulator`, then exits | No |
| Android emulator with the app installed | `emulator` | native window on your desktop | **Yes** |

The `server` and `test` pieces are the **default, headless stack**. The
`apk-builder` and `emulator` pieces are **opt-in** behind the `emulator` compose
profile, so a machine with no display can still build, test, and run the server
with `docker compose up` untouched.

All four share one **base image** (`docker/base.Dockerfile`) that holds the
Flutter SDK, Android SDK, and JDK 17, so the toolchain is installed once.

### Persisted build caches

The first `flutter build apk` in a build/test container installs the Android
**NDK** and **CMake** (auto-downloaded into `$ANDROID_SDK_ROOT/{ndk,cmake}`, ~2-3
min) and fills the **Gradle** and **pub** caches. Those live in the container
filesystem, so without help a fresh container — after `make down`, on a new build
image, or a new machine — reinstalls them every time.

To avoid that, the `apk-builder` and `test` services mount four named volumes at
the specific cache directories, so a fresh container reuses them and does the fast
incremental build instead:

| Volume | Mount | Holds |
|---|---|---|
| `android-ndk` | `$ANDROID_SDK_ROOT/ndk` | auto-installed Android NDK |
| `android-cmake` | `$ANDROID_SDK_ROOT/cmake` | auto-installed CMake |
| `gradle-cache` | `/home/dev/.gradle` | Gradle build cache + deps |
| `pub-cache` | `$PUB_CACHE` (`/opt/pub-cache`) | Dart/Flutter packages |

Measured effect: a cold APK build on empty volumes ~**200s** (NDK installs once),
then a fresh container reusing the volumes ~**40s** with no NDK reinstall.

Two details make this safe: the volumes mount at the specific cache *subdirs* so
they never shadow the platform-tools/platforms/build-tools baked into the base
image's `$ANDROID_SDK_ROOT`; and the mount points are pre-created owned by the
unprivileged `dev` user in `docker/build-test.Dockerfile`, so a fresh (otherwise
root-owned) volume is seeded writable by the build user. The caches survive `make
down` and are cleared by `make clean`.

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
make up            # == docker compose up --build
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
make emulator      # == docker compose --profile emulator up --build
```

On `make emulator`, Compose:

1. builds and starts **server**, waiting until its `/health` check passes;
2. runs **apk-builder** to produce the debug APK into a shared volume;
3. starts **emulator**, which boots Android (KVM-accelerated), opens its window
   on your desktop, installs the APK, and launches the app.

Watch progress with `make logs` (or `docker compose logs -f emulator`). The
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
X server and what GL renderer `/dev/dri` provides.

## Run the tests (no host Flutter, no display)

```sh
make test          # == docker compose run --rm test
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
make test          # analyze + headless tests
make logs          # follow logs
make down          # stop the stack
make clean         # stop and remove volumes (APK, server DB, build caches)
```

Docker output is **plain and append-only by default** (no in-place redraw), so
the terminal stays calm. Prefix any target with `VERBOSE=1` (e.g. `VERBOSE=1 make
emulator`) to restore Docker's animated build progress and live status table.

Port: server on `8080`. (No viewer port — the emulator is a native window.)

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
  (`docker compose ps`) and that `make logs` shows the socat bridge line.

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
