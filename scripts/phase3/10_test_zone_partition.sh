#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "TEST (INTERACTIVE+ROBUST): ZONE PARTITION -> UPSTREAM REPLAY + DRAIN (ADJACENCY)"
phase3_context

cat >&2 <<'EOF2'
EXPECTED OUTPUT / PASS CRITERIA
- Stop nats-zone (simulate partition between Central and Zone).
- Publish N orders on Leaf1 (HTTP 2xx).
- Optional: check backlog state while partitioned.
- Heal partition by starting nats-zone.
- UP_LEAF_STREAM lastSeq (seen from nats-central once healed) increases by >= N.
- UP_ZONE_STREAM lastSeq increases by >= N (relay chain reaches Central).
- Central durable consumer on UP_ZONE_STREAM drains (numPending -> 0).

INTERACTIVE FLOW
- Script pauses before stopping zone.
- Script pauses after zone stopped, before publishing.
- Script pauses after publishing, before healing.
- Script pauses before waiting for drain verification.

NON-INTERACTIVE MODE
- Set PHASE3_INTERACTIVE=0 to auto-continue at all prompts.

WHY THIS VERSION FIXES YOUR ERROR
- It does NOT use `nats stream info --json` / `nats consumer info --json` because your nats CLI
  fails JSON schema validation due to `config.placement.cluster` being empty in the response.
- Instead, it uses raw JetStream API subjects ($JS.API.*) via `nats req --raw` and parses the JSON itself.

EVIDENCE TO CAPTURE
- Baseline lastSeq for UP_LEAF_STREAM and UP_ZONE_STREAM
- lastSeq after heal for both streams
- Central consumer pending before/after heal
EOF2

STREAM_UP_LEAF="UP_LEAF_STREAM"
STREAM_UP_ZONE="UP_ZONE_STREAM"
STREAM_UP_SUBZONE="UP_SUBZONE_STREAM"

# Use adjacency durable names/filters to avoid WorkQueue "filtered consumer not unique" conflicts.
CENTRAL_DURABLE="central_central_none_central01__up__zone"
CENTRAL_FILTER="up.zone.z1.>"

ZONE_UP_DURABLE="zone_z1_sz1_zone01__up__subzone"
ZONE_UP_FILTER="up.subzone.z1.sz1.>"

LEAF1_API="${LEAF1_BASE}/api/orders"
HTTP_BASE="${LEAF1_BASE}"

PROJECT_NAME="${PROJECT_NAME:-syncmgmt_phase3}"
NATS_BOX_CONTAINER="${PROJECT_NAME}-nats-box-1"
NATS_SERVER="nats://nats-central:4222"

PUBLISH_COUNT="${1:-25}"

# ---- interactive helpers ----
PHASE3_INTERACTIVE="${PHASE3_INTERACTIVE:-1}"

_confirm() {
  local prompt="$1"
  local default_no="${2:-1}" # 1 => default No, 0 => default Yes

  if [[ "${PHASE3_INTERACTIVE}" != "1" ]]; then
    log_info "NON-INTERACTIVE: ${prompt} -> auto-continue"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    log_warn "No TTY available for prompt: ${prompt} -> auto-continue"
    return 0
  fi

  local suffix
  if [[ "${default_no}" -eq 1 ]]; then suffix="[y/N]"; else suffix="[Y/n]"; fi

  while true; do
    read -r -p "${prompt} ${suffix}: " ans
    if [[ -z "${ans}" ]]; then
      [[ "${default_no}" -eq 1 ]] && return 1 || return 0
    fi
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) echo "Please answer y/yes or n/no." ;;
    esac
  done
}

cleanup() {
  # Never leave the environment partitioned.
  _dc start nats-zone >/dev/null 2>&1 || true
}
trap cleanup EXIT

_js() {
  docker exec -i "${NATS_BOX_CONTAINER}" nats --server "${NATS_SERVER}" "$@"
}

# Parse JSON out of `nats req` output, which includes the nats banner.
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

# Extract first JSON object found in output (works even with banners above).
m = re.search(r"(\{.*\})", s, re.S)
j = try_json(m.group(1)) if m else (try_json(s) if s.startswith("{") else None)

if not isinstance(j, dict):
    print("")
    raise SystemExit(0)

if mode == "stream_lastseq":
    st = j.get("state") if isinstance(j.get("state"), dict) else {}
    # Stream info response: state.last_seq is canonical
    v = st.get("last_seq")
    if v is None:
        # fallbacks
        for k in ("lastSeq", "last_sequence", "lastSequence"):
            if k in st:
                v = st[k]; break
    print("" if v is None else v)
    raise SystemExit(0)

