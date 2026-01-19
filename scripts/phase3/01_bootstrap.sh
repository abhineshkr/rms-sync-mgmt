#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "PHASE 3 - BOOTSTRAP VALIDATION (ADJACENCY STREAMS + CONSUMERS)"
phase3_context

cat >&2 <<'EOF2'
EXPECTED OUTPUT / PASS CRITERIA
- Stream info endpoints return HTTP 200 for ALL directional streams.

  Upstream (WorkQueue retention):
    - UP_LEAF_STREAM       subjects include: up.leaf.>
    - UP_SUBZONE_STREAM    subjects include: up.subzone.>
    - UP_ZONE_STREAM       subjects include: up.zone.>

  Downstream (Interest retention):
    - DOWN_CENTRAL_STREAM  subjects include: down.central.>
    - DOWN_ZONE_STREAM     subjects include: down.zone.>
    - DOWN_SUBZONE_STREAM  subjects include: down.subzone.>

- Durable consumer ensure calls return HTTP 200 and JSON contains status="ok".

EVIDENCE TO CAPTURE
- Stream JSON for each stream
- consumer/ensure JSON for each ensured durable
EOF2

HTTP_BASE="${LEAF1_BASE}"  # In this POC, admin endpoints are available on Leaf1.

_wait_for_http "${HTTP_BASE}/poc/ping" 120 2

_validate_stream() {
  local stream="$1" expected_ret="$2" expected_subject="$3"
  log_step "Fetch stream info: ${stream}"

  local resp
  resp="$(_http_json GET "${HTTP_BASE}/poc/stream/${stream}")"

  # Evidence: pretty JSON
  echo "$resp" | python3 -m json.tool

  # Validate required fields.
  python3 - <<PY
import json,sys
stream="$stream"
expected_ret="$expected_ret".strip().upper()
expected_subj="$expected_subject".strip()

d=json.loads(sys.stdin.read())

ret=str(d.get("retention","")).strip().upper()
subjects=d.get("subjects",[])
if isinstance(subjects,str):
    subjects=[subjects]
subjects=[str(s) for s in subjects]

if ret != expected_ret:
    print(f"FAIL: {stream}: retention expected {expected_ret}, got {ret or '<missing>'}")
    raise SystemExit(1)
if expected_subj not in subjects:
    print(f"FAIL: {stream}: expected subjects to include {expected_subj}, got {subjects}")
    raise SystemExit(1)
print(f"OK: {stream}: retention={ret} subjects include {expected_subj}")
PY <<<"$resp"
}

_ensure_consumer() {
  local stream="$1" durable="$2" filter="$3"
  log_step "Ensure durable consumer: stream=${stream} durable=${durable} filter=${filter}"

  local resp status
  resp="$(_http_json POST "${HTTP_BASE}/poc/consumer/ensure" \
    -H "Content-Type: application/json" \
    -d "{\"stream\":\"${stream}\",\"durable\":\"${durable}\",\"filterSubject\":\"${filter}\"}")"

  echo "$resp" | python3 -m json.tool

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
    log_fail "consumer ensure failed: durable=${durable} status=${status:-<missing>}"
    exit 1
  fi
  log_ok "Ensured durable=${durable}"
}

# --- Streams ---
_validate_stream "UP_LEAF_STREAM"      "WORKQUEUE" "up.leaf.>"
_validate_stream "UP_SUBZONE_STREAM"   "WORKQUEUE" "up.subzone.>"
_validate_stream "UP_ZONE_STREAM"      "WORKQUEUE" "up.zone.>"
_validate_stream "DOWN_CENTRAL_STREAM" "INTEREST"  "down.central.>"
_validate_stream "DOWN_ZONE_STREAM"    "INTEREST"  "down.zone.>"
_validate_stream "DOWN_SUBZONE_STREAM" "INTEREST"  "down.subzone.>"

# --- Consumers (minimal adjacency set) ---
_ensure_consumer "UP_LEAF_STREAM"        "subzone_z1_sz1_subzone01__up__leaf"     "up.leaf.z1.sz1.>"
_ensure_consumer "UP_SUBZONE_STREAM"     "zone_z1_none_zone01__up__subzone"       "up.subzone.z1.>"
_ensure_consumer "UP_ZONE_STREAM"        "central_central_none_central01"         "up.zone.>"

_ensure_consumer "DOWN_CENTRAL_STREAM"   "zone_z1_none_zone01__down__central"     "down.central.z1.>"
_ensure_consumer "DOWN_ZONE_STREAM"      "subzone_z1_sz1_subzone01__down__zone"   "down.zone.z1.sz1.>"
_ensure_consumer "DOWN_SUBZONE_STREAM"   "leaf_z1_sz1_leaf02"                      "down.subzone.z1.sz1.>"

log_ok "Bootstrap validation complete."
echo "PASS: adjacency streams validated and required durable consumers ensured."
