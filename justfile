# Floodgate — standalone Fluid Framework server (Gleam/BEAM).
#
# Self-contained: every recipe here works without the surrounding Levee
# repository, so this file moves with the directory when Floodgate is extracted
# (see ../../docs/adr/009-floodgate-standalone-repo.md).

default:
    @just --list

# === BUILD ===

build:
    gleam build --target erlang

# Build the shared Lustre admin SPA without Elixir or Mix.
build-admin:
    cd ../levee_admin && gleam build --target javascript
    mkdir -p priv/static/admin
    cp -r ../levee_admin/build/dev/javascript/* priv/static/admin/
    cp ../levee_admin/index.html priv/static/admin/

deps:
    gleam deps download

check:
    gleam check

clean:
    rm -rf build

# === TEST ===

test:
    gleam test

# === QUALITY ===

format:
    gleam format

format-check:
    gleam format --check

lint: check format-check

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
    cd ../.. && docker build -f server/floodgate/Dockerfile -t floodgate:local .

up:
    docker compose up -d --wait --build

down:
    docker compose down -v

logs:
    docker compose logs -f floodgate

# === RELEASE ===

# Self-contained Erlang release; runs anywhere with a matching Erlang/OTP.
shipment:
    gleam export erlang-shipment
