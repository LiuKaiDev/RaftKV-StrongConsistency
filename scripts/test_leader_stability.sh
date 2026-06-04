#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DATA_ROOT="${TEST_DATA_ROOT:-/tmp/raftkv-test-data}"
TEST_REPORT_ROOT="${TEST_REPORT_ROOT:-/tmp/raftkv-test-reports}"
RUN_ID="${RUN_ID:-leader-stability-$(date +%Y%m%d-%H%M%S)-$$}"
RUN_DIR="${TEST_DATA_ROOT}/${RUN_ID}"
CLUSTER_DATA_DIR="${RUN_DIR}/leader-stability"
CONFIG_DIR="${CLUSTER_DATA_DIR}/config"
PID_DIR="${CLUSTER_DATA_DIR}/pids"
NODE_LOG_DIR="${CLUSTER_DATA_DIR}/logs"
REPORT_DIR="${TEST_REPORT_ROOT}/${RUN_ID}/leader-stability"
BUILD_DIR="${ROOT_DIR}/build/raft"
BUILD_JOBS="${BUILD_JOBS:-1}"
PORT_OFFSET="${PORT_OFFSET:-$((($$ % 1000) * 20))}"
RAFT_BASE_PORT="${RAFT_BASE_PORT:-$((40000 + PORT_OFFSET))}"
CLIENT_BASE_PORT="${CLIENT_BASE_PORT:-$((41000 + PORT_OFFSET))}"
SNAPSHOT_MAX_LOG_ENTRIES="${SNAPSHOT_MAX_LOG_ENTRIES:-12}"
CLIENT="${ROOT_DIR}/bin/kv_client"
SERVER="${ROOT_DIR}/bin/kv_server"
CLIENT_SERVERS="127.0.0.1:$((CLIENT_BASE_PORT + 1)),127.0.0.1:$((CLIENT_BASE_PORT + 2)),127.0.0.1:$((CLIENT_BASE_PORT + 3))"
CURRENT_STEP="init"
LAST_ERROR_FILE="${REPORT_DIR}/last_error.txt"
SUMMARY_FILE="${REPORT_DIR}/summary.txt"

