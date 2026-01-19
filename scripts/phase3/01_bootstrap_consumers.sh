#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "PHASE 3 - ENSURE DURABLE CONSUMERS (ADJACENCY MODEL)"
phase3_context

cat >&2 <<'EOF2'
EXPECTED OUTPUT / PASS CRITERIA
- Consumer ensure endpoint responds HTTP 200.
- Response JSON contains status="ok".
- Durables are ensured for the adjacency relays and demo consumers:
  Upstream:
    - UP_LEAF_STREAM    / subzone_z1_sz1_subzone01__up__leaf   (filter=up.leaf.z1.sz1.>)
    - UP_SUBZONE_STREAM / zone_z1_none_zone01__up__subzone     (filter=up.subzone.z1.>)
    - UP_ZONE_STREAM    / central_central_none_central01       (filter=up.zone.>)
  Downstream:
    - DOWN_CENTRAL_STREAM / zone_z1_none_zone01__down__central (filter=down.central.z1.>)
    - DOWN_ZONE_STREAM    / subzone_z1_sz1_subzone01__down__zone (filter=down.zone.z1.sz1.>)
    - DOWN_SUBZONE_STREAM / leaf_z1_sz1_leaf02                 (filter=down.subzone.z1.sz1.>)
EOF2

HTTP_BASE="${LEAF1_BASE}"  # PoC exposes admin endpoints on Leaf1 in this setup.

_ensure() {
  local stream="$1" durable="$2" filter="$3"
  log_step "Ensure consumer: stream=${stream} durable=${durable} filter=${filter}"

  local resp
  resp="$(_http_json POST "$HTTP_BASE/poc/consumer/ensure" \
    -H "Content-Type: application/json" \
    -d "{\"stream\":\"${stream}\",\"durable\":\"${durable}\",\"filterSubject\":\"${filter}\"}")"

  echo "$resp" | python3 -m json.tool

  local status
  status="$(printf "%s" "$resp" | python3 - <<'PY'
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit(0)
print(d.get("status",""))
PY
)"

  if [[ "$status" != "ok" ]]; then
    log_fail "consumer ensure returned status='${status:-<missing>}' for durable=${durable}"
    exit 1
  fi
  log_ok "Ensured consumer durable=${durable}"
}

_wait_for_http "${HTTP_BASE}/poc/ping" 120 2

# --- Upstream relays / consumers ---
_ensure "UP_LEAF_STREAM"    "subzone_z1_sz1_subzone01__up__leaf" "up.leaf.z1.sz1.>"
_ensure "UP_SUBZONE_STREAM" "zone_z1_none_zone01__up__subzone"   "up.subzone.z1.>"
_ensure "UP_ZONE_STREAM"    "central_central_none_central01"     "up.zone.>"

# --- Downstream relays / consumers ---
_ensure "DOWN_CENTRAL_STREAM" "zone_z1_none_zone01__down__central"    "down.central.z1.>"
_ensure "DOWN_ZONE_STREAM"    "subzone_z1_sz1_subzone01__down__zone"  "down.zone.z1.sz1.>"
_ensure "DOWN_SUBZONE_STREAM" "leaf_z1_sz1_leaf02"                    "down.subzone.z1.sz1.>"

log_ok "Consumers ensured."
echo "PASS: durable consumers are ensured."
