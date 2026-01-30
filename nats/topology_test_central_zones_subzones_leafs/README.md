# Topology Test Configs (Central + 2 Zones + 2 Subzones + 5 Leafs)

This folder contains NATS server configs for the target test topology:

- Central: nats-central (JetStream FILE ON), leaf listen :7422
- Zones: nats-zone-a, nats-zone-b (JetStream FILE ON), leaf listen :7422, remote -> central:7422
- Subzones: nats-subzone-a1, nats-subzone-b1 (JetStream FILE ON), leaf listen :7422, remote -> zone-x:7422
- Leafs: nats-leaf-* (JetStream OFF by design), remote -> attach-tier:7422

Ports inside containers:
- 4222 client
- 7422 leafnode
- 8222 monitoring

Monitoring endpoints:
- http://<host>:<mappedPort>/varz
- /jsz /leafz /connz /subsz

Auth/TLS:
- These configs are OPEN by default for ease of testing.
- For production-like testing, add authorization/accounts and (ideally) TLS, and ensure $JS.API subjects are permitted across leaf links.
