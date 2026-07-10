# Build/test image: unprivileged, run-and-exit. This is the CI-parity artifact —
# the same image runs the headless test suite and builds the debug APK that the
# emulator installs. The actual command is supplied by docker-compose.
FROM goober-base:latest

# APK handoff mount point, owned by the unprivileged user. A fresh named volume
# mounted here inherits this ownership, so the build can write the APK to the
# volume the emulator reads from.
RUN mkdir -p /apk && chown dev:dev /apk

# Run as the unprivileged user; no root, no device access.
USER dev
WORKDIR /workspace

# Default to the full check (fetch deps, static analysis, headless tests). The
# apk-builder service overrides this with a `flutter build apk` command.
CMD ["bash", "-lc", "cd app && flutter pub get && flutter analyze && flutter test"]
