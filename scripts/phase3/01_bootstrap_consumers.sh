#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/_common.sh"

# Ensure key durable consumers exist (even if the app is temporarily offline)
# - Central consumes leaf events
# - Leaf2 consumes central events

HTTP_BASE="http://localhost:18081"

# central durable name per convention: <consumer-tier>_<zone>_<subzone>_<node>
CENTRAL_DURABLE="central_central_none_central01"

# leaf2 durable
LEAF2_DURABLE="leaf_z1_sz1_leaf02"

_http POST "$HTTP_BASE/poc/consumer/ensure" \
  -H "Content-Type: application/json" \
  -d "{\"stream\":\"LEAF_STREAM\",\"durable\":\"$CENTRAL_DURABLE\",\"filterSubject\":\"leaf.>\"}" >/dev/null

_http POST "$HTTP_BASE/poc/consumer/ensure" \
  -H "Content-Type: application/json" \
  -d "{\"stream\":\"CENTRAL_STREAM\",\"durable\":\"$LEAF2_DURABLE\",\"filterSubject\":\"central.>\"}" >/dev/null

echo "Consumers ensured:"
echo "  LEAF_STREAM / $CENTRAL_DURABLE"
echo "  CENTRAL_STREAM / $LEAF2_DURABLE"
