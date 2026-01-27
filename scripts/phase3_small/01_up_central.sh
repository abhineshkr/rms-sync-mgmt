#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_common_small.sh"

phase3_prereqs
phase3_context

log_title "SMALL Phase3 – UP: Central only"

log_step "Starting central NATS + nats-box (+ central app)"
_dc up -d "${SVC_CENTRAL_NATS}" "${SVC_NATS_BOX}" "${SVC_APP_CENTRAL}"

log_step "Waiting for central NATS monitoring (8222/varz)"
wait_http_or_fail "http://localhost:8222/varz" 90

log_step "Waiting for central app /poc/ping (${CENTRAL_HTTP})"
wait_http_or_fail "${CENTRAL_HTTP}/poc/ping" 120

log_ok "Central is up"
