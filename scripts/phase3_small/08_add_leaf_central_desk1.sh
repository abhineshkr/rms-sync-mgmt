#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_common_small.sh"
source "$(cd "$(dirname "$0")" && pwd)/_poc_http.sh"

phase3_prereqs

log_title "SMALL Phase3 – Add Leaf to Central (desk1) + basic UP/DOWN check"

log_step "Starting central-attached leaf NATS: ${SVC_LEAF_CENTRAL_DESK1_NATS}"
_dc up -d "${SVC_LEAF_CENTRAL_DESK1_NATS}"

sleep 2

# UP check: publish from leaf, pull at central
DURABLE="tplan3_central_up_leaf_nhq_none"
FILTER="up.leaf.nhq.none.>"

log_step "Ensuring test consumer on ${STREAM_UP_LEAF} (${FILTER})"
poc_consumer_ensure "${CENTRAL_HTTP}" "${STREAM_UP_LEAF}" "${DURABLE}" "${FILTER}"

SUBJ="up.leaf.nhq.none.desk1.order.order.created"
PAYLOAD="{\"orderId\":\"tplan3-central-leaf-$(date +%s)\"}"

log_step "Publishing on leaf NATS: ${SUBJ}"
nats_box_nats --server "${NATS_URL_LEAF_CENTRAL_DESK1}" pub "${SUBJ}" "${PAYLOAD}" >/dev/null

sleep 2

log_step "Pulling 1 message from ${STREAM_UP_LEAF}/${DURABLE}"
out="$(poc_consumer_pull "${CENTRAL_HTTP}" "${STREAM_UP_LEAF}" "${DURABLE}" "${FILTER}" 1 8000)"
acked="$(echo "${out}" | _json_get acked)"
assert_int_ge "acked" "${acked}" 1

log_ok "Central-attached leaf basic UP check passed"

log_warn "DOWN to this leaf is not validated here because the PoC relays treat downstream as scope broadcast (zone/subzone), not per-leaf addressing."
