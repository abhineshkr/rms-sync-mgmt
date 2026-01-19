#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "TEST: DEDUP USING MSG-ID (ADJACENCY)"
phase3_context

cat >&2 <<'EOF'
TEST: Duplicate publish / JetStream Msg-Id dedup

EXPECTED OUTPUT / PASS CRITERIA
- Two publishes are executed with the SAME messageId.
- JetStream dedup ensures only ONE new stream message is stored:
    - DOWN_CENTRAL_STREAM lastSeq increases by exactly 1 (not 2).

EVIDENCE TO CAPTURE
- JSON publish responses (both)
- Baseline and final DOWN_CENTRAL_STREAM lastSeq
EOF

CENTRAL_ADMIN="${CENTRAL_BASE}"          # typically http://localhost:18080
STREAM="DOWN_CENTRAL_STREAM"
SUBJECT="down.central.z1.sz1.all.audit.dedup"
MSG_ID="${1:-dedup-$(date +%s)}"

payload="{\"test\":\"dedup\",\"ts\":\"$(date -Iseconds)\"}"

# Baseline lastSeq (authoritative)
baseline="$(_http GET "${CENTRAL_ADMIN}/poc/stream/${STREAM}" | _json_get lastSeq)"
echo "Baseline: ${STREAM} lastSeq=${baseline}"

echo "Publishing with Msg-Id=${MSG_ID} ..."
resp1=$(_http POST "${CENTRAL_ADMIN}/poc/publish" \
  -H "Content-Type: application/json" \
  -d "{\"subject\":\"${SUBJECT}\",\"payload\":${payload},\"messageId\":\"${MSG_ID}\"}")
echo "$resp1" | python3 -m json.tool

echo "Publishing duplicate with same Msg-Id=${MSG_ID} ..."
resp2=$(_http POST "${CENTRAL_ADMIN}/poc/publish" \
  -H "Content-Type: application/json" \
  -d "{\"subject\":\"${SUBJECT}\",\"payload\":${payload},\"messageId\":\"${MSG_ID}\"}")
echo "$resp2" | python3 -m json.tool

final="$(_http GET "${CENTRAL_ADMIN}/poc/stream/${STREAM}" | _json_get lastSeq)"
echo "After: ${STREAM} lastSeq=${final}"

# Validate lastSeq increased by exactly 1
python3 - <<PY
b=int("${baseline}")
f=int("${final}")
if f == b + 1:
    print("PASS: dedup kept only one message (lastSeq increased by 1)")
    raise SystemExit(0)
print(f"FAIL: expected lastSeq to increase by 1; baseline={b} final={f}")
raise SystemExit(1)
PY
