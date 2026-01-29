#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_common_small.sh"

phase3_prereqs
phase3_context

log_title "SMALL Phase3 – REPLAY: Zone(SNC) UP_ZONE_STREAM -> Central"

ZONE_SERVER="${NATS_URL_ZONE_SNC}"
CENTRAL_SERVER="${NATS_URL_CENTRAL}"

STREAM="${STREAM_UP_ZONE}"
DURABLE="replay_zone_snc_to_central"
FILTER="up.zone.nhq.snc.>"

log_step "Waiting for Zone JetStream"
wait_js_or_fail "${ZONE_SERVER}" 60

log_step "Ensuring replay durable on Zone: ${DURABLE} (${FILTER})"
# IMPORTANT: --force makes this non-interactive; do NOT hide errors.

nats_box_nats --server "${ZONE_SERVER}" consumer add "${STREAM}" "${DURABLE}" \
  --pull \
  --deliver all \
  --ack explicit \
  --replay instant \
  --filter "${FILTER}" \
  --max-deliver 0 \
  >/dev/null

log_step "Verifying replay consumer exists"
nats_box_nats --server "${ZONE_SERVER}" consumer info "${STREAM}" "${DURABLE}" >/dev/null
log_ok "Replay consumer verified"

log_step "Draining Zone backlog and republishing to Central..."
count=0

while true; do
  out="$(
    nats_box_nats --server "${ZONE_SERVER}" consumer next "${STREAM}" "${DURABLE}" \
      --count 1 --timeout 1s --ack 2>/dev/null || true
  )"

  # nothing available
  if [[ -z "${out}" ]] || echo "${out}" | grep -qiE "no messages|timeout|no pending"; then
    break
  fi

  subj="$(echo "${out}" | sed -n 's/.*Received on \"\([^\"]\+\)\".*/\1/p' | head -n1)"
  # payload: take the last non-empty line after the first blank line (works for your single-line payload tests)
  payload="$(echo "${out}" | sed -n '1,/^$/d;p' | sed '/^$/d' | tail -n1)"

  if [[ -z "${subj}" ]]; then
    echo "ERROR: could not parse subject from consumer output:" >&2
    echo "${out}" >&2
    exit 1
  fi

  # republish to Central (same subject)
  nats_box_nats --server "${CENTRAL_SERVER}" pub "${subj}" "${payload}" >/dev/null

  count=$((count + 1))
done

log_ok "Replay complete. Replayed ${count} messages Zone->Central."

log_step "Central UP_ZONE_STREAM"
nats_box_nats --server "${CENTRAL_SERVER}" stream info "${STREAM}" || true

log_step "Zone UP_ZONE_STREAM"
nats_box_nats --server "${ZONE_SERVER}" stream info "${STREAM}" || true

log_ok "DONE"
