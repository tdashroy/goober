#!/usr/bin/env bash
# Boot the Android emulator inside the container and draw its own Qt GUI as a
# native window on the host desktop through the host X server ($DISPLAY). No
# virtual framebuffer, no VNC — the window appears directly on the host. Also
# installs the app and bridges the guest's hop to the server container.
set -euo pipefail

SERVER_HOST="${SERVER_HOST:-server}"
SERVER_PORT="${SERVER_PORT:-8080}"
APK_PATH="${APK_PATH:-/apk/app-debug.apk}"
APP_ID="${APP_ID:-com.tdashroy.goober}"
DISPLAY="${DISPLAY:-:0}"
# GPU backend: "host" uses the host GPU via /dev/dri (hardware GL). Fall back to
# "swiftshader_indirect" (software GL) if hardware GL misbehaves in-container;
# KVM still gives CPU acceleration either way.
EMULATOR_GPU="${EMULATOR_GPU:-host}"
# Headless smoke mode: boot with no GUI window and no host display. KVM, adb,
# install and the server bridge are still exercised — used for CI-style checks.
EMULATOR_NO_WINDOW="${EMULATOR_NO_WINDOW:-0}"

log() { echo "[emulator] $*"; }

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
# container's :8080 to the server service so the app's default base URL works.
log "bridging :8080 -> ${SERVER_HOST}:${SERVER_PORT} (reachable from the guest at 10.0.2.2:8080)"
socat TCP-LISTEN:8080,fork,reuseaddr "TCP:${SERVER_HOST}:${SERVER_PORT}" >/tmp/socat.log 2>&1 &

log "booting Android emulator (KVM-accelerated, gpu: $EMULATOR_GPU)"
adb start-server
emulator -avd goober \
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
