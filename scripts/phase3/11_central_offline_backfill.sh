#!/usr/bin/env bash
set -euo pipefail

# Wrapper retained for backwards compatibility with earlier Phase-3 script naming.
# The "robust" implementation lives in 11_test_central_offline.sh and validates:
# - Central offline while Leaf1 continues to accept writes
# - UP_ZONE_STREAM lastSeq increases by >= N after Central restarts (backfill)
# - Central durable consumer drains (numPending -> 0)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "${SCRIPT_DIR}/11_test_central_offline.sh" "$@"
