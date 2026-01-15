#!/usr/bin/env bash
set -euo pipefail

# scripts/phase3/_common.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.phase3.yml"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-syncmgmt_phase3}"

# Default ports (override via env)
CENTRAL_HTTP_PORT="${CENTRAL_HTTP_PORT:-18080}"
LEAF1_HTTP_PORT="${LEAF1_HTTP_PORT:-18081}"

CENTRAL_BASE="http://localhost:${CENTRAL_HTTP_PORT}"
LEAF1_BASE="http://localhost:${LEAF1_HTTP_PORT}"

_dc() {
  (cd "$ROOT_DIR" && docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@")
}

_http() {
  local method="$1"; shift
  local url="$1"; shift
  curl -sS -X "$method" "$url" "$@"
}

_wait_for_http() {
  local url="$1"
  local tries="${2:-60}"
  local sleep_s="${3:-2}"

  for ((i=1; i<=tries; i++)); do
    if curl -sSf "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_s"
  done
  echo "Timed out waiting for $url" >&2
  exit 1
}

_json_get() {
  local key="$1"
  python3 - <<PY
import json,sys
obj=json.load(sys.stdin)
print(obj.get("$key",""))
PY
}

# DB defaults (override via env)
DB_USER="${DB_USER:-sync}"
DB_NAME="${DB_NAME:-dockyard_dev}"
DB_PASSWORD="${DB_PASSWORD:-sync}"
PG_SERVICE="${PG_SERVICE:-postgres}"

psql_in_pg() {
  _dc exec -T "$PG_SERVICE" psql -U "$DB_USER" -d "$DB_NAME" -Atc "$1" | tr -d '\r'
}

require_outbox_table() {
  local exists
  exists="$(psql_in_pg "select to_regclass('public.sync_outbox_event') is not null;")"
  if [[ "$exists" != "t" ]]; then
    echo "FAIL: sync_outbox_event does not exist in DB '$DB_NAME' (user '$DB_USER')." >&2
    echo "Hint: verify Flyway ran OR set DB_NAME to the DB where the table exists (you mentioned dockyard_dev)." >&2
    exit 1
  fi
}
