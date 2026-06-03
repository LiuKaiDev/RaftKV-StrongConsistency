#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DATA_ROOT="/root/raftkv-test-data"
TEST_REPORT_ROOT="/root/raftkv-test-reports"
RUN_ID="${RUN_ID:-cluster-$(date +%Y%m%d-%H%M%S)-$$}"
RUN_DIR="${TEST_DATA_ROOT}/${RUN_ID}"
CLUSTER_DATA_DIR="${RUN_DIR}/cluster"
CONFIG_DIR="${CLUSTER_DATA_DIR}/config"
PID_DIR="${CLUSTER_DATA_DIR}/pids"
NODE_LOG_DIR="${CLUSTER_DATA_DIR}/logs"
REPORT_DIR="${TEST_REPORT_ROOT}/${RUN_ID}/cluster-smoke"
BUILD_DIR="${ROOT_DIR}/build/raft"
BUILD_JOBS="${BUILD_JOBS:-1}"
RAFT_BASE_PORT="${RAFT_BASE_PORT:-18000}"
CLIENT_BASE_PORT="${CLIENT_BASE_PORT:-19000}"
CLIENT_SERVERS="127.0.0.1:$((CLIENT_BASE_PORT + 1)),127.0.0.1:$((CLIENT_BASE_PORT + 2)),127.0.0.1:$((CLIENT_BASE_PORT + 3))"
CLIENT="${ROOT_DIR}/bin/kv_client"
SERVER="${ROOT_DIR}/bin/kv_server"

