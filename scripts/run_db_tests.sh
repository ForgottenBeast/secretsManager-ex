#!/usr/bin/env bash
# Run rotating_secrets_vault DB integration tests against an ephemeral PostgreSQL instance.
#
# Usage (from inside `nix develop`):
#   ./scripts/run_db_tests.sh                        — runs :openbao_db tests only
#   RUST_CONSUMER_BIN=/path/to/http_server \
#     ./scripts/run_db_tests.sh                      — also runs :cross_lang_db tests
#   PG_PORT=5433 ./scripts/run_db_tests.sh           — use non-default port
#
# Two-phase interactive mode (source the script to use the functions directly):
#   source scripts/run_db_tests.sh && start_pg
#   PG_AVAILABLE=1 PG_HOST=127.0.0.1 mix test --only openbao_db
#   stop_pg
#
# Requirements:
#   pg_ctl, initdb, psql, pg_isready — provided by pkgs.postgresql in flake.nix devShell
#   bao (OpenBao)                    — provided by pkgs.openbao in flake.nix devShell
#   mix                              — provided by the Elixir devShell

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PG_PORT="${PG_PORT:-5432}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PGDATA=""

# ---------------------------------------------------------------------------
# start_pg: initialise and start an ephemeral PostgreSQL instance.
#   Sets PGDATA, exports PG_AVAILABLE, PG_HOST, PG_PORT.
#   Registers a cleanup trap on EXIT when called from the main flow.
# ---------------------------------------------------------------------------
start_pg() {
  if ! command -v pg_ctl &>/dev/null; then
    echo "ERROR: pg_ctl not found — run this script from inside 'nix develop'" >&2
    exit 1
  fi

  # Fail fast if port is already in use
  if pg_isready -h 127.0.0.1 -p "$PG_PORT" -q 2>/dev/null; then
    echo "ERROR: port $PG_PORT is already in use by a PostgreSQL instance." >&2
    echo "       Stop it first, or set PG_PORT to a free port." >&2
    exit 1
  fi

  PGDATA="$(mktemp -d)"
  echo "[run_db_tests] PGDATA=$PGDATA"

  # Initialise cluster with trust auth (allows password-free local setup)
  initdb -D "$PGDATA" \
    --username=postgres \
    --no-locale \
    --encoding=UTF8 \
    -A trust \
    2>/dev/null

  # Override listen address, port, and socket directory
  cat >> "$PGDATA/postgresql.conf" <<EOF
listen_addresses = '127.0.0.1'
port = $PG_PORT
unix_socket_directories = '$PGDATA'
EOF

  # Write final pg_hba.conf BEFORE starting the server:
  #   local connections  → trust  (used by psql to set the password below)
  #   TCP connections    → md5    (used by OpenBao database plugin with password)
  cat > "$PGDATA/pg_hba.conf" <<EOF
# TYPE  DATABASE  USER      ADDRESS         METHOD
# Unix socket — trust; used only during local setup
local   all       postgres                  trust
# TCP/IP — md5; OpenBao connects here with username/password
host    all       postgres  127.0.0.1/32    md5
EOF

  # Start server and wait for it to be ready (-w = synchronous)
  pg_ctl start -D "$PGDATA" -l "$PGDATA/logfile" -w

  # Set password via unix socket (uses local trust rule — no password needed)
  psql -h "$PGDATA" -U postgres -c "ALTER USER postgres PASSWORD 'postgres';" -q 2>/dev/null

  # Verify TCP endpoint is up (md5 auth now active)
  pg_isready -h 127.0.0.1 -p "$PG_PORT" -q

  export PG_AVAILABLE=1
  export PG_HOST=127.0.0.1
  export PG_PORT
  echo "[run_db_tests] PostgreSQL ready on 127.0.0.1:$PG_PORT"
}

# ---------------------------------------------------------------------------
# stop_pg: stop the ephemeral instance and remove its data directory.
# ---------------------------------------------------------------------------
stop_pg() {
  if [ -n "$PGDATA" ] && [ -d "$PGDATA" ]; then
    echo "[run_db_tests] Stopping PostgreSQL..."
    pg_ctl stop -D "$PGDATA" -m fast 2>/dev/null || true
    rm -rf "$PGDATA"
    PGDATA=""
    echo "[run_db_tests] PostgreSQL stopped and data directory removed."
  fi
}

# ---------------------------------------------------------------------------
# cleanup: called by the EXIT trap — always runs on exit, Ctrl-C, or error.
# ---------------------------------------------------------------------------
cleanup() {
  stop_pg
}

# ---------------------------------------------------------------------------
# Main — only runs when script is executed directly (not sourced).
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap cleanup EXIT

  start_pg

  # Determine which test tags to run
  TEST_ARGS="--only openbao_db"
  if [ -n "${RUST_CONSUMER_BIN:-}" ]; then
    echo "[run_db_tests] RUST_CONSUMER_BIN set — also running :cross_lang_db tests"
    TEST_ARGS="$TEST_ARGS --only cross_lang_db"
  else
    echo "[run_db_tests] RUST_CONSUMER_BIN not set — skipping :cross_lang_db tests"
    echo "               Set RUST_CONSUMER_BIN=/path/to/http_server to include them."
  fi

  echo "[run_db_tests] Running: mix test $TEST_ARGS $*"
  # shellcheck disable=SC2086  # word-splitting is intentional for TEST_ARGS
  (cd "$PROJECT_ROOT/rotating_secrets_vault" && mix test $TEST_ARGS "$@")
fi
