#!/usr/bin/env bash
set -euo pipefail

# Offline matrix runner (hardened)
#
# Usage:
#   scripts/phase3_small/12_offline_matrix_runner.sh [batch]
#
# batch: messages published per scenario (default: 5)

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_DIR}/_control_small.sh"
source "${_DIR}/_poc_http_v2.sh"

BATCH="${1:-5}"

phase3_prereqs
phase3_context

CENTRAL_ID="${SYNC_CENTRAL_ID:-nhq}"
ZONE_ID="${SYNC_ZONE_ID:-snc}"
SUBZONE_ID="${SYNC_SUBZONE_ID:-unit1}"

wait_http_or_fail "${CENTRAL_HTTP}/poc/ping" 90
wait_http_or_fail "${LEAF_DESK1_HTTP}/poc/ping" 90
wait_js_or_fail "${NATS_URL_CENTRAL}" 60

# --- compat wrappers (support older naming in your repo) ---
_call0() { local fn="$1"; shift || true; declare -F "$fn" >/dev/null 2>&1 && "$fn" "$@"; }
_stop_zone_app()    { _call0 stop_zone_app    || _call0 zone_snc_app_down; }
_start_zone_app()   { _call0 start_zone_app   || _call0 zone_snc_app_up; }
_stop_zone_nats()   { _call0 stop_zone_nats   || _call0 zone_snc_nats_down; }
_start_zone_nats()  { _call0 start_zone_nats  || _call0 zone_snc_nats_up; }
_stop_subzone_app() { _call0 stop_subzone_app || _call0 subzone_app_down; }
_start_subzone_app(){ _call0 start_subzone_app|| _call0 subzone_app_up; }
_stop_subzone_nats(){ _call0 stop_subzone_nats|| _call0 subzone_nats_down; }
_start_subzone_nats(){_call0 start_subzone_nats|| _call0 subzone_nats_up; }

_wait_zone_ready() {
  # Ensure Zone NATS JS is up + Zone relay responds
  wait_js_or_fail "${NATS_URL_ZONE_SNC}" 90
  wait_http_or_fail "${ZONE_SNC_HTTP}/poc/ping" 90 || _start_zone_app
  wait_http_or_fail "${ZONE_SNC_HTTP}/poc/ping" 90
}

_wait_subzone_ready() {
  wait_js_or_fail "${NATS_URL_SUBZONE_SNC_UNIT1}" 90
  wait_http_or_fail "${SUBZONE_SNC_UNIT1_HTTP}/poc/ping" 90 || _start_subzone_app
  wait_http_or_fail "${SUBZONE_SNC_UNIT1_HTTP}/poc/ping" 90
}

_assert_js_up() {
  local url="$1" label="$2"
  nats_box_nats --server "$url" stream ls >/dev/null 2>&1 || \
    log_fail "Expected JetStream UP for ${label} but it is NOT reachable (${url}). Relay-offline scenario requires NATS up."
}

_ensure_and_drain() {
  local stream="$1" durable="$2" filter="$3"
  poc_consumer_ensure "${CENTRAL_HTTP}" "$stream" "$durable" "$filter" "explicit" "all" "instant" 1000
  for _ in 1 2 3 4 5; do
    local out a
    out="$(poc_consumer_pull "${CENTRAL_HTTP}" "$stream" "$durable" 500 2 true)"
    a="$(echo "$out" | python3 - <<'PY'
import json,sys
try:
  d=json.load(sys.stdin); print(d.get('acked',0))
except Exception:
  print(0)
PY
)"
    [[ "$a" -gt 0 ]] || break
  done
}

_publish_orders() {
  local n="$1" tag="$2"
  local i
  for ((i=1; i<=n; i++)); do
    local rid="matrix-${tag}-${i}-$(date +%s)"
    poc_publish_order "${LEAF_DESK1_HTTP}" "${rid}" 1
  done
}

_pull_expect() {
  local stream="$1" durable="$2" filter="$3" want="$4" timeout_s="$5"
  local out acked
  out="$(poc_consumer_pull "${CENTRAL_HTTP}" "$stream" "$durable" "$want" "$timeout_s" true)"
  acked="$(echo "$out" | python3 - <<'PY'
import json,sys
try:
  d=json.load(sys.stdin); print(d.get('acked',0))
except Exception:
  print(0)
PY
)"
  [[ "$acked" -ge "$want" ]] || log_fail "Expected acked>=${want} but got acked=${acked} (stream=${stream} durable=${durable} filter=${filter})"
  log_ok "Pulled/acked ${acked}/${want} (stream=${stream} durable=${durable})"
}

