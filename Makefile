# Convenience targets for the containerized dev environment.
# See docs/dev-container.md for the full guide.

.PHONY: base up emulator test down logs clean

# Docker's default progress display redraws lines in place: BuildKit animates
# build steps and Compose repaints a live status table. That flickers in the
# terminal, so default to calm, append-only output — plain build progress and no
# ANSI repainting. `VERBOSE=1` restores the normal animated display.
ifeq ($(VERBOSE),1)
export BUILDKIT_PROGRESS = auto
COMPOSE_ANSI =
else
export BUILDKIT_PROGRESS = plain
COMPOSE_ANSI = --ansi never
endif

# Build the shared toolchain image the app containers derive from. Must run
# before `up`/`emulator`/`test` (all depend on it).
base:
	docker build -f docker/base.Dockerfile -t goober-base:latest .

# Bring up the headless default stack (just the server). No display needed; the
# emulator is opt-in via the `emulator` target below.
up: base
	docker compose $(COMPOSE_ANSI) up --build

# Build the app and launch the Android emulator as a native window on the host
# desktop (server + APK build + emulator). Requires a local display; run
# `xhost +local:` once on the host first (see docs/dev-container.md).
emulator: base
	docker compose $(COMPOSE_ANSI) --profile emulator up --build

# CI-parity check: static analysis + headless tests, no host toolchain.
test: base
	docker compose $(COMPOSE_ANSI) run --rm test

# Stop the stack. Includes the emulator profile so the opt-in apk-builder and
# emulator containers are torn down too (a bare `down` scopes only the default
# services and leaves them orphaned); `--remove-orphans` sweeps any left behind.
down:
	docker compose $(COMPOSE_ANSI) --profile emulator down --remove-orphans

# Follow logs (emulator boot progress, server output).
logs:
	docker compose $(COMPOSE_ANSI) logs -f

# Stop and remove volumes (APK, server database). Profile-aware like `down` so
# the emulator-profile containers and their volumes go too.
clean:
	docker compose $(COMPOSE_ANSI) --profile emulator down -v --remove-orphans
