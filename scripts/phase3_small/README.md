# Phase3 SMALL - Notes

## Why v2 scripts exist

The v2 helpers under `scripts/phase3_small` make the PoC staircase repeatable when running with
`SYNC_BOOTSTRAP_ENABLED=false` (common for SMALL).

Key changes:

1) **Baseline Central durable consumer is ensured**

`02_js_ensure_streams_v2.sh` now ensures the Central durable consumer used to pull from `UP_ZONE_STREAM`:

- stream: `UP_ZONE_STREAM`
- durable: `central_nhq_none_central01`
- filter: `up.zone.nhq.>`

This avoids the situation where streams exist but `consumer ls UP_ZONE_STREAM` returns **no consumers**.

> Guardrail: `UP_*` streams use WorkQueue retention. Avoid creating overlapping consumer filters on the same stream.

2) **/poc/consumer/pull timeout format**

Preferred format is ISO-8601 durations (Java `Duration.parse(...)`), for example:

- `"timeout":"PT5S"` (5 seconds)
- `"timeout":"PT30S"` (30 seconds)
- `"timeout":"PT1M"` (1 minute)

To avoid operator foot-guns, the PoC admin API also accepts shorthand seconds:

- `"timeout":"5s"`

The helper `scripts/phase3_small/_poc_http_v2.sh` generates `PT#S` automatically (recommended for scripts).

3) **nats-box CLI flag compatibility**

Some `nats-box` images ship an older `nats` CLI that does **not** support `nats sub --count` or `nats sub -m`.

For “one-message” smoke checks, use `--timeout` + `grep -m 1` (example):

```bash
( nats --server "$U" sub smoke.central --timeout 5s | grep -m 1 "hello-central" ) &
sleep 1
nats --server "$U" pub smoke.central "hello-central"
wait
```
