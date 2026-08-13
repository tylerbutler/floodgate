# Floodgate — standalone Fluid Framework server (Gleam/BEAM).
#
# Every recipe works from a standalone Floodgate checkout.

default:
    @just --list

# === BUILD ===

build:
    gleam build --target erlang
    cd client && pnpm build
    cd website && pnpm build
    just build-admin

build-admin:
    cd admin && gleam build --target javascript
    mkdir -p priv/static/admin
    cp -r admin/build/dev/javascript/* priv/static/admin/
    cp admin/index.html priv/static/admin/

deps:
    gleam deps download
    cd admin && gleam deps download
    cd client && pnpm install --frozen-lockfile
    cd website && pnpm install --frozen-lockfile

check:
    gleam check
    cd admin && gleam check
    cd client && pnpm check

clean:
    rm -rf build

# === TEST ===

test:
    gleam test
    cd admin && gleam test
    cd client && pnpm test

# === QUALITY ===

format:
    gleam format
    cd admin && gleam format
    cd client && pnpm format

format-check:
    gleam format --check
    cd admin && gleam format --check
    cd client && pnpm check

lint: check format-check

precommit: format-check test

# === RUN ===

# Start the server with development credentials. Never use these in production.
run port="3000":
    FLOODGATE_JWT_SECRET="${FLOODGATE_JWT_SECRET:-dev-tenant-secret-key}" \
    FLOODGATE_TOKEN_MINT_SECRET="${FLOODGATE_TOKEN_MINT_SECRET:-dev-token-mint-secret}" \
    FLOODGATE_ADMIN_KEY="${FLOODGATE_ADMIN_KEY:-dev-admin-key}" \
    PORT={{port}} \
        gleam run

# Start with an ephemeral store, so each run begins from empty state.
run-memory port="3000":
    FLOODGATE_JWT_SECRET="${FLOODGATE_JWT_SECRET:-dev-tenant-secret-key}" \
    FLOODGATE_TOKEN_MINT_SECRET="${FLOODGATE_TOKEN_MINT_SECRET:-dev-token-mint-secret}" \
    FLOODGATE_ADMIN_KEY="${FLOODGATE_ADMIN_KEY:-dev-admin-key}" \
    FLOODGATE_STORAGE_BACKEND=memory \
    PORT={{port}} \
        gleam run

# === DOCKER ===

docker-build:
    docker build -t floodgate:local .

up:
    docker compose up -d --wait --build

down:
    docker compose down -v

logs:
    docker compose logs -f floodgate

# === INTEGRATION ===

test-routerlicious:
    cd client && FLOODGATE_ROUTERLICIOUS_COMPAT=1 pnpm test:routerlicious

test-dual-mode:
    #!/usr/bin/env bash
    set -euo pipefail
    export FLOODGATE_JWT_SECRET=floodgate-routerlicious-compat-secret
    export FLOODGATE_TOKEN_MINT_SECRET=floodgate-routerlicious-mint-secret
    export FLOODGATE_STORAGE_BACKEND=memory
    server_pid=""
    cleanup() {
        [ -n "$server_pid" ] && kill -- "-$server_pid" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM
    scripts/setsid-portable bash -c 'gleam run' &
    server_pid=$!
    for i in $(seq 1 30); do
        curl --max-time 1 -sf http://localhost:3000/health >/dev/null && break
        [ "$i" = 30 ] && exit 1
        sleep 1
    done
    cd client
    pnpm test:routerlicious
    pnpm test:phoenix

test-example:
    just _test-example floodgate-example

test-todo:
    just _test-example floodgate-todo-list

test-presence:
    just _test-example floodgate-presence-tracker

_test-example package:
    #!/usr/bin/env bash
    set -euo pipefail
    export FLOODGATE_JWT_SECRET=floodgate-example-jwt-secret
    export FLOODGATE_TOKEN_MINT_SECRET=floodgate-example-mint-secret
    export FLOODGATE_STORAGE_BACKEND=memory
    server_pid=""
    cleanup() {
        [ -n "$server_pid" ] && kill -- "-$server_pid" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM
    scripts/setsid-portable bash -c 'gleam run' &
    server_pid=$!
    for i in $(seq 1 30); do
        curl --max-time 1 -sf http://localhost:3000/health >/dev/null && break
        [ "$i" = 30 ] && exit 1
        sleep 1
    done
    cd client/packages/{{package}}
    FLOODGATE_INTEGRATION=1 \
    FLOODGATE_HTTP_URL=http://localhost:3000 \
    FLOODGATE_MINT_CREDENTIAL=floodgate-example-mint-secret \
        pnpm test:vitest:integration

# === RELEASE ===

# Self-contained Erlang release; runs anywhere with a matching Erlang/OTP.
shipment:
    gleam export erlang-shipment
