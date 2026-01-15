#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

cat <<'EOF'
TEST: Central offline / full backfill

PASS CRITERIA (DETERMINISTIC)
1) Stop central node (nats-central + sync-central).
2) While Central is offline, Leaf1 continues to accept writes (/api/orders returns HTTP 2xx).
3) After Central restarts, backfill/replay is observed on Central:
   - LEAF_STREAM last_seq increases by at least N relative to baseline.

SECONDARY SIGNAL (best-effort)
- Central durable consumer drains (numPending -> 0) after restart.

EVIDENCE TO CAPTURE
- Baseline LEAF_STREAM last_seq (Central)
- Target last_seq and observed last_seq after restart
- Central /poc/ping after restart
- (Optional) consumer JSON showing numPending=0
EOF

CENTRAL_DURABLE="central_central_none_central01"
PUBLISH_COUNT="${1:-20}"   # default 20 to match existing test, override as needed

CENTRAL_ADMIN="${CENTRAL_BASE}"          # typically http://localhost:18080
LEAF1_API="${LEAF1_BASE}/api/orders"     # typically http://localhost:18081/api/orders

STREAM="LEAF_STREAM"
NATS_BOX_CONTAINER="${PROJECT_NAME}-nats-box-1"
NATS_SERVER="nats://nats-central:4222"

cleanup() {
  # always attempt to bring central back
  _dc start nats-central >/dev/null 2>&1 || true
  _dc start sync-central >/dev/null 2>&1 || true
}
trap cleanup EXIT

_js() {
  docker exec -i "${NATS_BOX_CONTAINER}" nats --server "${NATS_SERVER}" "$@"
}

_js_last_seq() {
  _js stream info "${STREAM}" --json \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["state"]["last_seq"])'
}

echo "Ensuring central durable consumer exists (stream=${STREAM} durable=${CENTRAL_DURABLE}) ..."
_http POST "${CENTRAL_ADMIN}/poc/consumer/ensure" \
  -H "Content-Type: application/json" \
  -d "{\"stream\":\"${STREAM}\",\"durable\":\"${CENTRAL_DURABLE}\",\"filterSubject\":\"leaf.>\"}" >/dev/null

baseline="$(_js_last_seq)"
echo "Baseline: ${STREAM} lastSeq=${baseline}"

printf "\nCentral consumer state BEFORE Central stop (evidence):\n"
_http GET "${CENTRAL_ADMIN}/poc/consumer/${STREAM}/${CENTRAL_DURABLE}" | python3 -m json.tool

echo "Stopping Central node (nats-central + sync-central) ..."
_dc stop sync-central
_dc stop nats-central

stamp="$(date +%s)"
echo "Publishing ${PUBLISH_COUNT} leaf events from Leaf1 while Central is offline ..."
for i in $(seq 1 "${PUBLISH_COUNT}"); do
  _http POST "${LEAF1_API}" \
    -H "Content-Type: application/json" \
    -d "{\"orderId\":\"central-offline-${stamp}-${i}\",\"amount\":1.00}" >/dev/null
done
echo "Published ${PUBLISH_COUNT} events (runId=${stamp})."

# NOTE: While central is down, we cannot query Central consumer state reliably.
# We only prove continuity of writes by successful POSTs above.

echo "Starting Central node (nats-central + sync-central) ..."
_dc start nats-central
_dc start sync-central

echo "Waiting for Central API /poc/ping ..."
_wait_for_http "${CENTRAL_ADMIN}/poc/ping" 180 2

printf "\nCentral ping after restart (evidence):\n"
_http GET "${CENTRAL_ADMIN}/poc/ping" | python3 -m json.tool

target=$((baseline + PUBLISH_COUNT))
echo "Waiting for ${STREAM} lastSeq >= ${target} (baseline ${baseline} + N ${PUBLISH_COUNT}) ..."
for _ in $(seq 1 90); do
  now="$(_js_last_seq || true)"
  if [[ -n "${now}" ]] && [[ "${now}" -ge "${target}" ]]; then
    echo "Replay/backfill observed: ${STREAM} lastSeq=${now} (target=${target})"
    break
  fi
  sleep 2
done

now="$(_js_last_seq || true)"
if [[ -z "${now}" ]] || [[ "${now}" -lt "${target}" ]]; then
  echo "FAIL: backfill not observed; expected lastSeq>=${target}, got ${now:-<empty>}" >&2
  exit 1
fi

echo "Waiting for central durable consumer to drain (numPending -> 0) ..."
for _ in $(seq 1 60); do
  info="$(_http GET "${CENTRAL_ADMIN}/poc/consumer/${STREAM}/${CENTRAL_DURABLE}" || true)"
  pending="$(printf "%s" "$info" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("numPending",""))' 2>/dev/null || true)"
  if [[ "${pending}" == "0" ]]; then
    echo "PASS: central backfill completed (numPending=0)"
    printf "\nCentral consumer state AFTER drain (evidence):\n"
    printf "%s\n" "$info" | python3 -m json.tool
    exit 0
  fi
  sleep 2
done

# Pass on deterministic signal even if pending metric is inconclusive.
echo "PASS: central offline backfill validated via lastSeq (numPending did not reach 0 within timeout; lastSeq=${now})"
exit 0
