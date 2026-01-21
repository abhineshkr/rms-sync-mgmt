#!/usr/bin/env python3
"""Topology + permission expander for Phase-3 PoC.

Design goals
- Single source of truth: config/topology.yml (JSON/YAML)
- No external dependencies: uses python stdlib only
- Bash-friendly: can print scalar values or JSON

Usage
  scripts/tools/topology.py get <json.path>
  scripts/tools/topology.py users
  scripts/tools/topology.py nats-authz

Examples
  scripts/tools/topology.py get topology.centralId
  scripts/tools/topology.py get topology.zones --json
  scripts/tools/topology.py users --json
  scripts/tools/topology.py nats-authz > nats/generated/authz_nhq.conf
"""

from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path
from typing import Any, Dict, List, Tuple

ROOT = Path(__file__).resolve().parents[2]
CFG_PATH = Path(os.environ.get("SYNC_TOPOLOGY_FILE", ROOT / "config" / "topology.yml"))


def load_cfg() -> Dict[str, Any]:
    raw = CFG_PATH.read_text(encoding="utf-8")
    # config/topology.yml is JSON syntax (valid YAML). Parse as JSON to avoid non-stdlib yaml.
    return json.loads(raw)


def jget(obj: Any, path: str) -> Any:
    cur = obj
    for part in path.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            raise KeyError(f"Path not found: {path} (stuck at {part})")
    return cur


def format_tokens(template: str, **kw: Any) -> str:
    return template.format(**kw)


def expand_role_users(cfg: Dict[str, Any]) -> List[Dict[str, Any]]:
    t = cfg["topology"]
    zones = t["zones"]
    subzones = t["subzonesPerZone"]
    leaves = t["leavesPerAttachment"]
    central_id = t["centralId"]
    zone_central = t["defaults"]["zoneForCentralAttachedLeaves"]

    roles = cfg["roles"]

    users: List[Dict[str, Any]] = []

    # Central relay
    users.append({
        "username": format_tokens(roles["relayCentral"]["userTemplate"], centralId=central_id),
        "role": "relayCentral",
        "publish": [format_tokens(s, centralId=central_id, zoneForCentralAttachedLeaves=zone_central) for s in roles["relayCentral"]["publish"]],
        "subscribe": [format_tokens(s, centralId=central_id, zoneForCentralAttachedLeaves=zone_central) for s in roles["relayCentral"]["subscribe"]],
    })

    # Zone relays
    for z in zones:
        users.append({
            "username": format_tokens(roles["relayZone"]["userTemplate"], centralId=central_id, zone=z),
            "role": "relayZone",
            "zone": z,
            "publish": [format_tokens(s, centralId=central_id, zone=z) for s in roles["relayZone"]["publish"]],
            "subscribe": [format_tokens(s, centralId=central_id, zone=z) for s in roles["relayZone"]["subscribe"]],
        })

    # Subzone relays
    for z in zones:
        for sz in subzones:
            users.append({
                "username": format_tokens(roles["relaySubzone"]["userTemplate"], centralId=central_id, zone=z, subzone=sz),
                "role": "relaySubzone",
                "zone": z,
                "subzone": sz,
                "publish": [format_tokens(s, centralId=central_id, zone=z, subzone=sz) for s in roles["relaySubzone"]["publish"]],
                "subscribe": [format_tokens(s, centralId=central_id, zone=z, subzone=sz) for s in roles["relaySubzone"]["subscribe"]],
            })

    # Leaf users: central-attached
    for leaf in leaves:
        users.append({
            "username": format_tokens(roles["leafCentral"]["userTemplate"], centralId=central_id, zoneForCentralAttachedLeaves=zone_central, leafId=leaf),
            "role": "leafCentral",
            "zone": zone_central,
            "leafId": leaf,
            "publish": [format_tokens(s, centralId=central_id, zoneForCentralAttachedLeaves=zone_central, leafId=leaf) for s in roles["leafCentral"]["publish"]],
            "subscribe": [format_tokens(s, centralId=central_id, zoneForCentralAttachedLeaves=zone_central, leafId=leaf) for s in roles["leafCentral"]["subscribe"]],
        })

    # Leaf users: zone-attached
    for z in zones:
        for leaf in leaves:
            users.append({
                "username": format_tokens(roles["leafZone"]["userTemplate"], centralId=central_id, zone=z, leafId=leaf),
                "role": "leafZone",
                "zone": z,
                "leafId": leaf,
                "publish": [format_tokens(s, centralId=central_id, zone=z, leafId=leaf) for s in roles["leafZone"]["publish"]],
                "subscribe": [format_tokens(s, centralId=central_id, zone=z, leafId=leaf) for s in roles["leafZone"]["subscribe"]],
            })

    # Leaf users: subzone-attached
    for z in zones:
        for sz in subzones:
            for leaf in leaves:
                users.append({
                    "username": format_tokens(roles["leafSubzone"]["userTemplate"], centralId=central_id, zone=z, subzone=sz, leafId=leaf),
                    "role": "leafSubzone",
                    "zone": z,
                    "subzone": sz,
                    "leafId": leaf,
                    "publish": [format_tokens(s, centralId=central_id, zone=z, subzone=sz, leafId=leaf) for s in roles["leafSubzone"]["publish"]],
                    "subscribe": [format_tokens(s, centralId=central_id, zone=z, subzone=sz, leafId=leaf) for s in roles["leafSubzone"]["subscribe"]],
                })

    return users


