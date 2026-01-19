# Phase 3 – POC: Expected Outputs and Evidence Collection (Adjacency Model)

This checklist maps each Phase 3 script to explicit pass criteria and the JSON / CLI fields to capture as evidence.

## How to capture evidence

Create a local evidence folder and tee script output into it:

```bash
mkdir -p evidence
./scripts/phase3/00_up.sh |& tee evidence/00_up.log
./scripts/phase3/01_bootstrap.sh |& tee evidence/01_bootstrap.log
./scripts/phase3/01_bootstrap_consumers.sh |& tee evidence/01_bootstrap_consumers.log
./scripts/phase3/10_zone_offline_replay.sh 25 |& tee evidence/10_zone_offline_replay.log
./scripts/phase3/10_test_zone_partition.sh 25 |& tee evidence/10_test_zone_partition.log
./scripts/phase3/11_test_central_offline.sh 20 |& tee evidence/11_test_central_offline.log
./scripts/phase3/12_leaf_offline_retain_and_replay.sh 10 |& tee evidence/12_leaf_offline_retain_and_replay.log
./scripts/phase3/12_test_leaf_offline.sh 15 |& tee evidence/12_test_leaf_offline.log
./scripts/phase3/13_dedup_msgid.sh |& tee evidence/13_dedup_msgid.log
./scripts/phase3/14_app_crash_outbox_replay.sh |& tee evidence/14_app_crash_outbox_replay.log
./scripts/phase3/14_test_outbox_replay.sh |& tee evidence/14_test_outbox_replay.log
./scripts/phase3/99_down.sh |& tee evidence/99_down.log
```

Optional (supplemental) logs:

```bash
docker compose -f docker-compose.phase3.yml logs -f --tail=200 > evidence/docker_logs.txt
```

## JetStream topology assumptions used by the tests

### Directional streams

Upstream (child -> parent) uses **WorkQueue** retention (messages removed once processed by the single relay durable):
- `UP_LEAF_STREAM` (subjects: `up.leaf.>`)
- `UP_SUBZONE_STREAM` (subjects: `up.subzone.>`)
- `UP_ZONE_STREAM` (subjects: `up.zone.>`)

Downstream (parent -> child) uses **Interest** retention (messages retained until all interested durables ACK):
- `DOWN_CENTRAL_STREAM` (subjects: `down.central.>`)
- `DOWN_ZONE_STREAM` (subjects: `down.zone.>`)
- `DOWN_SUBZONE_STREAM` (subjects: `down.subzone.>`)

### Durable naming convention

Durables are strings derived from tier + zone + subzone + nodeId, optionally with a relay direction marker.
Examples used in scripts:
- Central upstream consumer: `central_central_none_central01` on `UP_ZONE_STREAM` (filter `up.zone.>`)
- Zone upstream relay: `zone_z1_none_zone01__up__subzone` on `UP_SUBZONE_STREAM` (filter `up.subzone.z1.>`)
- Subzone upstream relay: `subzone_z1_sz1_subzone01__up__leaf` on `UP_LEAF_STREAM` (filter `up.leaf.z1.sz1.>`)
- Zone downstream relay: `zone_z1_none_zone01__down__central` on `DOWN_CENTRAL_STREAM` (filter `down.central.z1.>`)
- Subzone downstream relay: `subzone_z1_sz1_subzone01__down__zone` on `DOWN_ZONE_STREAM` (filter `down.zone.z1.sz1.>`)
- Leaf2 downstream consumer: `leaf_z1_sz1_leaf02` on `DOWN_SUBZONE_STREAM` (filter `down.subzone.z1.sz1.>`)

## Script expectations

### 00_up.sh — Start topology
**Pass criteria**
- `docker compose up` succeeds.
- `GET /poc/ping` returns `{"status":"ok"}` for:
  - Central: `http://localhost:18080/poc/ping`
  - Leaf1:   `http://localhost:18081/poc/ping`

**Evidence to capture**
- `docker compose ps` output.
- Both `/poc/ping` responses.

### 01_bootstrap.sh — Validate streams + ensure core durables
**Pass criteria**
- `GET /poc/stream/<name>` returns HTTP 200 for all 6 streams.
- Stream JSON shows correct `retention` and `subjects`:
  - Upstream streams: `retention=WORKQUEUE`
  - Downstream streams: `retention=INTEREST`
- `POST /poc/consumer/ensure` returns `{"status":"ok"}` for all durables ensured by the script.

