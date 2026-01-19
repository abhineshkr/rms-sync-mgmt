#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "TEST: DUPLICATE PUBLISH DEDUP (ADJACENCY)"
phase3_context

# Publishes twice with the same messageId and verifies DOWN_CENTRAL_STREAM lastSeq increases by exactly 1.

CENTRAL_ADMIN="${CENTRAL_BASE:-http://localhost:18080}"
STREAM="DOWN_CENTRAL_STREAM"
SUBJECT="down.central.z1.sz1.all.audit.dedup"
MSG_ID="dedup-$(date +%s)"

echo "Baseline: reading ${STREAM} lastSeq from ${CENTRAL_ADMIN} ..."
before="$(_http GET "${CENTRAL_ADMIN}/poc/stream/${STREAM}" | _json_get lastSeq)"
echo "Baseline lastSeq: ${before}"

echo "Publishing first message (messageId=${MSG_ID}) ..."
resp1="$(_http POST "${CENTRAL_ADMIN}/poc/publish" \
  -H "Content-Type: application/json" \
  -d "{\"subject\":\"${SUBJECT}\",\"payload\":\"{\\\"test\\\":1}\",\"messageId\":\"${MSG_ID}\"}")"
echo "$resp1" | python3 -m json.tool

echo "Publishing duplicate message (same messageId=${MSG_ID}) ..."
resp2="$(_http POST "${CENTRAL_ADMIN}/poc/publish" \
  -H "Content-Type: application/json" \
  -d "{\"subject\":\"${SUBJECT}\",\"payload\":\"{\\\"test\\\":1}\",\"messageId\":\"${MSG_ID}\"}")"
echo "$resp2" | python3 -m json.tool

# Wait briefly for stream state to reflect publishes
echo "Reading ${STREAM} lastSeq after publishes ..."
after=""
for _ in $(seq 1 10); do
  after="$(_http GET "${CENTRAL_ADMIN}/poc/stream/${STREAM}" | _json_get lastSeq || true)"
  [[ -n "$after" ]] && break
  sleep 1
done

if [[ -z "$after" ]]; then
  echo "FAIL: could not read ${STREAM} lastSeq after publishes" >&2
  exit 1
fi

echo "After lastSeq: ${after}"

python3 - <<PY
b=int("${before}")
a=int("${after}")
if a == b + 1:
    print("PASS: dedup validated (lastSeq increased by exactly 1).")
    raise SystemExit(0)
print(f"FAIL: expected lastSeq to increase by 1; baseline={b} after={a}")
raise SystemExit(1)
PY