ensure_under_root() {
  local path="$1"
  local root="$2"
  case "${path}" in
    "${root}"/*) ;;
    *) echo "ERROR: refusing path outside ${root}: ${path}" >&2; exit 1 ;;
  esac
}

process_running() {
  local pid="$1"
  local stat=""
  stat="$(ps -p "${pid}" -o stat= 2>/dev/null || true)"
  [[ -n "${stat}" && "${stat}" != Z* ]]
}

stop_pid() {
  local pid="$1"
  [[ -n "${pid}" ]] || return 0
  if process_running "${pid}"; then
    kill "${pid}" || true
    for _ in $(seq 1 30); do
      ! process_running "${pid}" && return 0
      sleep 0.2
    done
    kill -9 "${pid}" || true
  fi
}

capture_status() {
  local out="$1"
  : >"${out}"
  local id
  for id in 1 2 3; do
    {
      echo "===== node${id} ====="
      "${CLIENT}" --servers="$(node_client_addr "${id}")" --timeout_ms=1000 --retries=1 status || echo "UNAVAILABLE"
      echo
    } >>"${out}"
  done
}

copy_logs() {
  mkdir -p "${REPORT_DIR}/node_logs"
  local log_file
  for log_file in "${NODE_LOG_DIR}"/node*.log; do
    [[ -f "${log_file}" ]] && cp "${log_file}" "${REPORT_DIR}/node_logs/" || true
  done
}

write_summary() {
  {
    echo "run_id=${RUN_ID}"
    echo "current_step=${CURRENT_STEP}"
    echo "report_dir=${REPORT_DIR}"
    echo "data_dir=${RUN_DIR}"
    echo "replay_command=RUN_ID=${RUN_ID} RAFT_BASE_PORT=${RAFT_BASE_PORT} CLIENT_BASE_PORT=${CLIENT_BASE_PORT} bash scripts/test_leader_stability.sh"
    echo "last_error=$(cat "${LAST_ERROR_FILE}" 2>/dev/null || true)"
  } >"${SUMMARY_FILE}"
}

cleanup() {
  capture_status "${REPORT_DIR}/status_on_exit.txt" || true
  copy_logs || true
  write_summary || true
  local pid_file
  for pid_file in "${PID_DIR}"/node*.pid; do
    [[ -f "${pid_file}" ]] && stop_pid "$(cat "${pid_file}")"
  done
}

trap cleanup EXIT
trap 'exit 130' INT TERM

fail() {
  echo "$*" >"${LAST_ERROR_FILE}"
  echo "FAIL: $*" >&2
  exit 1
}

set_step() {
  CURRENT_STEP="$1"
  echo "step=${CURRENT_STEP}"
}

node_client_addr() { echo "127.0.0.1:$((CLIENT_BASE_PORT + $1))"; }

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
  for _ in $(seq 1 70); do
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

wait_noop_barrier() {
  local id="$1"
  local status committed appended commit last_log
  for _ in $(seq 1 50); do
    status="$(node_status "${id}" 2>/dev/null || true)"
    appended="$(status_value leader_noop_appended <<<"${status}")"
    committed="$(status_value leader_noop_committed <<<"${status}")"
    commit="$(status_value commit_index <<<"${status}")"
    last_log="$(status_value last_log_index <<<"${status}")"
    if [[ "${appended}" =~ ^[1-9][0-9]*$ && "${committed}" =~ ^[1-9][0-9]*$ &&
          "${commit}" =~ ^[0-9]+$ && "${last_log}" =~ ^[0-9]+$ && "${commit}" -ge 1 ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_value() {
  local key="$1"
  local expected="$2"
  local actual
  for _ in $(seq 1 40); do
    actual="$(client_cmd get "${key}" 2>/dev/null || true)"
    [[ "${actual}" == "${expected}" ]] && return 0
    sleep 1
  done
  return 1
}

ensure_under_root "${RUN_DIR}" "${TEST_DATA_ROOT}"
ensure_under_root "${REPORT_DIR}" "${TEST_REPORT_ROOT}"
mkdir -p "${CONFIG_DIR}" "${PID_DIR}" "${NODE_LOG_DIR}" "${REPORT_DIR}"
cd "${ROOT_DIR}"

set_step "build"
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT=ON
cmake --build "${BUILD_DIR}" -j"${BUILD_JOBS}" --target kv_server kv_client

set_step "start_cluster"
for id in 1 2 3; do
  write_config "${id}"
  start_node "${id}"
done

leader="$(wait_for_leader)" || fail "leader was not elected"
wait_noop_barrier "${leader}" || fail "leader no-op barrier did not commit"
capture_status "${REPORT_DIR}/status_after_initial_noop.txt"

set_step "read_index_without_business_write"
if client_cmd get missing_key >"${REPORT_DIR}/missing_get.out" 2>"${REPORT_DIR}/missing_get.err"; then
  fail "missing-key ReadIndex unexpectedly succeeded"
fi
grep -q "KEY_NOT_FOUND" "${REPORT_DIR}/missing_get.err" || fail "ReadIndex before business write did not reach KV state machine"

leader_status="$(node_status "${leader}")"
noop_log_count="$(status_value log_entry_count <<<"${leader_status}")"
[[ "${noop_log_count}" =~ ^[1-9][0-9]*$ ]] || fail "leader log does not contain no-op"
"${CLIENT}" --servers="$(node_client_addr "${leader}")" dump >"${REPORT_DIR}/leader_dump_after_noop.txt"
[[ ! -s "${REPORT_DIR}/leader_dump_after_noop.txt" ]] || fail "no-op polluted KV dump"

set_step "failover_read_index"
client_cmd put stable_key stable_value >/dev/null || fail "initial put failed"
wait_value stable_key stable_value || fail "initial value not readable"
old_leader="${leader}"
stop_pid "$(cat "${PID_DIR}/node${old_leader}.pid")"
new_leader="$(wait_for_leader "${old_leader}")" || fail "new leader was not elected"
wait_noop_barrier "${new_leader}" || fail "new leader no-op barrier did not commit"
wait_value stable_key stable_value || fail "ReadIndex after failover did not return latest value"
start_node "${old_leader}"
sleep 2

set_step "prevote_stability"
follower=1
[[ "${new_leader}" != "1" ]] || follower=2
term_before="$(status_value current_term <<<"$(node_status "${new_leader}")")"
stop_pid "$(cat "${PID_DIR}/node${follower}.pid")"
sleep 3
start_node "${follower}"
sleep 3
term_after="$(status_value current_term <<<"$(node_status "${new_leader}")")"
[[ "${term_after}" =~ ^[0-9]+$ && "${term_before}" =~ ^[0-9]+$ ]] || fail "invalid term around PreVote scenario"
[[ "${term_after}" -le $((term_before + 1)) ]] || fail "term jumped unexpectedly with PreVote enabled: ${term_before} -> ${term_after}"
client_cmd put prevote_key ok >/dev/null || fail "cluster did not serve write after PreVote scenario"

set_step "check_quorum"
leader="$(wait_for_leader)" || fail "leader missing before CheckQuorum"
peer1=1
peer2=2
if [[ "${leader}" == "1" ]]; then
  peer1=2
  peer2=3
elif [[ "${leader}" == "2" ]]; then
  peer1=1
  peer2=3
fi
stop_pid "$(cat "${PID_DIR}/node${peer1}.pid")"
stop_pid "$(cat "${PID_DIR}/node${peer2}.pid")"
sleep 3
old_status="$(node_status "${leader}" 2>/dev/null || true)"
old_role="$(status_value role <<<"${old_status}")"
if [[ "${old_role}" == "LEADER" ]]; then
  if "${CLIENT}" --servers="$(node_client_addr "${leader}")" --timeout_ms=1000 --retries=1 put cq_key value \
    >"${REPORT_DIR}/minority_put.out" 2>"${REPORT_DIR}/minority_put.err"; then
    fail "old leader accepted write without quorum"
  fi
fi
if "${CLIENT}" --servers="$(node_client_addr "${leader}")" --timeout_ms=1000 --retries=1 get stable_key \
  >"${REPORT_DIR}/minority_read.out" 2>"${REPORT_DIR}/minority_read.err"; then
  fail "old leader served ReadIndex without quorum"
fi

start_node "${peer1}"
start_node "${peer2}"
leader="$(wait_for_leader)" || fail "leader not restored after CheckQuorum"
wait_noop_barrier "${leader}" || fail "restored leader no-op barrier did not commit"
client_cmd put final_key final_value >/dev/null || fail "final write failed"
wait_value final_key final_value || fail "final read failed"

capture_status "${REPORT_DIR}/status_final.txt"
echo "LEADER STABILITY TEST PASSED"
