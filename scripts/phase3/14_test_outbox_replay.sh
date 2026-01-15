#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

# Test: App crash -> outbox replay on restart.
#
# Assertion: LEAF_STREAM last_seq increases by >= 1 after restarting sync-leaf1
# (validated via nats-box -> nats-central), which is robust under Interest retention.

LEAF1_ADMIN="http://localhost:18081"
LEAF1_API="http://localhost:18081/api/orders"
STREAM="LEAF_STREAM"

NATS_BOX_CONTAINER="${PROJECT_NAME}-nats-box-1"
NATS_SERVER="nats://nats-central:4222"

cleanup() {
  _dc start sync-leaf1 >/dev/null 2>&1 || true
}
trap cleanup EXIT

_js() {
  docker exec -i "${NATS_BOX_CONTAINER}" nats --server "${NATS_SERVER}" "$@"
}

_js_stream_last_seq() {
  local out val
  out="$(_js stream info "${STREAM}" --json 2>&1 || true)"
  [[ -z "$out" ]] && out="$(_js stream info "${STREAM}" 2>&1 || true)"

  val="$(printf "%s" "$out" | python3 -c '
import sys, json, re
raw = sys.stdin.read().strip()
if not raw:
    print(""); raise SystemExit(0)

# strip ANSI just in case
raw = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", raw).strip()

# try direct JSON first
d = None
try:
    if raw.startswith("{"):
        d = json.loads(raw)
except Exception:
    d = None

# else try to extract JSON block
if d is None:
    m = re.search(r"(\{.*\})", raw, re.S)
    if m:
        try: d = json.loads(m.group(1))
        except Exception: d = None

if isinstance(d, dict) and isinstance(d.get("state"), dict) and "last_seq" in d["state"]:
    print(d["state"]["last_seq"])
else:
    print("")
')"

  if [[ -z "$val" ]]; then
    echo "DEBUG: unable to parse ${STREAM} lastSeq. Raw output follows:" >&2
    echo "$out" >&2
  fi
  printf "%s" "$val"
}


before_last="$(_js_stream_last_seq)"
if [[ -z "$before_last" ]]; then
  echo "FAIL: unable to read ${STREAM} lastSeq from JetStream (nats-box -> nats-central)" >&2
  exit 1
fi
echo "Baseline: ${STREAM} lastSeq=${before_last}"

RUN_ID="$(date +%s)"
ORDER_ID="p3-outbox-crash-${RUN_ID}"

# Create an outbox event (intended to not publish immediately due to long poll interval)
_http POST "$LEAF1_API" -H "Content-Type: application/json" \
  -d "{\"orderId\":\"${ORDER_ID}\",\"amount\":9.99}" >/dev/null

echo "Stopping sync-leaf1 before dispatcher publishes..."
_dc stop sync-leaf1
sleep 2

echo "Restarting sync-leaf1 (dispatcher should replay outbox)..."
_dc start sync-leaf1
_wait_for_http "${LEAF1_ADMIN}/poc/ping" 60 2

echo "Waiting for ${STREAM} lastSeq to increase (>= baseline+1) ..."
target=$((before_last + 1))
for i in $(seq 1 90); do
  now_last="$(_js_stream_last_seq || true)"
  if [[ -n "$now_last" ]] && [[ "$now_last" -ge "$target" ]]; then
    echo "PASS: outbox replay published at least 1 message (baseline=${before_last} now=${now_last})"
    exit 0
  fi
  sleep 2
done

echo "FAIL: ${STREAM} lastSeq did not increase; baseline=${before_last} lastSeq=${now_last:-<unknown>}" >&2
exit 1
