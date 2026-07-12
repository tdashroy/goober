# Convenience targets for the containerized dev environment.
# See docs/dev-container.md for the full guide.

.PHONY: base up emulator scenario dev test down logs clean

# --- dev testing harness ---------------------------------------------------
# `make scenario` seeds the server with a ready-made world and opens one emulator
# per person named in USERS, each already signed in as them:
#
#   make scenario                                  # beach-trip, as bob + grandma
#   make scenario SEED=beach-trip USERS=bob,jen    # pick the world and the people
#
# SEED names a server seed profile (server/src/seed.rs); USERS names people from
# it. Both are dev-only and cannot exist in a release build — see
# docs/dev-container.md.
SEED ?= beach-trip
USERS ?= bob,grandma

# One emulator service per person, generated because how many there are is up to
# whoever runs the scenario. Rewritten by `make scenario`, removed by `make clean`.
SCENARIO_FILE := docker-compose.scenario.yml

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

# Seeded server + one emulator window per person, each booted straight into the
# app signed in as that person — the whole point of the dev testing harness. The
# server loads the SEED world (idempotently, so re-running is safe), the APK
# builder produces one APK per person in USERS, and each emulator installs its
# own. Same display requirements as `make emulator` (`xhost +local:` first).
scenario: base
	./docker/gen-scenario.sh "$(USERS)" > $(SCENARIO_FILE)
	SEED_PROFILE=$(SEED) CLIENT_PROFILES=$(USERS) \
	  docker compose $(COMPOSE_ANSI) -f docker-compose.yml -f $(SCENARIO_FILE) \
	    --profile emulator up --build

# Interactive Flutter hot-reload loop against an already-running emulator (start
# it first with `make emulator`). Drops you straight into `flutter run` attached
# to the emulator: press `r` to hot-reload, `R` to hot-restart, `q` to quit. The
# `dev` container joins the emulator container's network namespace so adb and the
# Dart VM service share one loopback — see docs/dev-container.md. Pass extra
# flutter args with FLUTTER_RUN_ARGS (e.g. `FLUTTER_RUN_ARGS=--verbose make dev`).
# Both profiles are enabled so the `emulator` service the `dev` container attaches
# its network namespace to is defined in the project; `--no-deps` then keeps
# `make dev` from (re)starting that stack — it only attaches to the emulator that
# `make emulator` already brought up.
dev:
	docker compose $(COMPOSE_ANSI) --profile emulator --profile dev run --rm --no-deps dev

# CI-parity check: static analysis + headless tests, no host toolchain.
test: base
	docker compose $(COMPOSE_ANSI) run --rm test

# Stop the stack. Includes the emulator profile so the opt-in apk-builder and
# emulator containers are torn down too (a bare `down` scopes only the default
# services and leaves them orphaned); `--remove-orphans` sweeps any left behind —
# which is also what removes the extra emulator instances a `make scenario` ran,
# since those services are not in the base compose file.
down:
	docker compose $(COMPOSE_ANSI) --profile emulator down --remove-orphans

# Follow logs (emulator boot progress, server output).
logs:
	docker compose $(COMPOSE_ANSI) logs -f

# Stop and remove volumes (APK, server database, persisted build caches).
# Profile-aware like `down` so the emulator-profile containers and their volumes
# go too, and `--remove-orphans` takes any extra scenario emulators with them.
# Note this drops the NDK/Gradle/pub caches, so the next build is cold — and the
# server database, so a seeded world is gone until the next seeded boot.
clean:
	docker compose $(COMPOSE_ANSI) --profile emulator down -v --remove-orphans
	rm -f $(SCENARIO_FILE)
