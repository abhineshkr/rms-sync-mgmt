# Phase 3 (PoC) – Small Step-by-Step Test Plan (NEW)

This is a **minimal, incremental** Phase-3 bring-up + validation plan for the topology in `docker-compose.phase3.yml` from `rms-sync-mgmt.zip`.

**Important:** This plan is **additive**. It does **not** replace the existing Phase-3 suite/scripts.

## Topology artifacts referenced
NATS servers (service/container names in `docker-compose.phase3.yml`):
- Central: `nats_nhq_central` (ports: 4222 / 8222)
- Zone (SNC): `nats_nhq_zone_snc` (ports: 4223 / 8223)
- Subzone (SNC/unit1): `nats_nhq_subzone_snc_unit1` (ports: 4225 / 8225)
- Leaf (attached to subzone): `nats_nhq_leaf_subzone_snc_unit1_desk1`
- Leaf (attached to central): `nats_nhq_leaf_central_nhq_none_desk1`
- Leaf (attached to zone): `nats_nhq_leaf_zone_snc_none_desk1`

POC apps (HTTP):
- Central app: `sync_relay_nhq_central` → http://localhost:18080
- Leaf app: `sync_leaf_nhq_subzone_snc_unit1_desk1` → http://localhost:18081
- Zone relay app: `sync_relay_nhq_zone_snc` → http://localhost:18082
- Subzone relay app: `sync_relay_nhq_subzone_snc_unit1` → http://localhost:18083

Utility:
- `nats_box` (CLI container)

## Canonical subject format used by the code (Phase-3 adjacency model)
`<dir>.<tier>.<zone>.<subzone>.<node>.<domain>.<entity>.<event>`

Examples (the ones used by the demo order API / relays):
- `up.leaf.snc.unit1.desk1.order.order.created`
- `up.subzone.snc.unit1.subzone_snc_unit1_01.order.order.created`
- `up.zone.snc.none.zone_snc_01.order.order.created`
- `down.central.snc.unit1.all.config.policy.updated`

## Streams required (JetStream)
These are the stream names hard-coded by the PoC components:
- `UP_LEAF_STREAM` (subjects: `up.leaf.>`, retention: workqueue)
- `UP_SUBZONE_STREAM` (subjects: `up.subzone.>`, retention: workqueue)
- `UP_ZONE_STREAM` (subjects: `up.zone.>`, retention: workqueue)
- `DOWN_CENTRAL_STREAM` (subjects: `down.central.>`, retention: interest)
- `DOWN_ZONE_STREAM` (subjects: `down.zone.>`, retention: interest)
- `DOWN_SUBZONE_STREAM` (subjects: `down.subzone.>`, retention: interest)

If your volumes already contain these streams, you can skip “Ensure streams” below.

## Durable consumers created automatically by relays (expected names)
From the code’s `ConsumerName.ofLink(...)`:
- Zone relay (SNC) reads DOWN from central:
  - `zone_snc_none_zone_snc_01__down__central` (stream: `DOWN_CENTRAL_STREAM`, filter: `down.central.snc.>`)
- Zone relay (SNC) reads UP from subzone:
  - `zone_snc_none_zone_snc_01__up__subzone` (stream: `UP_SUBZONE_STREAM`, filter: `up.subzone.snc.>`)
- Subzone relay (SNC/unit1) reads UP from leaf:
  - `subzone_snc_unit1_subzone_snc_unit1_01__up__leaf` (stream: `UP_LEAF_STREAM`, filter: `up.leaf.snc.unit1.>`)
- Subzone relay (SNC/unit1) reads DOWN from zone:
  - `subzone_snc_unit1_subzone_snc_unit1_01__down__zone` (stream: `DOWN_ZONE_STREAM`, filter: `down.zone.snc.unit1.>`)

## Step-by-step bring-up + validation
### Step 0 – Clean start (optional but recommended for repeatability)
- Stop stack:
  - `./scripts/phase3/99_down.sh`
- If you want a fully clean JetStream state:
  - `PURGE_VOLUMES=true ./scripts/phase3/99_down.sh`

### Step 1 – Start Central only
Start:
- `nats_nhq_central`
- `nats_box`
- `sync_relay_nhq_central` (optional; only needed for /poc endpoints)

Checks:
- Central monitoring: `curl -s http://localhost:8222/varz | head`
- Central app: `curl -s http://localhost:18080/poc/ping`

### Step 2 – Ensure streams exist (idempotent)
- Ensure the 6 streams listed above exist using `nats` CLI in `nats_box`.
- Evidence: `nats stream info <STREAM>` returns 0.

