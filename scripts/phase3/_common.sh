#!/usr/bin/env bash
set -euo pipefail

# scripts/phase3/_common.sh
#
# This file is sourced by all Phase-3 scripts.
# It provides:
# - consistent logging (to STDERR)
# - strict HTTP helpers (fail on non-2xx)
# - small JSON extraction + numeric assertions
# - docker compose wrapper
# - optional Postgres helpers for outbox evidence

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.phase3.yml"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-syncmgmt_phase3}"


# -----------------------------
# Topology + NATS credentials (config-driven)
# -----------------------------
# config/topology.yml is written in JSON syntax (valid YAML), so we can parse it without PyYAML.
TOPOLOGY_FILE="${SYNC_TOPOLOGY_FILE:-$ROOT_DIR/config/topology.yml}"
TOPOLOGY_TOOL="$ROOT_DIR/scripts/tools/topology.py"

# Compose interpolation inputs (defaults from topology.yml).
SYNC_CENTRAL_ID="${SYNC_CENTRAL_ID:-$(python3 "$TOPOLOGY_TOOL" get topology.centralId)}"
SYNC_NATS_USERNAME="${SYNC_NATS_USERNAME:-$(python3 "$TOPOLOGY_TOOL" get auth.admin.username)}"
SYNC_NATS_PASSWORD="${SYNC_NATS_PASSWORD:-$(python3 "$TOPOLOGY_TOOL" get auth.admin.password)}"
export SYNC_CENTRAL_ID SYNC_NATS_USERNAME SYNC_NATS_PASSWORD

require_valid_dotenv() {
  if [[ -f ".env" ]]; then
    # allow blank lines and comments; reject anything not KEY=VALUE
    if grep -nEv '^\s*(#.*)?$|^[A-Za-z_][A-Za-z0-9_]*=.*$' .env >/dev/null; then
      echo "ERROR: .env contains invalid lines. Only KEY=VALUE is allowed." >&2
      echo "Invalid lines:" >&2
      grep -nEv '^\s*(#.*)?$|^[A-Za-z_][A-Za-z0-9_]*=.*$' .env >&2
      exit 1
    fi
  fi
}



# --- Use phase3_small override compose (additive) if present ---
COMPOSE_FILE_SMALL_OVERRIDE="$ROOT_DIR/docker-compose.phase3.small.override.yml"

