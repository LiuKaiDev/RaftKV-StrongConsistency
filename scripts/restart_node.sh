#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ $# -ne 1 ]]; then
  echo "usage: restart_node.sh <node_id>"
  exit 1
fi

id="$1"
RUN_DIR="${ROOT_DIR}/run"
LOG_DIR="${ROOT_DIR}/logs"
pid_file="${RUN_DIR}/node${id}.pid"

mkdir -p "${RUN_DIR}" "${LOG_DIR}"

if [[ -f "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
  kill "$(cat "${pid_file}")" || true
  rm -f "${pid_file}"
  sleep 1
fi

nohup "${ROOT_DIR}/bin/kv_server" --config="${ROOT_DIR}/config/node${id}.yaml" \
  >"${LOG_DIR}/node${id}.log" 2>&1 &
echo "$!" >"${pid_file}"
echo "restarted node${id}: $(cat "${pid_file}")"
