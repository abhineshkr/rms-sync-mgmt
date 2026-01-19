#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "PHASE 3 - STOP TOPOLOGY"
phase3_context

cat >&2 <<'EOF2'
EXPECTED OUTPUT / PASS CRITERIA
- docker compose stops and removes containers.
- Running 'docker compose ps' shows no active services.
EOF2

log_step "Stop and remove containers"
_dc down -v

log_step "Show services (should be empty or exited)"
_dc ps || true

log_ok "Topology stopped."
echo "PASS: topology stopped and volumes removed."
