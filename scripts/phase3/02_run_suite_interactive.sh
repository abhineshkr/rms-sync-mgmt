#!/usr/bin/env bash
set -euo pipefail

# scripts/phase3/02_run_suite_interactive.sh
#
# Phase-3 simulation runner (AUTH-ONLY MODE).
#
# Runs in sequence:
#   00_up.sh
#   01_bootstrap.sh
#   10_test_zone_partition.sh
#   11_test_central_offline.sh
#   12_leaf_offline_outbox_retention.sh
#   12_test_leaf_offline.sh
#   13_dedup_msgid.sh
#   14_test_outbox_replay.sh
# Optional teardown at end:
#   99_down.sh

source "$(dirname "$0")/_common.sh"

phase3_prereqs
log_title "PHASE 3 - FULL TEST SUITE (AUTH ONLY)"
phase3_context

cat >&2 <<'EOF2'
PURPOSE
- Provide a single interactive runner that executes the Phase-3 tests in sequence.
- On any failure, capture a debug bundle and prompt you to retry, continue, or abort.

EXPECTED OUTPUT / PASS CRITERIA
- Each step prints PASS and exits 0.
- If any step fails, a debug folder is created and the runner offers next actions.

EVIDENCE TO CAPTURE
- Per-step logs under evidence/<timestamp>/phase3_suite/
- Per-failure debug bundles under evidence/<timestamp>/phase3_suite/debug_<step>/
EOF2

# -----------------------------
# Evidence directory
# -----------------------------
TS="$(date +%Y%m%d-%H%M%S)"
EVIDENCE_ROOT="${EVIDENCE_ROOT:-$ROOT_DIR/evidence}"
RUN_DIR="${EVIDENCE_DIR:-$EVIDENCE_ROOT/$TS/phase3_suite}"
mkdir -p "$RUN_DIR"
SUMMARY_MD="$RUN_DIR/SUITE_REPORT.md"

# Snapshot topology used for this run.
cp -f "$TOPOLOGY_FILE" "$RUN_DIR/topology.yml" 2>/dev/null || true

# Timeouts (from topology config; safe defaults if missing)
CLI_TIMEOUT="$(python3 "$TOPOLOGY_TOOL" get topology.timeouts.cliTimeout 2>/dev/null || echo 5s)"
DRAIN_TIMEOUT_SECONDS="$(python3 "$TOPOLOGY_TOOL" get topology.timeouts.drainTimeoutSeconds 2>/dev/null || echo 180)"
STARTUP_TIMEOUT_SECONDS="$(python3 "$TOPOLOGY_TOOL" get topology.timeouts.startupTimeoutSeconds 2>/dev/null || echo 180)"

LOG_TAIL_LINES="${LOG_TAIL_LINES:-200}"

# NATS access (AUTH-ONLY mode uses admin credential by default)
NATS_SERVER="nats://${SYNC_NATS_USERNAME}:${SYNC_NATS_PASSWORD}@nats-central:4222"

# -----------------------------
# Small interactive prompt helper
# -----------------------------
prompt_value() {
  local var_name="$1" default_val="$2" prompt_text="$3"

  if [[ "${PHASE3_INTERACTIVE:-1}" != "1" ]] || [[ ! -t 0 ]]; then
    printf -v "$var_name" "%s" "$default_val"
    return 0
  fi

  local ans
  read -r -p "${prompt_text} [default: ${default_val}]: " ans
  if [[ -z "${ans}" ]]; then
    ans="$default_val"
  fi
  printf -v "$var_name" "%s" "$ans"
}

# User-tunable parameters (defaults align with existing scripts)
prompt_value PUBLISH_COUNT_ZONE "${PUBLISH_COUNT_ZONE:-25}" "Orders to publish during ZONE partition test"
prompt_value PUBLISH_COUNT_CENTRAL "${PUBLISH_COUNT_CENTRAL:-20}" "Orders to publish during CENTRAL offline test"
prompt_value PUBLISH_COUNT_LEAF_OUTBOX "${PUBLISH_COUNT_LEAF_OUTBOX:-10}" "Orders to publish during LEAF offline outbox test"
prompt_value PUBLISH_COUNT_LEAF_DOWN "${PUBLISH_COUNT_LEAF_DOWN:-15}" "Orders to publish during LEAF downstream replay test"

