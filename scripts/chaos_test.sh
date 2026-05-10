#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CLIENT="${ROOT_DIR}/bin/kv_client"

"${ROOT_DIR}/scripts/start_cluster.sh"

echo "writing first 1000 keys"
for i in $(seq 1 1000); do
  "${CLIENT}" put "k${i}" "v${i}" >/dev/null
done

old_leader="$("${CLIENT}" leader | awk '{print $1}')"
"${ROOT_DIR}/scripts/kill_leader.sh"
sleep 2

echo "writing next 1000 keys after leader failover"
for i in $(seq 1001 2000); do
  "${CLIENT}" put "k${i}" "v${i}" >/dev/null
done

if [[ -n "${old_leader}" && "${old_leader}" != "-1" ]]; then
  "${ROOT_DIR}/scripts/restart_node.sh" "${old_leader}"
  sleep 3
fi

current_leader="$("${CLIENT}" leader | awk '{print $1}')"
follower=1
if [[ "${follower}" == "${current_leader}" ]]; then
  follower=2
fi

echo "kill follower node${follower} and continue writing"
if [[ -f "${ROOT_DIR}/run/node${follower}.pid" ]]; then
  kill "$(cat "${ROOT_DIR}/run/node${follower}.pid")" || true
  rm -f "${ROOT_DIR}/run/node${follower}.pid"
fi

for i in $(seq 2001 2500); do
  "${CLIENT}" put "k${i}" "v${i}" >/dev/null
done

"${ROOT_DIR}/scripts/restart_node.sh" "${follower}"
sleep 5
"${ROOT_DIR}/scripts/check_consistency.sh"

echo "chaos test passed"
