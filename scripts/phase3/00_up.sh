#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

cat <<EOF
EXPECTED OUTPUT / PASS CRITERIA
- docker compose starts successfully and containers are running.
- Central and Leaf1 admin endpoints respond with HTTP 200:
    - ${CENTRAL_BASE}/poc/ping -> {"status":"ok"}
    - ${LEAF1_BASE}/poc/ping   -> {"status":"ok"}

EVIDENCE TO CAPTURE
- docker compose services list
- /poc/ping JSON responses
EOF

echo "Starting Phase 3 POC topology..."
_dc up -d --build

printf "\nDocker compose services:\n"
_dc ps

echo "Waiting for node APIs..."
_wait_for_http "${CENTRAL_BASE}/poc/ping" 180 2
_wait_for_http "${LEAF1_BASE}/poc/ping" 180 2

printf "\nCentral ping:\n"
_http GET "${CENTRAL_BASE}/poc/ping" | python3 -m json.tool

printf "\nLeaf1 ping:\n"
_http GET "${LEAF1_BASE}/poc/ping" | python3 -m json.tool

echo "Phase 3 POC is up."
echo "- Central admin: ${CENTRAL_BASE}/poc/ping"
echo "- Leaf1 API:     ${LEAF1_BASE}/api/orders"
echo "- DB:            ${DB_NAME} (user=${DB_USER})"

echo "PASS: topology started and admin endpoints are reachable."
