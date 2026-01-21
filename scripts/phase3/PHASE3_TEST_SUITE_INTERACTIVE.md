# Phase-3 Test Suite Runner (Interactive, Auth Only)

This document describes how to run the Phase-3 "simulation" in a **single sequence** using the suite runner script:

- `scripts/phase3/02_run_suite_interactive.sh`

Current scope:
- **Enabled:** NATS username/password authentication
- **Not enabled yet:** subject-level authorization (allow/deny lists)

---

## What the suite runs (in order)

The runner executes the existing Phase-3 scripts in this sequence:

1. `00_up.sh` — bring up the topology
2. `01_bootstrap.sh` — ensure/validate streams + core durables
3. `10_test_zone_partition.sh` — zone partition → upstream replay + drain
4. `11_test_central_offline.sh` — central offline → backfill + drain
5. `12_leaf_offline_outbox_retention.sh` — leaf messaging offline → outbox retention → replay
6. `12_test_leaf_offline.sh` — leaf downstream offline → interest retention → replay
7. `13_dedup_msgid.sh` — msg-id dedup
8. `14_test_outbox_replay.sh` — app crash/outbox replay (JetStream evidence)
9. `99_down.sh` — optional teardown at end

---

## Quick start

From the repo root:

```bash
cd rms-sync-mgmt
./scripts/phase3/02_run_suite_interactive.sh
```

The suite will:
- prompt you for publish counts (defaults provided)
- run each test
- if a test fails, it captures a debug bundle and offers options to retry/continue/abort

---

## Evidence capture

Each run creates a timestamped evidence directory:

- `evidence/YYYYMMDD-HHMMSS/phase3_suite/`

Inside you will find:

- `SUITE_REPORT.md` — summary + pointers to logs and debug bundles
- one log per step, e.g. `01_up.log`, `02_bootstrap.log`, ...
- on any failure: `debug_<step>_<HHMMSS>/` containing:
  - `docker_ps.txt`
  - tail logs per service (NATS + apps)
  - `varz_*.json` for key NATS nodes
  - raw JetStream API responses for stream and consumer info

---

## Interactive behavior

### Prompts
At the start, the suite prompts for:
- publish counts for the partition/offline tests
- whether to run teardown automatically at the end

### Failure handling
If a step fails:
1. The runner saves the failing step log.
2. A debug bundle is captured.
3. A menu is presented:
   - Retry the failed step
   - Continue to next step
   - Abort the suite
   - Show quick status (`docker compose ps`)
   - Open a shell in `nats-box`

This is designed to support your workflow:
- **If success:** proceed to next test
- **If failure:** proceed to debug collection and decide next action

---

## Non-interactive mode (CI / automation)

To run without prompts:

```bash
PHASE3_INTERACTIVE=0 ./scripts/phase3/02_run_suite_interactive.sh
```

In non-interactive mode:
- the suite uses default publish counts
- if a step fails, it captures a debug bundle and then **stops** (non-zero exit)

---

## Common overrides

### Override publish counts

```bash
PUBLISH_COUNT_ZONE=50 \
PUBLISH_COUNT_CENTRAL=50 \
PUBLISH_COUNT_LEAF_OUTBOX=25 \
PUBLISH_COUNT_LEAF_DOWN=25 \
./scripts/phase3/02_run_suite_interactive.sh
```

### Keep the stack running at the end

```bash
RUN_TEARDOWN=false ./scripts/phase3/02_run_suite_interactive.sh
```

### Run with different NATS credentials

```bash
export SYNC_NATS_USERNAME=js_admin_nhq
export SYNC_NATS_PASSWORD=pwd_js_admin_nhq
./scripts/phase3/02_run_suite_interactive.sh
```

---

## Debug guidance (what to inspect)

When a failure occurs, start here:

1. `SUITE_REPORT.md` — see which step failed and where the debug bundle is
2. `debug_<step>_<time>/docker_ps.txt` — confirm which containers are up/healthy
3. `debug_<step>_<time>/log_*.txt` — inspect:
   - `log_nats-central.txt`, `log_nats-zone.txt`, `log_nats-subzone.txt`
   - the corresponding `sync-*` logs
4. `debug_<step>_<time>/stream_*.json` — confirm `last_seq` moved as expected
5. `debug_<step>_<time>/consumer_*.json` — confirm `num_pending` drained (or not)

If needed, choose "Open nats-box shell" in the menu and run ad-hoc commands.

---

## Expected exit codes

- `0` — all steps passed
- `1` — one or more steps failed (even if you chose to continue after failures)

