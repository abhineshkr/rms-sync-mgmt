#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NATS_DIR="${ROOT_DIR}/nats"

# Compose file and project name (match the rest of phase3 scripts)
COMPOSE_FILE="${COMPOSE_FILE:-${ROOT_DIR}/docker-compose.phase3.yml}"
PROJECT="${PROJECT:-syncmgmt_phase3}"

# What we consider "invalid" (legacy hostnames known to break)
INVALID_ROUTE_PATTERNS=(
  "nats-zone"
  "nats-subzone"
  "nats-central"
  "nats-leaf1"
  "nats-leaf2"
  "nats-leaf3"
  "nats-leaf4"
  "nats-leaf5"
)

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }
ok() { log "OK:   $*"; }

# Extract unique route targets from a conf file (host part of nats-route://HOST:PORT)
extract_routes() {
  local file="$1"
  grep -Eo 'nats-route://[^:[:space:]]+:[0-9]+' "$file" 2>/dev/null \
    | sed -E 's#nats-route://([^:]+):([0-9]+)#\1#' \
    | sort -u
}

# Extract service names from compose (these are resolvable DNS names on the compose network)
compose_services() {
  docker compose -f "$COMPOSE_FILE" -p "$PROJECT" config --services | sort -u
}

main() {
  [[ -d "$NATS_DIR" ]] || fail "Missing nats directory: $NATS_DIR"
  ls -1 "$NATS_DIR"/*.conf >/dev/null 2>&1 || fail "No .conf files found under $NATS_DIR"

  log "===== PHASE 3 - VALIDATE NATS ROUTES ====="
  log "NATS conf dir:   $NATS_DIR"
  log "Compose file:    $COMPOSE_FILE"
  log "Project:         $PROJECT"

  # 1) Block known invalid patterns immediately
  for p in "${INVALID_ROUTE_PATTERNS[@]}"; do
    if grep -RIn --line-number "$p" "$NATS_DIR"/*.conf >/dev/null 2>&1; then
      grep -RIn --line-number "$p" "$NATS_DIR"/*.conf >&2 || true
      fail "Found invalid legacy route target pattern: '$p' (see lines above)"
    fi
  done
  ok "No legacy/invalid hostname patterns found in nats/*.conf"

  # 2) Ensure no '*.conf' paths are directories (bind-mount safety)
  local bad_dirs
  bad_dirs="$(find "$NATS_DIR" -maxdepth 1 -name "*.conf" -type d -print || true)"
  if [[ -n "${bad_dirs}" ]]; then
    echo "$bad_dirs" >&2
    fail "Some *.conf paths are directories (Docker bind-mount will break). Remove/repair these."
  fi
  ok "All *.conf are regular files"

  # 3) Validate that every route target is a known compose service name
  mapfile -t services < <(compose_services)
  [[ "${#services[@]}" -gt 0 ]] || fail "No services found via docker compose config --services"

  # Build a fast lookup regex from services
  local svc_re
  svc_re="^($(printf "%s|" "${services[@]}" | sed 's/|$//'))$"

  local found_any_route="false"
  local unknown_targets=()
  while IFS= read -r conf; do
    mapfile -t targets < <(extract_routes "$conf" || true)
    if [[ "${#targets[@]}" -gt 0 ]]; then
      found_any_route="true"
    fi
    for t in "${targets[@]}"; do
      if ! [[ "$t" =~ $svc_re ]]; then
        unknown_targets+=("$(basename "$conf") -> $t")
      fi
    done
  done < <(ls -1 "$NATS_DIR"/*.conf)

  if [[ "${#unknown_targets[@]}" -gt 0 ]]; then
    printf '%s\n' "${unknown_targets[@]}" >&2
    fail "Found route targets that are not valid compose services (see list above)."
  fi
  ok "All route targets reference valid compose services"

  # 4) JetStream clustering sanity: require at least one routes list somewhere (usually central)
  # This avoids: "JetStream cluster requires configured routes ..."
  if [[ "$found_any_route" != "true" ]]; then
    fail "No routes found in any nats/*.conf. JetStream clustering will fail. Add routes to central at minimum."
  fi
  ok "At least one routes list present (JetStream clustering precondition satisfied)"

  ok "NATS route validation PASSED."
}

main "$@"