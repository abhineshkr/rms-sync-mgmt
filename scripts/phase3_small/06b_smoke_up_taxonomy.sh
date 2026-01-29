#!/usr/bin/env bash
set -euo pipefail

# Upstream E2E smoke using the newer taxonomy that includes centralId.
#
# Validates: Leaf publishes -> relays forward -> Central sees `up.zone.<centralId>.<zone>.>`

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_DIR}/_common_small.sh"
source "${_DIR}/_poc_http_v2.sh"

phase3_prereqs
phase3_context

phase3_prereqs
phase3_context

wait_http_or_fail "${CENTRAL_HTTP}/poc/ping" 90
wait_http_or_fail "${LEAF_DESK1_HTTP}/poc/ping" 90
wait_js_or_fail "${NATS_URL_CENTRAL}" 60

CENTRAL_ID="${SYNC_CENTRAL_ID:-nhq}"
ZONE_ID="${SYNC_ZONE_ID:-snc}"

STREAM="${STREAM_UP_ZONE}"
FILTER="up.zone.${CENTRAL_ID}.${ZONE_ID}.>"
DURABLE="tplan3_smoke_up_zone_${ZONE_ID}_$(date +%s)"

log_step "Ensure consumer (central) stream=${STREAM} durable=${DURABLE} filter=${FILTER}"
poc_consumer_ensure "${CENTRAL_HTTP}" "${STREAM}" "${DURABLE}" "${FILTER}" "explicit" "all" "instant" 1000

# Drain any existing backlog for this filter so the next pull reflects *new* traffic.
log_step "Drain backlog (if any) for durable=${DURABLE}"
for _ in 1 2 3 4 5; do
  out="$(poc_consumer_pull "${CENTRAL_HTTP}" "${STREAM}" "${DURABLE}" 200 2 true)"
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

log_step "Publish leaf order (generates upstream traffic)"
RID="smoke-up-${ZONE_ID}-$(date +%s)"
poc_publish_order "${LEAF_DESK1_HTTP}" "${RID}" 1

log_step "Pull 1 msg from central consumer"
out="$(poc_consumer_pull "${CENTRAL_HTTP}" "${STREAM}" "${DURABLE}" 1 20 true)"
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
  log_fail "Upstream smoke FAILED (acked=${acked}). Check relays/logs and subject taxonomy."
fi

log_ok "Upstream smoke OK (acked=${acked})."