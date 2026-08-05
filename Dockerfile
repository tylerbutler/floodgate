# Dockerfile for Floodgate — standalone Fluid Framework server (Gleam/BEAM).
#
# Floodgate is a drop-in replacement for the Levee Elixir server: one process
# serves the official Fluid/Routerlicious drivers over /socket.io/ and Phoenix
# Channels clients (levee-driver/levee-client) over /socket/websocket. See
# docs/adr/008-floodgate-phoenix-endpoint.md.
#
# Unlike ../Dockerfile (Levee), this image needs no Elixir or Mix — Floodgate is
# a pure Gleam application, shipped as a self-contained Erlang release.
#
# Build from the floodgate directory:
#   docker build -t floodgate:local server/floodgate

# === Stage 1: Build the Erlang shipment ===
FROM erlang:28-slim AS builder

ARG GLEAM_VERSION=1.18.1

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Gleam publishes musl static builds that run fine on glibc images.
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then \
      GLEAM_ARCH="aarch64-unknown-linux-musl"; \
    else \
      GLEAM_ARCH="x86_64-unknown-linux-musl"; \
    fi && \
    curl -fsSL "https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-${GLEAM_ARCH}.tar.gz" \
    | tar -xzC /usr/local/bin

WORKDIR /build

# Resolve dependencies first so source edits don't invalidate the dep layer.
# manifest.toml pins the git dependencies (beryl, dewdrop, spillway, signet,
# silt, windsock), so this layer is reproducible.
COPY gleam.toml manifest.toml ./
RUN gleam deps download

COPY src src
COPY test test

# Produces build/erlang-shipment: compiled BEAM files for floodgate and every
# dependency, plus an entrypoint script. No Gleam toolchain needed at runtime.
RUN gleam export erlang-shipment

# === Stage 2: Runtime ===
FROM erlang:28-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/build/erlang-shipment/ ./

# Persistent shelf (DETS) storage. Declared as a volume so document history
# survives container replacement; set FLOODGATE_STORAGE_BACKEND=memory for
# ephemeral test runs.
ENV FLOODGATE_DATA_DIR=/data
RUN mkdir -p /data
VOLUME ["/data"]

# Floodgate refuses to start without an explicit JWT secret, so there is no
# default here on purpose — supply FLOODGATE_JWT_SECRET at run time.
ENV PORT=3000
# Mist binds to localhost by default, which is unreachable from outside the
# container; published ports need a wildcard bind.
ENV FLOODGATE_BIND=0.0.0.0
ENV FLOODGATE_TENANT_ID=fluid
ENV FLOODGATE_STORAGE_BACKEND=shelf

EXPOSE 3000

# /health matches Levee's HealthController exactly ({"status":"ok"}).
# 127.0.0.1 rather than localhost: FLOODGATE_BIND=0.0.0.0 is IPv4-only, and
# localhost resolves to ::1 first inside the container.
HEALTHCHECK --interval=5s --timeout=3s --start-period=15s --retries=5 \
    CMD wget --no-verbose --tries=1 --spider "http://127.0.0.1:${PORT}/health" || exit 1

# Invoked through `sh` rather than directly: the entrypoint.sh that
# `gleam export erlang-shipment` generates (1.18.1) emits SPDX comments above
# the `#!/bin/sh` line, so the shebang is not on line 1 and exec'ing the file
# fails with "exec format error".
ENTRYPOINT ["/bin/sh", "./entrypoint.sh"]
CMD ["run"]
