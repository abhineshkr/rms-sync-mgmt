#!/usr/bin/env bash
set -euo pipefail

# ---- JAR location (you said it's in repo root) ----
APP_JAR="$(cd "$(dirname "$0")/.." && pwd)/rms-sync-mgmt.jar"

# ---- Ensure folders exist ----
mkdir -p "$(cd "$(dirname "$0")" && pwd)/env"
mkdir -p "$(cd "$(dirname "$0")" && pwd)/logs"

# ---- Helper: start one instance ----
start_app () {
  local name="$1"
  local base_dir
  base_dir="$(cd "$(dirname "$0")" && pwd)"

  # load env
  set -a
  source "${base_dir}/env/common.env"
  source "${base_dir}/env/${name}.env"
  set +a

  # start
  nohup java -jar "$APP_JAR" > "${base_dir}/logs/${name}.log" 2>&1 &
  echo "$!" > "${base_dir}/logs/${name}.pid"
  echo "Started ${name} (pid $(cat "${base_dir}/logs/${name}.pid")) log=${base_dir}/logs/${name}.log"
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
