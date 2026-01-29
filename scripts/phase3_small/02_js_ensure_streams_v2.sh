#!/usr/bin/env bash
set -euo pipefail

# Ensure Phase-3 PoC streams exist (idempotent).
#
# Usage:
#   scripts/phase3_small/02_js_ensure_streams_v2.sh [nats_url]
#
# If nats_url is omitted, defaults to $NATS_URL_CENTRAL from _common_small.sh.

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_DIR}/_common_small.sh"

phase3_prereqs

# nats-box is the CLI runner; ensure it's present/running.
_dc up -d "${SVC_NATS_BOX}" >/dev/null

SERVER="${1:-${NATS_URL_CENTRAL}}"
CENTRAL_ID="${SYNC_CENTRAL_ID:-nhq}"

log_step "Ensuring Phase-3 streams on ${SERVER} (centralId=${CENTRAL_ID})"

_js_req_raw() {
  # Usage: _js_req_raw <subject> [payload]
  local subj="$1"; shift
  local payload="${1:-}"
  nats_box_nats --server "$SERVER" req --raw "$subj" "$payload"
}

_json_get() {
  # Usage: echo '{...}' | _json_get key
  local key="$1"
  python3 - "$key" <<'PY'
import sys, json
key = sys.argv[1]
try:
    obj = json.load(sys.stdin)
    val = obj.get(key, None)
    print('' if val is None else val)
except Exception:
    print('')
PY
}

_is_stream_not_found() {
  # JS StreamNotFound == 10059
  local code
  code="$(echo "$1" | _json_get error_code)"
  [[ "$code" == "10059" ]]
}

_ensure_stream() {
  # Usage: _ensure_stream <stream_name> <subjects_json> <retention>
  local stream="$1" subjects_json="$2" retention="$3"

  local info
  info="$(_js_req_raw "\$JS.API.STREAM.INFO.${stream}" "" 2>/dev/null || true)"
  if [[ -n "$info" ]] && ! _is_stream_not_found "$info"; then
    log_info "Stream exists: ${stream}"
    return 0
  fi

  local payload
  payload=$(cat <<JSON
{
  "name": "${stream}",
  "subjects": ${subjects_json},
  "retention": "${retention}",
  "storage": "file",
  "replicas": 1,
  "max_msgs_per_subject": -1,
  "max_age": 0,
  "discard": "old",
  "deny_delete": false,
  "deny_purge": false
}
JSON
)

  _js_req_raw "\$JS.API.STREAM.CREATE.${stream}" "$payload" >/dev/null
  log_ok "Created stream: ${stream}"
}

# Upstream streams: WorkQueue (single durable per link)
_ensure_stream "$STREAM_UP_LEAF"     "[\"up.leaf.${CENTRAL_ID}.>\"]"     "workqueue"
_ensure_stream "$STREAM_UP_SUBZONE"  "[\"up.subzone.${CENTRAL_ID}.>\"]"  "workqueue"
_ensure_stream "$STREAM_UP_ZONE"     "[\"up.zone.${CENTRAL_ID}.>\"]"     "workqueue"

# Downstream streams: Interest (fan-out)
_ensure_stream "$STREAM_DOWN_CENTRAL" "[\"down.central.${CENTRAL_ID}.>\"]" "interest"
_ensure_stream "$STREAM_DOWN_ZONE"    "[\"down.zone.${CENTRAL_ID}.>\"]"    "interest"
_ensure_stream "$STREAM_DOWN_SUBZONE" "[\"down.subzone.${CENTRAL_ID}.>\"]" "interest"

log_ok "Streams ensured on ${SERVER}"