# Tear down stack at the end?
RUN_TEARDOWN="${RUN_TEARDOWN:-true}"
if [[ "${PHASE3_INTERACTIVE:-1}" == "1" ]] && [[ -t 0 ]]; then
  if confirm "Tear down (99_down.sh) automatically at end?" 0; then
    RUN_TEARDOWN="true"
  else
    RUN_TEARDOWN="false"
  fi
fi

# -----------------------------
# Report header
# -----------------------------
cat > "$SUMMARY_MD" <<MD
# Phase-3 Suite Report (Auth Only)

- Timestamp: $TS
- Evidence dir: $RUN_DIR
- Project: $PROJECT_NAME
- Compose: $COMPOSE_FILE
- Central: $CENTRAL_BASE
- Leaf1: $LEAF1_BASE
- NATS server (central): $NATS_SERVER

## Parameters
- ZONE partition publish count: $PUBLISH_COUNT_ZONE
- CENTRAL offline publish count: $PUBLISH_COUNT_CENTRAL
- LEAF offline outbox publish count: $PUBLISH_COUNT_LEAF_OUTBOX
- LEAF downstream publish count: $PUBLISH_COUNT_LEAF_DOWN
- Auto teardown: $RUN_TEARDOWN

## Results

MD

# -----------------------------
# Diagnostics and debug helpers
# -----------------------------
# NOTE: We intentionally use raw JetStream API requests (nats req --raw) for stream/consumer
# info collection to avoid nats CLI JSON schema validation issues.

CLI_TIMEOUT="${CLI_TIMEOUT:-5s}"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-200}"

NATS_SERVER="nats://${SYNC_NATS_USERNAME}:${SYNC_NATS_PASSWORD}@nats-central:4222"

js_req() {
  local subj="$1"
  _dc exec -T nats-box nats --server "$NATS_SERVER" req "$subj" "" --raw --timeout "$CLI_TIMEOUT"
}

capture_varz() {
  local svc="$1" outfile="$2"
  # Each NATS container has wget for the existing healthcheck.
  _dc exec -T "$svc" sh -lc 'wget -qO- http://127.0.0.1:8222/varz' >"$outfile" 2>&1 || true
}

capture_stream_info() {
  local stream="$1" outfile="$2"
  js_req "$JS_API_PREFIX.STREAM.INFO.$stream" >"$outfile" 2>&1 || true
}

capture_consumer_info() {
  local stream="$1" durable="$2" outfile="$3"
  js_req "$JS_API_PREFIX.CONSUMER.INFO.$stream.$durable" >"$outfile" 2>&1 || true
}

# JetStream API prefix used by the scripts (raw subject form)
JS_API_PREFIX='$JS.API'

# A small, stable set of durables used by the existing Phase-3 scripts.
# These are captured for quick troubleshooting when a suite step fails.
KNOWN_DURABLES=(
  'UP_LEAF_STREAM:subzone_z1_sz1_subzone01__up__leaf'
  'UP_SUBZONE_STREAM:zone_z1_sz1_zone01__up__subzone'
  'UP_ZONE_STREAM:central_central_none_central01__up__zone'
  'DOWN_CENTRAL_STREAM:zone_z1_sz1_zone01__down__central'
  'DOWN_ZONE_STREAM:subzone_z1_sz1_subzone01__down__zone'
  'DOWN_SUBZONE_STREAM:leaf_z1_sz1_leaf02__down__subzone'
)

SERVICES_CORE=(
  nats-central
  nats-zone
  nats-subzone
  nats-leaf1
  nats-leaf2
  nats-leaf3
  nats-leaf4
  sync-central
  sync-zone
  sync-subzone
  sync-leaf1
  sync-leaf2
  sync-leaf3
  sync-leaf4
  nats-box
)

