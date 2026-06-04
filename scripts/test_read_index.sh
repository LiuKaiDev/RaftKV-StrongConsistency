#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DATA_ROOT="${TEST_DATA_ROOT:-/tmp/raftkv-test-data}"
TEST_REPORT_ROOT="${TEST_REPORT_ROOT:-/tmp/raftkv-test-reports}"
RUN_ID="${RUN_ID:-read-index-$(date +%Y%m%d-%H%M%S)-$$}"
RUN_DIR="${TEST_DATA_ROOT}/${RUN_ID}"
CLUSTER_DATA_DIR="${RUN_DIR}/read-index"
CONFIG_DIR="${CLUSTER_DATA_DIR}/config"
PID_DIR="${CLUSTER_DATA_DIR}/pids"
NODE_LOG_DIR="${CLUSTER_DATA_DIR}/logs"
REPORT_DIR="${TEST_REPORT_ROOT}/${RUN_ID}/read-index"
BUILD_DIR="${ROOT_DIR}/build/raft"
BUILD_JOBS="${BUILD_JOBS:-1}"
PORT_OFFSET="${PORT_OFFSET:-$((($$ % 1000) * 20))}"
RAFT_BASE_PORT="${RAFT_BASE_PORT:-$((36000 + PORT_OFFSET))}"
CLIENT_BASE_PORT="${CLIENT_BASE_PORT:-$((37000 + PORT_OFFSET))}"
SNAPSHOT_MAX_LOG_ENTRIES="${SNAPSHOT_MAX_LOG_ENTRIES:-8}"
CLIENT="${ROOT_DIR}/bin/kv_client"
SERVER="${ROOT_DIR}/bin/kv_server"
CLIENT_SERVERS="127.0.0.1:$((CLIENT_BASE_PORT + 1)),127.0.0.1:$((CLIENT_BASE_PORT + 2)),127.0.0.1:$((CLIENT_BASE_PORT + 3))"

