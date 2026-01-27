#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_common_small.sh"

phase3_prereqs

log_title "SMALL Phase3 – Ensure JetStream streams (idempotent) [v2]"

log_step "Waiting for central JetStream to be ready"
wait_js_or_fail "${NATS_URL_CENTRAL}" 60

# 168h = 604800s = 604800000000000ns
MAX_AGE_NS=604800000000000

# --- Low level JS API helpers (use inside nats-box) ---

js_req() {
  local subj="$1"
  local payload="${2:-}"
  # keep stdout clean; if nats fails, propagate error
  nats_box_nats --server "${NATS_URL_CENTRAL}" req --raw "${subj}" "${payload}"
}

js_info() {
  local stream="$1"
  # If not found, server returns JSON with err_code=10059
  js_req "\$JS.API.STREAM.INFO.${stream}" "" 2>/dev/null || true
}

json_has_err_code() {
  local out="$1"
  local code="$2"
  [[ -n "$out" ]] && echo "$out" | grep -q "\"err_code\"[[:space:]]*:[[:space:]]*${code}"
}

stream_missing() {
  local out="$1"
  [[ -z "$out" ]] && return 0
  json_has_err_code "$out" 10059 && return 0
  return 1
}

js_temporarily_unavailable() {
  local out="$1"
  [[ -z "$out" ]] && return 1
  json_has_err_code "$out" 10008 && return 0
  return 1
}

js_create_stream() {
  local stream="$1"
  local config_json="$2"   # IMPORTANT: StreamConfig at top-level
  js_req "\$JS.API.STREAM.CREATE.${stream}" "${config_json}"
}

# --- Ensure logic ---

ensure_stream() {
  local name="$1"
  local subjects_json="$2"   # JSON array, e.g. ["up.leaf.>"]
  local retention="$3"       # workqueue | interest

  log_step "Stream ensure: ${name}"

  local info
  info="$(js_info "${name}")"

  if stream_missing "${info}"; then
    log_info "Creating stream ${name}"

    # StreamConfig JSON (no wrapper "config":{})
    local cfg
    cfg=$(
      cat <<JSON
{"name":"${name}","subjects":${subjects_json},"retention":"${retention}","storage":"file","max_age":${MAX_AGE_NS},"num_replicas":1,"discard":"old"}
JSON
    )

    # retry create if JS is still starting
    local attempt=1
    local max_attempts=10
    while true; do
      local out
      out="$(js_create_stream "${name}" "${cfg}" 2>/dev/null || true)"

      if [[ -n "$out" ]] && ! json_has_err_code "$out" 10008; then
        # created or already exists etc. Validate quickly with info.
        local post
        post="$(js_info "${name}")"
        if stream_missing "${post}"; then
          echo "ERROR: stream ${name} still missing after create. Raw response: $out" >&2
          exit 1
        fi
        log_ok "Created stream ${name}"
        break
      fi

      if (( attempt >= max_attempts )); then
        echo "ERROR: JetStream not ready (10008) while creating ${name} after ${max_attempts} attempts" >&2
        echo "Last response: ${out}" >&2
        exit 1
      fi

      log_info "JetStream not ready yet (10008). Retry ${attempt}/${max_attempts}..."
      attempt=$((attempt + 1))
      sleep 1
    done
  else
    log_ok "Stream exists: ${name}"
  fi
}

# --- Streams ---

# Workqueue UP streams
ensure_stream "${STREAM_UP_LEAF}"      '["up.leaf.>"]'      workqueue
ensure_stream "${STREAM_UP_SUBZONE}"   '["up.subzone.>"]'   workqueue
ensure_stream "${STREAM_UP_ZONE}"      '["up.zone.>"]'      workqueue

# Interest DOWN streams
ensure_stream "${STREAM_DOWN_CENTRAL}" '["down.central.>"]' interest
ensure_stream "${STREAM_DOWN_ZONE}"    '["down.zone.>"]'    interest
ensure_stream "${STREAM_DOWN_SUBZONE}" '["down.subzone.>"]' interest

log_ok "JetStream streams are present [v2]"
