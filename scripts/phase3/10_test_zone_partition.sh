#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

# Test: Zone offline -> leaf events are produced during partition and replayed when zone returns.
#
# Robust validation:
# - Read LEAF_STREAM lastSeq directly from JetStream via nats-box (no app HTTP dependency).
# - Stop nats-zone (partition).
# - Publish N orders on leaf1.
# - Start nats-zone (heal).
# - Wait until lastSeq increased by >= N.
# - Wait until central durable consumer pending drains to 0.

CENTRAL_DURABLE="central_central_none_central01"
LEAF1_API="http://localhost:18081/api/orders"

NATS_BOX_CONTAINER="${PROJECT_NAME}-nats-box-1"
NATS_SERVER="nats://nats-central:4222"

cleanup() {
  # Never leave the environment partitioned.
  _dc start nats-zone >/dev/null 2>&1 || true
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

# Strip ANSI escape sequences + non-printing control chars (except \n, \t)
raw = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", raw)
raw = "".join(ch for ch in raw if ch in ("\n", "\t") or (32 <= ord(ch) <= 126))
s = raw.strip()

if not s:
    print("")
    raise SystemExit(0)

def try_json(block: str):
    try:
        return json.loads(block)
    except Exception:
        return None

# Try JSON either as whole output or embedded
d = try_json(s) if s.startswith("{") else None
if d is None:
    m = re.search(r"(\{.*\})", s, re.S)
    if m:
        d = try_json(m.group(1))

if d is not None:
    state = d.get("state", d)

    if mode == "stream_lastseq":
        if isinstance(state, dict) and "last_seq" in state:
            print(state["last_seq"]); raise SystemExit(0)
        for k in ("lastSeq", "lastSequence", "last_sequence"):
            if isinstance(state, dict) and k in state:
                print(state[k]); raise SystemExit(0)
        print(""); raise SystemExit(0)

    if mode == "consumer_pending":
        if isinstance(state, dict) and "num_pending" in state:
            print(state["num_pending"]); raise SystemExit(0)
        for k in ("numPending", "pending", "numPendingMessages"):
            if isinstance(state, dict) and k in state:
                print(state[k]); raise SystemExit(0)
        print(""); raise SystemExit(0)

# Text fallbacks
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
  local stream="$1"
  local out

  # Capture stdout+stderr so we never parse an empty string due to redirects.
  out="$(_js stream info "$stream" --json 2>&1 || true)"
  if [[ -z "$out" ]]; then
    out="$(_js stream info "$stream" 2>&1 || true)"
  fi

  local val
  val="$(printf "%s" "$out" | _py_extract stream_lastseq)"
  if [[ -z "$val" ]]; then
    echo "DEBUG: unable to parse lastSeq. Raw 'nats stream info ${stream}' output follows:" >&2
    echo "$out" | head -n 60 >&2
  fi
  printf "%s" "$val"
}

_js_consumer_pending() {
  local stream="$1"
  local durable="$2"
  local out

  out="$(_js consumer info "$stream" "$durable" --json 2>&1 || true)"
  if [[ -z "$out" ]]; then
    out="$(_js consumer info "$stream" "$durable" 2>&1 || true)"
  fi

  local val
  val="$(printf "%s" "$out" | _py_extract consumer_pending)"
  if [[ -z "$val" ]]; then
    echo "DEBUG: unable to parse consumer pending. Raw 'nats consumer info ${stream} ${durable}' output follows:" >&2
    echo "$out" | head -n 60 >&2
  fi
  printf "%s" "$val"
}

# Ensure zone is up at start (idempotent)
_dc start nats-zone >/dev/null 2>&1 || true

before_last="$(_js_stream_last_seq LEAF_STREAM)"
if [[ -z "${before_last}" ]]; then
  echo "FAIL: unable to read LEAF_STREAM lastSeq from JetStream (nats-box -> nats-central)" >&2
  exit 1
fi
echo "Baseline: LEAF_STREAM lastSeq=${before_last}"

echo "Stopping nats-zone (partition between central and leaves)..."
_dc stop nats-zone

RUN_ID="$(date +%s)"
N=25
for i in $(seq 1 "$N"); do
  _http POST "$LEAF1_API" -H "Content-Type: application/json" \
    -d "{\"orderId\":\"p3-zone-partition-${RUN_ID}-${i}\",\"amount\":1.23}" >/dev/null
done
echo "Published ${N} leaf events while zone is offline. runId=${RUN_ID}"

pending="$(_js_consumer_pending LEAF_STREAM "$CENTRAL_DURABLE" || true)"
echo "Central consumer pending during partition: ${pending:-<unavailable>}"

echo "Starting nats-zone (heal partition)..."
_dc start nats-zone

target_last=$((before_last + N))
echo "Waiting for LEAF_STREAM lastSeq >= ${target_last} (baseline ${before_last} + N ${N}) ..."

for i in $(seq 1 60); do
  now_last="$(_js_stream_last_seq LEAF_STREAM || true)"
  if [[ -n "${now_last}" ]] && [[ "${now_last}" -ge "${target_last}" ]]; then
    echo "Replay/backfill observed: LEAF_STREAM lastSeq=${now_last} (target=${target_last})"
    break
  fi
  sleep 2
  if [[ "$i" == "60" ]]; then
    echo "FAIL: LEAF_STREAM lastSeq did not reach target (${target_last}); lastSeq=${now_last:-<unknown>}" >&2
    exit 1
  fi
done

echo "Waiting for central durable consumer to drain (numPending -> 0) ..."
for i in $(seq 1 60); do
  pending="$(_js_consumer_pending LEAF_STREAM "$CENTRAL_DURABLE" || true)"
  if [[ "${pending}" == "0" ]]; then
    echo "PASS: backlog drained (numPending=0)"
    exit 0
  fi
  sleep 2
done

echo "FAIL: backlog not drained; numPending=${pending:-<unavailable>}" >&2
exit 1
