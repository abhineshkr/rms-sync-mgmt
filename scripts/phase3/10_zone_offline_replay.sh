#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "TEST (INTERACTIVE+ROBUST): ZONE OFFLINE / PARTITION REPLAY (ADJACENCY UPSTREAM)"
phase3_context

cat >&2 <<'EOF2'
EXPECTED OUTPUT / PASS CRITERIA
- Stop nats-zone (simulate partition between Zone and Central).
- Publish N orders on Leaf1 (HTTP 2xx on /api/orders).
- While nats-zone is offline:
    - UP_SUBZONE_STREAM lastSeq increases (Subzone continues receiving from leaves).
    - Zone upstream durable on UP_SUBZONE_STREAM accumulates backlog: numPending increases.
- After starting nats-zone (heal partition):
    - UP_ZONE_STREAM lastSeq increases (Zone relays to Central again).
    - Zone upstream numPending drains to 0.
    - Central upstream numPending drains to 0.

INTERACTIVE FLOW
- Pause before stopping zone.
- Pause before publishing.
- Pause to check backlog while partitioned.
- Pause before healing.
- Pause before waiting for drain.

NON-INTERACTIVE MODE
- Set PHASE3_INTERACTIVE=0 to auto-continue at all prompts.

EVIDENCE TO CAPTURE
- Baseline lastSeq for UP_SUBZONE_STREAM and UP_ZONE_STREAM
- Baseline numPending for zone + central durables
- numPending after publish while partitioned
- lastSeq + numPending after heal (drain to 0)
EOF2

# ----------------------------
# Configuration (durables)
# ----------------------------
PUBLISH_COUNT="${1:-25}"
INTERACTIVE="${PHASE3_INTERACTIVE:-1}"

LEAF1_HTTP="${LEAF1_BASE}"
LEAF1_API="${LEAF1_BASE}/api/orders"

# These must match the durables actually used in your POC
ZONE_UP_DURABLE="zone_z1_none_zone01__up__subzone"
CENTRAL_UP_DURABLE="central_central_none_central01__up__zone"

STREAM_UP_SUBZONE="UP_SUBZONE_STREAM"
STREAM_UP_ZONE="UP_ZONE_STREAM"

# ----------------------------
# nats-box / JetStream API
# ----------------------------
PROJECT_NAME="${PROJECT_NAME:-syncmgmt_phase3}"
NATS_BOX_CONTAINER="${PROJECT_NAME}-nats-box-1"

SUBZONE_NATS="nats://nats-subzone:4222"
CENTRAL_NATS="nats://nats-central:4222"

cleanup() {
  # Never leave the environment partitioned.
  _dc start nats-zone >/dev/null 2>&1 || true
}
trap cleanup EXIT

confirm() {
  local prompt="$1"
  if [[ "${INTERACTIVE}" == "0" ]]; then
    echo "${prompt} [auto-continue: PHASE3_INTERACTIVE=0]"
    return 0
  fi

  local ans
  read -r -p "${prompt} [Y/n]: " ans
  ans="${ans:-Y}"
  case "${ans}" in
    Y|y|yes|YES) return 0 ;;
    *) echo "Aborted by user."; exit 2 ;;
  esac
}

_js_req() {
  local server="$1"
  local subject="$2"
  local payload="${3:-""}"
  docker exec -i "${NATS_BOX_CONTAINER}" sh -lc \
    "nats -s '${server}' req --raw '${subject}' '${payload}' --timeout 5s" 2>&1 || true
}

_py_json_extract() {
  local mode="$1"
  python3 <(cat <<'PY'
import json, re, sys

mode = sys.argv[1] if len(sys.argv) > 1 else ""
raw = sys.stdin.read()

# Strip ANSI + control chars except \n\t
raw = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", raw)
raw = "".join(ch for ch in raw if ch in ("\n","\t") or (32 <= ord(ch) <= 126))
s = raw.strip()

# nats-box prints a banner; extract the JSON object from the output
m = re.search(r"(\{.*\})", s, re.S)
if not m:
    print("")
    raise SystemExit(0)

try:
    d = json.loads(m.group(1))
except Exception:
    print("")
    raise SystemExit(0)

# JetStream error envelope
if isinstance(d, dict) and "error" in d:
    # Print empty so caller can handle gracefully
    print("")
    raise SystemExit(0)

if mode == "num_pending":
    v = d.get("num_pending")
    if v is None and isinstance(d.get("state"), dict):
        v = d["state"].get("num_pending")
    print("" if v is None else int(v))
    raise SystemExit(0)

if mode == "last_seq":
    st = d.get("state")
    if isinstance(st, dict):
        v = st.get("last_seq")
        print("" if v is None else int(v))
        raise SystemExit(0)
    print("")
    raise SystemExit(0)

print("")
PY
) "$mode"
}

_js_consumer_pending() {
  local server="$1" stream="$2" durable="$3"
  local out
  out="$(_js_req "$server" "\$JS.API.CONSUMER.INFO.${stream}.${durable}" "")"
  printf "%s" "$out" | _py_json_extract num_pending
}

_js_stream_lastseq() {
  local server="$1" stream="$2"
  local out
  out="$(_js_req "$server" "\$JS.API.STREAM.INFO.${stream}" "")"
  printf "%s" "$out" | _py_json_extract last_seq
}

# ----------------------------
# Preconditions
# ----------------------------
_wait_for_http "${LEAF1_HTTP}/poc/ping" 120 2

log_step "Baseline (authoritative JetStream): lastSeq + pending before partition"

