#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_common_small.sh"

phase3_prereqs
phase3_context

log_title "SMALL Phase3 – REPLAY: Subzone(SNC/unit1) UP_SUBZONE_STREAM -> Zone(SNC)"

SUBZONE_SERVER="${NATS_URL_SUBZONE_SNC_UNIT1}"
ZONE_SERVER="${NATS_URL_ZONE_SNC}"

STREAM="${STREAM_UP_SUBZONE}"
DURABLE="replay_subzone_unit1_to_zone_snc"
FILTER="up.subzone.nhq.snc.unit1.>"

log_step "Waiting for Subzone JetStream"
wait_js_or_fail "${SUBZONE_SERVER}" 60

log_step "Ensuring replay durable on Subzone: ${DURABLE} (${FILTER})"
nats_box_nats --server "${SUBZONE_SERVER}" consumer add "${STREAM}" "${DURABLE}" \
  --pull \
  --deliver all \
  --ack explicit \
  --replay instant \
  --filter "${FILTER}" \
  --max-deliver -1 \
  --max-ack-pending 1000 \
  >/dev/null 2>&1 || true

count=0
log_step "Draining Subzone backlog and republishing to Zone..."
while true; do
  out="$(
    nats_box_nats --server "${SUBZONE_SERVER}" consumer next "${STREAM}" "${DURABLE}" \
      --count 1 --timeout 1s --ack 2>/dev/null || true
  )"

  if [[ -z "${out}" ]] || echo "${out}" | grep -qiE "no messages|timeout|no pending"; then
    break
  fi

  subj="$(echo "${out}" | sed -n 's/.*Received on \"\\([^\"]\\+\\)\".*/\\1/p' | head -n1)"
  payload="$(echo "${out}" | tail -n1)"

  [[ -n "${subj}" ]] || log_fail "Replay failed: could not parse subject"

  nats_box_nats --server "${ZONE_SERVER}" pub "${subj}" "${payload}" >/dev/null
  count=$((count + 1))
done

log_ok "Replay complete. Replayed ${count} messages Subzone->Zone."