ensure_under_root() {
  local path="$1"
  local root="$2"
  case "${path}" in
    "${root}"/*) ;;
    *)
      echo "ERROR: refusing to use path outside ${root}: ${path}" >&2
      exit 1
      ;;
  esac
}

stop_pid() {
  local pid="$1"
  if [[ -z "${pid}" ]]; then
    return 0
  fi
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" || true
    for _ in $(seq 1 20); do
      if ! kill -0 "${pid}" 2>/dev/null; then
        return 0
      fi
      sleep 0.2
    done
    if kill -0 "${pid}" 2>/dev/null; then
      kill -9 "${pid}" || true
    fi
  fi
}

cleanup() {
  local pid_file
  for pid_file in "${PID_DIR}"/node*.pid; do
    [[ -f "${pid_file}" ]] || continue
    stop_pid "$(cat "${pid_file}")"
  done
}

trap cleanup EXIT

write_config() {
  local id="$1"
  local raft_port="$((RAFT_BASE_PORT + id))"
  local client_port="$((CLIENT_BASE_PORT + id))"
  local data_dir="${CLUSTER_DATA_DIR}/node${id}"
  cat >"${CONFIG_DIR}/node${id}.yaml" <<EOF
node_id: ${id}
listen_addr: 127.0.0.1:${raft_port}
client_addr: 127.0.0.1:${client_port}
data_dir: ${data_dir}

peers:
  - id: 1
    addr: 127.0.0.1:$((RAFT_BASE_PORT + 1))
    client_addr: 127.0.0.1:$((CLIENT_BASE_PORT + 1))
  - id: 2
    addr: 127.0.0.1:$((RAFT_BASE_PORT + 2))
    client_addr: 127.0.0.1:$((CLIENT_BASE_PORT + 2))
  - id: 3
    addr: 127.0.0.1:$((RAFT_BASE_PORT + 3))
    client_addr: 127.0.0.1:$((CLIENT_BASE_PORT + 3))

snapshot:
  max_log_entries: 10000
  snapshot_dir: ${data_dir}

raft:
  election_timeout_ms_min: 300
  election_timeout_ms_max: 600
  heartbeat_interval_ms: 100
  rpc_timeout_ms: 300
EOF
}

start_node() {
  local id="$1"
  local log_file="${NODE_LOG_DIR}/node${id}.log"
  "${SERVER}" --config="${CONFIG_DIR}/node${id}.yaml" >"${log_file}" 2>&1 &
  local pid="$!"
  echo "${pid}" >"${PID_DIR}/node${id}.pid"
  echo "started node${id}: pid=${pid}, log=${log_file}"
}

client_cmd() {
  "${CLIENT}" --servers="${CLIENT_SERVERS}" --timeout_ms=1000 --retries=10 "$@"
}

wait_for_leader() {
  local previous="${1:-}"
  local out=""
  local leader=""
  for _ in $(seq 1 50); do
    out="$(client_cmd leader 2>/dev/null || true)"
    leader="$(awk '{print $1}' <<<"${out}")"
    if [[ "${leader}" =~ ^[1-3]$ ]]; then
      if [[ -z "${previous}" || "${leader}" != "${previous}" ]]; then
        echo "${leader}"
        return 0
      fi
    fi
    sleep 1
  done
  echo "ERROR: leader was not elected in time; last response: ${out}" >&2
  return 1
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "ERROR: ${label}: expected '${expected}', got '${actual}'" >&2
    return 1
  fi
}

check_consistency() {
  for attempt in $(seq 1 20); do
    local ok=1
    for id in 1 2 3; do
      if ! "${CLIENT}" --servers="127.0.0.1:$((CLIENT_BASE_PORT + id))" dump \
        | sort >"${REPORT_DIR}/node${id}.dump"; then
        ok=0
      fi
    done
    if [[ "${ok}" -eq 1 ]] &&
      cmp -s "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node2.dump" &&
      cmp -s "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node3.dump"; then
      echo "final consistency: PASS"
      return 0
    fi
    sleep 1
  done
  echo "ERROR: final consistency check failed" >&2
  diff -u "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node2.dump" || true
  diff -u "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node3.dump" || true
  return 1
}

ensure_under_root "${RUN_DIR}" "${TEST_DATA_ROOT}"
ensure_under_root "${REPORT_DIR}" "${TEST_REPORT_ROOT}"
ensure_under_root "${NODE_LOG_DIR}" "${TEST_DATA_ROOT}"
mkdir -p "${CONFIG_DIR}" "${PID_DIR}" "${NODE_LOG_DIR}" "${REPORT_DIR}"

cd "${ROOT_DIR}"

echo "== Cluster smoke baseline =="
echo "run_id=${RUN_ID}"
echo "data_dir=${RUN_DIR}"
echo "report_dir=${REPORT_DIR}"
echo "node_log_dir=${NODE_LOG_DIR}"
echo "client_servers=${CLIENT_SERVERS}"

echo "command: cmake -S ${ROOT_DIR} -B ${BUILD_DIR} -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT=ON"
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT=ON

echo "command: cmake --build ${BUILD_DIR} -j${BUILD_JOBS} --target kv_server kv_client"
cmake --build "${BUILD_DIR}" -j"${BUILD_JOBS}" --target kv_server kv_client

for id in 1 2 3; do
  write_config "${id}"
done

for id in 1 2 3; do
  start_node "${id}"
done

leader="$(wait_for_leader)"
echo "leader=${leader}"

client_cmd put smoke_key smoke_value >/dev/null
value="$(client_cmd get smoke_key)"
assert_equals "smoke_value" "${value}" "get after put"

value="$(client_cmd append smoke_key _append)"
assert_equals "smoke_value_append" "${value}" "append result"

client_cmd delete smoke_key >/dev/null
if client_cmd get smoke_key >"${REPORT_DIR}/deleted_get.out" 2>"${REPORT_DIR}/deleted_get.err"; then
  echo "ERROR: get after delete unexpectedly succeeded" >&2
  exit 1
fi
if ! grep -q "KEY_NOT_FOUND" "${REPORT_DIR}/deleted_get.err"; then
  echo "ERROR: get after delete did not return KEY_NOT_FOUND" >&2
  cat "${REPORT_DIR}/deleted_get.err" >&2
  exit 1
fi

old_leader="${leader}"
old_pid="$(cat "${PID_DIR}/node${old_leader}.pid")"
echo "stopping old leader node${old_leader}: pid=${old_pid}"
stop_pid "${old_pid}"

new_leader="$(wait_for_leader "${old_leader}")"
echo "new_leader=${new_leader}"

client_cmd put after_failover ok >/dev/null
value="$(client_cmd get after_failover)"
assert_equals "ok" "${value}" "get after failover"

echo "restarting old leader node${old_leader}"
start_node "${old_leader}"
sleep 5

check_consistency

echo "CLUSTER SMOKE PASSED"
