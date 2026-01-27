#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_common_small.sh"

phase3_prereqs
phase3_context

log_title "SMALL Phase3 – UP: Add Leaf (subzone-attached) desk1"

log_step "Starting Leaf NATS + Leaf app"
_dc up -d "${SVC_LEAF_SUBZONE_SNC_UNIT1_DESK1_NATS}" "${SVC_APP_LEAF_SUBZONE_SNC_UNIT1_DESK1}"

log_step "Waiting for Leaf app /poc/ping (${LEAF_DESK1_HTTP})"
wait_http_or_fail "${LEAF_DESK1_HTTP}/poc/ping" 120

log_ok "Leaf desk1 is up"
