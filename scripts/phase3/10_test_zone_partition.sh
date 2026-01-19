#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "TEST (ROBUST): ZONE PARTITION -> UPSTREAM REPLAY + DRAIN (ADJACENCY)"
phase3_context

cat >&2 <<'EOF2'
EXPECTED OUTPUT / PASS CRITERIA
- Stop nats-zone (simulate partition between Central and Zone).
- Publish N orders on Leaf1 (HTTP 2xx).
- Heal partition by starting nats-zone.
- UP_LEAF_STREAM lastSeq (seen from nats-central once healed) increases by >= N.
- UP_ZONE_STREAM lastSeq increases by >= N (relay chain reaches Central).
- Central durable consumer on UP_ZONE_STREAM drains (numPending -> 0).

EVIDENCE TO CAPTURE
- Baseline lastSeq for UP_LEAF_STREAM and UP_ZONE_STREAM
- lastSeq after heal for both streams
- Central consumer pending before/after heal
EOF2

# This is a "robust" variant of 10_zone_offline_replay.sh that uses nats-box + nats CLI
# for authoritative stream/consumer state (instead of only the app HTTP JSON).

STREAM_UP_LEAF="UP_LEAF_STREAM"
STREAM_UP_ZONE="UP_ZONE_STREAM"
STREAM_UP_SUBZONE="UP_SUBZONE_STREAM"

CENTRAL_DURABLE="central_central_none_central01"
ZONE_UP_DURABLE="zone_z1_none_zone01__up__subzone"

LEAF1_API="${LEAF1_BASE}/api/orders"
HTTP_BASE="${LEAF1_BASE}"   # admin endpoints reachable on Leaf1 in this POC

NATS_BOX_CONTAINER="${PROJECT_NAME}-nats-box-1"
NATS_SERVER="nats://nats-central:4222"

PUBLISH_COUNT="${1:-25}"

cleanup() {
  # Never leave the environment partitioned.
  _dc start nats-zone 2>&1 || true
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
j = try_json(s) if s.startswith("{") else None
if j is None:
    m = re.search(r"(\{.*\})", s, re.S)
    if m:
        j = try_json(m.group(1))

if isinstance(j, dict):
    state = j.get("state", j)

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
        for k in ("numPending", "pending"):
            if isinstance(state, dict) and k in state:
                print(state[k]); raise SystemExit(0)
        # sometimes nested
        if isinstance(j.get("delivered"), dict) and "consumer_seq" in j["delivered"]:
            pass
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
  local stream="$1" out val
  out="$(_js stream info "$stream" --json 2>&1 || true)"
  [[ -z "$out" ]] && out="$(_js stream info "$stream" 2>&1 || true)"
  val="$(printf "%s" "$out" | _py_extract stream_lastseq)"
  if [[ -z "$val" ]]; then
    echo "DEBUG: unable to parse lastSeq. Raw 'nats stream info ${stream}' output follows:" >&2
    echo "$out" | head -n 80 >&2
  fi
  printf "%s" "$val"
}

_js_consumer_pending() {
  local stream="$1" durable="$2" out val
  out="$(_js consumer info "$stream" "$durable" --json 2>&1 || true)"
  [[ -z "$out" ]] && out="$(_js consumer info "$stream" "$durable" 2>&1 || true)"
  val="$(printf "%s" "$out" | _py_extract consumer_pending)"
  if [[ -z "$val" ]]; then
    echo "DEBUG: unable to parse consumer pending. Raw 'nats consumer info ${stream} ${durable}' output follows:" >&2
    echo "$out" | head -n 80 >&2
  fi
  printf "%s" "$val"
}

# Ensure partition target is up at start (idempotent)
_dc start nats-zone 2>&1 || true

# Ensure key durables exist (idempotent)
_wait_for_http "${HTTP_BASE}/poc/ping" 120 2
_http_discard POST "${HTTP_BASE}/poc/consumer/ensure" \
  -H "Content-Type: application/json" \
  -d "{\"stream\":\"${STREAM_UP_SUBZONE}\",\"durable\":\"${ZONE_UP_DURABLE}\",\"filterSubject\":\"up.subzone.z1.>\"}"
