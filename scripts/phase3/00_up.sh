#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "PHASE 3 - START TOPOLOGY"
phase3_context

cat >&2 <<EOF2
EXPECTED OUTPUT / PASS CRITERIA
- docker compose starts successfully and containers are running.
- Central and Leaf1 admin endpoints respond with HTTP 200:
    - ${CENTRAL_BASE}/poc/ping -> {"status":"ok"}
    - ${LEAF1_BASE}/poc/ping   -> {"status":"ok"}

EVIDENCE TO CAPTURE
- docker compose services list
- /poc/ping JSON responses
EOF2

log_step "Start containers (build + up -d)"
_dc up -d --build

log_step "Show running services"
_dc ps

log_step "Wait for Central and Leaf1 admin endpoints"
_wait_for_http "${CENTRAL_BASE}/poc/ping" 180 2
_wait_for_http "${LEAF1_BASE}/poc/ping" 180 2

log_step "Central ping JSON"
_http_json GET "${CENTRAL_BASE}/poc/ping" | python3 -m json.tool

log_step "Leaf1 ping JSON"
_http_json GET "${LEAF1_BASE}/poc/ping" | python3 -m json.tool

log_ok "Phase 3 POC is up"
log_info "Central admin: ${CENTRAL_BASE}/poc/ping"
log_info "Leaf1 API:     ${LEAF1_BASE}/api/orders"
log_info "DB:            ${DB_NAME} (user=${DB_USER})"

echo "PASS: topology started and admin endpoints are reachable."
