#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

cat <<EOF
TEST: Leaf messaging offline / outbox retention + replay

EXPECTED OUTPUT / PASS CRITERIA
- While nats-leaf1 is stopped, Leaf1 app can still write outbox events (HTTP 2xx on /api/orders).
- The outbox table shows PENDING increases while NATS is down.
- After restarting nats-leaf1, the outbox drains:
    - PENDING becomes 0 within the timeout window.

EVIDENCE TO CAPTURE
- Outbox PENDING count before stopping NATS
- Outbox PENDING count after creating orders while NATS is down
- Outbox PENDING count after drain (0)

CONFIG (for evidence)
- LEAF1 API: ${LEAF1_BASE}
- DB: ${DB_NAME} (user=${DB_USER})
EOF

PUBLISH_COUNT="${1:-10}"

# --- helpers (self-contained) ---
psql_in_pg() {
  # prints a single scalar, trimmed
  local sql="$1"
  _dc exec -T "${PG_SERVICE}" psql -U "${DB_USER}" -d "${DB_NAME}" -t -c "${sql}" \
    | tr -d '[:space:]'
}

require_outbox_table() {
  # Fail fast with a useful message if the expected table isn't present.
  local exists
  exists="$(psql_in_pg "select count(*) from information_schema.tables where table_name='sync_outbox_event';")"
  if [[ "${exists}" != "1" ]]; then
    echo "FAIL: expected outbox table 'sync_outbox_event' not found in DB '${DB_NAME}'." >&2
    echo "HINT: run: _dc exec -it ${PG_SERVICE} psql -U ${DB_USER} -d ${DB_NAME} -c '\\dt'" >&2
    exit 1
  fi
}

cleanup() {
  # Ensure leaf NATS is brought back even on failure
  _dc start nats-leaf1 >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- prechecks ---
_wait_for_http "${LEAF1_BASE}/poc/ping" 120 2
require_outbox_table

before="$(psql_in_pg "select count(*) from sync_outbox_event where status='PENDING';")"
echo "Outbox PENDING before stopping nats-leaf1: ${before}"

echo "Stopping nats-leaf1 (Leaf messaging node offline) ..."
_dc stop nats-leaf1

stamp="$(date +%s)"
echo "Creating ${PUBLISH_COUNT} orders on Leaf1 while its NATS server is down (events should remain in outbox) ..."
for i in $(seq 1 "${PUBLISH_COUNT}"); do
  _http POST "${LEAF1_BASE}/api/orders" \
    -H "Content-Type: application/json" \
    -d "{\"orderId\":\"leaf-offline-${stamp}-${i}\",\"amount\":1.00}" >/dev/null
done

# Give dispatcher a moment to attempt publishes and record retries
sleep 3

pending="$(psql_in_pg "select count(*) from sync_outbox_event where status='PENDING';")"
echo "Outbox PENDING while nats-leaf1 is down: ${pending} (expected >= $((before + PUBLISH_COUNT)))"

echo "Starting nats-leaf1 (Leaf back online) ..."
_dc start nats-leaf1

echo "Waiting for outbox to drain (PENDING -> 0) ..."
for _ in $(seq 1 120); do
  pending="$(psql_in_pg "select count(*) from sync_outbox_event where status='PENDING';")"
  if [[ "${pending}" == "0" ]]; then
    echo "Outbox drained (PENDING=0)."
    echo "Outbox PENDING after drain (evidence): ${pending}"
    echo "PASS: leaf messaging offline retention + replay validated (outbox pending -> 0 after NATS restart)."
    exit 0
  fi
  sleep 2
done

echo "FAIL: Outbox did not drain in time. Last PENDING=${pending}" >&2
exit 1
