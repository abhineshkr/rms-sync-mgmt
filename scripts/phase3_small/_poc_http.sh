#!/usr/bin/env bash
set -euo pipefail

# HTTP helpers for the PoC admin endpoints.
# Requires phase3/_common.sh (for _http_json) and _common_small.sh for base URLs.

poc_ping() {
  local base="$1"
  _http_json GET "${base}/poc/ping" >/dev/null
}

poc_publish() {
  local base="$1"
  local subject="$2"
  local payload="${3:-{}}"
  local msgid="${4:-}"

  if [[ -n "${msgid}" ]]; then
    _http_json POST "${base}/poc/publish" \
      -H 'Content-Type: application/json' \
      -d "{\"subject\":\"${subject}\",\"payload\":\"${payload}\",\"messageId\":\"${msgid}\"}"
  else
    _http_json POST "${base}/poc/publish" \
      -H 'Content-Type: application/json' \
      -d "{\"subject\":\"${subject}\",\"payload\":\"${payload}\"}"
  fi
}

poc_consumer_ensure() {
  local base="$1"
  local stream="$2"
  local durable="$3"
  local filter="$4"

  _http_json POST "${base}/poc/consumer/ensure" \
    -H 'Content-Type: application/json' \
    -d "{\"stream\":\"${stream}\",\"durable\":\"${durable}\",\"filterSubject\":\"${filter}\"}" >/dev/null
}

poc_consumer_info() {
  local base="$1"
  local stream="$2"
  local durable="$3"
  _http_json GET "${base}/poc/consumer/${stream}/${durable}"
}

poc_consumer_pull() {
  local base="$1"
  local stream="$2"
  local durable="$3"
  local filter="$4"
  local batch="${5:-1}"
  local timeout_ms="${6:-5000}"

  # Spring/Java Duration.parse does NOT accept fractional milliseconds like "PT5000MS".
  # Convert ms -> ceil seconds and send an ISO-8601 Duration that Java understands.
  local timeout_s=$(( (timeout_ms + 999) / 1000 ))
  if (( timeout_s < 1 )); then timeout_s=1; fi

  _http_json POST "${base}/poc/consumer/pull" \
    -H 'Content-Type: application/json' \
    -d "{\"stream\":\"${stream}\",\"durable\":\"${durable}\",\"filterSubject\":\"${filter}\",\"batchSize\":${batch},\"timeout\":\"PT${timeout_s}S\"}"
}
