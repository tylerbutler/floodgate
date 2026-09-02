#!/usr/bin/env bash
set -euo pipefail

repo_root="$(pwd)"
fluid_repo="${FLUID_REPO:-../FluidFramework}"
log_dir="${FLOODGATE_LOG_DIR:-artifacts/fluid-canonical}"

case "$fluid_repo" in
  /*) ;;
  *) fluid_repo="$repo_root/$fluid_repo" ;;
esac

case "$log_dir" in
  /*) ;;
  *) log_dir="$repo_root/$log_dir" ;;
esac

fluid_test_package='@fluid-private/test-end-to-end-tests'
fluid_test_dir="$fluid_repo/packages/test/test-end-to-end-tests"
fluid_install_filter="${fluid_test_package}..."

pnpm_cmd="${PNPM:-pnpm}"
if [[ "$pnpm_cmd" == */* ]]; then
  export PATH="$(dirname "$pnpm_cmd"):$PATH"
fi
port="${FLOODGATE_PORT:-3000}"
tenant_id="${FLOODGATE_TENANT_ID:-fluid}"
jwt_secret="${FLOODGATE_JWT_SECRET:-floodgate-routerlicious-compat-secret}"
token_mint_secret="${FLOODGATE_TOKEN_MINT_SECRET:-floodgate-routerlicious-mint-secret}"
base_url="${FLOODGATE_BASE_URL:-http://127.0.0.1:${port}}"

server_log="$log_dir/floodgate-server.log"
suite_log="$log_dir/fluid-test.log"
server_pid=""

if [[ ! -f "$fluid_repo/package.json" || ! -f "$fluid_repo/pnpm-lock.yaml" ]]; then
  echo "FluidFramework checkout not found at $fluid_repo" >&2
  exit 1
fi

if [[ ! -d "$fluid_test_dir" ]]; then
  echo "Fluid test package not found at $fluid_test_dir" >&2
  exit 1
fi

mkdir -p "$log_dir"
: > "$server_log"
: > "$suite_log"

cleanup_done=0
cleanup() {
  local status=$?

  if [[ "$cleanup_done" -eq 1 ]]; then
    return
  fi
  cleanup_done=1

  if [[ -n "$server_pid" ]]; then
    kill -- "-$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi

  if [[ $status -ne 0 && -f "$server_log" ]]; then
    echo "Floodgate server log ($server_log):" >&2
    tail -n 200 "$server_log" >&2 || true
  fi

  echo "Floodgate server log: $server_log"
  echo "Fluid suite log: $suite_log"
}
trap cleanup EXIT INT TERM

echo "==> Installing filtered Fluid workspace dependencies"
(
  cd "$fluid_repo"
  "$pnpm_cmd" install --frozen-lockfile --filter "$fluid_install_filter"
)

echo "==> Building Fluid end-to-end test package"
(
  cd "$fluid_repo"
  "$pnpm_cmd" --filter "$fluid_test_package" build
)

echo "==> Building Floodgate server"
gleam build --target erlang

if curl --max-time 1 -sf "$base_url/health" >/dev/null 2>&1; then
  echo "ERROR: something is already answering health checks at $base_url (port $port) before Floodgate started." >&2
  echo "Refusing to run the suite against a server this script did not start; free the port and retry." >&2
  exit 1
fi

echo "==> Starting Floodgate with memory storage"
FLOODGATE_JWT_SECRET="$jwt_secret" \
FLOODGATE_TOKEN_MINT_SECRET="$token_mint_secret" \
FLOODGATE_TENANT_ID="$tenant_id" \
FLOODGATE_STORAGE_BACKEND=memory \
FLOODGATE_BIND=127.0.0.1 \
FLOODGATE_PUBLIC_URL="$base_url" \
PORT="$port" \
scripts/setsid-portable gleam run >"$server_log" 2>&1 &
server_pid=$!

for _ in $(seq 1 60); do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "Floodgate exited before becoming healthy." >&2
    exit 1
  fi

  if curl --max-time 1 -sf "$base_url/health" >/dev/null; then
    break
  fi

  sleep 1
done

if ! kill -0 "$server_pid" 2>/dev/null; then
  echo "Floodgate exited before becoming healthy." >&2
  exit 1
fi

if ! curl --max-time 1 -sf "$base_url/health" >/dev/null; then
  echo "Floodgate did not become healthy at $base_url/health" >&2
  exit 1
fi

echo "==> Running Fluid canonical Floodgate suite"
driver_config="$(
  node -e 'process.stdout.write(JSON.stringify({
    host: process.argv[1],
    tenantId: process.argv[2],
    tenantSecret: process.argv[3],
    ordererUrl: process.argv[1],
    deltaStorageUrl: process.argv[1],
    deltaStreamUrl: process.argv[1],
  }))' "$base_url" "$tenant_id" "$jwt_secret"
)"
(
  cd "$fluid_test_dir"
  fluid__test__driver=r11s \
  fluid__test__r11sEndpointName=custom \
  fluid__test__driver__custom="$driver_config" \
  "$pnpm_cmd" run test:realsvc:run -- \
    --driver=r11s \
    --r11sEndpointName=custom \
    --timeout=20s | tee "$suite_log"
)
