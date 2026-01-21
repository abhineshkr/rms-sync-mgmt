#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "TEST (ROBUST): LEAF2 OFFLINE -> DOWNSTREAM REPLAY + DRAIN (ADJACENCY)"
phase3_context

cat >&2 <<'EOF2'
EXPECTED OUTPUT / PASS CRITERIA
- Stop sync-leaf2.
- Publish N DOWNSTREAM messages at Central (HTTP 2xx on /poc/publish).
- DOWN_SUBZONE_STREAM lastSeq increases by >= N (relay chain reaches leaves).
- Restart sync-leaf2.
- Leaf2 durable consumer on DOWN_SUBZONE_STREAM drains (numPending -> 0).
EOF2

STREAM_DOWN_SUBZONE="DOWN_SUBZONE_STREAM"
LEAF2_DURABLE="leaf_z1_sz1_leaf02"

CENTRAL_ADMIN="${CENTRAL_BASE}"
LEAF2_PING="http://localhost:18084/poc/ping"

NATS_BOX_CONTAINER="${PROJECT_NAME}-nats-box-1"
NATS_SERVER="nats://${SYNC_NATS_USERNAME}:${SYNC_NATS_PASSWORD}@nats-central:4222"

PUBLISH_COUNT="${1:-15}"

cleanup() {
  _dc start sync-leaf2 2>&1 || true
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

j = try_json(s) if s.startswith("{") else None
if j is None:
    m = re.search(r"(\{.*\})", s, re.S)
    if m: j = try_json(m.group(1))

if isinstance(j, dict):
    state = j.get("state", j)
    if mode == "stream_lastseq":
        if isinstance(state, dict) and "last_seq" in state:
            print(state["last_seq"]); raise SystemExit(0)
        for k in ("lastSeq","last_sequence"):
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
  local out val
  out="$(_js stream info "${STREAM_DOWN_SUBZONE}" --json 2>&1 || true)"
  [[ -z "$out" ]] && out="$(_js stream info "${STREAM_DOWN_SUBZONE}" 2>&1 || true)"
  val="$(printf "%s" "$out" | _py_extract stream_lastseq)"
  if [[ -z "$val" ]]; then
    echo "DEBUG: unable to parse ${STREAM_DOWN_SUBZONE} last_seq. Raw output:" >&2
    echo "$out" | head -n 80 >&2
  fi
  printf "%s" "$val"
}

_js_consumer_pending() {
  local out val
  out="$(_js consumer info "${STREAM_DOWN_SUBZONE}" "${LEAF2_DURABLE}" --json 2>&1 || true)"
  [[ -z "$out" ]] && out="$(_js consumer info "${STREAM_DOWN_SUBZONE}" "${LEAF2_DURABLE}" 2>&1 || true)"
  val="$(printf "%s" "$out" | _py_extract consumer_pending)"
  if [[ -z "$val" ]]; then
    echo "DEBUG: unable to parse consumer pending. Raw output:" >&2
    echo "$out" | head -n 80 >&2
  fi
  printf "%s" "$val"
}

baseline="$(_js_stream_last_seq)"
if [[ -z "$baseline" ]]; then
  echo "FAIL: unable to read ${STREAM_DOWN_SUBZONE} lastSeq from JetStream (nats-box -> nats-central)" >&2
  exit 1
fi
echo "Baseline: ${STREAM_DOWN_SUBZONE} lastSeq=${baseline}"

log_step "Stop sync-leaf2 (simulate leaf consumer offline)"
_dc stop sync-leaf2

RUN_ID="$(date +%s)"
log_step "Publish ${PUBLISH_COUNT} downstream messages at Central"
for i in $(seq 1 "${PUBLISH_COUNT}"); do
  _http_discard POST "${CENTRAL_ADMIN}/poc/publish" -H "Content-Type: application/json" \
    -d "{\"subject\":\"down.central.z1.sz1.all.config.updated\",\"payload\":\"{\\\"seq\\\":${i}}\",\"messageId\":\"p3-down-leaf2-offline-${RUN_ID}-${i}\"}"
done

# Wait until downstream relay chain reaches leaf-tier stream.
target=$((baseline + PUBLISH_COUNT))
echo "Waiting for ${STREAM_DOWN_SUBZONE} lastSeq >= ${target} ..."
for i in $(seq 1 60); do
  now="$(_js_stream_last_seq || true)"
  if [[ -n "$now" ]] && [[ "$now" -ge "$target" ]]; then
    echo "Downstream relay observed: ${STREAM_DOWN_SUBZONE} lastSeq=${now} (target=${target})"
    break
  fi
  sleep 2
  if [[ "$i" == "60" ]]; then
    echo "FAIL: ${STREAM_DOWN_SUBZONE} lastSeq did not reach target; lastSeq=${now:-<unknown>}" >&2
    exit 1
  fi
done

log_step "Start sync-leaf2 (reconnect)"
_dc start sync-leaf2
_wait_for_http "${LEAF2_PING}" 120 2

echo "Waiting for leaf2 durable to drain (numPending -> 0) ..."
for i in $(seq 1 90); do
  pending="$(_js_consumer_pending || true)"
  if [[ "$pending" == "0" ]]; then
    echo "PASS: leaf2 replay completed (numPending=0)"
    exit 0
  fi
  sleep 2
done

echo "FAIL: leaf2 replay not completed; numPending=${pending:-<unavailable>}" >&2
exit 1
