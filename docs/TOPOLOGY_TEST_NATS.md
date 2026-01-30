# Running the target topology NATS servers (Docker)

From the repo root:

```bash
docker compose -f docker-compose.topology-test.yml up -d
```

Monitoring:
- Central: http://localhost:8222
- Zone-A:  http://localhost:8223
- Zone-B:  http://localhost:8224
- Subzone-A1: http://localhost:8225
- Subzone-B1: http://localhost:8226
- Leafs: http://localhost:8230..8234

Leaf-link checks:
- Central: /leafz should show connections from Zone-A, Zone-B, Leaf-C
- Zone-A: /leafz should show Subzone-A1 and Leaf-ZA
- Subzone-A1: /leafz should show Leaf-SA1 (similarly for region B)

JetStream checks:
- /jsz on central/zone/subzone nodes (leaf nodes have JS disabled by design).

Auth/TLS:
- These configs are open by default.
- If you enable auth/TLS, ensure:
  - leafnode remotes include proper credentials and/or TLS settings
  - $JS.API.> is permitted for the app identities that manage consumers on upstream tiers.
