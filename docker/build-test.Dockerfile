# Build/test image: unprivileged, run-and-exit. This is the CI-parity artifact —
# the same image runs the headless test suite and builds the debug APK that the
# emulator installs. The actual command is supplied by docker-compose.
FROM goober-base:latest

# APK handoff mount point, owned by the unprivileged user. A fresh named volume
# mounted here inherits this ownership, so the build can write the APK to the
# volume the emulator reads from.
#
# The same trick pre-creates the persisted-cache mount points owned by `dev`.
# When Docker first mounts an *empty* named volume over a path that exists in the
# image, it seeds the volume from that path and carries its ownership across — so
# a fresh (otherwise root-owned) volume lands writable by the unprivileged build
# user. These hold the expensive, reusable artifacts a `flutter build apk` would
# otherwise reinstall from scratch on every fresh container:
#   - $ANDROID_SDK_ROOT/ndk, $ANDROID_SDK_ROOT/cmake — the Android NDK + CMake,
#     auto-installed on the first APK build (~2-3 min). Mounted at these specific
#     subdirs so the volumes never shadow the platform-tools/platforms/build-tools
#     already baked into the base image's $ANDROID_SDK_ROOT.
#   - /home/dev/.gradle — the Gradle build cache and downloaded dependencies.
#   - $PUB_CACHE — Dart/Flutter package cache.
#   - /home/dev/.android — holds the debug keystore every debug APK is signed
#     with. Persisted so the key stays the same from build to build: a fresh key
#     would make an emulator that still has an earlier build installed reject the
#     new APK as an incompatible update (see docker/build-apks.sh).
RUN mkdir -p /apk "${ANDROID_SDK_ROOT}/ndk" "${ANDROID_SDK_ROOT}/cmake" \
             /home/dev/.gradle /home/dev/.android "${PUB_CACHE}" \
    && chown dev:dev /apk "${ANDROID_SDK_ROOT}/ndk" "${ANDROID_SDK_ROOT}/cmake" \
             /home/dev/.gradle /home/dev/.android "${PUB_CACHE}"

# Run as the unprivileged user; no root, no device access.
USER dev
WORKDIR /workspace

# Default to the full check (fetch deps, static analysis, headless tests). The
# apk-builder service overrides this with a `flutter build apk` command.
CMD ["bash", "-lc", "cd app && flutter pub get && flutter analyze && flutter test"]