_http_discard POST "${HTTP_BASE}/poc/consumer/ensure" \
  -H "Content-Type: application/json" \
  -d "{\"stream\":\"${STREAM_UP_ZONE}\",\"durable\":\"${CENTRAL_DURABLE}\",\"filterSubject\":\"up.zone.>\"}"

before_leaf="$(_js_stream_last_seq "${STREAM_UP_LEAF}")"
before_zone="$(_js_stream_last_seq "${STREAM_UP_ZONE}")"

if [[ -z "${before_leaf}" || -z "${before_zone}" ]]; then
  echo "FAIL: unable to read baseline lastSeq from JetStream (nats-box -> nats-central)" >&2
  exit 1
fi

echo "Baseline: ${STREAM_UP_LEAF} lastSeq=${before_leaf}"
echo "Baseline: ${STREAM_UP_ZONE} lastSeq=${before_zone}"

pending_before="$(_js_consumer_pending "${STREAM_UP_ZONE}" "${CENTRAL_DURABLE}" || true)"
echo "Central consumer pending before partition: ${pending_before:-<unavailable>}"

echo "Stopping nats-zone (partition between central and zone/subzone/leaves)..."
_dc stop nats-zone

RUN_ID="$(date +%s)"
echo "Publishing ${PUBLISH_COUNT} orders while nats-zone is offline... runId=${RUN_ID}"
for i in $(seq 1 "${PUBLISH_COUNT}"); do
  _http_discard POST "${LEAF1_API}" -H "Content-Type: application/json" \
    -d "{\"orderId\":\"p3-zone-partition-${RUN_ID}-${i}\",\"amount\":1.23}"
done

echo "Starting nats-zone (heal partition)..."
_dc start nats-zone

# Targets: once healed, central can observe stream leader state again.
target_leaf=$((before_leaf + PUBLISH_COUNT))
target_zone=$((before_zone + PUBLISH_COUNT))

echo "Waiting for ${STREAM_UP_LEAF} lastSeq >= ${target_leaf} (baseline ${before_leaf} + N ${PUBLISH_COUNT}) ..."
for i in $(seq 1 90); do
  now_leaf="$(_js_stream_last_seq "${STREAM_UP_LEAF}" || true)"
  if [[ -n "${now_leaf}" ]] && [[ "${now_leaf}" -ge "${target_leaf}" ]]; then
    echo "Observed: ${STREAM_UP_LEAF} lastSeq=${now_leaf} (target=${target_leaf})"
    break
  fi
  sleep 2
  if [[ "$i" == "90" ]]; then
    echo "FAIL: ${STREAM_UP_LEAF} lastSeq did not reach target (${target_leaf}); lastSeq=${now_leaf:-<unknown>}" >&2
    exit 1
  fi
end

echo "Waiting for ${STREAM_UP_ZONE} lastSeq >= ${target_zone} (relay reaches Central) ..."
for i in $(seq 1 120); do
  now_zone="$(_js_stream_last_seq "${STREAM_UP_ZONE}" || true)"
  if [[ -n "${now_zone}" ]] && [[ "${now_zone}" -ge "${target_zone}" ]]; then
    echo "Observed: ${STREAM_UP_ZONE} lastSeq=${now_zone} (target=${target_zone})"
    break
  fi
  sleep 2
  if [[ "$i" == "120" ]]; then
    echo "FAIL: ${STREAM_UP_ZONE} lastSeq did not reach target (${target_zone}); lastSeq=${now_zone:-<unknown>}" >&2
    exit 1
  fi
end

echo "Waiting for central durable consumer to drain (numPending -> 0) ..."
for i in $(seq 1 120); do
  pending="$(_js_consumer_pending "${STREAM_UP_ZONE}" "${CENTRAL_DURABLE}" || true)"
  if [[ "${pending}" == "0" ]]; then
    echo "PASS: backlog drained (numPending=0)"
    exit 0
  fi
  sleep 2
end

echo "FAIL: backlog not drained; numPending=${pending:-<unavailable>}" >&2
exit 1