debug_bundle() {
  local failed_step="$1" failed_log="$2"
  local dbg_dir="$RUN_DIR/debug_${failed_step}_$(date +%H%M%S)"
  mkdir -p "$dbg_dir"

  log_warn "Capturing debug bundle -> $dbg_dir"

  _dc ps >"$dbg_dir/docker_ps.txt" 2>&1 || true

  # Topology/config snapshot
  cp -f "$TOPOLOGY_FILE" "$dbg_dir/topology.yml" 2>/dev/null || true
  cp -f "$COMPOSE_FILE" "$dbg_dir/docker-compose.phase3.yml" 2>/dev/null || true

  # Logs
  for s in "${SERVICES_CORE[@]}"; do
    _dc logs --no-color --tail "$LOG_TAIL_LINES" "$s" >"$dbg_dir/log_${s}.txt" 2>&1 || true
  done

  # NATS varz
  capture_varz nats-central "$dbg_dir/varz_nats-central.json"
  capture_varz nats-zone "$dbg_dir/varz_nats-zone.json"
  capture_varz nats-subzone "$dbg_dir/varz_nats-subzone.json"
  capture_varz nats-leaf1 "$dbg_dir/varz_nats-leaf1.json"

  # Stream info
  capture_stream_info UP_LEAF_STREAM "$dbg_dir/stream_UP_LEAF_STREAM.json"
  capture_stream_info UP_SUBZONE_STREAM "$dbg_dir/stream_UP_SUBZONE_STREAM.json"
  capture_stream_info UP_ZONE_STREAM "$dbg_dir/stream_UP_ZONE_STREAM.json"
  capture_stream_info DOWN_CENTRAL_STREAM "$dbg_dir/stream_DOWN_CENTRAL_STREAM.json"
  capture_stream_info DOWN_ZONE_STREAM "$dbg_dir/stream_DOWN_ZONE_STREAM.json"
  capture_stream_info DOWN_SUBZONE_STREAM "$dbg_dir/stream_DOWN_SUBZONE_STREAM.json"

  # Consumer info (known adjacency durables)
  for pair in "${KNOWN_DURABLES[@]}"; do
    IFS=':' read -r stream durable <<<"$pair"
    capture_consumer_info "$stream" "$durable" "$dbg_dir/consumer_${stream}__${durable}.json"
  done

  # Add pointer to the failing step log
  if [[ -f "$failed_log" ]]; then
    cp -f "$failed_log" "$dbg_dir/failing_step.log" 2>/dev/null || true
  fi

  cat >>"$SUMMARY_MD" <<MD
### Debug bundle captured
- Failed step: $failed_step
- Debug dir: $dbg_dir
MD

  log_ok "Debug bundle captured. See: $dbg_dir"
}

show_quick_status() {
  log_title "QUICK STATUS"
  _dc ps || true
  log_info "If containers are unhealthy, review evidence logs under: $RUN_DIR"
}

open_nats_box_shell() {
  if [[ ! -t 0 ]]; then
    log_warn "No TTY available. Cannot open interactive shell."
    return 0
  fi
  log_info "Opening shell in nats-box (type 'exit' to return)"
  _dc exec nats-box sh || true
}

debug_menu() {
  local failed_step="$1" failed_log="$2"

  if [[ "${PHASE3_INTERACTIVE:-1}" != "1" ]] || [[ ! -t 0 ]]; then
    log_fail "Non-interactive mode: stopping after failure in step '$failed_step'."
    return 3
  fi

  while true; do
    echo "" >&2
    echo "Failure detected in: $failed_step" >&2
    echo "Log: $failed_log" >&2
    echo "Choose next action:" >&2
    echo "  1) Retry this step" >&2
    echo "  2) Continue to next step" >&2
    echo "  3) Abort suite" >&2
    echo "  4) Show quick status (docker compose ps)" >&2
    echo "  5) Open nats-box shell" >&2
    echo "" >&2

    read -r -p "Selection [default: 1]: " choice
    if [[ -z "$choice" ]]; then choice=1; fi

    case "$choice" in
      1) return 2 ;;  # retry
      2) return 1 ;;  # continue
      3) return 3 ;;  # abort
      4) show_quick_status; continue ;;
      5) open_nats_box_shell; continue ;;
      *) echo "Invalid selection." >&2 ;;
    esac
  done
}

