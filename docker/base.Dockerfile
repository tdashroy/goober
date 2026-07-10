# Shared toolchain image: JDK 17 + Android SDK + Flutter SDK.
#
# The build/test and emulator images both `FROM goober-base:latest`, so the
# Flutter and Android toolchains are installed exactly once and reused. Build it
# before the compose stack:
#
#   docker build -f docker/base.Dockerfile -t goober-base:latest .
#
# (the `make base` target does this for you).
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Toolchain locations, exported on PATH for every derived image and for both the
# root (emulator) and unprivileged `dev` (build/test) users.
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk \
    FLUTTER_HOME=/opt/flutter \
    PUB_CACHE=/opt/pub-cache
ENV PATH=$FLUTTER_HOME/bin:$FLUTTER_HOME/bin/cache/dart-sdk/bin:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
      openjdk-17-jdk-headless \
      git curl unzip zip xz-utils \
      ca-certificates \
      libglu1-mesa \
      bash coreutils \
    && rm -rf /var/lib/apt/lists/*

# --- Android command-line tools + the SDK packages needed to build the app ---
# The emulator + a system image are heavier and live only in the emulator image,
# so the build/test image stays lean.
ARG ANDROID_CMDLINE_TOOLS=commandlinetools-linux-11076708_latest.zip
RUN mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools" \
    && curl -fsSL "https://dl.google.com/android/repository/${ANDROID_CMDLINE_TOOLS}" -o /tmp/cmdline-tools.zip \
    && unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools \
    && mv /tmp/cmdline-tools/cmdline-tools "${ANDROID_SDK_ROOT}/cmdline-tools/latest" \
    && rm -rf /tmp/cmdline-tools.zip /tmp/cmdline-tools

RUN yes | sdkmanager --licenses >/dev/null \
    && sdkmanager --install \
        "platform-tools" \
        "platforms;android-36" \
        "platforms;android-35" \
        "build-tools;36.0.0" >/dev/null

# --- Flutter SDK, pinned to the stable release matching the project's Dart SDK
# constraint (pubspec.yaml: sdk ^3.12.2). Cloning the release *tag* (not a bare
# commit) keeps the tag reachable so Flutter can report its version — pub rejects
# an SDK that reports 0.0.0-unknown against the constraint.
ARG FLUTTER_VERSION=3.44.5
RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" \
        https://github.com/flutter/flutter.git "${FLUTTER_HOME}" \
    && git config --system --add safe.directory "${FLUTTER_HOME}"

# Warm the caches (Dart SDK, Android build artifacts) and accept SDK licenses at
# build time so no downloads or prompts happen when a container runs.
RUN flutter config --no-analytics --no-cli-animations \
    && flutter precache --android --universal \
    && (yes | flutter doctor --android-licenses >/dev/null || true) \
    && flutter doctor -v || true

# An unprivileged user for the build/test container. uid 1000 matches the typical
# host user so bind-mounted source stays writable without ownership friction.
RUN useradd -m -u 1000 -s /bin/bash dev

# The toolchain is installed as root; make it usable (and its caches writable) by
# any user, so the unprivileged build/test container can run it as-is.
RUN mkdir -p "${PUB_CACHE}" \
    && chmod -R a+rwX "${FLUTTER_HOME}" "${ANDROID_SDK_ROOT}" "${PUB_CACHE}"