### Step 3 – Add Zone (SNC)
Start:
- `nats_nhq_zone_snc`
- `sync_relay_nhq_zone_snc`

Checks:
- Zone monitoring: `curl -s http://localhost:8223/varz | head`
- Routes visible on central: `curl -s http://localhost:8222/routez | head`
- Zone relay creates durables:
  - `zone_snc_none_zone_snc_01__down__central`
  - `zone_snc_none_zone_snc_01__up__subzone`

Functional smoke tests:
- Downstream smoke (central → zone): publish 1 message to `down.central.snc.unit1.all.config.policy.updated` and verify it lands in `DOWN_ZONE_STREAM` as `down.zone.snc.unit1.zone_snc_01.config.policy.updated`.
- Upstream smoke (subzone → zone): publish 1 message to `up.subzone.snc.unit1.testnode.order.order.created` and verify it lands in `UP_ZONE_STREAM` as `up.zone.snc.none.zone_snc_01.order.order.created`.

### Step 4 – Add Subzone (SNC/unit1)
Start:
- `nats_nhq_subzone_snc_unit1`
- `sync_relay_nhq_subzone_snc_unit1`

Checks:
- Subzone monitoring: `curl -s http://localhost:8225/varz | head`
- Subzone relay creates durables:
  - `subzone_snc_unit1_subzone_snc_unit1_01__up__leaf`
  - `subzone_snc_unit1_subzone_snc_unit1_01__down__zone`

### Step 5 – Add Leaf (subzone-attached) and validate end-to-end
Start:
- `nats_nhq_leaf_subzone_snc_unit1_desk1`
- `sync_leaf_nhq_subzone_snc_unit1_desk1`

End-to-end UP (leaf → subzone → zone → central):
1. POST 1 order on leaf:
   - `curl -s -XPOST http://localhost:18081/api/orders -H 'Content-Type: application/json' -d '{"orderId":"t1","amount":1.0}'`
2. Verify the subject transforms exist in streams:
   - `UP_LEAF_STREAM`: `up.leaf.snc.unit1.desk1.order.order.created`
   - `UP_SUBZONE_STREAM`: `up.subzone.snc.unit1.subzone_snc_unit1_01.order.order.created`
   - `UP_ZONE_STREAM`: `up.zone.snc.none.zone_snc_01.order.order.created`

End-to-end DOWN (central → zone → subzone):
1. Publish 1 config event on central:
   - `down.central.snc.unit1.all.config.policy.updated`
2. Verify it appears in:
   - `DOWN_ZONE_STREAM`: `down.zone.snc.unit1.zone_snc_01.config.policy.updated`
   - `DOWN_SUBZONE_STREAM`: `down.subzone.snc.unit1.subzone_snc_unit1_01.config.policy.updated`

### Step 6 – Add Central-attached Leaf (desk1) and smoke test
Start:
- `nats_nhq_leaf_central_nhq_none_desk1`

Smoke:
- Publish an UP leaf event at the central-attached leaf:
  - `up.leaf.nhq.none.desk1.order.order.created`
- Verify central can pull it from `UP_LEAF_STREAM`.

### Step 7 – Add Zone-attached Leaf (snc/desk1) (optional)
Start:
- `nats_nhq_leaf_zone_snc_none_desk1`

Note: The default zone relay is configured with `SYNC_ZONE_HAS_SUBZONES=true` (it consumes UP from subzones, not directly from leaves). If you want zone-attached leaf → zone relay behavior, run a separate zone relay instance with `SYNC_ZONE_HAS_SUBZONES=false`.

## Offline/Online (partition) tests (minimal set)
Run only after Step 5 is passing.

1) Zone offline replay (stop zone NATS):
- Stop `nats_nhq_zone_snc`
- Publish N leaf orders (leaf still connected to subzone)
- Verify backlog accumulates at the zone relay’s UP consumer
- Start `nats_nhq_zone_snc`
- Verify backlog drains to 0 and `UP_ZONE_STREAM` last sequence increases

2) Subzone offline replay (stop subzone NATS):
- Stop `nats_nhq_subzone_snc_unit1`
- Publish N leaf orders
- Start `nats_nhq_subzone_snc_unit1`
- Verify replay drains and upstream reaches zone/central

3) Leaf offline (stop leaf NATS):
- Stop `nats_nhq_leaf_subzone_snc_unit1_desk1`
- Create orders via API should fail (expected) OR outbox accumulates (depending on your DB/outbox semantics)
- Start leaf NATS
- Verify outbox drains and upstream reaches central

