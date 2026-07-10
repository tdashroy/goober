# Rust server image: build the axum + SQLite binary, then run it on a slim base.
# Builds against the committed sqlx offline cache (SQLX_OFFLINE, set in
# server/.cargo/config.toml) so no database is needed at build time.

# --- build stage ---
FROM rust:1-bookworm AS build
WORKDIR /src
COPY server/ ./
RUN cargo build --release --locked

# --- runtime stage ---
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/target/release/goober-server /usr/local/bin/goober-server

WORKDIR /data
# SQLite file lives on a volume; the server creates it and migrates on startup.
# Bind all interfaces so the emulator container can reach it over the network.
ENV DATABASE_URL=sqlite:///data/goober.db \
    GOOBER_BIND=0.0.0.0:8080 \
    RUST_LOG=info
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=5 \
  CMD curl -fsS http://localhost:8080/health || exit 1
CMD ["goober-server"]