_dc() {
  log_info "docker compose (phase3_small) $*"
  if [[ -f "$COMPOSE_FILE_SMALL_OVERRIDE" ]]; then
    (cd "$ROOT_DIR" && docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" -f "$COMPOSE_FILE_SMALL_OVERRIDE" "$@")
  else
    (cd "$ROOT_DIR" && docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@")
  fi
}



# Generate nats/generated/authz_<centralId>.conf (mounted into every NATS container).
phase3_generate_nats_authz() {
  local out="$ROOT_DIR/nats/generated/authz_${SYNC_CENTRAL_ID}.conf"
  mkdir -p "$(dirname "$out")"
  python3 "$TOPOLOGY_TOOL" nats-authz > "$out"
}

# Default ports (override via env)
CENTRAL_HTTP_PORT="${CENTRAL_HTTP_PORT:-18080}"
LEAF1_HTTP_PORT="${LEAF1_HTTP_PORT:-18081}"

CENTRAL_BASE="http://localhost:${CENTRAL_HTTP_PORT}"
LEAF1_BASE="http://localhost:${LEAF1_HTTP_PORT}"

# -----------------------------
# Logging helpers (STDERR only)
# -----------------------------
_ts() { date +"%Y-%m-%d %H:%M:%S"; }

log_title() { echo "[$(_ts)] ===== $* =====" >&2; }
log_step()  { echo "[$(_ts)] STEP: $*" >&2; }
log_info()  { echo "[$(_ts)] INFO: $*" >&2; }
log_ok()    { echo "[$(_ts)] OK:   $*" >&2; }
log_warn()  { echo "[$(_ts)] WARN: $*" >&2; }
log_fail()  { echo "[$(_ts)] FAIL: $*" >&2; }

# -----------------------------
# Prereqs / context
# -----------------------------
require_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || { log_fail "Missing required command: $c"; exit 1; }
}

phase3_prereqs() {
  require_cmd docker
  require_cmd curl
  require_cmd python3
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    log_fail "Compose file not found: $COMPOSE_FILE"
    exit 1
  fi
  # Ensure authentication file exists (required by mounted NATS configs)
  phase3_generate_nats_authz
}

phase3_context() {
  log_info "Project:          $PROJECT_NAME"
  log_info "Compose file:      $COMPOSE_FILE"
  log_info "Central endpoint:  $CENTRAL_BASE"
  log_info "Leaf1 endpoint:    $LEAF1_BASE"
}

# -----------------------------
# docker compose wrapper
# -----------------------------
_dc() {
  # Logs to STDERR only so it will not break pipelines that parse STDOUT.
  log_info "docker compose $*"
  (cd "$ROOT_DIR" && docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@")
}

# -----------------------------
# HTTP helpers
# -----------------------------
# _http_json  : print response body to STDOUT, fail on non-2xx
# _http_discard: discard body, fail on non-2xx
# NOTE: We intentionally use -f (fail) and -sS (quiet but show errors).

_http_json() {
  local method="$1"; shift
  local url="$1"; shift
  log_info "HTTP $method $url"
  curl -fsS -X "$method" "$url" "$@"
}

_http_discard() {
  local method="$1"; shift
  local url="$1"; shift
  log_info "HTTP $method $url"
  curl -fsS -o /dev/null -X "$method" "$url" "$@"
}

# Backwards-compatible name used by some scripts.
_http() {
  _http_json "$@"
}

_wait_for_http() {
  local url="$1"
  local tries="${2:-60}"
  local sleep_s="${3:-2}"

  for ((i=1; i<=tries; i++)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      log_ok "Reachable: $url"
      return 0
    fi
    if (( i % 10 == 0 )); then
      log_info "Waiting for $url (attempt $i/$tries)"
    fi
    sleep "$sleep_s"
  done
  log_fail "Timed out waiting for $url"
  exit 1
}

# -----------------------------
# JSON helpers
# -----------------------------
_json_get() {
  local key="$1"
  python3 - "$key" <<'PY'
import json,sys

key=sys.argv[1]
raw=sys.stdin.read()

if not raw.strip():
    print("")
    raise SystemExit(0)

try:
    obj=json.loads(raw)
except Exception:
    # Tolerate non-JSON or truncated output; return empty
    print("")
    raise SystemExit(0)

print(obj.get(key, ""))
PY
}

_json_get_path() {
  # Usage: echo '{"a":{"b":1}}' | _json_get_path a.b
  local path="$1"
  python3 - "$path" <<'PY'
import json,sys

path=sys.argv[1]
raw=sys.stdin.read()

if not raw.strip():
    print("")
    raise SystemExit(0)

try:
    obj=json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)

cur=obj
for k in path.split('.'):
    if isinstance(cur, dict) and k in cur:
        cur=cur[k]
    else:
        print("")
        raise SystemExit(0)

print(cur if cur is not None else "")
PY
}

assert_int_ge() {
  local label="$1" actual="$2" min="$3"
  python3 - "$label" "$actual" "$min" <<'PY'
import sys

label=sys.argv[1]
actual_s=sys.argv[2]
min_s=sys.argv[3]

try:
    actual=int(actual_s)
except Exception:
    print(f"FAIL: {label} expected an integer, got '{actual_s}'")
    sys.exit(1)

minv=int(min_s)
if actual < minv:
    print(f"FAIL: {label} expected >= {minv}, got {actual}")
    sys.exit(1)
print(f"OK: {label} >= {minv} (got {actual})")
PY
}

assert_int_eq() {
  local label="$1" actual="$2" expected="$3"
  python3 - "$label" "$actual" "$expected" <<'PY'
import sys

label=sys.argv[1]
actual_s=sys.argv[2]
exp_s=sys.argv[3]

try:
    actual=int(actual_s)
except Exception:
    print(f"FAIL: {label} expected an integer, got '{actual_s}'")
    sys.exit(1)

exp=int(exp_s)
if actual != exp:
    print(f"FAIL: {label} expected == {exp}, got {actual}")
    sys.exit(1)
print(f"OK: {label} == {exp}")
PY
}

# -----------------------------
# DB defaults (override via env)
# -----------------------------
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-dockyard_dev}"
DB_PASSWORD="${DB_PASSWORD:-postgres}"
PG_SERVICE="${PG_SERVICE:-postgres}"

psql_in_pg() {
  # Returns a single value (no headers) and strips CRs.
  _dc exec -T "$PG_SERVICE" psql -U "$DB_USER" -d "$DB_NAME" -Atc "$1" | tr -d '\r'
}

require_outbox_table() {
  local exists
  exists="$(psql_in_pg "select to_regclass('public.sync_outbox_event') is not null;" | tr -d '[:space:]')"
  if [[ "$exists" != "t" ]]; then
    log_fail "sync_outbox_event does not exist in DB '$DB_NAME' (user '$DB_USER')."
    log_info "If your DB name differs, run: DB_NAME=<your_db> $0"
    exit 1
  fi
  log_ok "Found table sync_outbox_event in DB '$DB_NAME'."
}


# -----------------------------
# Interactive helper
# -----------------------------
# PHASE3_INTERACTIVE:
#   1 (default) => prompt user at checkpoints
#   0           => auto-continue (CI/non-interactive)
PHASE3_INTERACTIVE="${PHASE3_INTERACTIVE:-1}"

confirm() {
  local prompt="$1"
  local default_no="${2:-1}" # 1 => default No, 0 => default Yes

  if [[ "${PHASE3_INTERACTIVE}" != "1" ]]; then
    log_info "NON-INTERACTIVE: ${prompt} -> auto-continue"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    log_warn "No TTY available for prompt: ${prompt} -> auto-continue"
    return 0
  fi

  local suffix
  if [[ "$default_no" -eq 1 ]]; then suffix="[y/N]"; else suffix="[Y/n]"; fi

  while true; do
    read -r -p "${prompt} ${suffix}: " ans
    if [[ -z "${ans}" ]]; then
      [[ "$default_no" -eq 1 ]] && return 1 || return 0
    fi
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) echo "Please answer y/yes or n/no." ;;
    esac
  done
}