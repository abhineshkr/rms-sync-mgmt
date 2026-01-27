#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_common_small.sh"
source "$(cd "$(dirname "$0")" && pwd)/_poc_http.sh"

phase3_prereqs

log_title "SMALL Phase3 – SMOKE: UP end-to-end (leaf → subzone → zone → central)"

# Consumer on UP_ZONE_STREAM is safe (no PoC component consumes it by default)
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

log_step "Pulling 1 message from ${STREAM_UP_ZONE}/${DURABLE}"
out="$(poc_consumer_pull "${CENTRAL_HTTP}" "${STREAM_UP_ZONE}" "${DURABLE}" "${FILTER}" 1 8000)"
acked="$(echo "${out}" | _json_get acked)"
assert_int_ge "acked" "${acked}" 1

log_ok "UP end-to-end smoke passed"
