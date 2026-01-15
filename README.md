# RMS SYNC_MGMT (Spring Boot 4.0.1 + R2DBC + NATS JetStream)

This repository is a **single-module** Spring Boot starter implementation based on **RMS_SYNC_MGMT.docx**.

It implements the locked conventions described in the doc:
- Canonical subject format: `<origin-tier>.<zone>.<subzone>.<origin-node>.<domain>.<entity>.<event>`
- Streams: `LEAF_STREAM`, `ZONE_STREAM`, `CENTRAL_STREAM` mapped to `leaf.>`, `zone.>`, `central.>`
- Retention: `WorkQueue` with max age per tier
- Consumer naming: `<consumer-tier>_<zone>_<subzone>_<node>`
- Outbox pattern: `sync_outbox_event` with JetStream dedup via `Msg-Id = outbox_event.id`

## Code layout

The code is organized by package (formerly separate modules):
- `com.rms.sync.core` — subject + event model + interfaces
- `com.rms.sync.r2dbc` — reactive outbox persistence (PostgreSQL / R2DBC)
- `com.rms.sync.jetstream` — JetStream bootstrap + publisher
- `com.rms.sync.poc` — runnable demo app (WebFlux) with an outbox dispatcher + pull consumer

## Quickstart (single-node)

Prereqs: Java 21, Maven, Docker.

```bash
# infrastructure
docker compose up -d

# app
mvn -q -DskipTests package
mvn spring-boot:run
```

Create an outbox event:

```bash
curl -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' \
  -d '{"orderId":"o-1001","amount":42.50}'
```

The outbox dispatcher will publish to JetStream, and the demo pull-consumer will fetch + ACK.

---

## Phase 3 – POC (multi-node JetStream topology)

Deliverables in this repo for Phase 3:
- `docker-compose.phase3.yml` — a multi-node NATS/JetStream topology (Central → Zone → SubZone → Leaf[1..5])
- `nats/*.conf` — per-node NATS configs (cluster routes wired in a hierarchy)
- `scripts/phase3/*` — partition/offline replay test scripts
- `/poc/*` admin endpoints (used by scripts; disable via `syncmgmt.poc-admin.enabled=false`)

### Start the POC topology

```bash
./scripts/phase3/00_up.sh
./scripts/phase3/01_bootstrap.sh
```

Key endpoints:
- Central admin: `http://localhost:8080/poc/ping`
- Leaf1 Orders API: `http://localhost:8081/api/orders`

### Failure-handling test scripts (aligned to the DoD)

For an explicit pass/fail checklist and the JSON fields to capture as evidence, see:
- `scripts/phase3/EXPECTED_OUTPUTS.md`

1) **Zone offline / partition replay**

Stops the Zone NATS server (partitioning Central from the leaf side), publishes events from Leaf1, then heals the partition and verifies the Central durable consumer drains its backlog.

```bash
./scripts/phase3/10_zone_offline_replay.sh 25
```

2) **Central offline / full backfill**

Stops the Central NATS server and Central app, publishes events from Leaf1, restarts Central, and verifies the Central durable consumer drains its backlog.

```bash
./scripts/phase3/11_central_offline_backfill.sh 25
```

3) **Leaf messaging node offline / outbox retention + replay**

Stops `nats-leaf1` (Leaf messaging offline) while leaving the Leaf1 app up, creates orders (outbox writes still succeed), then restarts `nats-leaf1` and verifies the outbox drains to `PUBLISHED`.

```bash
./scripts/phase3/12_leaf_offline_retain_and_replay.sh 10
```

4) **Duplicate publish / JetStream Msg-Id dedup**

Publishes the same Msg-Id twice and expects the second publish to be treated as a duplicate.

```bash
./scripts/phase3/13_dedup_msgid.sh
```

5) **App crash / outbox replay after restart**

Leaf1 is configured with a slower outbox poll interval (30s) in Phase 3 compose. This script creates an order, crashes the Leaf1 app before dispatch, then restarts and verifies the outbox drains.

```bash
./scripts/phase3/14_app_crash_outbox_replay.sh
```

### Stop and clean volumes

```bash
./scripts/phase3/99_down.sh
```

## Notes / knobs

Runtime toggles are controlled by environment variables (see `application.yml`):
- `SYNC_BOOTSTRAP_ENABLED` — enable/disable JetStream stream bootstrapper
- `SYNC_OUTBOX_ENABLED` — enable/disable outbox dispatcher
- `SYNC_CONSUMER_ENABLED` — enable/disable the demo pull consumer
- `SYNC_POC_ADMIN_ENABLED` — enable/disable `/poc/*` admin endpoints

The Phase 3 compose uses these toggles to run different behaviors per node without changing the code.
