#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

# Test: Duplicate publish -> JetStream dedup.
# Assertion: CENTRAL_STREAM last_seq increases by exactly 1 for two publishes with the same messageId.

STREAM="CENTRAL_STREAM"
SUBJECT="central.central.none.central01.audit.logged"

CENTRAL_ADMIN="${CENTRAL_BASE}"                # http://localhost:18080
NATS_BOX_CONTAINER="${PROJECT_NAME}-nats-box-1"
NATS_SERVER="nats://nats-central:4222"

RUN_ID="$(date +%s)"
MSG_ID="p3-dedup-${RUN_ID}"

_js_last_seq() {
  docker exec -i "${NATS_BOX_CONTAINER}" nats --server "${NATS_SERVER}" stream info "${STREAM}" --json \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["state"]["last_seq"])'
}

before_last="$(_js_last_seq)"
echo "Baseline: ${STREAM} lastSeq=${before_last}"

# First publish
_http POST "${CENTRAL_ADMIN}/poc/publish" -H "Content-Type: application/json" \
  -d "{\"subject\":\"${SUBJECT}\",\"payload\":\"{\\\"hello\\\":\\\"world\\\"}\",\"messageId\":\"${MSG_ID}\"}" >/dev/null

# Duplicate publish (same messageId)
_http POST "${CENTRAL_ADMIN}/poc/publish" -H "Content-Type: application/json" \
  -d "{\"subject\":\"${SUBJECT}\",\"payload\":\"{\\\"hello\\\":\\\"world\\\"}\",\"messageId\":\"${MSG_ID}\"}" >/dev/null

after_last="$(_js_last_seq)"
echo "After: ${STREAM} lastSeq=${after_last}"

python3 - <<PY
b=int("${before_last}")
a=int("${after_last}")
if a == b + 1:
  print("PASS: dedup kept only one message (lastSeq increased by 1)")
  raise SystemExit(0)
print(f"FAIL: expected lastSeq==before+1 but got before={b} after={a}")
raise SystemExit(1)
PY
