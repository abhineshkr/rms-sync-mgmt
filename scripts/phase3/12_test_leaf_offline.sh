#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

# Test: Leaf2 app offline -> central publishes CENTRAL_STREAM -> leaf2 replays on reconnect.
#
# Robust validation (no HTTP JSON parsing dependency):
# - Capture CENTRAL_STREAM baseline last_seq via nats-box -> nats-central
# - Stop sync-leaf2
# - Publish N central events via central app
# - Start sync-leaf2 and wait for its ping
# - Confirm CENTRAL_STREAM last_seq increased by >= N
# - Confirm consumer pending drains to 0 via nats consumer info

LEAF2_DURABLE="leaf_z1_sz1_leaf02"
CENTRAL_ADMIN="${CENTRAL_BASE}"                 # http://localhost:18080 from _common.sh
LEAF2_PING="http://localhost:18084/poc/ping"

NATS_BOX_CONTAINER="${PROJECT_NAME}-nats-box-1"
NATS_SERVER="nats://nats-central:4222"

cleanup() {
  _dc start sync-leaf2 >/dev/null 2>&1 || true
}
trap cleanup EXIT

_js() {
  docker exec -i "${NATS_BOX_CONTAINER}" nats --server "${NATS_SERVER}" "$@"
}

_py_extract() {
  local mode="$1"
  python3 <(cat <<'PY'
import json, re, sys
mode = sys.argv[1] if len(sys.argv) > 1 else ""
raw = sys.stdin.read()
raw = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", raw)
raw = "".join(ch for ch in raw if ch in ("\n","\t") or (32 <= ord(ch) <= 126))
s = raw.strip()
if not s:
    print(""); raise SystemExit(0)

def try_json(t):
    try: return json.loads(t)
    except Exception: return None

d = try_json(s) if s.startswith("{") else None
if d is None:
    m = re.search(r"(\{.*\})", s, re.S)
    if m: d = try_json(m.group(1))

if d is not None:
    state = d.get("state", d)
    if mode == "stream_lastseq":
        if isinstance(state, dict) and "last_seq" in state:
            print(state["last_seq"]); raise SystemExit(0)
        print(""); raise SystemExit(0)
    if mode == "consumer_pending":
        if isinstance(state, dict) and "num_pending" in state:
            print(state["num_pending"]); raise SystemExit(0)
        print(""); raise SystemExit(0)

# text fallbacks
if mode == "stream_lastseq":
    m = re.search(r"Last\s*Seq(?:uence)?\s*:\s*([0-9]+)", s, re.I)
    print(m.group(1) if m else "")
elif mode == "consumer_pending":
    m = re.search(r"Unprocessed\s+Messages\s*:\s*([0-9]+)", s, re.I) or re.search(r"Num\s+Pending\s*:\s*([0-9]+)", s, re.I)
    print(m.group(1) if m else "")
else:
    print("")
PY
) "$mode"
}

_js_stream_last_seq() {
  local out val
  out="$(_js stream info CENTRAL_STREAM --json 2>&1 || true)"
  [[ -z "$out" ]] && out="$(_js stream info CENTRAL_STREAM 2>&1 || true)"
  val="$(printf "%s" "$out" | _py_extract stream_lastseq)"
  if [[ -z "$val" ]]; then
    echo "DEBUG: unable to parse CENTRAL_STREAM last_seq. Raw output:" >&2
    echo "$out" | head -n 80 >&2
  fi
  printf "%s" "$val"
}

_js_consumer_pending() {
  local out val
  out="$(_js consumer info CENTRAL_STREAM "$LEAF2_DURABLE" --json 2>&1 || true)"
  [[ -z "$out" ]] && out="$(_js consumer info CENTRAL_STREAM "$LEAF2_DURABLE" 2>&1 || true)"
  val="$(printf "%s" "$out" | _py_extract consumer_pending)"
  if [[ -z "$val" ]]; then
    echo "DEBUG: unable to parse consumer pending. Raw output:" >&2
    echo "$out" | head -n 80 >&2
  fi
  printf "%s" "$val"
}

baseline="$(_js_stream_last_seq)"
if [[ -z "$baseline" ]]; then
  echo "FAIL: unable to read CENTRAL_STREAM lastSeq from JetStream (nats-box -> nats-central)" >&2
  exit 1
fi
echo "Baseline: CENTRAL_STREAM lastSeq=${baseline}"

echo "Stopping sync-leaf2 (simulate leaf offline)..."
_dc stop sync-leaf2

RUN_ID="$(date +%s)"
N=15
for i in $(seq 1 "$N"); do
  _http POST "$CENTRAL_ADMIN/poc/publish" -H "Content-Type: application/json" \
    -d "{\"subject\":\"central.central.none.central01.config.updated\",\"payload\":\"{\\\"seq\\\":$i}\",\"messageId\":\"p3-leaf-offline-${RUN_ID}-${i}\"}" >/dev/null
done
echo "Published ${N} central events while leaf2 app is down. runId=${RUN_ID}"

target=$((baseline + N))
echo "Waiting for CENTRAL_STREAM lastSeq >= ${target} ..."
for i in $(seq 1 30); do
  now="$(_js_stream_last_seq || true)"
  if [[ -n "$now" ]] && [[ "$now" -ge "$target" ]]; then
    echo "Publish observed: CENTRAL_STREAM lastSeq=${now} (target=${target})"
    break
  fi
  sleep 1
  if [[ "$i" == "30" ]]; then
    echo "FAIL: CENTRAL_STREAM lastSeq did not reach target; lastSeq=${now:-<unknown>}" >&2
    exit 1
  fi
done

echo "Starting sync-leaf2 (leaf reconnect)..."
_dc start sync-leaf2
_wait_for_http "$LEAF2_PING" 60 2

echo "Waiting for leaf2 consumer to drain (numPending -> 0) ..."
for i in $(seq 1 60); do
  pending="$(_js_consumer_pending || true)"
  if [[ "$pending" == "0" ]]; then
    echo "PASS: leaf replay completed (numPending=0)"
    exit 0
  fi
  sleep 2
done

echo "FAIL: leaf replay not completed; numPending=${pending:-<unavailable>}" >&2
exit 1
