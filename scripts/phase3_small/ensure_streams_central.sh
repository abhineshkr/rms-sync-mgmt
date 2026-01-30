#!/usr/bin/env bash
set -euo pipefail

# Backwards-compatible helper used during development.
# Prefer: scripts/phase3_small/02_js_ensure_streams_v2.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/02_js_ensure_streams_v2.sh" "$@"
