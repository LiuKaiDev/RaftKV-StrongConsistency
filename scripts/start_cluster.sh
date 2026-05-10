#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
RUN_DIR="${ROOT_DIR}/run"
LOG_DIR="${ROOT_DIR}/logs"

mkdir -p "${RUN_DIR}" "${LOG_DIR}" "${ROOT_DIR}/data"

for id in 1 2 3; do
  pid_file="${RUN_DIR}/node${id}.pid"
  if [[ -f "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
    echo "node${id} already running: $(cat "${pid_file}")"
    continue
  fi
  nohup "${ROOT_DIR}/bin/kv_server" --config="${ROOT_DIR}/config/node${id}.yaml" \
    >"${LOG_DIR}/node${id}.log" 2>&1 &
  echo "$!" >"${pid_file}"
  echo "started node${id}: $(cat "${pid_file}")"
done

sleep 2
"${ROOT_DIR}/bin/kv_client" leader || true
