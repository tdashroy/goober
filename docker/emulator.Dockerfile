# Emulator image: long-running, hardware-accelerated Android emulator whose own
# Qt window is drawn as a native window on the host desktop through the host X
# server. Needs /dev/kvm (CPU accel) and /dev/dri (host GPU), runs privileged,
# and mounts the host X socket (see docker-compose.yml and docs/dev-container.md).
FROM goober-base:latest

USER root
ENV DEBIAN_FRONTEND=noninteractive
# Keep the AVD outside the user home so it survives regardless of who runs.
ENV ANDROID_AVD_HOME=/opt/android-avd

# The emulator engine and a KVM-accelerated x86_64 system image (google_apis so
# the image is rootable and automation-friendly). These layers are heavy but
# stable, so they come before the GUI libraries — editing the runtime deps below
# does not re-download the system image.
RUN yes | sdkmanager --licenses >/dev/null \
    && sdkmanager --install "emulator" "system-images;android-35;google_apis;x86_64" >/dev/null

# Pre-create the AVD so boot is the only runtime step. The pixel_6 profile is
# 1080x2400 @ 420dpi — a very tall window on a desktop. Override the panel to a
# compact 540x1140 @ 240dpi (360x760dp, a normal phone layout) so the native
# window sits comfortably on the host display. Also force hw.keyboard=yes: the
# pixel_6 profile leaves it off, which disables host-keyboard input into Android
# text fields, so you cannot type into the app.
RUN mkdir -p "${ANDROID_AVD_HOME}" \
    && echo "no" | avdmanager create avd -n goober \
         -k "system-images;android-35;google_apis;x86_64" -d pixel_6 \
    && CFG="${ANDROID_AVD_HOME}/goober.avd/config.ini" \
    && sed -i '/^hw\.lcd\.\(width\|height\|density\)=/d' "$CFG" \
    && printf 'hw.lcd.width=540\nhw.lcd.height=1140\nhw.lcd.density=240\n' >> "$CFG" \
    && sed -i '/^hw\.keyboard=/d' "$CFG" \
    && printf 'hw.keyboard=yes\n' >> "$CFG" \
    && chmod -R a+rwX "${ANDROID_AVD_HOME}"

# Runtime libraries the emulator loads:
#  - socat: the app->server TCP bridge (see emulator-entrypoint.sh).
#  - mesa (libgl1-mesa-dri, libglx-mesa0, libegl1): userspace GL that talks to
#    /dev/dri for hardware-accelerated rendering (-gpu host).
#  - the X11 / XCB stack: the emulator's Qt UI uses the xcb platform plugin to
#    open its window on the host X server.
#  - x11-utils (xdpyinfo) + mesa-utils (glxinfo): a startup reachability/GL check.
RUN apt-get update && apt-get install -y --no-install-recommends \
      socat \
      libgl1 libglx-mesa0 libgl1-mesa-dri libegl1 libglu1-mesa \
      libx11-6 libx11-xcb1 libxcb1 libxcb-glx0 libxcb-shm0 libxcb-render0 \
      libxcb-randr0 libxcb-xfixes0 libxcb-shape0 libxcb-render-util0 \
      libxcb-image0 libxcb-keysyms1 libxcb-icccm4 libxcb-util1 libxcb-cursor0 \
      libxkbcommon0 libxkbcommon-x11-0 \
      libnss3 libxcursor1 libxdamage1 libxrandr2 libxcomposite1 libxi6 libxtst6 \
      libasound2 libpulse0 libfontconfig1 libdbus-1-3 \
      x11-utils mesa-utils \
    && rm -rf /var/lib/apt/lists/*

COPY docker/emulator-entrypoint.sh /usr/local/bin/emulator-entrypoint.sh
RUN chmod +x /usr/local/bin/emulator-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/emulator-entrypoint.sh"]
