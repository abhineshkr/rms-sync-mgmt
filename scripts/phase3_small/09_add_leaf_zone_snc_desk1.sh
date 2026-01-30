#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_common_small.sh"
source "$(cd "$(dirname "$0")" && pwd)/_poc_http.sh"

phase3_prereqs

log_title "SMALL Phase3 – Add Leaf to Zone SNC (desk1) + basic UP check"

log_step "Starting zone-attached leaf NATS: ${SVC_LEAF_ZONE_SNC_DESK1_NATS}"
_dc up -d "${SVC_LEAF_ZONE_SNC_DESK1_NATS}"

sleep 2

DURABLE="tplan3_zone_leaf_up_snc_none"
FILTER="up.leaf.snc.none.>"

log_step "Ensuring test consumer on ${STREAM_UP_LEAF} (${FILTER})"
poc_consumer_ensure "${CENTRAL_HTTP}" "${STREAM_UP_LEAF}" "${DURABLE}" "${FILTER}"

SUBJ="up.leaf.snc.none.desk1.order.order.created"
PAYLOAD="{\"orderId\":\"tplan3-zone-leaf-$(date +%s)\"}"

log_step "Publishing on zone-attached leaf NATS: ${SUBJ}"
nats_box_nats --server "${NATS_URL_LEAF_ZONE_SNC_DESK1}" pub "${SUBJ}" "${PAYLOAD}" >/dev/null

sleep 2

log_step "Pulling 1 message from ${STREAM_UP_LEAF}/${DURABLE}"
out="$(poc_consumer_pull "${CENTRAL_HTTP}" "${STREAM_UP_LEAF}" "${DURABLE}" "${FILTER}" 1 8000)"
acked="$(echo "${out}" | _json_get acked)"
assert_int_ge "acked" "${acked}" 1

log_ok "Zone-attached leaf basic UP check passed"

log_warn "End-to-end leaf→zone→central relay path is not applicable for this leaf because the zone relay in docker-compose.phase3.yml is configured to relay from subzones (SYNC_ZONE_HAS_SUBZONES=true)."
