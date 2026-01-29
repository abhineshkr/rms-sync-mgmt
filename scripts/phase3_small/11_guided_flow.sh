#!/usr/bin/env bash
set -euo pipefail

# Guided bring-up flow: Central -> Zone -> Subzone -> Leaf
#
# Usage:
#   scripts/phase3_small/11_guided_flow.sh [stage]
#
# stage: central | zone | subzone | leaf | all  (default: all)

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_DIR}/_control_small.sh"

STAGE="${1:-all}"

phase3_prereqs
phase3_context

case "${STAGE}" in
  central|zone|subzone|leaf|all) ;;
  *)
    log_fail "Unknown stage '${STAGE}'. Use: central|zone|subzone|leaf|all"
    ;;
esac

log_step "GUIDED bring-up to stage=${STAGE}"

# Always ensure nats-box is present.
nats_box_up

# 1) Central NATS + app
central_nats_up
central_app_up

# Streams (idempotent)
"${_DIR}/02_js_ensure_streams_v2.sh" "$NATS_URL_CENTRAL"

if [[ "${STAGE}" == "central" ]]; then
  show_status
  exit 0
fi

# 2) Zone NATS + relay
zone_snc_nats_up
zone_snc_app_up

if [[ "${STAGE}" == "zone" ]]; then
  show_status
  exit 0
fi

# 3) Subzone NATS + relay
subzone_nats_up
subzone_app_up

if [[ "${STAGE}" == "subzone" ]]; then
  show_status
  exit 0
fi

# 4) Leaf (subzone desk1) NATS + app
leaf_subzone_desk1_nats_up
leaf_subzone_desk1_app_up

show_status

log_ok "Guided bring-up completed (stage=${STAGE})"

log_info "Next suggested actions:"
log_info "  - Upstream smoke:   scripts/phase3_small/06b_smoke_up_taxonomy.sh"
log_info "  - Downstream smoke: scripts/phase3_small/07b_smoke_down_taxonomy.sh"
log_info "  - DoD checks:       scripts/phase3_small/13_poc_dod_checks.sh"
log_info "  - Offline matrix:   scripts/phase3_small/12_offline_matrix_runner.sh"
