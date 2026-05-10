#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
leader_line="$("${ROOT_DIR}/bin/kv_client" leader)"
leader_id="$(awk '{print $1}' <<<"${leader_line}")"

if [[ -z "${leader_id}" || "${leader_id}" == "-1" ]]; then
  echo "leader not found"
  exit 1
fi

pid_file="${ROOT_DIR}/run/node${leader_id}.pid"
if [[ ! -f "${pid_file}" ]]; then
  echo "pid file not found for leader node${leader_id}"
  exit 1
fi

pid="$(cat "${pid_file}")"
kill "${pid}" || true
rm -f "${pid_file}"
echo "killed leader node${leader_id}: ${pid}"
