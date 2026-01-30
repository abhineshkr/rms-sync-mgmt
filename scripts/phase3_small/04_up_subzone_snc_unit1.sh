#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_common_small.sh"

phase3_prereqs
phase3_context

log_title "SMALL Phase3 – UP: Add Subzone SNC/unit1"

log_step "Starting Subzone SNC/unit1 NATS + Subzone relay app"
_dc up -d "${SVC_SUBZONE_SNC_UNIT1_NATS}" "${SVC_APP_SUBZONE_SNC_UNIT1}"

log_step "Waiting for Subzone NATS monitoring (8231/varz)"
wait_http_or_fail "http://localhost:8231/varz" 90

# Ensure Subzone-tier JS streams (idempotent) on the Subzone NATS endpoint
js_ensure_phase3_streams_on "${NATS_URL_SUBZONE_SNC_UNIT1}"

# Quick verification to prevent false "ensured" positives
log_step "Verifying Subzone stream exists: ${STREAM_UP_SUBZONE}"
nats_box_nats --server "${NATS_URL_SUBZONE_SNC_UNIT1}" stream info "${STREAM_UP_SUBZONE}" >/dev/null
log_ok "Verified Subzone stream exists: ${STREAM_UP_SUBZONE}"

log_step "Waiting for Subzone relay app /poc/ping (${SUBZONE_SNC_UNIT1_HTTP})"
wait_http_or_fail "${SUBZONE_SNC_UNIT1_HTTP}/poc/ping" 120

log_ok "Subzone SNC/unit1 is up"