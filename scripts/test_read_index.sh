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
CLIENT_TIMEOUT_MS="${CLIENT_TIMEOUT_MS:-1000}"
CLIENT="${ROOT_DIR}/bin/kv_client"
SERVER="${ROOT_DIR}/bin/kv_server"
CLIENT_SERVERS="127.0.0.1:$((CLIENT_BASE_PORT + 1)),127.0.0.1:$((CLIENT_BASE_PORT + 2)),127.0.0.1:$((CLIENT_BASE_PORT + 3))"
CURRENT_STEP="init"
LAST_REQUEST=""
LAST_RESPONSE=""
LAST_DISCOVERED_LEADER=""
LAST_ALIVE_NODES=""
RETRY_COUNT=0
NEXT_REQUEST_ID=1000
CLIENT_ID="test_read_index_${RUN_ID}"
LAST_ERROR_FILE="${REPORT_DIR}/last_error.txt"
SUMMARY_FILE="${REPORT_DIR}/summary.txt"
DIAG_DIR="${REPORT_DIR}/diagnostics"

ensure_under_root() {
  local path="$1"
  local root="$2"
  case "${path}" in
    "${root}"/*) ;;
    *) echo "ERROR: refusing to use path outside ${root}: ${path}" >&2; exit 1 ;;
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

node_client_addr() {
  echo "127.0.0.1:$((CLIENT_BASE_PORT + $1))"
}

status_value() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key {print $2; exit}'
}

node_status() {
  local id="$1"
  "${CLIENT}" --servers="$(node_client_addr "${id}")" --timeout_ms="${CLIENT_TIMEOUT_MS}" --retries=1 status
}

client_cmd() {
  "${CLIENT}" --servers="${CLIENT_SERVERS}" --timeout_ms="${CLIENT_TIMEOUT_MS}" --retries=10 "$@"
}

client_cmd_node() {
  local id="$1"
  shift
  "${CLIENT}" --servers="$(node_client_addr "${id}")" --timeout_ms="${CLIENT_TIMEOUT_MS}" --retries=1 "$@"
}

capture_status() {
  local output_file="$1"
  mkdir -p "$(dirname "${output_file}")"
  : >"${output_file}"
  local id
  LAST_ALIVE_NODES=""
  for id in 1 2 3; do
    {
      echo "===== node${id} ====="
      if node_status "${id}"; then
        LAST_ALIVE_NODES="${LAST_ALIVE_NODES} ${id}"
      else
        echo "UNAVAILABLE"
      fi
      echo
    } >>"${output_file}"
  done
}

copy_logs() {
  mkdir -p "${REPORT_DIR}/node_logs" "${DIAG_DIR}"
  local log_file base
  for log_file in "${NODE_LOG_DIR}"/node*.log; do
    if [[ -f "${log_file}" ]]; then
      cp "${log_file}" "${REPORT_DIR}/node_logs/" || true
      base="$(basename "${log_file}")"
      tail -n 240 "${log_file}" >"${DIAG_DIR}/${base}.tail" || true
    fi
  done
}

write_summary() {
  {
    echo "run_id=${RUN_ID}"
    echo "current_step=${CURRENT_STEP}"
    echo "report_dir=${REPORT_DIR}"
    echo "data_dir=${RUN_DIR}"
    echo "replay_command=RUN_ID=${RUN_ID} RAFT_BASE_PORT=${RAFT_BASE_PORT} CLIENT_BASE_PORT=${CLIENT_BASE_PORT} bash scripts/test_read_index.sh"
    echo "last_error=$(cat "${LAST_ERROR_FILE}" 2>/dev/null || true)"
    echo "last_request=${LAST_REQUEST}"
    echo "last_response=${LAST_RESPONSE}"
    echo "last_discovered_leader=${LAST_DISCOVERED_LEADER}"
    echo "alive_nodes=${LAST_ALIVE_NODES}"
    echo "retry_count=${RETRY_COUNT}"
  } >"${SUMMARY_FILE}"
}

write_failure_diagnostics() {
  mkdir -p "${DIAG_DIR}"
  {
    echo "current_step=${CURRENT_STEP}"
    echo "last_request=${LAST_REQUEST}"
    echo "last_response=${LAST_RESPONSE}"
    echo "last_discovered_leader=${LAST_DISCOVERED_LEADER}"
    echo "alive_nodes=${LAST_ALIVE_NODES}"
    echo "retry_count=${RETRY_COUNT}"
    echo "replay_command=RUN_ID=${RUN_ID} RAFT_BASE_PORT=${RAFT_BASE_PORT} CLIENT_BASE_PORT=${CLIENT_BASE_PORT} bash scripts/test_read_index.sh"
  } >"${DIAG_DIR}/failure_context.txt"
  capture_status "${DIAG_DIR}/status_of_each_node.txt" || true
  copy_logs || true
  write_summary || true
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
  mkdir -p "${REPORT_DIR}"
  echo "$*" >"${LAST_ERROR_FILE}"
  write_failure_diagnostics || true
  echo "FAIL: $*" >&2
  exit 1
}

set_step() {
  CURRENT_STEP="$1"
  echo "step=${CURRENT_STEP}"
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

wait_node_unavailable() {
  local id="$1"
  local pid_file="${PID_DIR}/node${id}.pid"
  local pid=""
  [[ -f "${pid_file}" ]] && pid="$(cat "${pid_file}")"
  for _ in $(seq 1 50); do
    if { [[ -z "${pid}" ]] || ! process_running "${pid}"; } && ! node_status "${id}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

discover_leader() {
  local previous="${1:-}"
  local id out role node_id leader="" leader_count=0
  local snapshot_file="${REPORT_DIR}/last_discover_leader_status.txt"
  capture_status "${snapshot_file}" || true
  for id in 1 2 3; do
    out="$(awk -v node="===== node${id} =====" '
      $0 == node {inside=1; next}
      /^===== node/ {inside=0}
      inside {print}
    ' "${snapshot_file}")"
    role="$(status_value role <<<"${out}")"
    node_id="$(status_value node_id <<<"${out}")"
    if [[ "${role}" == "LEADER" && "${node_id}" =~ ^[1-3]$ ]]; then
      leader="${node_id}"
      leader_count=$((leader_count + 1))
    fi
  done
  if [[ "${leader_count}" -eq 1 && ( -z "${previous}" || "${leader}" != "${previous}" ) ]]; then
    LAST_DISCOVERED_LEADER="${leader}"
    echo "${leader}"
    return 0
  fi
  return 1
}

wait_for_stable_leader() {
  local previous="${1:-}"
  local leader status role noop_committed commit_index last_applied last_log_index current_term
  local stable_leader="" stable_seen=0
  for _ in $(seq 1 90); do
    leader="$(discover_leader "${previous}" 2>/dev/null || true)"
    if [[ "${leader}" =~ ^[1-3]$ ]]; then
      status="$(node_status "${leader}" 2>/dev/null || true)"
      role="$(status_value role <<<"${status}")"
      noop_committed="$(status_value leader_noop_committed <<<"${status}")"
      commit_index="$(status_value commit_index <<<"${status}")"
      last_applied="$(status_value last_applied <<<"${status}")"
      last_log_index="$(status_value last_log_index <<<"${status}")"
      current_term="$(status_value current_term <<<"${status}")"
      if [[ "${role}" == "LEADER" &&
            "${noop_committed}" =~ ^[0-9]+$ && "${noop_committed}" -gt 0 &&
            "${commit_index}" =~ ^[0-9]+$ &&
            "${last_applied}" =~ ^[0-9]+$ &&
            "${last_log_index}" =~ ^[0-9]+$ &&
            "${current_term}" =~ ^[0-9]+$ &&
            "${commit_index}" -ge 1 &&
            "${last_log_index}" -ge "${commit_index}" &&
            "${last_applied}" -ge "${commit_index}" ]]; then
        if [[ "${leader}" == "${stable_leader}" ]]; then
          stable_seen=$((stable_seen + 1))
        else
          stable_leader="${leader}"
          stable_seen=1
        fi
        if [[ "${stable_seen}" -ge 3 ]]; then
          LAST_DISCOVERED_LEADER="${leader}"
          echo "${leader}"
          return 0
        fi
      else
        stable_leader=""
        stable_seen=0
      fi
    else
      stable_leader=""
      stable_seen=0
    fi
    sleep 1
  done
  capture_status "${REPORT_DIR}/stable_leader_timeout_status.txt" || true
  return 1
}

leader_from_hint() {
  local text="$1"
  if [[ "${text}" =~ leader[[:space:]]hint:[[:space:]]([1-3]) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

alive_nodes() {
  local out="" id
  LAST_ALIVE_NODES=""
  for id in 1 2 3; do
    if node_status "${id}" >/dev/null 2>&1; then
      [[ -n "${out}" ]] && out+=" "
      out+="${id}"
    fi
  done
  LAST_ALIVE_NODES="${out}"
  echo "${out}"
}

retry_write_to_leader() {
  local key="$1"
  local value="$2"
  local label="$3"
  local request_id="${NEXT_REQUEST_ID}"
  NEXT_REQUEST_ID=$((NEXT_REQUEST_ID + 1))
  local leader="${LAST_DISCOVERED_LEADER}"
  local attempt target stdout stderr rc hinted alive
  mkdir -p "${DIAG_DIR}"
  for attempt in $(seq 1 90); do
    RETRY_COUNT="${attempt}"
    if [[ ! "${leader}" =~ ^[1-3]$ ]]; then
      leader="$(discover_leader 2>/dev/null || true)"
    fi
    if [[ "${leader}" =~ ^[1-3]$ ]]; then
      target="${leader}"
    else
      alive="$(alive_nodes)"
      target="$(awk '{print $1}' <<<"${alive}")"
      [[ "${target}" =~ ^[1-3]$ ]] || target="$(( (attempt - 1) % 3 + 1 ))"
    fi

    LAST_REQUEST="${label}: put ${key} ${value} client_id=${CLIENT_ID} request_id=${request_id}"
    local stdout_file="${DIAG_DIR}/${label}_attempt_${attempt}_stdout.txt"
    local stderr_file="${DIAG_DIR}/${label}_attempt_${attempt}_stderr.txt"
    set +e
    stdout="$("${CLIENT}" --servers="$(node_client_addr "${target}")" \
      --client_id="${CLIENT_ID}" --request_id="${request_id}" \
      --timeout_ms="${CLIENT_TIMEOUT_MS}" --retries=1 \
      put "${key}" "${value}" >"${stdout_file}" 2>"${stderr_file}")"
    rc=$?
    set -e
    stdout="$(cat "${stdout_file}" 2>/dev/null || true)"
    stderr="$(cat "${stderr_file}" 2>/dev/null || true)"
    LAST_RESPONSE="target=node${target} rc=${rc} stdout=${stdout} stderr=${stderr}"
    if [[ "${rc}" -eq 0 && "${stdout}" == "OK" ]]; then
      LAST_DISCOVERED_LEADER="${target}"
      return 0
    fi

    hinted="$(leader_from_hint "${stdout} ${stderr}" 2>/dev/null || true)"
    if [[ "${hinted}" =~ ^[1-3]$ ]]; then
      leader="${hinted}"
      LAST_DISCOVERED_LEADER="${leader}"
    else
      leader="$(discover_leader 2>/dev/null || true)"
    fi
    sleep 0.5
  done
  capture_status "${REPORT_DIR}/${label}_retry_exhausted_status.txt" || true
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
  for _ in $(seq 1 40); do
    actual="$(client_cmd get "${key}" 2>/dev/null || true)"
    [[ "${actual}" == "${expected}" ]] && return 0
    sleep 1
  done
  echo "last_value=${actual}" >"${LAST_ERROR_FILE}"
  return 1
}

ensure_under_root "${RUN_DIR}" "${TEST_DATA_ROOT}"
ensure_under_root "${REPORT_DIR}" "${TEST_REPORT_ROOT}"
mkdir -p "${CONFIG_DIR}" "${PID_DIR}" "${NODE_LOG_DIR}" "${REPORT_DIR}" "${DIAG_DIR}"

cd "${ROOT_DIR}"
set_step "build"
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT=ON
cmake --build "${BUILD_DIR}" -j"${BUILD_JOBS}" --target kv_server kv_client

set_step "start_cluster"
for id in 1 2 3; do
  write_config "${id}"
  start_node "${id}"
done

set_step "initial_leader"
leader="$(wait_for_stable_leader)" || fail "leader was not elected"
retry_write_to_leader ri_key v1 initial_put || fail "initial put failed"
wait_for_value ri_key v1 || fail "ReadIndex get did not return initial value"

leader_status_before="$(node_status "${leader}")"
wal_before="$(status_value wal_bytes <<<"${leader_status_before}")"
log_before="$(status_value log_entry_count <<<"${leader_status_before}")"
set_step "repeated_read_index_get"
for _ in $(seq 1 5); do
  [[ "$(client_cmd get ri_key)" == "v1" ]] || fail "repeated ReadIndex get returned wrong value"
done
leader_status_after="$(node_status "${leader}")"
wal_after="$(status_value wal_bytes <<<"${leader_status_after}")"
log_after="$(status_value log_entry_count <<<"${leader_status_after}")"
[[ "${wal_before}" == "${wal_after}" ]] || fail "ReadIndex get changed wal_bytes: ${wal_before} -> ${wal_after}"
[[ "${log_before}" == "${log_after}" ]] || fail "ReadIndex get changed log_entry_count: ${log_before} -> ${log_after}"

set_step "follower_read_rejected"
follower=1
[[ "${leader}" != "1" ]] || follower=2
if "${CLIENT}" --servers="$(node_client_addr "${follower}")" --timeout_ms="${CLIENT_TIMEOUT_MS}" --retries=1 get ri_key \
  >"${REPORT_DIR}/follower_read.out" 2>"${REPORT_DIR}/follower_read.err"; then
  fail "follower ReadIndex unexpectedly succeeded"
fi
grep -q "leader hint" "${REPORT_DIR}/follower_read.err" || fail "follower ReadIndex did not return leader hint"

set_step "minority_read_rejected"
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
wait_node_unavailable "${other1}" || fail "node${other1} did not stop"
wait_node_unavailable "${other2}" || fail "node${other2} did not stop"
if "${CLIENT}" --servers="$(node_client_addr "${leader}")" --timeout_ms="${CLIENT_TIMEOUT_MS}" --retries=1 get ri_key \
  >"${REPORT_DIR}/minority_read.out" 2>"${REPORT_DIR}/minority_read.err"; then
  fail "minority Leader ReadIndex unexpectedly succeeded"
fi

set_step "restore_majority"
start_node "${other1}"
start_node "${other2}"
leader="$(wait_for_stable_leader)" || fail "leader was not restored"
retry_write_to_leader ri_key v2 post_restore_put || fail "post-restore barrier put failed"
wait_for_value ri_key v2 || fail "ReadIndex get did not return post-restore value"

set_step "leader_failover"
old_leader="${leader}"
stop_pid "$(cat "${PID_DIR}/node${old_leader}.pid")"
wait_node_unavailable "${old_leader}" || fail "old leader node${old_leader} did not stop"
new_leader="$(wait_for_stable_leader "${old_leader}")" || fail "new leader was not elected"
leader="${new_leader}"
retry_write_to_leader ri_key v3 post_failover_put || fail "post-failover barrier put failed"
wait_for_value ri_key v3 || fail "ReadIndex get did not return post-failover value"
start_node "${old_leader}"
leader="$(wait_for_stable_leader)" || fail "leader was not stable after old leader restart"

set_step "snapshot_read_index"
for i in $(seq 1 20); do
  retry_write_to_leader "snap_${i}" "value_${i}" "snapshot_put_${i}" || fail "snapshot put ${i} failed"
done
wait_for_snapshot || fail "snapshot_index did not advance"
wait_for_value ri_key v3 || fail "ReadIndex get failed after snapshot"

capture="${REPORT_DIR}/status_after.txt"
capture_status "${capture}"

grep -q "read_index_success=" "${capture}" || fail "read_index metrics missing from status"
echo "READ INDEX TEST PASSED"
