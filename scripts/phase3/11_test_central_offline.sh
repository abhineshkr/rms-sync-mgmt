#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "TEST (ROBUST): CENTRAL OFFLINE -> UPSTREAM BACKFILL + DRAIN (ADJACENCY)"
phase3_context

cat >&2 <<'EOF2'
EXPECTED OUTPUT / PASS CRITERIA
- Stop central (nats-central + sync-central).
- Publish N orders on Leaf1 (HTTP 2xx).
- Restart central.
- UP_ZONE_STREAM lastSeq increases by >= N (zone relay backfills into Central once it returns).
- Central durable consumer on UP_ZONE_STREAM drains to 0.

EVIDENCE TO CAPTURE
- Baseline UP_ZONE_STREAM lastSeq (before central stop)
- lastSeq after restart
- Central consumer pending drain
EOF2

STREAM_UP_ZONE="UP_ZONE_STREAM"
CENTRAL_DURABLE="central_central_none_central01"

LEAF1_API="${LEAF1_BASE}/api/orders"

NATS_BOX_CONTAINER="${PROJECT_NAME}-nats-box-1"
NATS_SERVER="nats://${SYNC_NATS_USERNAME}:${SYNC_NATS_PASSWORD}@nats-central:4222"

PUBLISH_COUNT="${1:-20}"

cleanup() {
  # Never leave central down.
  _dc start nats-central  2>&1 || true
  _dc start sync-central  2>&1 || true
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
    if m:
        d = try_json(m.group(1))

if isinstance(d, dict):
    state = d.get("state", d)
    if mode == "stream_lastseq":
        if isinstance(state, dict) and "last_seq" in state:
            print(state["last_seq"]); raise SystemExit(0)
        for k in ("lastSeq","last_sequence","lastSequence"):
            if isinstance(state, dict) and k in state:
                print(state[k]); raise SystemExit(0)
        print(""); raise SystemExit(0)
    if mode == "consumer_pending":
        if isinstance(state, dict) and "num_pending" in state:
            print(state["num_pending"]); raise SystemExit(0)
        for k in ("numPending","pending"):
            if isinstance(state, dict) and k in state:
                print(state[k]); raise SystemExit(0)
        print(""); raise SystemExit(0)

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
    echo "DEBUG: unable to parse lastSeq. Raw output follows:" >&2
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
    echo "DEBUG: unable to parse consumer pending. Raw output follows:" >&2
    echo "$out" | head -n 80 >&2
  fi
  printf "%s" "$val"
}

log_step "Ensure central durable consumer exists (idempotent)"
_http_discard POST "${CENTRAL_BASE}/poc/consumer/ensure" \
  -H "Content-Type: application/json" \
  -d "{\"stream\":\"${STREAM_UP_ZONE}\",\"durable\":\"${CENTRAL_DURABLE}\",\"filterSubject\":\"up.zone.>\"}"

baseline_last="$(_js_stream_last_seq "$STREAM_UP_ZONE")"
if [[ -z "$baseline_last" ]]; then
  echo "FAIL: unable to read ${STREAM_UP_ZONE} lastSeq from JetStream (nats-box -> nats-central)" >&2
  exit 1
fi
echo "Baseline: ${STREAM_UP_ZONE} lastSeq=${baseline_last}"

log_step "Stop central node (nats-central + sync-central)"
_dc stop sync-central
_dc stop nats-central

RUN_ID="$(date +%s)"
log_step "Publish ${PUBLISH_COUNT} orders on Leaf1 while central is offline"
for i in $(seq 1 "$PUBLISH_COUNT"); do
  _http_discard POST "$LEAF1_API" -H "Content-Type: application/json" \
    -d "{\"orderId\":\"p3-central-offline-${RUN_ID}-${i}\",\"amount\":2.34}"
done
log_ok "Published ${PUBLISH_COUNT} orders (runId=${RUN_ID})"

log_step "Start central node (nats-central + sync-central)"
_dc start nats-central
_dc start sync-central

log_step "Wait for central admin endpoint"
_wait_for_http "${CENTRAL_BASE}/poc/ping" 180 2

target_last=$((baseline_last + PUBLISH_COUNT))
echo "Waiting for ${STREAM_UP_ZONE} lastSeq >= ${target_last} (baseline ${baseline_last} + N ${PUBLISH_COUNT}) ..."

for i in $(seq 1 90); do
  now_last="$(_js_stream_last_seq "$STREAM_UP_ZONE" || true)"
  if [[ -n "${now_last}" ]] && [[ "${now_last}" -ge "${target_last}" ]]; then
    echo "Backfill observed: ${STREAM_UP_ZONE} lastSeq=${now_last} (target=${target_last})"
    break
  fi
  sleep 2
  if [[ "$i" == "90" ]]; then
    echo "FAIL: ${STREAM_UP_ZONE} lastSeq did not reach target (${target_last}); lastSeq=${now_last:-<unknown>}" >&2
    exit 1
  fi
done

log_step "Wait for central durable consumer to drain (numPending -> 0)"
for i in $(seq 1 120); do
  pending="$(_js_consumer_pending "$STREAM_UP_ZONE" "$CENTRAL_DURABLE" || true)"
  if [[ "${pending}" == "0" ]]; then
    echo "PASS: central backfill completed (numPending=0)"
    exit 0
  fi
  sleep 2
done

echo "FAIL: central consumer did not drain; numPending=${pending:-<unavailable>}" >&2
exit 1
