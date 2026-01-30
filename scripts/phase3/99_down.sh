#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "PHASE 3 - STOP TOPOLOGY"
phase3_context

cat >&2 <<'EOF2'
EXPECTED OUTPUT / PASS CRITERIA
- docker compose stops and removes containers (docker compose down).
- Running 'docker compose ps' shows no services for this compose project.
- If PURGE_VOLUMES=true, named volumes are also removed.
EOF2

PURGE_VOLUMES="${PURGE_VOLUMES:-false}"

if [[ "$PURGE_VOLUMES" == "true" ]]; then
  log_step "Stopping stack and PURGING named volumes (PURGE_VOLUMES=true)"
  _dc down -v --remove-orphans
  volumes_msg="volumes removed"
else
  log_step "Stopping stack (keeping named volumes)"
  _dc down --remove-orphans
  volumes_msg="volumes kept"
  echo "NOTE: Volumes kept. To purge volumes:"
  echo "  PURGE_VOLUMES=true ./scripts/phase3/99_down.sh"
fi

log_step "Show services (should be empty)"
# After 'down', containers are removed, so 'ps' should show nothing for this project.
# Keep '|| true' so the script doesn't fail due to non-zero exit codes in edge cases.
_dc ps || true

log_ok "Topology stopped (${volumes_msg})."
echo "PASS: topology stopped (${volumes_msg})."
