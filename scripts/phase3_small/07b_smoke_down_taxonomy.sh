#!/usr/bin/env bash
set -euo pipefail

# Downstream E2E smoke (best-effort) using stream-config-derived subject prefixes.
#
# Validates: Central publishes a down.* message -> relays rewrite -> message appears under
# the DOWN_SUBZONE_STREAM subject prefix.
#
# Notes:
# - This does not assume a specific *exact* rewritten subject, only that it lands under
#   the down.subzone... prefix configured on DOWN_SUBZONE_STREAM.

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_DIR}/_common_small.sh"
source "${_DIR}/_poc_http_v2.sh"

phase3_prereqs
phase3_context

phase3_prereqs
phase3_context

wait_http_or_fail "${CENTRAL_HTTP}/poc/ping" 90
wait_js_or_fail "${NATS_URL_CENTRAL}" 60

CENTRAL_ID="${SYNC_CENTRAL_ID:-nhq}"
ZONE_ID="${SYNC_ZONE_ID:-snc}"
SUBZONE_ID="${SYNC_SUBZONE_ID:-unit1}"

_js_info() {
  local stream="$1"
  nats_box_nats --server "${NATS_URL_CENTRAL}" req --raw "\$JS.API.STREAM.INFO.${stream}" ""
}

_first_subject() {
  python3 - <<'PY'
import json,sys
try:
  d=json.load(sys.stdin)
  subs=d.get('config',{}).get('subjects',[])
  print(subs[0] if subs else '')
except Exception:
  print('')
PY
}

DOWN_CENTRAL_SUBJ="$(_js_info "${STREAM_DOWN_CENTRAL}" | _first_subject)"
DOWN_SUBZONE_SUBJ="$(_js_info "${STREAM_DOWN_SUBZONE}" | _first_subject)"

if [[ -z "${DOWN_CENTRAL_SUBJ}" || -z "${DOWN_SUBZONE_SUBJ}" ]]; then
  log_fail "Unable to read stream subjects via JS API (check JS readiness and permissions)."
fi

# Convert stream subject wildcard to a usable filter.
# Example: down.subzone.nhq.>  -> down.subzone.nhq.>
FILTER="${DOWN_SUBZONE_SUBJ}"
DURABLE="tplan3_smoke_down_${ZONE_ID}_${SUBZONE_ID}_$(date +%s)"

log_step "Ensure consumer (central) stream=${STREAM_DOWN_SUBZONE} durable=${DURABLE} filter=${FILTER}"
poc_consumer_ensure "${CENTRAL_HTTP}" "${STREAM_DOWN_SUBZONE}" "${DURABLE}" "${FILTER}" "explicit" "all" "instant" 1000

# Drain existing backlog for this prefix.
log_step "Drain backlog (if any) for durable=${DURABLE}"
for _ in 1 2 3 4 5; do
  out="$(poc_consumer_pull "${CENTRAL_HTTP}" "${STREAM_DOWN_SUBZONE}" "${DURABLE}" 200 2 true)"
  a="$(echo "$out" | python3 - <<'PY'
import json,sys
try:
  d=json.load(sys.stdin)
  print(d.get('acked',0))
except Exception:
  print(0)
PY
)"
  [[ "$a" -gt 0 ]] || break
done

# Build a publish subject under DOWN_CENTRAL_SUBJ prefix.
# We append a deterministic, POC-friendly suffix that includes zone/subzone + a unique token.
# Example target subject (when DOWN_CENTRAL_SUBJ is down.central.nhq.>):
#   down.central.nhq.snc.unit1.all.config.policy.updated.smoke.<ts>
BASE="${DOWN_CENTRAL_SUBJ%>}"         # trim trailing wildcard marker
BASE="${BASE%.}"                      # trim trailing dot if any

TS="$(date +%s)"
PUB_SUBJ="${BASE}.${ZONE_ID}.${SUBZONE_ID}.all.config.policy.updated.smoke.${TS}"
PAYLOAD="smoke-down ${ZONE_ID}/${SUBZONE_ID} ${TS}"

log_step "Publish down message on central subject=${PUB_SUBJ}"
poc_publish "${CENTRAL_HTTP}" "${PUB_SUBJ}" "${PAYLOAD}" "smoke-down-${TS}"

log_step "Pull 1 rewritten msg from DOWN_SUBZONE_STREAM"
out="$(poc_consumer_pull "${CENTRAL_HTTP}" "${STREAM_DOWN_SUBZONE}" "${DURABLE}" 1 25 true)"
acked="$(echo "$out" | python3 - <<'PY'
import json,sys
try:
  d=json.load(sys.stdin)
  print(d.get('acked',0))
except Exception:
  print(0)
PY
)"

if [[ "${acked}" -lt 1 ]]; then
  log_fail "Downstream smoke FAILED (acked=${acked}). Check relays, subject rewrite rules, and DOWN_* stream subjects."
fi

log_ok "Downstream smoke OK (acked=${acked})."