run_up_scenario() {
  local name="$1" tier="$2"

  local ts stream filter durable
  ts="$(date +%s)"
  stream="${STREAM_UP_ZONE}"
  filter="up.zone.${CENTRAL_ID}.${ZONE_ID}.>"
  durable="tplan3_matrix_up_${name}_${ts}"

  log_step "[UP] Scenario=${name} tier=${tier} batch=${BATCH}"
  _ensure_and_drain "$stream" "$durable" "$filter"

  log_step "Stop target (${name})"
  case "$name" in
    zone_relay)   _stop_zone_app;   _assert_js_up "${NATS_URL_ZONE_SNC}" "ZONE NATS";;
    zone_nats)    _stop_zone_nats;;
    subzone_relay)_stop_subzone_app; _assert_js_up "${NATS_URL_SUBZONE_SNC_UNIT1}" "SUBZONE NATS";;
    subzone_nats) _stop_subzone_nats;;
    *) log_fail "Unknown scenario ${name}";;
  esac

  log_step "Publish ${BATCH} orders while OFFLINE (${name})"
  _publish_orders "$BATCH" "${name}"

  log_step "Start target (${name})"
  case "$name" in
    zone_relay)   _start_zone_app;   _wait_zone_ready;;
    zone_nats)    _start_zone_nats;  _wait_zone_ready;;      # ensure app is alive after NATS outage
    subzone_relay)_start_subzone_app; _wait_subzone_ready;;
    subzone_nats) _start_subzone_nats; _wait_subzone_ready;;
  esac

  log_step "Pull ${BATCH} forwarded msgs at central (timeout 60s)"
  _pull_expect "$stream" "$durable" "$filter" "$BATCH" 60
}

run_down_scenario() {
  local name="$1"

  local ts stream filter durable base
  ts="$(date +%s)"
  stream="${STREAM_DOWN_SUBZONE}"

  filter="$(nats_box_nats --server "${NATS_URL_CENTRAL}" req --raw "\$JS.API.STREAM.INFO.${stream}" "" | python3 - <<'PY'
import json,sys
try:
  d=json.load(sys.stdin)
  subs=d.get('config',{}).get('subjects',[])
  print(subs[0] if subs else '')
except Exception:
  print('')
PY
)"
  [[ -n "$filter" ]] || filter="down.subzone.${CENTRAL_ID}.>"
  durable="tplan3_matrix_down_${name}_${ts}"

  log_step "[DOWN] Scenario=${name} batch=${BATCH}"
  _ensure_and_drain "$stream" "$durable" "$filter"

  log_step "Stop target (${name})"
  case "$name" in
    zone_relay)   _stop_zone_app;   _assert_js_up "${NATS_URL_ZONE_SNC}" "ZONE NATS";;
    zone_nats)    _stop_zone_nats;;
    subzone_relay)_stop_subzone_app; _assert_js_up "${NATS_URL_SUBZONE_SNC_UNIT1}" "SUBZONE NATS";;
    subzone_nats) _stop_subzone_nats;;
  esac

  base="$(nats_box_nats --server "${NATS_URL_CENTRAL}" req --raw "\$JS.API.STREAM.INFO.${STREAM_DOWN_CENTRAL}" "" | python3 - <<'PY'
import json,sys
try:
  d=json.load(sys.stdin)
  subs=d.get('config',{}).get('subjects',[])
  s=subs[0] if subs else ''
  if s.endswith('>'): s=s[:-1]
  if s.endswith('.'): s=s[:-1]
  print(s)
except Exception:
  print('')
PY
)"
  [[ -n "$base" ]] || base="down.central.${CENTRAL_ID}"

  log_step "Publish ${BATCH} down msgs while OFFLINE (${name})"
  for i in $(seq 1 "$BATCH"); do
    local subj="${base}.${ZONE_ID}.${SUBZONE_ID}.all.config.policy.updated.matrix.${name}.${ts}.${i}"
    poc_publish "${CENTRAL_HTTP}" "$subj" "down-matrix ${name} ${ts} ${i}" "down-matrix-${name}-${ts}-${i}"
  done

  log_step "Start target (${name})"
  case "$name" in
    zone_relay)   _start_zone_app;   _wait_zone_ready;;
    zone_nats)    _start_zone_nats;  _wait_zone_ready;;
    subzone_relay)_start_subzone_app; _wait_subzone_ready;;
    subzone_nats) _start_subzone_nats; _wait_subzone_ready;;
  esac

  log_step "Pull ${BATCH} rewritten msgs at central (timeout 60s)"
  _pull_expect "$stream" "$durable" "$filter" "$BATCH" 60
}

log_step "=== OFFLINE MATRIX RUNNER (batch=${BATCH}) ==="

run_up_scenario "zone_relay"   "zone"
run_up_scenario "zone_nats"    "zone"
run_up_scenario "subzone_relay" "subzone"
run_up_scenario "subzone_nats"  "subzone"

run_down_scenario "zone_relay"
run_down_scenario "zone_nats"
run_down_scenario "subzone_relay"
run_down_scenario "subzone_nats"

log_ok "Offline matrix completed."

