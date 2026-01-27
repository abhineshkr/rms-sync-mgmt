#!/usr/bin/env bash
set -euo pipefail

# Purpose:
# - Ensure every bind-mounted NATS config/auth file exists as a regular file BEFORE docker compose up.
# - Repair the common failure mode where Docker previously created a directory at a *.conf path.
# - Keep behavior stable by COPYING from existing templates (central.conf, zone.conf, subzone.conf, leaf1.conf).

source "$(dirname "$0")/_common.sh"

require_valid_dotenv

log_title "PHASE 3 - PREFLIGHT: ENSURE NATS BIND SOURCE FILES EXIST"

# Load .env (compose uses it automatically; scripts need it explicitly)
if [[ -f ".env" ]]; then
  while IFS='=' read -r k v; do
    [[ -z "${k:-}" ]] && continue
    [[ "$k" =~ ^[[:space:]]*# ]] && continue
    k="$(echo "$k" | xargs)"
    v="$(echo "${v:-}" | xargs)"
    [[ -n "$k" ]] && export "$k=$v"
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env || true)
fi

CENTRAL_ID="${SYNC_CENTRAL_ID:-nhq}"
AUTHZ_FILE="./nats/generated/authz_${CENTRAL_ID}.conf"

ZONES=(snc enc wnc)
UNITS=(unit1 unit2)
DESKS=(desk1 desk2)

TPL_CENTRAL="./nats/central.conf"
TPL_ZONE="./nats/zone.conf"
TPL_SUBZONE="./nats/subzone.conf"
TPL_LEAF="./nats/leaf1.conf"

_die() { echo "ERROR: $*" >&2; exit 1; }

_need_file() { [[ -f "$1" ]] || _die "Missing required template file: $1"; }

_rm_force() {
  local p="$1"
  if rm -rf "$p" 2>/dev/null; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo rm -rf "$p"
    return 0
  fi
  _die "Cannot remove '$p'. Try: sudo rm -rf '$p'"
}

_ensure_from_template() {
  local target="$1"
  local template="$2"

  # If target exists as directory, remove it (Docker artifact)
  if [[ -d "$target" ]]; then
    log_warn "Repairing Docker artifact: $target is a directory (should be a file)"
    _rm_force "$target"
  fi

  # If missing as file, copy template
  if [[ ! -f "$target" ]]; then
    log_step "Creating: $target (from $(basename "$template"))"
    cp -f "$template" "$target"
    chmod 0644 "$target" || true
  fi
}

_ensure_authz_file() {
  mkdir -p ./nats/generated

  if [[ -d "$AUTHZ_FILE" ]]; then
    log_warn "Repairing Docker artifact: $AUTHZ_FILE is a directory (should be a file)"
    _rm_force "$AUTHZ_FILE"
  fi

  if [[ ! -f "$AUTHZ_FILE" ]]; then
    # Auth-only for now (single user/pass); no subject permissions
    local u="${SYNC_NATS_USERNAME:-js_admin_${CENTRAL_ID}}"
    local p="${SYNC_NATS_PASSWORD:-pwd_js_admin_${CENTRAL_ID}}"
    log_step "Creating authz file (auth-only): $AUTHZ_FILE"
    cat >"$AUTHZ_FILE" <<EOF
authorization {
  users = [
    { user: "${u}", password: "${p}" }
  ]
}
EOF
    chmod 0644 "$AUTHZ_FILE" || true
  fi
}

_validate_regular_file() {
  local f="$1"
  [[ -f "$f" ]] || _die "Expected regular file but not found: $f"
}

log_step "Validate template files exist (used to generate per-node conf files)"
_need_file "$TPL_CENTRAL"
_need_file "$TPL_ZONE"
_need_file "$TPL_SUBZONE"
_need_file "$TPL_LEAF"

log_step "Repair any '*.conf' directories under ./nats (left by previous Docker binds)"
while IFS= read -r d; do
  log_warn "Found bad conf directory: $d"
  _rm_force "$d"
done < <(find ./nats -maxdepth 1 -type d -name '*.conf' -print || true)

log_step "Ensure authz bind source exists"
_ensure_authz_file
_validate_regular_file "$AUTHZ_FILE"

log_step "Ensure required NATS config files exist as regular files"

# central.conf
_ensure_from_template "./nats/central.conf" "$TPL_CENTRAL"

# zones
for z in "${ZONES[@]}"; do
  _ensure_from_template "./nats/zone_${z}.conf" "$TPL_ZONE"
done

# subzones
for z in "${ZONES[@]}"; do
  for u in "${UNITS[@]}"; do
    _ensure_from_template "./nats/subzone_${z}_${u}.conf" "$TPL_SUBZONE"
  done
done

# leaves
for d in "${DESKS[@]}"; do
  _ensure_from_template "./nats/leaf_central_${d}.conf" "$TPL_LEAF"
done

for z in "${ZONES[@]}"; do
  for d in "${DESKS[@]}"; do
    _ensure_from_template "./nats/leaf_zone_${z}_${d}.conf" "$TPL_LEAF"
  done
done

for z in "${ZONES[@]}"; do
  for u in "${UNITS[@]}"; do
    for d in "${DESKS[@]}"; do
      _ensure_from_template "./nats/leaf_subzone_${z}_${u}_${d}.conf" "$TPL_LEAF"
    done
  done
done

log_step "Final validation: ensure no *.conf paths are directories"
if find ./nats -maxdepth 1 -type d -name '*.conf' -print | grep -q .; then
  echo "Bad paths (directories) still present:" >&2
  find ./nats -maxdepth 1 -type d -name '*.conf' -print >&2
  _die "Preflight failed: some .conf paths are directories."
fi

log_ok "Preflight complete: all bind source files exist as regular files."
