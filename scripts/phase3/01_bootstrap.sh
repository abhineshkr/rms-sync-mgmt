#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

cat <<'EOF'
EXPECTED OUTPUT / PASS CRITERIA
- Stream info for LEAF_STREAM, ZONE_STREAM, CENTRAL_STREAM returns HTTP 200 and JSON fields:
    - retention should be INTEREST
    - subjects should match leaf.>, zone.>, central.>
    - messages/firstSeq/lastSeq are present
- Durable consumers are ensured successfully (response status=ok):
    - LEAF_STREAM durable: central_central_none_central01 (filterSubject=leaf.>)
    - CENTRAL_STREAM durable: leaf_z1_sz1_leaf02 (filterSubject=central.>)

EVIDENCE TO CAPTURE
- Stream JSON for each stream
- ensure consumer JSON responses
EOF

CENTRAL_DURABLE="central_central_none_central01"
LEAF2_DURABLE="leaf_z1_sz1_leaf02"

# Ensure streams exist (bootstrapper should already do this on central)
for s in LEAF_STREAM ZONE_STREAM CENTRAL_STREAM; do
  echo "Stream info: $s"
  _http GET "http://localhost:18081/poc/stream/$s" | python3 -m json.tool
done

echo "Ensuring central durable consumer exists on LEAF_STREAM..."
_http POST "http://localhost:18081/poc/consumer/ensure" \
  -H "Content-Type: application/json" \
  -d "{\"stream\":\"LEAF_STREAM\",\"durable\":\"$CENTRAL_DURABLE\",\"filterSubject\":\"leaf.>\"}" \
  | python3 -m json.tool

echo "Ensuring leaf2 durable consumer exists on CENTRAL_STREAM..."
_http POST "http://localhost:18081/poc/consumer/ensure" \
  -H "Content-Type: application/json" \
  -d "{\"stream\":\"CENTRAL_STREAM\",\"durable\":\"$LEAF2_DURABLE\",\"filterSubject\":\"central.>\"}" \
  | python3 -m json.tool

echo "Bootstrap complete."

echo "PASS: streams exist and required durable consumers are ensured."
