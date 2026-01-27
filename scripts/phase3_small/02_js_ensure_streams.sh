#!/usr/bin/env bash
set -euo pipefail

# Backwards-compatible entrypoint.
# The original version of this script had issues with JetStream API payloads.
# The v2 script is the supported implementation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/02_js_ensure_streams_v2.sh" "$@"
