#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_common_small.sh"
source "$(cd "$(dirname "$0")" && pwd)/_poc_http_v2.sh"

phase3_prereqs

log_title "SMALL Phase3 – SMOKE (v2): UP end-to-end (leaf → subzone → zone → central)"

log_step "Waiting for central JetStream to be ready"
wait_js_or_fail "${NATS_URL_CENTRAL}" 60

DURABLE="tplan3_central_up_zone_snc"
FILTER="up.zone.snc.>"

log_step "Ensuring test consumer on ${STREAM_UP_ZONE} (${FILTER})"
poc_consumer_ensure "${CENTRAL_HTTP}" "${STREAM_UP_ZONE}" "${DURABLE}" "${FILTER}"

ORDER_ID="tplan3-$(date +%s)"
PAYLOAD="{\"orderId\":\"${ORDER_ID}\",\"amount\":1.0}"

log_step "Creating one order on leaf desk1: ${ORDER_ID}"
_http_json POST "${LEAF_DESK1_HTTP}/api/orders" \
  -H 'Content-Type: application/json' \
  -d "${PAYLOAD}" >/dev/null

sleep 2

log_step "Pulling 1 message from ${STREAM_UP_ZONE}/${DURABLE} (timeout=8s)"
out="$(poc_consumer_pull "${CENTRAL_HTTP}" "${STREAM_UP_ZONE}" "${DURABLE}" "${FILTER}" 1 8000)"

if [[ -z "${out}" ]]; then
  log_fail "Consumer pull returned an empty response (often 204 on timeout). Verify the order reached ${STREAM_UP_ZONE} and/or increase the pull timeout."
fi

acked="$(echo "${out}" | _json_get acked)"

# Some older/newer POC responses may use a different field name, or may return
# an error envelope (e.g., {status,error,...}) where `acked` is absent.
if [[ -z "${acked}" ]]; then
  # Try a couple common alternates.
  acked="$(echo "${out}" | _json_get acknowledged)"
fi
if [[ -z "${acked}" ]]; then
  acked="$(echo "${out}" | _json_get ackCount)"
fi

if [[ -z "${acked}" ]]; then
  status="$(echo "${out}" | _json_get status)"
  err="$(echo "${out}" | _json_get error)"
  if [[ -n "${status}" || -n "${err}" ]]; then
    log_fail "consumer/pull did not return 'acked'. Looks like an error response: status='${status}' error='${err}'. Full body: ${out}"
  else
    log_fail "consumer/pull did not return 'acked'. Full body: ${out}"
  fi
fi

assert_int_ge "acked" "${acked}" 1

log_ok "UP end-to-end smoke (v2) passed"