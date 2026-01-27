#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_common_small.sh"
source "$(cd "$(dirname "$0")" && pwd)/_poc_http.sh"

phase3_prereqs

log_title "SMALL Phase3 – OFFLINE/ONLINE: Zone relay offline replay (leaf backlog drains)"

DURABLE="tplan3_replay_up_zone_snc"
FILTER="up.zone.snc.>"
BATCH="${1:-5}"

log_step "Ensuring test consumer on ${STREAM_UP_ZONE} (${FILTER})"
poc_consumer_ensure "${CENTRAL_HTTP}" "${STREAM_UP_ZONE}" "${DURABLE}" "${FILTER}"

log_step "Stopping Zone relay app (${SVC_APP_ZONE_SNC})"
_dc stop "${SVC_APP_ZONE_SNC}"

log_step "Publishing ${BATCH} new orders at leaf (while zone relay is offline)"
for i in $(seq 1 "${BATCH}"); do
  ORDER_ID="tplan3-replay-$(date +%s)-${i}"
  _http_json POST "${LEAF_DESK1_HTTP}/api/orders" \
    -H 'Content-Type: application/json' \
    -d "{\"orderId\":\"${ORDER_ID}\",\"amount\":1.0}" >/dev/null
  sleep 0.2
done

sleep 2

log_step "Starting Zone relay app (${SVC_APP_ZONE_SNC})"
_dc start "${SVC_APP_ZONE_SNC}"
wait_http_or_fail "${ZONE_SNC_HTTP}/poc/ping" 120

log_step "Pulling up to ${BATCH} messages from ${STREAM_UP_ZONE}/${DURABLE}"
out="$(poc_consumer_pull "${CENTRAL_HTTP}" "${STREAM_UP_ZONE}" "${DURABLE}" "${FILTER}" "${BATCH}" 15000)"
acked="$(echo "${out}" | _json_get acked)"
assert_int_ge "acked" "${acked}" "${BATCH}"

log_ok "Zone replay passed (acked >= ${BATCH})"