ensure_under_root() {
  local path="$1"
  local root="$2"
  case "${path}" in
    "${root}"/*) ;;
    *) echo "ERROR: refusing to use path outside ${root}: ${path}" >&2; exit 1 ;;
  esac
}

stop_pid() {
  local pid="$1"
  [[ -n "${pid}" ]] || return 0
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" || true
    for _ in $(seq 1 30); do
      ! kill -0 "${pid}" 2>/dev/null && return 0
      sleep 0.2
    done
    kill -9 "${pid}" || true
  fi
}

cleanup() {
  mkdir -p "${REPORT_DIR}/node_logs"
  local log_file pid_file
  for log_file in "${NODE_LOG_DIR}"/node*.log; do
    [[ -f "${log_file}" ]] && cp "${log_file}" "${REPORT_DIR}/node_logs/" || true
  done
  for pid_file in "${PID_DIR}"/node*.pid; do
    [[ -f "${pid_file}" ]] && stop_pid "$(cat "${pid_file}")"
  done
}

trap cleanup EXIT
trap 'exit 130' INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

node_client_addr() {
  echo "127.0.0.1:$((CLIENT_BASE_PORT + $1))"
}

status_value() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key {print $2; exit}'
}

client_cmd() {
  "${CLIENT}" --servers="${CLIENT_SERVERS}" --timeout_ms=1000 --retries=10 "$@"
}

node_status() {
  local id="$1"
  "${CLIENT}" --servers="$(node_client_addr "${id}")" --timeout_ms=1000 --retries=1 status
}

write_config() {
  local id="$1"
  local data_dir="${CLUSTER_DATA_DIR}/node${id}"
  cat >"${CONFIG_DIR}/node${id}.yaml" <<EOF
node_id: ${id}
listen_addr: 127.0.0.1:$((RAFT_BASE_PORT + id))
client_addr: 127.0.0.1:$((CLIENT_BASE_PORT + id))
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
  max_log_entries: ${SNAPSHOT_MAX_LOG_ENTRIES}
  snapshot_dir: ${data_dir}

raft:
  election_timeout_ms_min: 300
  election_timeout_ms_max: 600
  heartbeat_interval_ms: 100
  rpc_timeout_ms: 300
  pre_vote: true
  check_quorum: true

read:
  mode: read_index
EOF
}

start_node() {
  local id="$1"
  local log_file="${NODE_LOG_DIR}/node${id}.log"
  "${SERVER}" --config="${CONFIG_DIR}/node${id}.yaml" >"${log_file}" 2>&1 &
  echo "$!" >"${PID_DIR}/node${id}.pid"
}

wait_for_leader() {
  local previous="${1:-}"
  local out leader
  for _ in $(seq 1 60); do
    out="$(client_cmd leader 2>/dev/null || true)"
    leader="$(awk '{print $1}' <<<"${out}")"
    if [[ "${leader}" =~ ^[1-3]$ ]] && [[ -z "${previous}" || "${leader}" != "${previous}" ]]; then
      echo "${leader}"
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_snapshot() {
  local id snapshot_index
  for _ in $(seq 1 40); do
    for id in 1 2 3; do
      snapshot_index="$(node_status "${id}" 2>/dev/null | status_value snapshot_index || true)"
      [[ "${snapshot_index}" =~ ^[1-9][0-9]*$ ]] && return 0
    done
    sleep 1
  done
  return 1
}

wait_for_value() {
  local key="$1"
  local expected="$2"
  local actual=""
  for _ in $(seq 1 30); do
    actual="$(client_cmd get "${key}" 2>/dev/null || true)"
    [[ "${actual}" == "${expected}" ]] && return 0
    sleep 1
  done
  echo "last_value=${actual}" >"${REPORT_DIR}/last_error.txt"
  return 1
}

ensure_under_root "${RUN_DIR}" "${TEST_DATA_ROOT}"
ensure_under_root "${REPORT_DIR}" "${TEST_REPORT_ROOT}"
mkdir -p "${CONFIG_DIR}" "${PID_DIR}" "${NODE_LOG_DIR}" "${REPORT_DIR}"

cd "${ROOT_DIR}"
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT=ON
cmake --build "${BUILD_DIR}" -j"${BUILD_JOBS}" --target kv_server kv_client

for id in 1 2 3; do
  write_config "${id}"
  start_node "${id}"
done

leader="$(wait_for_leader)" || fail "leader was not elected"
client_cmd put ri_key v1 >/dev/null || fail "initial put failed"
wait_for_value ri_key v1 || fail "ReadIndex get did not return initial value"

leader_status_before="$(node_status "${leader}")"
wal_before="$(status_value wal_bytes <<<"${leader_status_before}")"
log_before="$(status_value log_entry_count <<<"${leader_status_before}")"
for _ in $(seq 1 5); do
  [[ "$(client_cmd get ri_key)" == "v1" ]] || fail "repeated ReadIndex get returned wrong value"
done
leader_status_after="$(node_status "${leader}")"
wal_after="$(status_value wal_bytes <<<"${leader_status_after}")"
log_after="$(status_value log_entry_count <<<"${leader_status_after}")"
[[ "${wal_before}" == "${wal_after}" ]] || fail "ReadIndex get changed wal_bytes: ${wal_before} -> ${wal_after}"
[[ "${log_before}" == "${log_after}" ]] || fail "ReadIndex get changed log_entry_count: ${log_before} -> ${log_after}"

follower=1
[[ "${leader}" != "1" ]] || follower=2
if "${CLIENT}" --servers="$(node_client_addr "${follower}")" --timeout_ms=1000 --retries=1 get ri_key \
  >"${REPORT_DIR}/follower_read.out" 2>"${REPORT_DIR}/follower_read.err"; then
  fail "follower ReadIndex unexpectedly succeeded"
fi
grep -q "leader hint" "${REPORT_DIR}/follower_read.err" || fail "follower ReadIndex did not return leader hint"

other1=1
other2=2
if [[ "${leader}" == "1" ]]; then
  other1=2
  other2=3
elif [[ "${leader}" == "2" ]]; then
  other1=1
  other2=3
fi
stop_pid "$(cat "${PID_DIR}/node${other1}.pid")"
stop_pid "$(cat "${PID_DIR}/node${other2}.pid")"
if "${CLIENT}" --servers="$(node_client_addr "${leader}")" --timeout_ms=1000 --retries=1 get ri_key \
  >"${REPORT_DIR}/minority_read.out" 2>"${REPORT_DIR}/minority_read.err"; then
  fail "minority Leader ReadIndex unexpectedly succeeded"
fi

start_node "${other1}"
start_node "${other2}"
leader="$(wait_for_leader)" || fail "leader was not restored"
client_cmd put ri_key v2 >/dev/null || fail "post-restore barrier put failed"
wait_for_value ri_key v2 || fail "ReadIndex get did not return post-restore value"

old_leader="${leader}"
stop_pid "$(cat "${PID_DIR}/node${old_leader}.pid")"
new_leader="$(wait_for_leader "${old_leader}")" || fail "new leader was not elected"
client_cmd put ri_key v3 >/dev/null || fail "post-failover barrier put failed"
wait_for_value ri_key v3 || fail "ReadIndex get did not return post-failover value"
start_node "${old_leader}"

for i in $(seq 1 20); do
  client_cmd put "snap_${i}" "value_${i}" >/dev/null || fail "snapshot put ${i} failed"
done
wait_for_snapshot || fail "snapshot_index did not advance"
wait_for_value ri_key v3 || fail "ReadIndex get failed after snapshot"

capture="${REPORT_DIR}/status_after.txt"
: >"${capture}"
for id in 1 2 3; do
  echo "===== node${id} =====" >>"${capture}"
  node_status "${id}" >>"${capture}" 2>/dev/null || echo "UNAVAILABLE" >>"${capture}"
done

grep -q "read_index_success=" "${capture}" || fail "read_index metrics missing from status"
echo "READ INDEX TEST PASSED"
