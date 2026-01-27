#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_common_small.sh"

phase3_prereqs
phase3_context

log_title "SMALL Phase3 – UP: Central (JS quorum)"

# Option B: Central JS runs in a *clustered* JetStream meta-group (size=3).
# If we start only the central NATS node, JetStream can stay in 10008 (temporarily unavailable)
# waiting for quorum. So for the SMALL flow we bring up the *peer NATS nodes* early.

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

log_ok "Central is up"
