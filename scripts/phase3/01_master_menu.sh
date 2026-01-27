#!/usr/bin/env bash
set -euo pipefail

# scripts/phase3/01_master_menu.sh
#
# Master menu for Phase-3 suite execution.
#
# Prompts:
#   1) Fast mode  (desk1 only)
#   2) Full mode  (desk1 + desk2)
#
# The chosen mode is exported as LEAF_SET for downstream scripts.
# - LEAF_SET=desk1 => fast
# - LEAF_SET=all   => full
#
# NOTE (current Phase-3 repo state):
# - Some existing Phase-3 scripts are still single-leaf oriented.
# - The suite runner will always execute the standard sequence; LEAF_SET is
#   surfaced so that future/topology-wide matrix tests can switch behavior
#   without changing the menu contract.

source "$(dirname "$0")/_common.sh"

log_title "PHASE 3 - MASTER MENU"
phase3_context

cat >&2 <<'EOF2'
PURPOSE
- Provide a single entrypoint that prompts for run mode:
    1) Fast mode (desk1)
    2) Full mode (desk1 + desk2)

BEHAVIOR
- FAST  => exports LEAF_SET=desk1
- FULL  => exports LEAF_SET=all
- Then runs: scripts/phase3/02_run_suite_interactive.sh

EVIDENCE
- Evidence is captured by the suite runner under evidence/<timestamp>/phase3_suite/
EOF2

if [[ ! -t 0 ]] || [[ "${PHASE3_INTERACTIVE:-1}" != "1" ]]; then
  log_warn "No interactive TTY detected (or PHASE3_INTERACTIVE=0). Defaulting to FAST mode (desk1)."
  export LEAF_SET="desk1"
  exec "$ROOT_DIR/scripts/phase3/02_run_suite_interactive.sh"
fi

echo "" >&2
echo "Select run mode:" >&2
echo "  1) Fast mode  (desk1 only)" >&2
echo "  2) Full mode  (desk1 + desk2)" >&2
echo "  3) Exit" >&2
echo "" >&2

read -r -p "Selection [default: 1]: " choice
if [[ -z "${choice}" ]]; then choice=1; fi

case "$choice" in
  1)
    export LEAF_SET="desk1"
    log_ok "Mode selected: FAST (LEAF_SET=desk1)"
    ;;
  2)
    export LEAF_SET="all"
    log_ok "Mode selected: FULL (LEAF_SET=all)"
    ;;
  3)
    log_info "Exiting."
    exit 0
    ;;
  *)
    log_warn "Invalid selection '$choice'. Defaulting to FAST (desk1)."
    export LEAF_SET="desk1"
    ;;
esac

exec "$ROOT_DIR/scripts/phase3/02_run_suite_interactive.sh"
