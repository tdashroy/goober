#!/usr/bin/env bash
# Boot the Android emulator inside the container and draw its own Qt GUI as a
# native window on the host desktop through the host X server ($DISPLAY). No
# virtual framebuffer, no VNC — the window appears directly on the host. Also
# installs the app and bridges the guest's hop to the server container.
set -euo pipefail

SERVER_HOST="${SERVER_HOST:-server}"
SERVER_PORT="${SERVER_PORT:-8080}"
# The port the guest reaches us on, as 10.0.2.2:$GUEST_PORT. Distinct from
# SERVER_PORT, which is the *upstream* port on the server container that we
# forward to: the two happen to both be 8080 today, but they are not the same
# thing. This is the one the socat listener binds and the one the reachability
# check probes, so those two can never drift apart. It has to match the base URL
# the app is compiled with, so treat it as fixed unless the app changes too.
GUEST_PORT="${GUEST_PORT:-8080}"
APK_PATH="${APK_PATH:-/apk/app-debug.apk}"
APP_ID="${APP_ID:-com.tdashroy.goober}"
AVD_NAME="${AVD_NAME:-goober}"
ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-/opt/android-avd}"
DISPLAY="${DISPLAY:-:0}"
# GPU backend: "host" uses the host GPU via /dev/dri (hardware GL). Fall back to
# "swiftshader_indirect" (software GL) if hardware GL misbehaves in-container;
# KVM still gives CPU acceleration either way.
EMULATOR_GPU="${EMULATOR_GPU:-host}"
# Headless smoke mode: boot with no GUI window and no host display. KVM, adb,
# install and the server bridge are still exercised — used for CI-style checks.
EMULATOR_NO_WINDOW="${EMULATOR_NO_WINDOW:-0}"
# Which seeded person this instance's app is signed in as (informational — the
# APK it installs is the one compiled with that client profile).
CLIENT_PROFILE="${CLIENT_PROFILE:-}"

log() { echo "[emulator] $*"; }

if [ -n "$CLIENT_PROFILE" ]; then
  log "this instance runs the app signed in as '$CLIENT_PROFILE'"
fi

window_args=()
if [ "$EMULATOR_NO_WINDOW" = "1" ]; then
  # No window: drop DISPLAY entirely so nothing tries to reach an X server.
  unset DISPLAY
  log "headless mode: booting with -no-window (host display not used)"
  window_args=(-no-window)
else
  export DISPLAY
  log "rendering native window on host display $DISPLAY (gpu: $EMULATOR_GPU)"
  if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    log "host X server $DISPLAY is reachable"
    glxinfo -B 2>/dev/null | grep -iE 'OpenGL renderer|direct rendering' \
      | sed 's/^/[emulator] gl: /' || true
  else
    log "WARNING: host X server $DISPLAY is not reachable — allow the container"
    log "         to connect with 'xhost +local:' on the host (see docs/dev-container.md)"
  fi
fi

# Inside the guest, the host loopback (10.0.2.2) is this container. Forward this
# container's $GUEST_PORT to the server service so the app's default base URL works.
log "bridging :${GUEST_PORT} -> ${SERVER_HOST}:${SERVER_PORT} (reachable from the guest at 10.0.2.2:${GUEST_PORT})"
socat "TCP-LISTEN:${GUEST_PORT},fork,reuseaddr" "TCP:${SERVER_HOST}:${SERVER_PORT}" >/tmp/socat.log 2>&1 &

# Self-heal stale AVD lock/running state before launching. When `make emulator`
# is interrupted with Ctrl-C, Compose STOPS the container but does not remove it
# (only `make down` does). The next `make emulator` reuses that stopped
# container, whose writable layer still holds the previous run's exclusive AVD
# locks and running-state dir. The emulator then FATALs with "Running multiple
# emulators with the same AVD" and dies immediately, so adb never sees a device
# and wait-for-device below hangs forever. These locks only mean "an emulator is
# live for this AVD"; at entrypoint start nothing is running yet (this is the
# sole process that boots it), so any leftover is guaranteed stale — clear it so
# a reused container or leftover lock never blocks boot.
AVD_DIR="${ANDROID_AVD_HOME}/${AVD_NAME}.avd"
if [ -d "$AVD_DIR" ]; then
  stale=$(find "$AVD_DIR" -maxdepth 1 -name '*.lock' -print 2>/dev/null)
  if [ -n "$stale" ] || [ -d "$AVD_DIR/running" ]; then
    log "clearing stale AVD lock/running state in $AVD_DIR"
  fi
  # hardware-qemu.ini.lock / multiinstance.lock are plain files on some emulator
  # builds and lock *directories* (holding a pidfile) on others, so remove
  # recursively to cover both; also sweep any other *.lock (e.g. snapshot locks)
  # and the live running-state dir.
  find "$AVD_DIR" -maxdepth 1 -name '*.lock' -exec rm -rf {} + 2>/dev/null || true
  rm -rf "$AVD_DIR/running" 2>/dev/null || true
