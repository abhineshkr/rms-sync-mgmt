#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "TEST: APP CRASH -> OUTBOX REPLAY (DB ASSERTION)"
phase3_context

cat >&2 <<'EOF2'
TEST: App crash / outbox replay after restart

EXPECTED OUTPUT / PASS CRITERIA
- After creating an order and immediately stopping sync-leaf1, the outbox PENDING increases (> before).
- After restarting sync-leaf1, PENDING returns to 0 within the timeout window.

EVIDENCE TO CAPTURE
- Outbox PENDING before, after crash, and after drain
- Leaf1 /poc/ping after restart

NOTES
- This script uses Postgres to validate the outbox table. If your DB name differs, run:
    DB_NAME=<your_db> ./14_app_crash_outbox_replay.sh
EOF2

# Preconditions
log_step "Wait for Leaf1 admin endpoint"
_wait_for_http "${LEAF1_BASE}/poc/ping" 120 2

log_step "Verify outbox table exists"
require_outbox_table

_outbox_pending() {
  # Read pending count reliably and strip whitespace.
  local v
  v="$(psql_in_pg "select count(*) from sync_outbox_event where status='PENDING';" | tr -d '[:space:]')"
  echo "${v:-0}"
}

log_step "Read outbox PENDING before"
before="$(_outbox_pending)"
log_info "Outbox PENDING before: ${before}"

stamp="$(date +%s)"
order_id="crash-${stamp}"

log_step "Create order on Leaf1 (creates outbox row)"
_http_discard POST "${LEAF1_BASE}/api/orders" \
  -H "Content-Type: application/json" \
  -d "{\"orderId\":\"${order_id}\",\"amount\":1.00}"

log_step "Stop sync-leaf1 immediately to simulate crash before dispatcher publishes"
_dc stop sync-leaf1

log_step "Wait briefly for the outbox row to appear (bounded)"
pending=""
for _ in $(seq 1 10); do
  pending="$(_outbox_pending)"
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

log_info "Outbox PENDING after crash: ${pending} (expected > ${before})"

# Enforce increase
python3 - <<PY
b=int("${before}")
p=int("${pending}")
if p <= b:
    print(f"FAIL: expected outbox pending to increase after crash; before={b} after_crash={p}")
    raise SystemExit(1)
print("OK: pending increased after crash.")
PY

log_step "Restart sync-leaf1 (dispatcher should replay outbox)"
_dc start sync-leaf1
_wait_for_http "${LEAF1_BASE}/poc/ping" 120 2

log_step "Leaf1 ping after restart (evidence)"
_http_json GET "${LEAF1_BASE}/poc/ping" | python3 -m json.tool

log_step "Wait for outbox to drain (PENDING -> 0)"
for _ in $(seq 1 120); do
  pending="$(_outbox_pending)"
  if [[ "$pending" == "0" ]]; then
    log_ok "Outbox drained (pending=0)"
    echo "PASS: app crash outbox replay validated (pending -> 0 after restart)."
    exit 0
  fi
  sleep 2
done

log_fail "Outbox did not drain in time. Last pending=${pending}"
exit 1
