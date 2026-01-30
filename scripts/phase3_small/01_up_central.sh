#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_common_small.sh"

phase3_prereqs
phase3_context

log_title "SMALL Phase3 – UP: Central (JS quorum)"

log_step "Starting Central NATS (first)"
_dc up -d "${SVC_CENTRAL_NATS}"

log_step "Waiting for Central NATS monitoring (8222/varz)"
wait_http_or_fail "http://localhost:8222/varz" 90

log_step "Starting peer NATS nodes for JS quorum"
_dc up -d \
  "${SVC_ZONE_SNC_NATS}" \
  "${SVC_SUBZONE_SNC_UNIT1_NATS}"

log_step "Waiting for Zone NATS monitoring (8223/varz)"
wait_http_or_fail "http://localhost:8223/varz" 90

log_step "Waiting for Subzone NATS monitoring (8231/varz)"
wait_http_or_fail "http://localhost:8231/varz" 90

log_step "Starting nats-box (+ central app)"
_dc up -d \
  "${SVC_NATS_BOX}" \
  "${SVC_APP_CENTRAL}"

log_step "Waiting for central app /poc/ping (${CENTRAL_HTTP})"
wait_http_or_fail "${CENTRAL_HTTP}/poc/ping" 120

ENSURE_SCRIPT="$(cd "$(dirname "$0")" && pwd)/02_js_ensure_streams_v2.sh"

log_step "Ensuring Phase-3 streams on Central (${NATS_URL_CENTRAL})"
"${ENSURE_SCRIPT}" "${NATS_URL_CENTRAL}"

log_step "Ensuring Phase-3 streams on Zone (${NATS_URL_ZONE_SNC})"
"${ENSURE_SCRIPT}" "${NATS_URL_ZONE_SNC}"

log_step "Ensuring Phase-3 streams on Subzone (${NATS_URL_SUBZONE_SNC_UNIT1})"
"${ENSURE_SCRIPT}" "${NATS_URL_SUBZONE_SNC_UNIT1}"

log_ok "Central is up"