**Evidence to capture**
- Stream JSON dumps.
- `consumer/ensure` JSON dumps.

### 10_zone_offline_replay.sh — Zone partition replay (HTTP evidence)
**Pass criteria**
- `nats-zone` is stopped.
- Publishing from Leaf1 continues successfully.
- Zone upstream relay backlog is observable while partitioned (WorkQueue):
  - Consumer JSON for `UP_SUBZONE_STREAM/zone_z1_none_zone01__up__subzone` shows `numPending` increases.
- After `nats-zone` is restarted, backlog drains:
  - `numPending` becomes `0` within timeout.

**Evidence to capture**
- Consumer JSON before partition, after publish (pending), and after heal (pending=0).

### 10_test_zone_partition.sh — Zone partition replay (authoritative JetStream state)
**Pass criteria**
- Baseline `lastSeq` captured for `UP_LEAF_STREAM` and `UP_ZONE_STREAM`.
- While partition exists, Leaf1 continues to accept writes.
- After heal:
  - `UP_LEAF_STREAM lastSeq` increases by `>= N`.
  - `UP_ZONE_STREAM lastSeq` increases by `>= N`.
  - Central durable `UP_ZONE_STREAM/central_central_none_central01` drains (`numPending=0`).

**Evidence to capture**
- Baseline and target lastSeq lines.
- `nats consumer info` pending drain.

### 11_test_central_offline.sh — Central offline backfill (robust)
**Pass criteria**
- `nats-central` and `sync-central` are stopped.
- Publishing from Leaf1 continues successfully.
- After Central restarts:
  - `UP_ZONE_STREAM lastSeq` increases by `>= N` relative to baseline.
  - Central durable `UP_ZONE_STREAM/central_central_none_central01` drains (`numPending=0`).

**Evidence to capture**
- Baseline and observed lastSeq.
- Consumer pending drain.

### 12_leaf_offline_retain_and_replay.sh — Leaf messaging offline (outbox retention)
**Pass criteria**
- `nats-leaf1` is stopped while the Leaf1 application remains available.
- Orders can still be created (outbox writes succeed).
- DB evidence:
  - outbox `PENDING` count increases while `nats-leaf1` is down,
  - outbox `PENDING` drains to `0` after `nats-leaf1` restarts.

**Evidence to capture**
- Printed outbox PENDING counts: before stop, after creation, after drain.

### 12_test_leaf_offline.sh — Leaf2 offline downstream replay
**Pass criteria**
- Stop `sync-leaf2`.
- Publish `N` messages to `DOWN_CENTRAL_STREAM` via Central `/poc/publish`.
- Confirm relay chain reaches leaves:
  - `DOWN_SUBZONE_STREAM lastSeq` increases by `>= N`.
- Restart `sync-leaf2`.
- Leaf2 durable drains (`DOWN_SUBZONE_STREAM/leaf_z1_sz1_leaf02 numPending -> 0`).

**Evidence to capture**
- Baseline and observed lastSeq.
- Consumer pending drain.

### 13_dedup_msgid.sh — JetStream Msg-Id dedup
**Pass criteria**
- Two publishes to the same subject are made with the same `messageId`.
- Stream evidence shows only one stored message:
  - `DOWN_CENTRAL_STREAM lastSeq` increases by exactly `1`.

**Evidence to capture**
- Both publish JSON responses.
- Baseline and final `lastSeq`.

### 14_app_crash_outbox_replay.sh — App crash and outbox replay (DB assertion)
**Pass criteria**
- Before crash, script prints outbox PENDING count.
- After creating an order and stopping `sync-leaf1`, PENDING is greater than the “before” value.
- After restarting `sync-leaf1`, the outbox drains and PENDING becomes `0`.

**Evidence to capture**
- Printed PENDING counts: before, after crash, after drain.
- Leaf1 `/poc/ping` after restart.

### 14_test_outbox_replay.sh — App crash and outbox replay (JetStream lastSeq)
**Pass criteria**
- Create an order on Leaf1.
- Stop `sync-leaf1` quickly (simulated crash), then restart it.
- `UP_LEAF_STREAM lastSeq` increases by `>= 1` after restart.

**Evidence to capture**
- Baseline and observed lastSeq.

### 99_down.sh — Stop and cleanup
**Pass criteria**
- `docker compose down -v` completes.
- `docker compose ps` shows no remaining services.

**Evidence to capture**
- Output from `docker compose ps` after shutdown.
