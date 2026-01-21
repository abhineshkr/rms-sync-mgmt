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

  # Validate required fields using env vars + Python heredoc (no shell quoting traps).
  RESP="$resp" STREAM="$stream" EXPECTED_RET="$expected_ret" EXPECTED_SUBJ="$expected_subject" python3 - <<'PY'
import json, os, sys

resp = os.environ.get("RESP", "")
stream = os.environ.get("STREAM", "")
expected_ret = os.environ.get("EXPECTED_RET", "").strip().upper()
expected_subj = os.environ.get("EXPECTED_SUBJ", "").strip()
missing = "<missing>"

try:
    d = json.loads(resp)
except Exception:
    print(f"FAIL: {stream}: response is not valid JSON")
    sys.exit(1)

ret = str(d.get("retention", "")).strip().upper()
subjects = d.get("subjects", [])
if isinstance(subjects, str):
    subjects = [subjects]
subjects = [str(s) for s in subjects]

if ret != expected_ret:
    print(f"FAIL: {stream}: retention expected {expected_ret}, got {ret or missing}")
    sys.exit(1)

if expected_subj not in subjects:
    print(f"FAIL: {stream}: expected subjects to include {expected_subj}, got {subjects}")
    sys.exit(1)

print(f"OK: {stream}: retention={ret} subjects include {expected_subj}")
PY
}

_ensure_consumer() {
  local stream="$1" durable="$2" filter="$3"
  log_step "Ensure durable consumer: stream=${stream} durable=${durable} filter=${filter}"

  local resp
  resp="$(_http_json POST "${HTTP_BASE}/poc/consumer/ensure" \
    -H "Content-Type: application/json" \
    -d "{\"stream\":\"${stream}\",\"durable\":\"${durable}\",\"filterSubject\":\"${filter}\"}")"

  echo "$resp" | python3 -m json.tool

  # Extract status reliably from JSON in RESP env var (no stdin/heredoc collisions).
  local status
  status="$(RESP="$resp" python3 - <<'PY'
import json, os
resp = os.environ.get("RESP","")
try:
    d = json.loads(resp)
except Exception:
    d = {}
print(d.get("status",""))
PY
)"

  if [[ "$status" != "ok" ]]; then
    log_fail "consumer ensure failed: durable=${durable} status=${status:-<missing>}"
    exit 1
  fi

  log_ok "Ensured consumer durable=${durable}"
}

# --- Validate streams (retention + subjects) ---
_validate_stream "UP_LEAF_STREAM"      "WORKQUEUE" "up.leaf.>"
_validate_stream "UP_SUBZONE_STREAM"   "WORKQUEUE" "up.subzone.>"
_validate_stream "UP_ZONE_STREAM"      "WORKQUEUE" "up.zone.>"

_validate_stream "DOWN_CENTRAL_STREAM" "INTEREST"  "down.central.>"
_validate_stream "DOWN_ZONE_STREAM"    "INTEREST"  "down.zone.>"
_validate_stream "DOWN_SUBZONE_STREAM" "INTEREST"  "down.subzone.>"

# --- Ensure adjacency consumers (durables) ---
# Durable naming convention used in this POC:
#   <tier>_<zone>_<subzone>_<nodeId>__<direction>__<peer>
#
# Direction meanings:
#   __up__X    = consuming upstream traffic from X (WorkQueue streams)
#   __down__X  = consuming downstream traffic from X (Interest streams)

SUBZONE_UP_LEAF_DURABLE="subzone_z1_sz1_subzone01__up__leaf"
ZONE_UP_SUBZONE_DURABLE="zone_z1_sz1_zone01__up__subzone"
CENTRAL_UP_ZONE_DURABLE="central_central_none_central01__up__zone"

ZONE_DOWN_CENTRAL_DURABLE="zone_z1_sz1_zone01__down__central"
SUBZONE_DOWN_ZONE_DURABLE="subzone_z1_sz1_subzone01__down__zone"
LEAF2_DOWN_SUBZONE_DURABLE="leaf_z1_sz1_leaf02__down__subzone"

# Filters (must be subsets of the stream subjects)
_ensure_consumer "UP_LEAF_STREAM"       "$SUBZONE_UP_LEAF_DURABLE"      "up.leaf.z1.sz1.>"
_ensure_consumer "UP_SUBZONE_STREAM"    "$ZONE_UP_SUBZONE_DURABLE"     "up.subzone.z1.sz1.>"
_ensure_consumer "UP_ZONE_STREAM"       "$CENTRAL_UP_ZONE_DURABLE"     "up.zone.z1.>"

_ensure_consumer "DOWN_CENTRAL_STREAM"  "$ZONE_DOWN_CENTRAL_DURABLE"   "down.central.z1.>"
_ensure_consumer "DOWN_ZONE_STREAM"     "$SUBZONE_DOWN_ZONE_DURABLE"   "down.zone.z1.sz1.>"
_ensure_consumer "DOWN_SUBZONE_STREAM"  "$LEAF2_DOWN_SUBZONE_DURABLE"  "down.subzone.z1.sz1.>"

log_ok "Bootstrap validation complete."
echo "PASS: streams and durables validated."
