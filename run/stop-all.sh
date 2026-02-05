#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -d "${BASE_DIR}/logs" ]]; then
  echo "No logs directory: ${BASE_DIR}/logs" >&2
  exit 0
fi

shopt -s nullglob
for pidfile in "${BASE_DIR}/logs"/*.pid; do
  name="$(basename "${pidfile}" .pid)"
  pid="$(cat "${pidfile}" || true)"
  if [[ -z "${pid}" ]]; then
    continue
  fi
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" || true
    echo "Stopped ${name} (pid ${pid})"
  else
    echo "Not running: ${name} (pid ${pid})"
  fi
  rm -f "${pidfile}"
done
