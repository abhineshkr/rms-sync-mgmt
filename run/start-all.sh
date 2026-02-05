#!/usr/bin/env bash
set -euo pipefail

# ---- JAR location (repo root) ----
APP_JAR="$(cd "$(dirname "$0")/.." && pwd)/rms-sync-mgmt.jar"

# ---- Folders ----
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "${BASE_DIR}/logs"
mkdir -p "${BASE_DIR}/yaml"

# ---- JVM options (replaces JAVA_TOOL_OPTIONS from env/common.env) ----
JAVA_OPTS=(
  "-XX:+UseG1GC"
  "-Xms256m"
  "-Xmx512m"
)

# ---- Helper: start one instance from YAML (no .env files) ----
# Loads:
#   1) run/yaml/common.yml
#   2) run/yaml/<name>.yml
# Instance YAML overrides common.yml.
start_app () {
  local name="$1"

  local common_cfg="${BASE_DIR}/yaml/common.yml"
  local instance_cfg="${BASE_DIR}/yaml/${name}.yml"

  if [[ ! -f "${common_cfg}" ]]; then
    echo "Missing common config: ${common_cfg}" >&2
    exit 1
  fi
  if [[ ! -f "${instance_cfg}" ]]; then
    echo "Missing instance config: ${instance_cfg}" >&2
    exit 1
  fi

  nohup java "${JAVA_OPTS[@]}" -jar "${APP_JAR}" \
    --spring.config.additional-location="file:${common_cfg},file:${instance_cfg}" \
    > "${BASE_DIR}/logs/${name}.log" 2>&1 &

  echo "$!" > "${BASE_DIR}/logs/${name}.pid"
  echo "Started ${name} (pid $(cat "${BASE_DIR}/logs/${name}.pid")) log=${BASE_DIR}/logs/${name}.log"
}

# ---- Start order ----
start_app central

start_app zone-a
start_app zone-b

start_app subzone-a1
start_app subzone-b1

start_app leaf-c
start_app leaf-za
start_app leaf-zb
start_app leaf-sa1
start_app leaf-sb1

echo ""
echo "Smoke tests (central/zone/subzone):"
echo "  curl -s http://localhost:8080/poc/ping"
echo "  curl -s http://localhost:8081/poc/ping"
echo "  curl -s http://localhost:8082/poc/ping"
echo "  curl -s http://localhost:8083/poc/ping"
echo "  curl -s http://localhost:8084/poc/ping"
