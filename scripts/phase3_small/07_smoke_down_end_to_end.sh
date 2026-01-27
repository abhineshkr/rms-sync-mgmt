#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_common_small.sh"
source "$(cd "$(dirname "$0")" && pwd)/_poc_http.sh"

phase3_prereqs

log_title "SMALL Phase3 – SMOKE: DOWN end-to-end (central → zone → subzone)"

DURABLE="tplan3_subzone_down_snc_unit1"
FILTER="down.subzone.snc.unit1.>"

log_step "Ensuring test consumer on ${STREAM_DOWN_SUBZONE} (${FILTER})"
poc_consumer_ensure "${CENTRAL_HTTP}" "${STREAM_DOWN_SUBZONE}" "${DURABLE}" "${FILTER}"

MSGID="tplan3-down-$(date +%s)"
SUBJECT="down.central.snc.unit1.all.config.policy.updated"

log_step "Publishing downstream message on central: ${SUBJECT} (msgid=${MSGID})"
poc_publish "${CENTRAL_HTTP}" "${SUBJECT}" "{}" "${MSGID}" >/dev/null

sleep 2

log_step "Pulling 1 message from ${STREAM_DOWN_SUBZONE}/${DURABLE}"
out="$(poc_consumer_pull "${CENTRAL_HTTP}" "${STREAM_DOWN_SUBZONE}" "${DURABLE}" "${FILTER}" 1 8000)"
acked="$(echo "${out}" | _json_get acked)"
assert_int_ge "acked" "${acked}" 1

log_ok "DOWN end-to-end smoke passed"
