#!/usr/bin/env bash
set -euo pipefail

# Phase-3 SMALL helper (NEW). Reuses the existing phase3/_common.sh.
# This file and all scripts under scripts/phase3_small are additive.

# IMPORTANT: use BASH_SOURCE so this works both when executed and when sourced.
_PHASE3_SMALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "${_PHASE3_SMALL_DIR}/../phase3" && pwd)/_common.sh"

# ---- Services (docker-compose.phase3.yml) ----
SVC_CENTRAL_NATS="nats_nhq_central"
SVC_ZONE_SNC_NATS="nats_nhq_zone_snc"
SVC_SUBZONE_SNC_UNIT1_NATS="nats_nhq_subzone_snc_unit1"

SVC_LEAF_SUBZONE_SNC_UNIT1_DESK1_NATS="nats_nhq_leaf_subzone_snc_unit1_desk1"
SVC_LEAF_CENTRAL_DESK1_NATS="nats_nhq_leaf_central_nhq_none_desk1"
SVC_LEAF_ZONE_SNC_DESK1_NATS="nats_nhq_leaf_zone_snc_none_desk1"

SVC_APP_CENTRAL="sync_relay_nhq_central"
SVC_APP_ZONE_SNC="sync_relay_nhq_zone_snc"
SVC_APP_SUBZONE_SNC_UNIT1="sync_relay_nhq_subzone_snc_unit1"
SVC_APP_LEAF_SUBZONE_SNC_UNIT1_DESK1="sync_leaf_nhq_subzone_snc_unit1_desk1"

SVC_NATS_BOX="nats_box"

# ---- HTTP endpoints ----
CENTRAL_HTTP="${CENTRAL_BASE}"
LEAF_DESK1_HTTP="${LEAF1_BASE}"
ZONE_SNC_HTTP="http://localhost:${ZONE_SNC_HTTP_PORT:-18082}"
SUBZONE_SNC_UNIT1_HTTP="http://localhost:${SUBZONE_SNC_UNIT1_HTTP_PORT:-18083}"

# ---- NATS URLs as seen from inside the docker network (for nats-box CLI) ----
NATS_URL_CENTRAL="nats://${SYNC_NATS_USERNAME}:${SYNC_NATS_PASSWORD}@${SVC_CENTRAL_NATS}:4222"
NATS_URL_ZONE_SNC="nats://${SYNC_NATS_USERNAME}:${SYNC_NATS_PASSWORD}@${SVC_ZONE_SNC_NATS}:4222"
NATS_URL_SUBZONE_SNC_UNIT1="nats://${SYNC_NATS_USERNAME}:${SYNC_NATS_PASSWORD}@${SVC_SUBZONE_SNC_UNIT1_NATS}:4222"
NATS_URL_LEAF_SUBZONE_SNC_UNIT1_DESK1="nats://${SYNC_NATS_USERNAME}:${SYNC_NATS_PASSWORD}@${SVC_LEAF_SUBZONE_SNC_UNIT1_DESK1_NATS}:4222"
NATS_URL_LEAF_CENTRAL_DESK1="nats://${SYNC_NATS_USERNAME}:${SYNC_NATS_PASSWORD}@${SVC_LEAF_CENTRAL_DESK1_NATS}:4222"
NATS_URL_LEAF_ZONE_SNC_DESK1="nats://${SYNC_NATS_USERNAME}:${SYNC_NATS_PASSWORD}@${SVC_LEAF_ZONE_SNC_DESK1_NATS}:4222"

# ---- JetStream objects used in PoC ----
STREAM_UP_LEAF="UP_LEAF_STREAM"
STREAM_UP_SUBZONE="UP_SUBZONE_STREAM"
STREAM_UP_ZONE="UP_ZONE_STREAM"
STREAM_DOWN_CENTRAL="DOWN_CENTRAL_STREAM"
STREAM_DOWN_ZONE="DOWN_ZONE_STREAM"
STREAM_DOWN_SUBZONE="DOWN_SUBZONE_STREAM"

# ---- Expected durable names created by relays ----
DUR_ZONE_DOWN_CENTRAL="zone_snc_none_zone_snc_01__down__central"
DUR_ZONE_UP_SUBZONE="zone_snc_none_zone_snc_01__up__subzone"
DUR_SUBZONE_UP_LEAF="subzone_snc_unit1_subzone_snc_unit1_01__up__leaf"
DUR_SUBZONE_DOWN_ZONE="subzone_snc_unit1_subzone_snc_unit1_01__down__zone"

# --- Utilities ---
nats_box_exec() {
  # Usage: nats_box_exec <command...>
  docker exec -i "${SVC_NATS_BOX}" sh -lc "$*"
}

wait_http_or_fail() {
  local url="$1"
  local timeout_s="${2:-90}"
  _wait_for_http "$url" "$timeout_s" 2
}

nats_box_nats() {
  # Usage: nats_box_nats --server <nats://...> <nats subcommand ...>
  docker exec -i "${SVC_NATS_BOX}" nats "$@"
}

# --- phase3_small: compose override support (additive) ---
COMPOSE_FILE_SMALL_OVERRIDE="$ROOT_DIR/docker-compose.phase3.small.override.yml"

_dc() {
  log_info "docker compose $*"
  if [[ -f "$COMPOSE_FILE_SMALL_OVERRIDE" ]]; then
    (cd "$ROOT_DIR" && docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" -f "$COMPOSE_FILE_SMALL_OVERRIDE" "$@")
  else
    (cd "$ROOT_DIR" && docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@")
  fi
}
