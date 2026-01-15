# Phase 3 – POC: Expected Outputs and Evidence Collection

This checklist maps each Phase 3 script to explicit pass criteria and the JSON fields to capture as evidence.

## How to capture evidence

Create a local evidence folder and tee script output into it:

```bash
mkdir -p evidence
./scripts/phase3/00_up.sh | tee evidence/00_up.log
./scripts/phase3/01_bootstrap.sh | tee evidence/01_bootstrap.log
./scripts/phase3/10_zone_offline_replay.sh 25 | tee evidence/10_zone_offline_replay.log
./scripts/phase3/11_central_offline_backfill.sh 25 | tee evidence/11_central_offline_backfill.log
./scripts/phase3/12_leaf_offline_retain_and_replay.sh 10 | tee evidence/12_leaf_offline_retain_and_replay.log
./scripts/phase3/13_dedup_msgid.sh | tee evidence/13_dedup_msgid.log
./scripts/phase3/14_app_crash_outbox_replay.sh | tee evidence/14_app_crash_outbox_replay.log
./scripts/phase3/99_down.sh | tee evidence/99_down.log
```

Optional (supplemental) logs:

```bash
docker compose -f docker-compose.phase3.yml logs -f --tail=200 > evidence/docker_logs.txt
```

## Script expectations

### 00_up.sh — Start topology
**Pass criteria**
- `docker compose up` succeeds.
- `GET /poc/ping` returns `{"status":"ok"}` for:
  - Central: `http://localhost:18080/poc/ping`
  - Leaf1: `http://localhost:18081/poc/ping`

**Evidence to capture**
- `docker compose ps` output.
- Both `/poc/ping` responses.

### 01_bootstrap.sh — Stream and consumer bootstrap
**Pass criteria**
- Stream info endpoints return HTTP 200 for `LEAF_STREAM`, `ZONE_STREAM`, `CENTRAL_STREAM`.
- Each stream JSON includes at least: `name`, `subjects`, `retention`, `messages`, `firstSeq`, `lastSeq`.
- Consumer ensure calls return `{"status":"ok"}`.

**Evidence to capture**
- Stream JSON dumps.
- `POST /poc/consumer/ensure` JSON dumps.

### 10_zone_offline_replay.sh — Zone partition replay
**Pass criteria**
- `nats-zone` is stopped.
- Publishing from Leaf1 continues successfully.
- Consumer JSON for `LEAF_STREAM/central_central_none_central01` shows:
  - `numPending` increases while partitioned,
  - `numPending` drains to `0` after `nats-zone` is restarted.

**Evidence to capture**
- Consumer JSON before partition, after publish, and after heal.

### 11_central_offline_backfill.sh — Central offline backfill
**Pass criteria**
- `nats-central` and `sync-central` are stopped.
- Publishing from Leaf1 continues successfully.
- Central returns to healthy state:
  - `GET http://localhost:18080/poc/ping` returns `{"status":"ok"}` after restart.
- Consumer JSON for `LEAF_STREAM/central_central_none_central01` shows:
  - `numPending` increases while Central is offline,
  - `numPending` drains to `0` after Central restarts.

**Evidence to capture**
- Consumer JSON after publish while Central is offline.
- Central `/poc/ping` after restart.
- Consumer JSON after drain.

### 12_leaf_offline_retain_and_replay.sh — Leaf messaging offline (outbox retention)
**Pass criteria**
- `nats-leaf1` is stopped while the Leaf1 application remains available.
- Orders can still be created (outbox writes succeed).
- DB query output shows:
  - outbox `PENDING` count increases while `nats-leaf1` is down,
  - outbox `PENDING` drains to `0` after `nats-leaf1` restarts.

**Evidence to capture**
- Printed outbox PENDING counts: before stop, after creation, after drain.

### 13_dedup_msgid.sh — JetStream Msg-Id dedup
**Pass criteria**
- First publish returns JSON containing `stream` and `seq`.
- Second publish with the same `messageId` indicates dedup in at least one of these ways:
  - `duplicate=true` is present on the second response (if supported by client/server), or
  - the second response returns the same `seq` as the first.

**Evidence to capture**
- Both publish JSON responses.
- The script’s summary lines showing seq/duplicate.

### 14_app_crash_outbox_replay.sh — App crash and outbox replay
**Pass criteria**
- Before crash, script prints outbox PENDING count.
- After creating an order and stopping `sync-leaf1`, PENDING is greater than the “before” value.
- After restarting `sync-leaf1`, the outbox drains and PENDING becomes `0`.

**Evidence to capture**
- Printed PENDING counts: before, after crash, after drain.
- Leaf1 `/poc/ping` after restart.

### 99_down.sh — Stop and cleanup
**Pass criteria**
- `docker compose down -v` completes.
- `docker compose ps` shows no remaining services.

**Evidence to capture**
- Output from `docker compose ps` after shutdown.
