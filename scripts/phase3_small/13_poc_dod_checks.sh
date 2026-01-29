#!/usr/bin/env bash
set -euo pipefail

# Phase-3 PoC Definition-of-Done checks (menu-friendly).
#
# This is a *fast* health + functional validation set. It is designed to be run
# repeatedly while iterating on compose/topology and relay behavior.

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_DIR}/_control_small.sh"

phase3_prereqs
phase3_context
source "${_DIR}/_poc_http_v2.sh"

phase3_prereqs
phase3_context

CENTRAL_ID="${SYNC_CENTRAL_ID:-nhq}"
ZONE_ID="${SYNC_ZONE_ID:-snc}"
SUBZONE_ID="${SYNC_SUBZONE_ID:-unit1}"

log_step "=== PoC DoD Checks ==="

# nats-box is required for JS API / CLI checks
log_step "Ensure nats-box is running"
ensure_service_up "${SVC_NATS_BOX}"

# 1) Containers healthy
log_step "Check NATS containers healthy"
wait_central_nats
wait_zone_nats
wait_subzone_nats

log_step "Check app endpoints"
wait_central_app
wait_zone_app
wait_subzone_app
wait_leaf_app

# 2) JetStream streams exist
log_step "Check streams exist (via JS API)"
for s in "${STREAM_UP_LEAF}" "${STREAM_UP_SUBZONE}" "${STREAM_UP_ZONE}" \
         "${STREAM_DOWN_CENTRAL}" "${STREAM_DOWN_ZONE}" "${STREAM_DOWN_SUBZONE}"; do
  if nats_box_nats --server "${NATS_URL_CENTRAL}" req --raw "\$JS.API.STREAM.INFO.${s}" "" >/dev/null 2>&1; then
    log_ok "Stream exists: ${s}"
  else
    log_fail "Missing stream: ${s}"
  fi
done

# 3) Relay consumers present (heuristic)
log_step "Check relay consumers exist (heuristic, warns if absent)"

_consumer_names() {
  local stream="$1"
  nats_box_nats --server "${NATS_URL_CENTRAL}" consumer ls "$stream" 2>/dev/null | awk '{print $1}' | grep -v -E '^(Consumers:|\s*$)' || true
}

_warn_if_missing_like() {
  local stream="$1" pattern="$2" desc="$3"
  if _consumer_names "$stream" | grep -qE "$pattern"; then
    log_ok "Consumer present (${desc}) on ${stream}"
  else
    log_warn "Consumer NOT found (${desc}) on ${stream} (pattern: ${pattern})"
  fi
}

# Patterns cover both older and newer naming conventions.
_warn_if_missing_like "${STREAM_UP_ZONE}"      'up|zone|central|replay|__up__'  "zone->central (upstream)"
_warn_if_missing_like "${STREAM_UP_SUBZONE}"   'subzone|zone|__up__'           "subzone->zone (upstream)"
_warn_if_missing_like "${STREAM_UP_LEAF}"      'leaf|subzone|__up__'           "leaf->subzone (upstream)"
_warn_if_missing_like "${STREAM_DOWN_CENTRAL}" 'down|central|__down__'         "central->zone (downstream)"
_warn_if_missing_like "${STREAM_DOWN_ZONE}"    'down|zone|__down__'            "zone->subzone (downstream)"
_warn_if_missing_like "${STREAM_DOWN_SUBZONE}" 'down|subzone|__down__'         "subzone->leaf (downstream)"

# 4) Functional smoke (fast)
log_step "Functional smoke: upstream"
"${_DIR}/06b_smoke_up_taxonomy.sh"

log_step "Functional smoke: downstream"
"${_DIR}/07b_smoke_down_taxonomy.sh"

log_ok "PoC DoD checks complete."
