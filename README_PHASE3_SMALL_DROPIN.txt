Phase3 Small staircase - drop-in fixes

How to apply:
1) From repo root, backup current files (optional).
2) Unzip this archive OVER the repo root so paths align.
   Example:
     unzip -o phase3_small_dropin_fixes.zip -d /path/to/rms-sync-mgmt

What it fixes:
- JSON parsing helper in scripts/phase3/_common.sh (stdin-safe)
- Docker DNS hostnames in phase3_small scripts (use hyphenated network aliases)
- Leaf/Zone/Subzone NATS configs: leafnode links (7422) + JetStream enabled
- Leaf add scripts wait for container health before using nats-box
- Smoke tests poll pulls until message observed
