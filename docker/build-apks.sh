#!/usr/bin/env bash
# Build the debug APK(s) the emulators install, into the shared /apk volume.
#
# With no CLIENT_PROFILES, this builds the one plain APK (`app-debug.apk`) — the
# app boots into its normal login flow. With CLIENT_PROFILES=bob,grandma it builds
# one APK per named person instead (`app-debug-bob.apk`, ...), each compiled with
# that client profile so it boots already signed in as them. A client profile is a
# compile-time define, so "two people at once" means two APKs, one per emulator.
set -euo pipefail

API_BASE="${GOOBER_API_BASE:-http://10.0.2.2:8080}"
APK_DIR="${APK_DIR:-/apk}"
CLIENT_PROFILES="${CLIENT_PROFILES:-}"

cd /workspace/app
mkdir -p "$APK_DIR"

# The APKs this run is responsible for. Emulators wait for their file to appear
# rather than for this container to exit, so every one of them is cleared up front
# — an emulator can then never install a leftover APK from a previous run.
outputs=()
if [ -n "$CLIENT_PROFILES" ]; then
  IFS=, read -ra profiles <<< "$CLIENT_PROFILES"
  for profile in "${profiles[@]}"; do
    profile="${profile// /}"
    [ -n "$profile" ] || continue
    outputs+=("app-debug-${profile}.apk:${profile}")
  done
fi
if [ "${#outputs[@]}" -eq 0 ]; then
  outputs=("app-debug.apk:")
fi

for entry in "${outputs[@]}"; do
  rm -f "${APK_DIR}/${entry%%:*}"
done

flutter pub get

for entry in "${outputs[@]}"; do
  out="${entry%%:*}"
  profile="${entry#*:}"

  args=(--debug "--dart-define=GOOBER_API_BASE=${API_BASE}")
  if [ -n "$profile" ]; then
    # Honored only by a debug build (see app/lib/src/dev_login.dart), which is
    # exactly what this is.
    args+=("--dart-define=CLIENT_PROFILE=${profile}")
    echo "[apk] building ${out} — signs in as '${profile}'"
  else
    echo "[apk] building ${out} — normal login flow"
  fi

  flutter build apk "${args[@]}"
  # Publish by atomic rename so a waiting emulator only ever sees a whole APK.
  cp build/app/outputs/flutter-apk/app-debug.apk "${APK_DIR}/${out}.tmp"
  mv "${APK_DIR}/${out}.tmp" "${APK_DIR}/${out}"
  echo "[apk] ready: ${APK_DIR}/${out}"
done
