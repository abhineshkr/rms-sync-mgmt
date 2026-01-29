#!/usr/bin/env bash
set -euo pipefail

# Small helpers for granular start/stop per component (NATS vs App).
# Intended to be sourced by menu scripts.

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_DIR}/_common_small.sh"

_container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

_is_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" == "true" ]]
}

_svc_up() {
  # Idempotent start/ensure container exists
  local svc="$1"
  _dc up -d "$svc" >/dev/null
}

_svc_stop() {
  local svc="$1"
  _dc stop "$svc" >/dev/null || true
}

_svc_start_if_exists_else_up() {
  local svc="$1"
  if _container_exists "$svc"; then
    docker start "$svc" >/dev/null || true
  else
    _svc_up "$svc"
  fi
}

_svc_stop_if_running() {
  local svc="$1"
  if _is_running "$svc"; then
    docker stop "$svc" >/dev/null || true
  fi
}

central_nats_up()    { log_step "Start CENTRAL NATS";    _svc_start_if_exists_else_up "$SVC_CENTRAL_NATS";    wait_container_healthy_or_fail "$SVC_CENTRAL_NATS"; }
zone_snc_nats_up()   { log_step "Start ZONE(SNC) NATS";  _svc_start_if_exists_else_up "$SVC_ZONE_SNC_NATS";   wait_container_healthy_or_fail "$SVC_ZONE_SNC_NATS"; }
subzone_nats_up()    { log_step "Start SUBZONE(SNC/unit1) NATS"; _svc_start_if_exists_else_up "$SVC_SUBZONE_SNC_UNIT1_NATS"; wait_container_healthy_or_fail "$SVC_SUBZONE_SNC_UNIT1_NATS"; }

leaf_subzone_desk1_nats_up() {
  log_step "Start LEAF(subzone snc/unit1 desk1) NATS"
  _svc_start_if_exists_else_up "$SVC_LEAF_SUBZONE_SNC_UNIT1_DESK1_NATS"
  wait_container_healthy_or_fail "$SVC_LEAF_SUBZONE_SNC_UNIT1_DESK1_NATS"
}

central_nats_down()  { log_step "Stop CENTRAL NATS";   _svc_stop_if_running "$SVC_CENTRAL_NATS"; }
zone_snc_nats_down() { log_step "Stop ZONE(SNC) NATS"; _svc_stop_if_running "$SVC_ZONE_SNC_NATS"; }
subzone_nats_down()  { log_step "Stop SUBZONE(SNC/unit1) NATS"; _svc_stop_if_running "$SVC_SUBZONE_SNC_UNIT1_NATS"; }
leaf_subzone_desk1_nats_down() { log_step "Stop LEAF(subzone snc/unit1 desk1) NATS"; _svc_stop_if_running "$SVC_LEAF_SUBZONE_SNC_UNIT1_DESK1_NATS"; }

nats_box_up() {
  log_step "Start nats-box"
  _svc_start_if_exists_else_up "$SVC_NATS_BOX"
}

central_app_up() {
  log_step "Start CENTRAL app"
  _svc_start_if_exists_else_up "$SVC_APP_CENTRAL"
  wait_http_or_fail "${CENTRAL_HTTP}/poc/ping" 90
}

zone_snc_app_up() {
  log_step "Start ZONE(SNC) relay"
  _svc_start_if_exists_else_up "$SVC_APP_ZONE_SNC"
  wait_http_or_fail "${ZONE_SNC_HTTP}/poc/ping" 90
}

subzone_app_up() {
  log_step "Start SUBZONE(SNC/unit1) relay"
  _svc_start_if_exists_else_up "$SVC_APP_SUBZONE_SNC_UNIT1"
  wait_http_or_fail "${SUBZONE_SNC_UNIT1_HTTP}/poc/ping" 90
}

leaf_subzone_desk1_app_up() {
  log_step "Start LEAF(subzone snc/unit1 desk1) app"
  _svc_start_if_exists_else_up "$SVC_APP_LEAF_SUBZONE_SNC_UNIT1_DESK1"
  wait_http_or_fail "${LEAF_DESK1_HTTP}/poc/ping" 90
}

central_app_down() { log_step "Stop CENTRAL app"; _svc_stop_if_running "$SVC_APP_CENTRAL"; }
zone_snc_app_down() { log_step "Stop ZONE(SNC) relay"; _svc_stop_if_running "$SVC_APP_ZONE_SNC"; }
subzone_app_down() { log_step "Stop SUBZONE(SNC/unit1) relay"; _svc_stop_if_running "$SVC_APP_SUBZONE_SNC_UNIT1"; }
leaf_subzone_desk1_app_down() { log_step "Stop LEAF(subzone snc/unit1 desk1) app"; _svc_stop_if_running "$SVC_APP_LEAF_SUBZONE_SNC_UNIT1_DESK1"; }

baseline_nats_up() {
  # Minimum cluster quorum for JetStream metadata in this PoC topology.
  central_nats_up
  zone_snc_nats_up
  subzone_nats_up
  nats_box_up
}

baseline_apps_up() {
  central_app_up
  zone_snc_app_up
  subzone_app_up
  leaf_subzone_desk1_app_up
}

baseline_up() {
  baseline_nats_up
  baseline_apps_up
}

show_status() {
  log_info "---- Container status (running/health) ----"
  local c
  for c in \
    "$SVC_CENTRAL_NATS" "$SVC_ZONE_SNC_NATS" "$SVC_SUBZONE_SNC_UNIT1_NATS" \
    "$SVC_APP_CENTRAL" "$SVC_APP_ZONE_SNC" "$SVC_APP_SUBZONE_SNC_UNIT1" "$SVC_APP_LEAF_SUBZONE_SNC_UNIT1_DESK1" \
    "$SVC_LEAF_SUBZONE_SNC_UNIT1_DESK1_NATS" "$SVC_NATS_BOX"; do
    local run health
    run="$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo "-")"
    health="$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo "-")"
    printf "%-40s running=%-6s health=%s\n" "$c" "$run" "$health"
  done
}