def build_nats_authz(cfg: Dict[str, Any]) -> str:
    """Return a NATS authorization block.

    This repository uses NATS "authorization" both for:
      - Authentication (username/password)
      - Authorization (subject-scoped publish/subscribe permissions)

    For early bring-up and smoke testing, you may want *authentication only*.
    Control this with config/topology.yml:
      auth.enforcePermissions: false

    When auth.enforcePermissions is true (the target end-state), we generate:
      - strict allow-lists per role (from topology.yml role matrix)
      - minimal JetStream internal subjects required by the NATS client
        (no $JS.API.> wildcard)
    """

    auth_cfg = cfg.get("auth", {})
    enforce = bool(auth_cfg.get("enforcePermissions", True))
    pwd_prefix = auth_cfg.get("passwordPrefix", "pwd_")

    users: List[Dict[str, Any]] = []

    # Admin principal
    admin = auth_cfg.get("admin") or {}
    if not admin.get("username") or not admin.get("password"):
        raise ValueError("auth.admin.username/password must be set in topology.yml")

    if enforce:
        js_pub = auth_cfg.get("jsClientInternal", {}).get("publishAllow", [])
        js_sub = auth_cfg.get("jsClientInternal", {}).get("subscribeAllow", [])

        users.append({
            "user": admin["username"],
            "password": admin["password"],
            "permissions": {
                "publish": {"allow": admin.get("publishAllow", [">"] )},
                "subscribe": {"allow": admin.get("subscribeAllow", [">"] )},
            },
        })

        for u in expand_role_users(cfg):
            username = u["username"]
            users.append({
                "user": username,
                "password": f"{pwd_prefix}{username}",
                "permissions": {
                    "publish": {"allow": sorted(set(u["publish"] + js_pub))},
                    "subscribe": {"allow": sorted(set(u["subscribe"] + js_sub))},
                },
            })

    else:
        # Authentication only (no subject permissions).
        users.append({
            "user": admin["username"],
            "password": admin["password"],
        })
        for u in expand_role_users(cfg):
            username = u["username"]
            users.append({
                "user": username,
                "password": f"{pwd_prefix}{username}",
            })

    def q(val: str) -> str:
        return "\"" + val.replace("\"", "\\\"") + "\""

    out: List[str] = []
    out.append("authorization {")
    out.append("  users = [")

    for idx, user in enumerate(users):
        out.append("    {")
        out.append(f"      user = {q(user['user'])}")
        out.append(f"      password = {q(user['password'])}")

        if enforce:
            perms = user["permissions"]
            out.append("      permissions = {")
            out.append("        publish = {")
            out.append("          allow = [" + ", ".join(q(s) for s in perms["publish"]["allow"]) + "]")
            out.append("        }")
            out.append("        subscribe = {")
            out.append("          allow = [" + ", ".join(q(s) for s in perms["subscribe"]["allow"]) + "]")
            out.append("        }")
            out.append("      }")

        out.append("    }" + ("," if idx < len(users) - 1 else ""))

    out.append("  ]")
    out.append("}")
    return "\n".join(out) + "\n"

def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    ap_get = sub.add_parser("get")
    ap_get.add_argument("path")
    ap_get.add_argument("--json", action="store_true")

    ap_users = sub.add_parser("users")
    ap_users.add_argument("--json", action="store_true")

    sub.add_parser("nats-authz")

    args = ap.parse_args()
    cfg = load_cfg()

    if args.cmd == "get":
        v = jget(cfg, args.path)
        if args.json or isinstance(v, (dict, list)):
            print(json.dumps(v))
        else:
            print(v)
        return 0

    if args.cmd == "users":
        users = expand_role_users(cfg)
        if args.json:
            print(json.dumps(users))
        else:
            for u in users:
                print(u["username"])
        return 0

    if args.cmd == "nats-authz":
        print(build_nats_authz(cfg), end="")
        return 0

    raise AssertionError("unreachable")


if __name__ == "__main__":
    raise SystemExit(main())
