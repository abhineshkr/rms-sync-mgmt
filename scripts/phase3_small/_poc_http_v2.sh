#!/usr/bin/env bash
set -euo pipefail

# v2: fixes Java Duration format for /poc/consumer/pull
#
# IMPORTANT (manual curl): the PoC endpoint expects timeout as an ISO-8601 Java Duration,
# e.g. "PT5S" (5 seconds), "PT30S", "PT1M". A plain "5s" will return HTTP 400.
#
# Original scripts used: "PT${timeout_ms}MS" (not accepted by Duration.parse)
# New scripts use:      "PT${timeout_s}S"  (accepted)

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

  # Ceil(ms/1000) -> seconds (Duration.parse-friendly)
  local timeout_s=$(( (timeout_ms + 999) / 1000 ))
  if (( timeout_s < 1 )); then timeout_s=1; fi

  _http_json POST "${base}/poc/consumer/pull" \
    -H 'Content-Type: application/json' \
    -d "{\"stream\":\"${stream}\",\"durable\":\"${durable}\",\"filterSubject\":\"${filter}\",\"batchSize\":${batch},\"timeout\":\"PT${timeout_s}S\"}"
}