# -----------------------------
# Step runner
# -----------------------------
STEP_NUM=0
PASS_COUNT=0
FAIL_COUNT=0

run_step() {
  local label="$1"; shift
  local step_name
  local log_file
  local rc

  STEP_NUM=$((STEP_NUM + 1))
  step_name=$(printf "%02d_%s" "$STEP_NUM" "$label")
  log_file="$RUN_DIR/${step_name}.log"

  log_title "RUNNING: $step_name"
  log_info "Log file: $log_file"

  cat >>"$SUMMARY_MD" <<MD
### $step_name
- Command: $*
- Log: $log_file
MD

  # Run step and capture output without terminating the suite on failure.
  set +e
  "$@" |& tee "$log_file"
  rc=${PIPESTATUS[0]}
  set -e

  if [[ "$rc" -eq 0 ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    log_ok "PASS: $step_name"
    echo "- Result: PASS" >>"$SUMMARY_MD"
    return 0
  fi

  FAIL_COUNT=$((FAIL_COUNT + 1))
  log_fail "FAIL: $step_name (exit=$rc)"
  echo "- Result: FAIL (exit=$rc)" >>"$SUMMARY_MD"

  debug_bundle "$step_name" "$log_file"
  debug_menu "$step_name" "$log_file"
  case "$?" in
    1)
      log_warn "Continuing after failure in: $step_name"
      return 0
      ;;
    2)
      log_warn "Retry requested for: $step_name"
      run_step "$label" "$@"
      return $?
      ;;
    3)
      log_fail "Aborting suite after failure in: $step_name"
      return 1
      ;;
    *)
      log_fail "Unexpected debug menu result. Aborting."
      return 1
      ;;
  esac
}

# -----------------------------
# Suite execution
# -----------------------------
log_title "STARTING SUITE"
log_info "Evidence dir: $RUN_DIR"
log_info "You can re-run this suite with PHASE3_INTERACTIVE=0 for non-interactive mode."

# Always run bring-up + bootstrap first.
run_step up "$ROOT_DIR/scripts/phase3/00_up.sh" || exit 1
run_step bootstrap "$ROOT_DIR/scripts/phase3/01_bootstrap.sh" || exit 1

# Core test sequence
run_step zone_partition "$ROOT_DIR/scripts/phase3/10_test_zone_partition.sh" "$PUBLISH_COUNT_ZONE" || exit 1
run_step central_offline "$ROOT_DIR/scripts/phase3/11_test_central_offline.sh" "$PUBLISH_COUNT_CENTRAL" || exit 1
run_step leaf_outbox "$ROOT_DIR/scripts/phase3/12_leaf_offline_outbox_retention.sh" "$PUBLISH_COUNT_LEAF_OUTBOX" || exit 1
run_step leaf_downstream "$ROOT_DIR/scripts/phase3/12_test_leaf_offline.sh" "$PUBLISH_COUNT_LEAF_DOWN" || exit 1
run_step dedup_msgid "$ROOT_DIR/scripts/phase3/13_dedup_msgid.sh" || exit 1
run_step outbox_replay "$ROOT_DIR/scripts/phase3/14_test_outbox_replay.sh" || exit 1

# Optional teardown
if [[ "$RUN_TEARDOWN" == "true" ]]; then
  run_step down "$ROOT_DIR/scripts/phase3/99_down.sh" || true
else
  log_warn "Auto teardown disabled. Stack remains running."
fi

# Final summary
cat >>"$SUMMARY_MD" <<MD

## Summary
- Steps passed: $PASS_COUNT
- Steps failed: $FAIL_COUNT

If a step failed, see the debug bundle directory referenced above.
MD

log_title "SUITE COMPLETE"
log_info "Steps passed: $PASS_COUNT"
log_info "Steps failed: $FAIL_COUNT"
log_info "Suite report: $SUMMARY_MD"

if [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo "PASS: Phase-3 suite completed with no failures. Evidence: $RUN_DIR"
  exit 0
fi

echo "FAIL: Phase-3 suite had failures. Evidence: $RUN_DIR"
exit 1
