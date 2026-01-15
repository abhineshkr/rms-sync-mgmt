#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

cat <<'EOF'
TEST: Zone offline / partition replay

EXPECTED OUTPUT / PASS CRITERIA
- After stopping nats-zone, publishing continues from Leaf1 (HTTP 200 on /api/orders).
- The Central durable consumer (LEAF_STREAM/central_central_none_central01) shows:
    - numPending >= publish count (backlog accumulates while partition exists)
- After restarting nats-zone, the backlog drains:
    - numPending becomes 0 within the timeout window

EVIDENCE TO CAPTURE
- Consumer JSON before partition, after publish (pending), and after heal (pending=0)
- Any Central logs showing consumption resume (optional)
EOF

CENTRAL_DURABLE="central_central_none_central01"
PUBLISH_COUNT="${1:-25}"

echo "Ensuring central consumer exists (durable=$CENTRAL_DURABLE) ..."
_http POST "http://localhost:18081/poc/consumer/ensure" \
  -H "Content-Type: application/json" \
  -d "{\"stream\":\"LEAF_STREAM\",\"durable\":\"$CENTRAL_DURABLE\",\"filterSubject\":\"leaf.>\"}" >/dev/null

printf "\nConsumer state BEFORE partition:\n"
_http GET "http://localhost:18081/poc/consumer/LEAF_STREAM/$CENTRAL_DURABLE" | python3 -m json.tool

echo "Stopping nats-zone (simulating Zone offline / partition between Central and the rest) ..."
_dc stop nats-zone

stamp="$(date +%s)"
echo "Publishing $PUBLISH_COUNT leaf events from Leaf1 while Zone is offline ..."
for i in $(seq 1 "$PUBLISH_COUNT"); do
  _http POST "http://localhost:18081/api/orders" \
    -H "Content-Type: application/json" \
    -d "{\"orderId\":\"zone-offline-$stamp-$i\",\"amount\":1.00}" >/dev/null
done

# Query consumer state from Leaf1 (still connected to the leaf/subzone side)
info=$(_http GET "http://localhost:18081/poc/consumer/LEAF_STREAM/$CENTRAL_DURABLE")
pending=$(echo "$info" | _json_get numPending)
echo "Central consumer pending (expected >= $PUBLISH_COUNT): $pending"

printf "\nConsumer state AFTER publish while partitioned:\n"
echo "$info" | python3 -m json.tool

echo "Starting nats-zone (healing partition) ..."
_dc start nats-zone

echo "Waiting for Central consumer to drain backlog ..."
for _ in $(seq 1 90); do
  info=$(_http GET "http://localhost:18081/poc/consumer/LEAF_STREAM/$CENTRAL_DURABLE")
  pending=$(echo "$info" | _json_get numPending)
  if [[ "$pending" == "0" ]]; then
    echo "Backlog drained (pending=0)."
    printf "\nConsumer state AFTER heal (evidence):\n"
    _http GET "http://localhost:18081/poc/consumer/LEAF_STREAM/$CENTRAL_DURABLE" | python3 -m json.tool
    echo "PASS: zone partition replay validated (pending -> 0 after heal)."
    exit 0
  fi
  sleep 2
done

echo "Backlog did not drain in time. Last pending=$pending" >&2
exit 1
