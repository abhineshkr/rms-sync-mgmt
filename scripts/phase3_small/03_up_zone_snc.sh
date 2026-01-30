#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_common_small.sh"

phase3_prereqs
phase3_context

log_title "SMALL Phase3 – UP: Add Zone SNC"

log_step "Starting Zone SNC NATS + Zone relay app"
_dc up -d "${SVC_ZONE_SNC_NATS}" "${SVC_APP_ZONE_SNC}"

log_step "Waiting for Zone SNC NATS monitoring (8223/varz)"
wait_http_or_fail "http://localhost:8223/varz" 90

# Ensure Zone-tier JS streams (idempotent) on the Zone NATS endpoint
js_ensure_phase3_streams_on "${NATS_URL_ZONE_SNC}"

# Quick verification to prevent false "ensured" positives
log_step "Verifying Zone stream exists: ${STREAM_UP_ZONE}"
nats_box_nats --server "${NATS_URL_ZONE_SNC}" stream info "${STREAM_UP_ZONE}" >/dev/null
log_ok "Verified Zone stream exists: ${STREAM_UP_ZONE}"

log_step "Waiting for Zone relay app /poc/ping (${ZONE_SNC_HTTP})"
wait_http_or_fail "${ZONE_SNC_HTTP}/poc/ping" 120

log_ok "Zone SNC is up"