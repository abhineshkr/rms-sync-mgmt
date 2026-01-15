#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

cat <<'EOF'
TEST: App crash / outbox replay after restart

EXPECTED OUTPUT / PASS CRITERIA
- After creating an order and immediately stopping sync-leaf1, the outbox PENDING increases (> before).
- After restarting sync-leaf1, PENDING returns to 0 within the timeout window.

EVIDENCE TO CAPTURE
- Outbox PENDING before, after crash, and after drain
- Leaf1 /poc/ping after restart
EOF

# Preconditions
_wait_for_http "${LEAF1_BASE}/poc/ping" 120 2
require_outbox_table

# Helper: read pending count reliably
_outbox_pending() {
  # psql_in_pg already trims reasonably, but we additionally strip whitespace defensively
  local v
  v="$(psql_in_pg "select count(*) from sync_outbox_event where status='PENDING';" | tr -d '[:space:]')"
  echo "${v:-0}"
}

echo "Outbox PENDING before:"
before="$(_outbox_pending)"
echo "$before"

stamp="$(date +%s)"
order_id="crash-${stamp}"

echo "Creating one order on Leaf1, then crashing Leaf1 immediately (before poll interval runs) ..."
_http POST "${LEAF1_BASE}/api/orders" \
  -H "Content-Type: application/json" \
  -d "{\"orderId\":\"${order_id}\",\"amount\":1.00}" >/dev/null

# Stop the app quickly to simulate crash
_dc stop sync-leaf1

# Wait briefly for the outbox row to be committed (bounded)
pending=""
for _ in $(seq 1 10); do
  pending="$(_outbox_pending)"
  # Expect pending to be > before
  if python3 - <<PY
b=int("${before}")
p=int("${pending}")
import sys
sys.exit(0 if p>b else 1)
PY
  then
    break
  fi
  sleep 1
done

echo "Outbox PENDING after crash: $pending (expected > $before)"

# Enforce the expectation (fail fast if it never increased)
python3 - <<PY
b=int("${before}")
p=int("${pending}")
if p <= b:
    print(f"FAIL: expected outbox pending to increase after crash; before={b} after_crash={p}")
    raise SystemExit(1)
print("OK: pending increased after crash.")
PY

echo "Restarting Leaf1 ..."
_dc start sync-leaf1
_wait_for_http "${LEAF1_BASE}/poc/ping" 120 2

printf "\nLeaf1 ping after restart:\n"
_http GET "${LEAF1_BASE}/poc/ping" | python3 -m json.tool

echo "Waiting for outbox to drain (PENDING -> 0) ..."
for _ in $(seq 1 120); do
  pending="$(_outbox_pending)"
  if [[ "$pending" == "0" ]]; then
    echo "Outbox drained (pending=0)."
    echo "PASS: app crash outbox replay validated (pending -> 0 after restart)."
    exit 0
  fi
  sleep 2
done

echo "FAIL: Outbox did not drain in time. Last pending=$pending" >&2
exit 1