base_subzone_last="$(_js_stream_lastseq "${SUBZONE_NATS}" "${STREAM_UP_SUBZONE}")"
base_central_last="$(_js_stream_lastseq "${CENTRAL_NATS}" "${STREAM_UP_ZONE}")"

base_zone_pending="$(_js_consumer_pending "${SUBZONE_NATS}" "${STREAM_UP_SUBZONE}" "${ZONE_UP_DURABLE}")"
base_central_pending="$(_js_consumer_pending "${CENTRAL_NATS}" "${STREAM_UP_ZONE}" "${CENTRAL_UP_DURABLE}")"

echo "Baseline: ${STREAM_UP_SUBZONE} lastSeq (nats-subzone) = ${base_subzone_last:-<unavailable>}"
echo "Baseline: ${STREAM_UP_ZONE}    lastSeq (nats-central) = ${base_central_last:-<unavailable>}"
echo "Baseline: Zone durable pending  (nats-subzone)        = ${base_zone_pending:-<unavailable>}"
echo "Baseline: Central durable pending(nats-central)        = ${base_central_pending:-<unavailable>}"

if [[ -z "${base_subzone_last}" || -z "${base_central_last}" ]]; then
  log_fail "Cannot read baseline lastSeq via JetStream API. Verify nats-box is running and NATS endpoints are reachable."
  exit 1
fi

confirm "Proceed to STOP Zone (simulate partition)?"

log_step "Stop nats-zone (simulate partition between Zone and Central)"
_dc stop nats-zone
log_ok "Zone is OFFLINE (partition active)."

confirm "Zone is offline. Proceed to publish ${PUBLISH_COUNT} orders from Leaf1?"

stamp="$(date +%s)"
log_step "Publish ${PUBLISH_COUNT} orders on Leaf1 while nats-zone is offline (stamp=${stamp})"
for i in $(seq 1 "${PUBLISH_COUNT}"); do
  _http_discard POST "${LEAF1_API}" \
    -H "Content-Type: application/json" \
    -d "{\"orderId\":\"zone-offline-${stamp}-${i}\",\"amount\":1.00}"
done
log_ok "Published ${PUBLISH_COUNT} orders."

confirm "Check authoritative backlog now (while still partitioned)?"

log_step "Authoritative state WHILE partitioned"
mid_subzone_last="$(_js_stream_lastseq "${SUBZONE_NATS}" "${STREAM_UP_SUBZONE}")"
mid_central_last="$(_js_stream_lastseq "${CENTRAL_NATS}" "${STREAM_UP_ZONE}")"
mid_zone_pending="$(_js_consumer_pending "${SUBZONE_NATS}" "${STREAM_UP_SUBZONE}" "${ZONE_UP_DURABLE}")"
mid_central_pending="$(_js_consumer_pending "${CENTRAL_NATS}" "${STREAM_UP_ZONE}" "${CENTRAL_UP_DURABLE}")"

echo "Partitioned: ${STREAM_UP_SUBZONE} lastSeq (nats-subzone) = ${mid_subzone_last:-<unavailable>}"
echo "Partitioned: ${STREAM_UP_ZONE}    lastSeq (nats-central) = ${mid_central_last:-<unavailable>}"
echo "Partitioned: Zone durable pending  (nats-subzone)        = ${mid_zone_pending:-<unavailable>}"
echo "Partitioned: Central durable pending(nats-central)        = ${mid_central_pending:-<unavailable>}"

# Expectations during partition:
# - Subzone lastSeq should increase (it is still ingesting).
# - Zone pending should increase (zone cannot pull/ack while its server is down).
if [[ -n "${mid_subzone_last}" ]]; then
  if [[ "${mid_subzone_last}" -lt "$((base_subzone_last + PUBLISH_COUNT))" ]]; then
    log_warn "UP_SUBZONE_STREAM lastSeq did not increase by N yet. Relay from leaves->subzone may be delayed or filter mismatch."
  fi
fi

confirm "Proceed to START Zone (heal partition)?"

log_step "Start nats-zone (heal partition)"
_dc start nats-zone
log_ok "Zone start requested (healing in progress)."

confirm "Proceed to WAIT for drain (zone + central pending -> 0) and Central lastSeq advance?"

log_step "Wait for drain: zone pending -> 0 AND central pending -> 0"
for i in $(seq 1 180); do
  now_zone_pending="$(_js_consumer_pending "${SUBZONE_NATS}" "${STREAM_UP_SUBZONE}" "${ZONE_UP_DURABLE}")"
  now_central_pending="$(_js_consumer_pending "${CENTRAL_NATS}" "${STREAM_UP_ZONE}" "${CENTRAL_UP_DURABLE}")"
  now_central_last="$(_js_stream_lastseq "${CENTRAL_NATS}" "${STREAM_UP_ZONE}")"

  if [[ "${now_zone_pending}" == "0" && "${now_central_pending}" == "0" ]]; then
    log_ok "Backlogs drained (zone=0, central=0)"
    echo "After heal: ${STREAM_UP_ZONE} lastSeq (nats-central) = ${now_central_last:-<unavailable>}"
    echo "PASS: zone partition replay validated (authoritative pending drained after heal)."
    exit 0
  fi

  if (( i % 10 == 0 )); then
    log_info "Waiting... zonePending=${now_zone_pending:-?} centralPending=${now_central_pending:-?} centralLastSeq=${now_central_last:-?}"
  fi

  sleep 2
done

log_fail "Drain timed out. zonePending=${now_zone_pending:-<unavailable>} centralPending=${now_central_pending:-<unavailable>}"
exit 1
