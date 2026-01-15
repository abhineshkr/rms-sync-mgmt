#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

cat <<'EOF'
EXPECTED OUTPUT / PASS CRITERIA
- docker compose stops all Phase 3 containers and removes named volumes (-v).
- Subsequent `docker compose ps` shows no running containers for this compose file.
EOF

echo "Stopping Phase 3 POC topology ..."
_dc down -v

printf "\nDocker compose services after down (should be empty):\n"
_dc ps || true

echo "PASS: topology stopped and volumes removed."