if mode == "consumer_pending":
    # Consumer info response: num_pending is typically top-level; sometimes under state in custom wrappers.
    v = j.get("num_pending")
    if v is None and isinstance(j.get("state"), dict):
        v = j["state"].get("num_pending")
    if v is None:
        # fallbacks
        for k in ("numPending", "pending"):
            if k in j:
                v = j[k]; break
            if isinstance(j.get("state"), dict) and k in j["state"]:
                v = j["state"][k]; break
    print("" if v is None else v)
    raise SystemExit(0)

print("")
PY
) "$mode"
}

# --- IMPORTANT FIX: use raw JetStream API instead of `nats stream info --json` ---
_js_stream_last_seq() {
  local stream="$1" out val
  out="$(_js req "\$JS.API.STREAM.INFO.${stream}" "" --raw --timeout 5s 2>&1 || true)"
  val="$(printf "%s" "$out" | _py_extract stream_lastseq)"
  if [[ -z "$val" ]]; then
    echo "DEBUG: unable to parse lastSeq via JS API. Raw output follows:" >&2
    echo "$out" | head -n 120 >&2
  fi
  printf "%s" "$val"
}

_js_consumer_pending() {
  local stream="$1" durable="$2" out val
  out="$(_js req "\$JS.API.CONSUMER.INFO.${stream}.${durable}" "" --raw --timeout 5s 2>&1 || true)"
  val="$(printf "%s" "$out" | _py_extract consumer_pending)"
  if [[ -z "$val" ]]; then
    echo "DEBUG: unable to parse consumer pending via JS API. Raw output follows:" >&2
    echo "$out" | head -n 120 >&2
  fi
  printf "%s" "$val"
}

# Ensure zone is up at start (idempotent)
_dc start nats-zone >/dev/null 2>&1 || true

# Ensure key durables exist (idempotent)
_wait_for_http "${HTTP_BASE}/poc/ping" 120 2

_http_discard POST "${HTTP_BASE}/poc/consumer/ensure" \
  -H "Content-Type: application/json" \
  -d "{\"stream\":\"${STREAM_UP_SUBZONE}\",\"durable\":\"${ZONE_UP_DURABLE}\",\"filterSubject\":\"${ZONE_UP_FILTER}\"}"

_http_discard POST "${HTTP_BASE}/poc/consumer/ensure" \
  -H "Content-Type: application/json" \
  -d "{\"stream\":\"${STREAM_UP_ZONE}\",\"durable\":\"${CENTRAL_DURABLE}\",\"filterSubject\":\"${CENTRAL_FILTER}\"}"

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

if ! _confirm "Proceed to STOP Zone (simulate partition)?" 0; then
  log_warn "User aborted before partition. Exiting."
  exit 0
fi

echo "Stopping nats-zone (partition between central and zone/subzone/leaves)..."
_dc stop nats-zone
log_ok "Zone is OFFLINE (partition active)."

if ! _confirm "Zone is offline. Proceed to publish ${PUBLISH_COUNT} orders from Leaf1?" 0; then
  log_warn "User chose not to publish. Healing partition and exiting."
  _dc start nats-zone >/dev/null 2>&1 || true
  exit 0
fi

RUN_ID="$(date +%s)"
echo "Publishing ${PUBLISH_COUNT} orders while nats-zone is offline... runId=${RUN_ID}"
for i in $(seq 1 "${PUBLISH_COUNT}"); do
  _http_discard POST "${LEAF1_API}" -H "Content-Type: application/json" \
    -d "{\"orderId\":\"p3-zone-partition-${RUN_ID}-${i}\",\"amount\":1.23}"
done
log_ok "Publish completed: ${PUBLISH_COUNT} orders."

if _confirm "Do you want to check consumer pending now (while still partitioned)?" 0; then
  pending_mid="$(_js_consumer_pending "${STREAM_UP_ZONE}" "${CENTRAL_DURABLE}" || true)"
  echo "Central consumer pending while partitioned: ${pending_mid:-<unavailable>}"
fi

if ! _confirm "Proceed to START Zone (heal partition) so backlog syncs to Central?" 0; then
  log_warn "User chose not to heal. Healing anyway for safety cleanup; exiting."
  _dc start nats-zone >/dev/null 2>&1 || true
  exit 0
fi

echo "Starting nats-zone (heal partition)..."
_dc start nats-zone
log_ok "Zone start requested (healing in progress)."

if ! _confirm "Proceed to WAIT for lastSeq targets and drain (numPending -> 0)?" 0; then
  log_warn "User chose not to wait. Exiting (Zone remains online)."
  exit 0
fi

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
done

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
done

echo "Waiting for central durable consumer to drain (numPending -> 0) ..."
for i in $(seq 1 120); do
  pending="$(_js_consumer_pending "${STREAM_UP_ZONE}" "${CENTRAL_DURABLE}" || true)"
  if [[ "${pending}" == "0" ]]; then
    echo "PASS: backlog drained (numPending=0)"
    exit 0
  fi
  sleep 2
done

echo "FAIL: backlog not drained; numPending=${pending:-<unavailable>}" >&2
exit 1
