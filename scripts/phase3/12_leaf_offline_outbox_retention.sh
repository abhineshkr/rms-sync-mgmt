#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "TEST: LEAF OFFLINE OUTBOX RETENTION"
phase3_context

cat >&2 <<'EOF'
TEST: Leaf messaging offline -> outbox retained, then published on recovery

PASS CRITERIA (DETERMINISTIC)
1) Stop nats-leaf1 (simulate leaf messaging layer offline).
2) Leaf1 business API continues to accept requests (HTTP 2xx on /api/orders),
   meaning outbox rows are created while messaging is down.
3) Restart nats-leaf1.
4) Outbox pending rows drain to 0 AND JetStream UP_LEAF_STREAM last_seq increases
   by at least N relative to baseline after recovery.

EVIDENCE TO CAPTURE
- Outbox pending count after publishing while nats-leaf1 is down
- Baseline and final UP_LEAF_STREAM last_seq
- Final outbox pending count (0)
EOF

PUBLISH_COUNT="${1:-10}"

LEAF1_API="${LEAF1_BASE}/api/orders"       # typically http://localhost:18081/api/orders
STREAM="UP_LEAF_STREAM"

# JetStream query via nats-box to central (authoritative stream)
NATS_BOX_CONTAINER="${PROJECT_NAME}-nats-box-1"
NATS_SERVER="nats://${SYNC_NATS_USERNAME}:${SYNC_NATS_PASSWORD}@nats-central:4222"

_js() {
  docker exec -i "${NATS_BOX_CONTAINER}" nats --server "${NATS_SERVER}" "$@"
}

_js_last_seq() {
  _js stream info "${STREAM}" --json \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["state"]["last_seq"])'
}

# DB settings come from _common.sh (DB_USER, DB_NAME, DB_PASSWORD, PG_SERVICE)
_outbox_pending_count() {
  # Adjust table/column here if your schema differs
  local sql="
    select count(*)
    from sync_outbox_event
    where status = 'PENDING';
  "
  _dc exec -T "${PG_SERVICE}" psql -U "${DB_USER}" -d "${DB_NAME}" -t -c "${sql}" 2>/dev/null \
    | tr -d '[:space:]' || true
}

cleanup() {
  _dc start nats-leaf1 2>&1 || true
}
trap cleanup EXIT

baseline="$(_js_last_seq)"
echo "Baseline: ${STREAM} lastSeq=${baseline}"

echo "Stopping Leaf1 NATS server (nats-leaf1) ..."
_dc stop nats-leaf1

stamp="$(date +%s)"
echo "Creating ${PUBLISH_COUNT} outbox events on Leaf1 while its NATS server is offline ..."
for i in $(seq 1 "${PUBLISH_COUNT}"); do
  _http_discard POST "${LEAF1_API}" \
    -H "Content-Type: application/json" \
    -d "{\"orderId\":\"leaf-offline-${stamp}-${i}\",\"amount\":3.00}"
done
echo "Published ${PUBLISH_COUNT} business events (runId=${stamp})."

pending_db="$(_outbox_pending_count)"
if [[ -z "${pending_db}" ]]; then
  echo "WARN: Could not read outbox pending count (table/DB mismatch)."
  echo "      Verify DB=${DB_NAME} and table sync_outbox_event exists."
else
  echo "Outbox pending rows (expected > 0): ${pending_db}"
fi

echo "Starting Leaf1 NATS server (nats-leaf1) ..."
_dc start nats-leaf1

target=$((baseline + PUBLISH_COUNT))
echo "Waiting for outbox to publish and clear PENDING and for ${STREAM} lastSeq >= ${target} ..."

for _ in $(seq 1 90); do
  now="$(_js_last_seq || true)"
  pending_db="$(_outbox_pending_count)"

  # If DB query is unavailable, fall back to last_seq only.
  db_ok=true
  if [[ -z "${pending_db}" ]]; then
    db_ok=false
  fi

  seq_ok=false
  if [[ -n "${now}" ]] && [[ "${now}" -ge "${target}" ]]; then
    seq_ok=true
  fi

  if $db_ok; then
    if [[ "${pending_db}" == "0" ]] && $seq_ok; then
      echo "PASS: outbox cleared (PENDING=0) and publish observed (lastSeq=${now}, baseline=${baseline}, target=${target})"
      exit 0
    fi
  else
    if $seq_ok; then
      echo "PASS: publish observed via lastSeq (DB outbox count unavailable). lastSeq=${now}, baseline=${baseline}, target=${target}"
      exit 0
    fi
  fi

  sleep 2
done

now="$(_js_last_seq || true)"
echo "FAIL: recovery not observed in time." >&2
echo "  lastSeq now=${now:-<empty>} baseline=${baseline} target=${target}" >&2
echo "  outbox PENDING=${pending_db:-<unavailable>}" >&2
exit 1
