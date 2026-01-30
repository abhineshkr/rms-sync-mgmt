#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NATS_DIR="${ROOT_DIR}/nats"

CENTRAL_ID="${SYNC_CENTRAL_ID:-nhq}"
ZONES=(${SYNC_ZONES:-"snc enc wnc"})
UNITS=(${SYNC_UNITS:-"unit1 unit2"})
DESKS=(${SYNC_DESKS:-"desk1 desk2"})

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

# Build a valid NATS routes array block (commas between elements, quotes around URLs)
make_routes_block() {
  local urls=("$@")
  if [[ "${#urls[@]}" -eq 0 ]]; then
    echo ""
    return 0
  fi

  echo "  routes = ["
  local i
  for i in "${!urls[@]}"; do
    if [[ "$i" -lt "$((${#urls[@]} - 1))" ]]; then
      echo "    \"${urls[$i]}\","
    else
      echo "    \"${urls[$i]}\""
    fi
  done
  echo "  ]"
}

write_conf() {
  local file="$1" server_name="$2" tag1="$3" tag2="${4:-}"
  shift 4
  local routes_block="${1:-}"

  cat > "${file}" <<EOF
server_name: ${server_name}
port: 4222
http: 8222
server_tags: [${tag1}${tag2:+, ${tag2}}]

jetstream {
  store_dir: "/data/jetstream"
}

cluster {
  name: rms
  listen: 0.0.0.0:6222
${routes_block}
}

include "authz.conf"
EOF
}

main() {
  mkdir -p "${NATS_DIR}"
  log "Regenerating NATS confs under: ${NATS_DIR}"
  log "centralId=${CENTRAL_ID} zones=(${ZONES[*]}) units=(${UNITS[*]}) desks=(${DESKS[*]})"

  [[ "${#ZONES[@]}" -ge 1 ]] || fail "SYNC_ZONES must contain at least 1 zone"
  [[ "${#UNITS[@]}" -ge 1 ]] || fail "SYNC_UNITS must contain at least 1 unit"
  [[ "${#DESKS[@]}" -ge 1 ]] || fail "SYNC_DESKS must contain at least 1 desk"

  local z0="${ZONES[0]}"
  local u0="${UNITS[0]}"
  local d0="${DESKS[0]}"
  local d1="${DESKS[1]:-${DESKS[0]}}"
  local u1="${UNITS[1]:-${UNITS[0]}}"

  # CENTRAL routes -> all zones (required for JS clustered mode in your current design)
  local central_urls=()
  for z in "${ZONES[@]}"; do
    central_urls+=("nats-route://nats_${CENTRAL_ID}_zone_${z}:6222")
  done
  local central_routes
  central_routes="$(make_routes_block "${central_urls[@]}")"
  write_conf "${NATS_DIR}/central.conf" "nats_${CENTRAL_ID}_central" "central" "" "${central_routes}"

  # ZONES route -> central (single route is still emitted as an array)
  for z in "${ZONES[@]}"; do
    local zr
    zr="$(make_routes_block "nats-route://nats_${CENTRAL_ID}_central:6222")"
    write_conf "${NATS_DIR}/zone_${z}.conf" "nats_${CENTRAL_ID}_zone_${z}" "zone" "${z}" "${zr}"
  done

  # SUBZONES route -> their zone
  for z in "${ZONES[@]}"; do
    for u in "${UNITS[@]}"; do
      local sr
      sr="$(make_routes_block "nats-route://nats_${CENTRAL_ID}_zone_${z}:6222")"
      write_conf "${NATS_DIR}/subzone_${z}_${u}.conf" "nats_${CENTRAL_ID}_subzone_${z}_${u}" "subzone" "${z}_${u}" "${sr}"
    done
  done

  # LEAVES attached to CENTRAL
  for d in "${DESKS[@]}"; do
    local lr
    lr="$(make_routes_block "nats-route://nats_${CENTRAL_ID}_central:6222")"
    write_conf "${NATS_DIR}/leaf_central_${CENTRAL_ID}_none_${d}.conf" \
      "nats_${CENTRAL_ID}_leaf_central_${CENTRAL_ID}_none_${d}" "leaf" "central_${d}" "${lr}"
  done

  # LEAVES attached to ZONES
  for z in "${ZONES[@]}"; do
    for d in "${DESKS[@]}"; do
      local lr
      lr="$(make_routes_block "nats-route://nats_${CENTRAL_ID}_zone_${z}:6222")"
      write_conf "${NATS_DIR}/leaf_zone_${z}_none_${d}.conf" \
        "nats_${CENTRAL_ID}_leaf_zone_${z}_none_${d}" "leaf" "zone_${z}_${d}" "${lr}"
    done
  done

  # LEAVES attached to SUBZONES
  for z in "${ZONES[@]}"; do
    for u in "${UNITS[@]}"; do
      for d in "${DESKS[@]}"; do
        local lr
        lr="$(make_routes_block "nats-route://nats_${CENTRAL_ID}_subzone_${z}_${u}:6222")"
        write_conf "${NATS_DIR}/leaf_subzone_${z}_${u}_${d}.conf" \
          "nats_${CENTRAL_ID}_leaf_subzone_${z}_${u}_${d}" "leaf" "subzone_${z}_${u}_${d}" "${lr}"
      done
    done
  done

  # Compatibility aliases: overwrite legacy filenames so they remain valid
  cp -f "${NATS_DIR}/zone_${z0}.conf"          "${NATS_DIR}/zone.conf"
  cp -f "${NATS_DIR}/subzone_${z0}_${u0}.conf" "${NATS_DIR}/subzone.conf"

  cp -f "${NATS_DIR}/leaf_subzone_${z0}_${u0}_${d0}.conf" "${NATS_DIR}/leaf1.conf"
  cp -f "${NATS_DIR}/leaf_subzone_${z0}_${u0}_${d1}.conf" "${NATS_DIR}/leaf2.conf"
  cp -f "${NATS_DIR}/leaf_subzone_${z0}_${u1}_${d0}.conf" "${NATS_DIR}/leaf3.conf"
  cp -f "${NATS_DIR}/leaf_subzone_${z0}_${u1}_${d1}.conf" "${NATS_DIR}/leaf4.conf"
  cp -f "${NATS_DIR}/leaf_zone_${z0}_none_${d0}.conf"     "${NATS_DIR}/leaf5.conf"

  cp -f "${NATS_DIR}/leaf_central_${CENTRAL_ID}_none_${d0}.conf" "${NATS_DIR}/leaf_central_desk1.conf"
  cp -f "${NATS_DIR}/leaf_central_${CENTRAL_ID}_none_${d1}.conf" "${NATS_DIR}/leaf_central_desk2.conf"

  for z in "${ZONES[@]}"; do
    cp -f "${NATS_DIR}/leaf_zone_${z}_none_${d0}.conf" "${NATS_DIR}/leaf_zone_${z}_desk1.conf"
    cp -f "${NATS_DIR}/leaf_zone_${z}_none_${d1}.conf" "${NATS_DIR}/leaf_zone_${z}_desk2.conf"
  done

  log "Done."
  log "Sanity check (should be empty):"
  grep -RIn "nats-zone|nats-subzone|nats-central|nats-leaf" "${NATS_DIR}"/*.conf || true
}

main "$@"
