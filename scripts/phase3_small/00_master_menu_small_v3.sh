#!/usr/bin/env bash
set -euo pipefail

# Phase-3 SMALL interactive menu (v3)
# - Adds granular start/stop per component (NATS vs App)
# - Adds guided bring-up flow
# - Adds offline matrix runner
# - Adds PoC DoD checks

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_DIR}/_control_small.sh"

phase3_prereqs

_hdr() {
  echo
  echo "============================================================"
  echo "PHASE3_SMALL MENU (v3)"
  phase3_context || true
  echo "============================================================"
  echo
}

_status() {
  echo
  log_info "Compose status"
  _dc ps || true
  echo
  log_info "Key URLs"
  echo "  CENTRAL_HTTP : ${CENTRAL_HTTP}"
  echo "  ZONE_SNC_HTTP : ${ZONE_SNC_HTTP}"
  echo "  SUBZONE_HTTP  : ${SUBZONE_SNC_UNIT1_HTTP}"
  echo "  LEAF_HTTP     : ${LEAF_DESK1_HTTP}"
  echo
}

_run() {
  local cmd="$1"; shift
  log_step "RUN: ${cmd} $*"
  "${cmd}" "$@"
}

while true; do
  _hdr
  _status

  cat <<'MENU'
--- Bring-up / Control ---
  1) Start NATS quorum + nats-box (central/zone/subzone)
  2) Stop  NATS quorum + nats-box
  3) Start Central app
  4) Stop  Central app
  5) Start Zone SNC app
  6) Stop  Zone SNC app
  7) Start Subzone SNC/unit1 app
  8) Stop  Subzone SNC/unit1 app
  9) Start Leaf (subzone snc/unit1 desk1) app
 10) Stop  Leaf (subzone snc/unit1 desk1) app

--- Ensure / Validate ---
 20) Ensure streams (JS API)
 21) Smoke UP (taxonomy, drains backlog)
 22) Smoke DOWN (best-effort, drains backlog)
 23) PoC DoD checks (health + smoke)

--- Guided ---
 30) Guided flow (central -> zone -> subzone -> leaf)

--- Offline / Replay ---
 40) Offline matrix runner (stop relay vs stop NATS, up+down)

--- Misc ---
 90) Logs (tail key containers)
 99) Quit
MENU

  read -r -p "Select: " choice
  case "${choice}" in
    1)
      start_nats_quorum
      ;;
    2)
      stop_nats_quorum
      ;;
    3)
      start_central_app; wait_central_app
      ;;
    4)
      stop_central_app
      ;;
    5)
      start_zone_app; wait_zone_app
      ;;
    6)
      stop_zone_app
      ;;
    7)
      start_subzone_app; wait_subzone_app
      ;;
    8)
      stop_subzone_app
      ;;
    9)
      start_leaf_app; wait_leaf_app
      ;;
    10)
      stop_leaf_app
      ;;
    20)
      "${_DIR}/02_js_ensure_streams_v2.sh" "${NATS_URL_CENTRAL}"
      ;;
    21)
      "${_DIR}/06b_smoke_up_taxonomy.sh"
      ;;
    22)
      "${_DIR}/07b_smoke_down_taxonomy.sh"
      ;;
    23)
      "${_DIR}/13_poc_dod_checks.sh"
      ;;
    30)
      echo "Run: ${_DIR}/11_guided_flow.sh [central|zone|subzone|leaf|all]"
      "${_DIR}/11_guided_flow.sh" all
      ;;
    40)
      echo "Run: ${_DIR}/12_offline_matrix_runner.sh [batch]"
      "${_DIR}/12_offline_matrix_runner.sh" 5
      ;;
    90)
      echo
      log_info "Tail logs (Ctrl+C to stop)"
      docker logs -f "${SVC_APP_CENTRAL}" &
      docker logs -f "${SVC_APP_ZONE_SNC}" &
      docker logs -f "${SVC_APP_SUBZONE_SNC_UNIT1}" &
      docker logs -f "${SVC_APP_LEAF_SUBZONE_SNC_UNIT1_DESK1}" &
      wait || true
      ;;
    99|q|quit|exit)
      log_ok "Bye"
      exit 0
      ;;
    *)
      log_warn "Unknown selection: ${choice}"
      ;;
  esac

  echo
  read -r -p "Press Enter to continue..." _
done