fi

log "booting Android emulator (KVM-accelerated, gpu: $EMULATOR_GPU)"
adb start-server
emulator -avd "$AVD_NAME" \
  -no-audio -no-boot-anim -no-snapshot -no-metrics \
  -gpu "$EMULATOR_GPU" -accel on \
  "${window_args[@]}" \
  >/tmp/emulator.log 2>&1 &

log "waiting for the device to come online"
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
  sleep 2
done
log "boot completed"

# Prove the guest can actually reach the server before we hand over a window.
# Everything the app does — not least signing in as its seeded person — goes to
# 10.0.2.2:$GUEST_PORT, the guest's alias for this container, which socat bridges
# on to the server. When that path is broken the app just falls back to
# onboarding, a silent failure that looks exactly like "not seeded yet". So say
# so, loudly.
#
# The ping proves the guest has IPv4 routing to 10.0.2.2 at all; the connect
# proves the bridge behind it is live and the server is answering. The server may
# still be starting up, so retry before giving up.
check_guest_can_reach_server() {
  adb shell ping -c1 -W2 10.0.2.2 >/dev/null 2>&1 || return 1
  # A bare TCP connect to the port socat listens on — the same one the app uses.
  # The guest's toybox nc has no -z, so close stdin immediately and let a clean
  # exit stand for "connected".
  adb shell "echo | nc -w2 10.0.2.2 ${GUEST_PORT}" >/dev/null 2>&1
}

log "checking the guest can reach the server at 10.0.2.2:${GUEST_PORT}"
reach_waited=0
reach_timeout="${SERVER_REACH_TIMEOUT:-60}"
reachable=0
while [ "$reach_waited" -le "$reach_timeout" ]; do
  if check_guest_can_reach_server; then
    reachable=1
    break
  fi
  sleep 2
  reach_waited=$((reach_waited + 2))
done

if [ "$reachable" = "1" ]; then
  log "guest reaches the server ✓"
else
  log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  log "!! WARNING: the guest CANNOT reach the server at 10.0.2.2:${GUEST_PORT}."
  log "!! The app will fail to sign in and will fall back to onboarding"
  log "!! ('Start your beach trip') instead of booting as its seeded person."
  log "!! Check that the server container is up, that socat is bridging (see"
  log "!! /tmp/socat.log), and that the emulator is NOT booted -read-only —"
  log "!! that flag leaves the guest with no IPv4 default route."
  log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
fi

# Force the classic 3-button navigation bar (Back / Home / Recents) instead of
# gesture navigation, so the buttons are always on-screen and clickable — a
# gesture-only bar strands a mouse user in any screen they open. Both knobs are
# applied for robustness across system images.
log "enabling 3-button navigation bar"
adb shell cmd overlay enable com.android.internal.systemui.navbar.threebutton || true
adb shell settings put secure navigation_mode 0 || true

# Dismiss the lock screen so the app is visible immediately.
adb shell input keyevent 82 || true

# The app-build runs as a sibling container and drops the APK into the shared
# volume when it finishes. We wait for the file itself rather than gating on that
# container's exit status, so a stale or failed prior build can never block a
# launch. The builder clears the old APK first and publishes the new one by
# atomic rename, so seeing the file here means a complete, fresh build.
apk_waited=0
apk_timeout="${APK_WAIT_TIMEOUT:-1800}"
if [ ! -f "$APK_PATH" ]; then
  log "waiting for the app APK at $APK_PATH (timeout ${apk_timeout}s)"
  while [ ! -f "$APK_PATH" ] && [ "$apk_waited" -lt "$apk_timeout" ]; do
    sleep 2
    apk_waited=$((apk_waited + 2))
  done
fi

if [ -f "$APK_PATH" ]; then
  log "installing app from $APK_PATH"
  adb install -r "$APK_PATH"
  log "launching $APP_ID"
  adb shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1 \
    || adb shell am start -n "$APP_ID/.MainActivity" \
    || true
else
  log "WARNING: no APK at $APK_PATH; skipping install"
fi

log "ready — the emulator window should now be on your desktop (see docs/dev-container.md)"
# Keep the container alive and stream the emulator log.
tail -f /tmp/emulator.log
