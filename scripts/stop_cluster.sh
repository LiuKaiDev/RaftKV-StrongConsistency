#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
RUN_DIR="${ROOT_DIR}/run"

for pid_file in "${RUN_DIR}"/node*.pid; do
  [[ -f "${pid_file}" ]] || continue
  pid="$(cat "${pid_file}")"
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" || true
    echo "stopped $(basename "${pid_file}" .pid): ${pid}"
  fi
  rm -f "${pid_file}"
done
