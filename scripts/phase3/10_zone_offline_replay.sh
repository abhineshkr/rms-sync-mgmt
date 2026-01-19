#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "TEST: ZONE OFFLINE / PARTITION REPLAY (ADJACENCY UPSTREAM)"
phase3_context

cat >&2 <<'EOF2'
EXPECTED OUTPUT / PASS CRITERIA
- After stopping nats-zone, publishing continues from Leaf1 (HTTP 2xx on /api/orders).
- While nats-zone is offline, the Zone upstream consumer backlog grows on:
    - UP_SUBZONE_STREAM / zone_z1_none_zone01__up__subzone
      (zone cannot pull + relay from subzone)
- After restarting nats-zone, backlog drains as the relay resumes:
    - Zone upstream consumer numPending -> 0
    - Central upstream consumer numPending -> 0

EVIDENCE TO CAPTURE
- Consumer JSON before partition, after publish (pending), and after heal (pending=0)
EOF2

HTTP_BASE="${LEAF1_BASE}"

ZONE_UP_DURABLE="zone_z1_none_zone01__up__subzone"
CENTRAL_UP_DURABLE="central_central_none_central01"

PUBLISH_COUNT="${1:-25}"

pending_from_json() {
  python3 - <<'PY'
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit(0)
for k in ("numPending","num_pending"):
    if isinstance(d, dict) and k in d:
        try:
            print(int(d[k])); raise SystemExit(0)
        except Exception:
            pass
if isinstance(d, dict) and "state" in d and isinstance(d["state"], dict):
    for k in ("num_pending","numPending"):
        if k in d["state"]:
            try:
                print(int(d["state"][k])); raise SystemExit(0)
            except Exception:
                pass
print("")
PY
}

_wait_for_http "${HTTP_BASE}/poc/ping" 120 2

log_step "Ensure required consumers exist (idempotent)"
_http_discard POST "${HTTP_BASE}/poc/consumer/ensure" \
  -H "Content-Type: application/json" \
  -d "{\"stream\":\"UP_SUBZONE_STREAM\",\"durable\":\"${ZONE_UP_DURABLE}\",\"filterSubject\":\"up.subzone.z1.>\"}"

_http_discard POST "${HTTP_BASE}/poc/consumer/ensure" \
  -H "Content-Type: application/json" \
  -d "{\"stream\":\"UP_ZONE_STREAM\",\"durable\":\"${CENTRAL_UP_DURABLE}\",\"filterSubject\":\"up.zone.>\"}"

log_step "Consumer state BEFORE partition (zone upstream)"
zone_before="$(_http_json GET "${HTTP_BASE}/poc/consumer/UP_SUBZONE_STREAM/${ZONE_UP_DURABLE}")"
echo "$zone_before" | python3 -m json.tool

log_step "Stop nats-zone (simulate partition between subzone and central)"
_dc stop nats-zone

stamp="$(date +%s)"
log_step "Publish ${PUBLISH_COUNT} orders on Leaf1 while nats-zone is offline"
for i in $(seq 1 "${PUBLISH_COUNT}"); do
  _http_discard POST "${HTTP_BASE}/api/orders" \
    -H "Content-Type: application/json" \
    -d "{\"orderId\":\"zone-offline-${stamp}-${i}\",\"amount\":1.00}"
done
log_ok "Published ${PUBLISH_COUNT} orders (stamp=${stamp})"

log_step "Zone upstream consumer state AFTER publish (should have backlog)"
zone_mid="$(_http_json GET "${HTTP_BASE}/poc/consumer/UP_SUBZONE_STREAM/${ZONE_UP_DURABLE}")"
echo "$zone_mid" | python3 -m json.tool
pending_mid="$(printf "%s" "$zone_mid" | pending_from_json)"
if [[ -n "${pending_mid}" ]]; then
  assert_int_ge "zone upstream numPending while partitioned" "${pending_mid}" "${PUBLISH_COUNT}"
else
  log_warn "Could not parse numPending; skipping assertion"
fi

log_step "Start nats-zone (heal partition)"
_dc start nats-zone

log_step "Wait for zone + central upstream backlogs to drain (numPending -> 0)"
for _ in $(seq 1 120); do
  zone_now="$(_http_json GET "${HTTP_BASE}/poc/consumer/UP_SUBZONE_STREAM/${ZONE_UP_DURABLE}")"
  central_now="$(_http_json GET "${HTTP_BASE}/poc/consumer/UP_ZONE_STREAM/${CENTRAL_UP_DURABLE}")"
  pz="$(printf "%s" "$zone_now" | pending_from_json)"
  pc="$(printf "%s" "$central_now" | pending_from_json)"
  if [[ "${pz}" == "0" && "${pc}" == "0" ]]; then
    log_ok "Backlogs drained (zone=0, central=0)"
    log_step "Consumer states AFTER heal (evidence)"
    echo "$zone_now" | python3 -m json.tool
    echo "$central_now" | python3 -m json.tool
    echo "PASS: zone partition replay validated (zone+central pending -> 0 after heal)."
    exit 0
  fi
  sleep 2
done

log_fail "Backlogs did not drain in time (zone=${pz:-<unavailable>}, central=${pc:-<unavailable>})"
exit 1
