#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "TEST (ROBUST): APP CRASH -> OUTBOX REPLAY (STREAM LASTSEQ)"
phase3_context

cat >&2 <<'EOF2'
TEST: App crash -> outbox replay on restart.

EXPECTED OUTPUT / PASS CRITERIA
- Create an order on Leaf1 (HTTP 2xx).
- Stop sync-leaf1 quickly to simulate crash before dispatcher runs.
- Restart sync-leaf1.
- UP_LEAF_STREAM lastSeq increases by >= 1 (observed via nats-box -> nats-central).
EOF2

LEAF1_ADMIN="${LEAF1_BASE}"
LEAF1_API="${LEAF1_BASE}/api/orders"
STREAM="UP_LEAF_STREAM"

NATS_BOX_CONTAINER="${PROJECT_NAME}-nats-box-1"
NATS_SERVER="nats://${SYNC_NATS_USERNAME}:${SYNC_NATS_PASSWORD}@nats-central:4222"

cleanup() {
  _dc start sync-leaf1 2>&1 || true
}
trap cleanup EXIT

_js() {
  docker exec -i "${NATS_BOX_CONTAINER}" nats --server "${NATS_SERVER}" "$@"
}

_js_stream_last_seq() {
  local out val
  out="$(_js stream info "${STREAM}" --json 2>&1 || true)"
  [[ -z "$out" ]] && out="$(_js stream info "${STREAM}" 2>&1 || true)"

  val="$(printf "%s" "$out" | python3 - <<'PY'
import sys, json, re
raw=sys.stdin.read().strip()
if not raw:
    print(""); raise SystemExit(0)
raw=re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", raw).strip()
# try direct JSON first
try:
    if raw.startswith("{"):
        d=json.loads(raw)
    else:
        m=re.search(r"(\{.*\})", raw, re.S)
        d=json.loads(m.group(1)) if m else None
except Exception:
    d=None
if isinstance(d, dict) and isinstance(d.get("state"), dict) and "last_seq" in d["state"]:
    print(d["state"]["last_seq"])
else:
    print("")
PY
)"

  if [[ -z "$val" ]]; then
    log_warn "Unable to parse ${STREAM} lastSeq; raw output (first 60 lines) follows"
    echo "$out" | head -n 60 >&2
  fi
  printf "%s" "$val"
}

log_step "Ensure Leaf1 is reachable"
_wait_for_http "${LEAF1_ADMIN}/poc/ping" 120 2

before_last="$(_js_stream_last_seq)"
if [[ -z "$before_last" ]]; then
  log_fail "Unable to read ${STREAM} lastSeq from JetStream (nats-box -> nats-central)"
  exit 1
fi
log_info "Baseline: ${STREAM} lastSeq=${before_last}"

RUN_ID="$(date +%s)"
ORDER_ID="p3-outbox-crash-${RUN_ID}"

log_step "Create an order (writes outbox row; publish may be delayed)"
_http_discard POST "${LEAF1_API}" -H "Content-Type: application/json" \
  -d "{\"orderId\":\"${ORDER_ID}\",\"amount\":9.99}"

log_step "Stop sync-leaf1 before dispatcher publishes (simulate crash)"
_dc stop sync-leaf1
sleep 2

log_step "Restart sync-leaf1 (dispatcher should replay outbox)"
_dc start sync-leaf1
_wait_for_http "${LEAF1_ADMIN}/poc/ping" 60 2

log_step "Wait for ${STREAM} lastSeq to increase (>= baseline+1)"
target=$((before_last + 1))
for _ in $(seq 1 90); do
  now_last="$(_js_stream_last_seq || true)"
  if [[ -n "$now_last" ]] && [[ "$now_last" -ge "$target" ]]; then
    log_ok "Outbox replay observed (baseline=${before_last} now=${now_last})"
    echo "PASS: outbox replay published at least 1 message after restart."
    exit 0
  fi
  sleep 2
done

log_fail "${STREAM} lastSeq did not increase; baseline=${before_last} lastSeq=${now_last:-<unknown>}"
exit 1
