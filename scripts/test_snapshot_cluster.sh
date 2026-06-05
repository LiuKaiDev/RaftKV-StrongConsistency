#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DATA_ROOT="${TEST_DATA_ROOT:-/tmp/raftkv-test-data}"
TEST_REPORT_ROOT="${TEST_REPORT_ROOT:-/tmp/raftkv-test-reports}"
RUN_ID="${RUN_ID:-snapshot-cluster-$(date +%Y%m%d-%H%M%S)-$$}"
RUN_DIR="${TEST_DATA_ROOT}/${RUN_ID}"
CLUSTER_DATA_DIR="${RUN_DIR}/snapshot-cluster"
CONFIG_DIR="${CLUSTER_DATA_DIR}/config"
PID_DIR="${CLUSTER_DATA_DIR}/pids"
NODE_LOG_DIR="${CLUSTER_DATA_DIR}/logs"
REPORT_DIR="${TEST_REPORT_ROOT}/${RUN_ID}/snapshot-cluster"
BUILD_DIR="${ROOT_DIR}/build/raft"
BUILD_JOBS="${BUILD_JOBS:-1}"
PORT_OFFSET="${PORT_OFFSET:-$((($$ % 1000) * 20))}"
RAFT_BASE_PORT="${RAFT_BASE_PORT:-$((22000 + PORT_OFFSET))}"
CLIENT_BASE_PORT="${CLIENT_BASE_PORT:-$((23000 + PORT_OFFSET))}"
SNAPSHOT_MAX_LOG_ENTRIES="${SNAPSHOT_MAX_LOG_ENTRIES:-5}"
SNAPSHOT_WORKLOAD_COUNT="${SNAPSHOT_WORKLOAD_COUNT:-40}"
CLIENT_TIMEOUT_MS="${CLIENT_TIMEOUT_MS:-2000}"
CLIENT_RETRIES="${CLIENT_RETRIES:-20}"
CLIENT_COMMAND_ATTEMPTS="${CLIENT_COMMAND_ATTEMPTS:-60}"
CLIENT_COMMAND_RETRY_SLEEP="${CLIENT_COMMAND_RETRY_SLEEP:-1}"
INTERRUPT_ABORT_CHUNKS="${INTERRUPT_ABORT_CHUNKS:-1}"
CLIENT_SERVERS="127.0.0.1:$((CLIENT_BASE_PORT + 1)),127.0.0.1:$((CLIENT_BASE_PORT + 2)),127.0.0.1:$((CLIENT_BASE_PORT + 3))"
CLIENT="${ROOT_DIR}/bin/kv_client"
SERVER="${ROOT_DIR}/bin/kv_server"
LAST_ERROR_FILE="${REPORT_DIR}/last_error.txt"
CLIENT_ATTEMPT_LOG="${REPORT_DIR}/client_attempts.log"
FAILURE_CONTEXT_FILE="${REPORT_DIR}/failure_context.txt"
CURRENT_STEP="initializing"
declare -A NODE_START_LOG_LINE=()

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

record_error() {
  mkdir -p "${REPORT_DIR}"
  printf '%s\n' "$*" >"${LAST_ERROR_FILE}"
  echo "ERROR: $*" >&2
}

record_node_log_tail() {
  local id="$1"
  local log_file="${NODE_LOG_DIR}/node${id}.log"
  local tail_file="${REPORT_DIR}/node${id}_last_log_tail.txt"
  if [[ -f "${log_file}" ]]; then
    tail -n 120 "${log_file}" >"${tail_file}" || true
  fi
}

record_all_node_log_tails() {
  local id
  for id in 1 2 3; do
    record_node_log_tail "${id}"
  done
}

set_step() {
  CURRENT_STEP="$1"
  echo "step=${CURRENT_STEP}"
}

node_raft_port() {
  local id="$1"
  echo "$((RAFT_BASE_PORT + id))"
}

node_client_port() {
  local id="$1"
  echo "$((CLIENT_BASE_PORT + id))"
}

tcp_port_open() {
  local host="$1"
  local port="$2"
  (exec 3<>"/dev/tcp/${host}/${port}") >/dev/null 2>&1
}

process_running() {
  local pid="$1"
  local stat=""
  stat="$(ps -p "${pid}" -o stat= 2>/dev/null || true)"
  [[ -n "${stat}" && "${stat}" != Z* ]]
}

reap_pid() {
  local pid="$1"
  wait "${pid}" 2>/dev/null || true
}

raw_client_cmd_to_servers() {
  local servers="$1"
  shift
  "${CLIENT}" --servers="${servers}" --timeout_ms="${CLIENT_TIMEOUT_MS}" --retries="${CLIENT_RETRIES}" "$@"
}

write_failure_diagnostics() {
  local step="$1"
  local servers="$2"
  local request="$3"
  local status="$4"
  local stdout_text="$5"
  local stderr_text="$6"
  local leader_out=""
  leader_out="$(raw_client_cmd_to_servers "${servers}" leader 2>&1 || true)"
  {
    echo "step=${step}"
    echo "servers=${servers}"
    echo "request=${request}"
    echo "status=${status}"
    echo "leader_query=${leader_out}"
    echo "stdout=${stdout_text}"
    echo "stderr=${stderr_text}"
    echo
    echo "pids:"
    local id
    for id in 1 2 3; do
      local pid_file="${PID_DIR}/node${id}.pid"
      local pid=""
      local running="no"
      if [[ -f "${pid_file}" ]]; then
        pid="$(cat "${pid_file}")"
        if process_running "${pid}"; then
          running="yes"
        fi
      fi
      echo "node${id}: pid=${pid:-missing} running=${running}"
    done
    echo
    echo "ports:"
    for id in 1 2 3; do
      local raft_port
      local client_port
      local raft_state="closed"
      local client_state="closed"
      raft_port="$(node_raft_port "${id}")"
      client_port="$(node_client_port "${id}")"
      if tcp_port_open "127.0.0.1" "${raft_port}"; then
        raft_state="open"
      fi
      if tcp_port_open "127.0.0.1" "${client_port}"; then
        client_state="open"
      fi
      echo "node${id}: raft=127.0.0.1:${raft_port} ${raft_state}, client=127.0.0.1:${client_port} ${client_state}"
    done
  } >"${FAILURE_CONTEXT_FILE}"
  record_all_node_log_tails
}

is_transient_client_error() {
  local status="$1"
  local text="$2"
  if grep -Eiq 'NOT_LEADER|not leader|connect failed|connection refused|request failed|empty response|timed out|timeout|temporary unavailable|temporarily unavailable|unavailable|try again|broken pipe|connection reset' <<<"${text}"; then
    return 0
  fi
  [[ "${status}" -ne 0 ]] && grep -Eiq 'failed|error' <<<"${text}"
}

client_success_response_valid() {
  local op="$1"
  local text="$2"
  if grep -Eiq 'NOT_LEADER|BAD_REQUEST|TIMEOUT|INTERNAL|request failed|connect failed|connection refused|empty response|unavailable|not leader' <<<"${text}"; then
    return 1
  fi
  case "${op}" in
    put|delete)
      [[ "${text}" == "OK" ]]
      ;;
    append|get)
      [[ -n "${text}" ]]
      ;;
    dump)
      [[ -n "${text}" ]]
      ;;
    leader)
      [[ "${text}" =~ ^[1-3][[:space:]]+127\.0\.0\.1:[0-9]+$ ]]
      ;;
    *)
      [[ -n "${text}" ]]
      ;;
  esac
}

server_list_contains() {
  local servers="$1"
  local needle="$2"
  [[ -n "${needle}" && ",${servers}," == *",${needle},"* ]]
}

prefer_server() {
  local servers="$1"
  local preferred="$2"
  if ! server_list_contains "${servers}" "${preferred}"; then
    echo "${servers}"
    return 0
  fi
  local result="${preferred}"
  local server
  IFS=',' read -ra server_array <<<"${servers}"
  for server in "${server_array[@]}"; do
    if [[ "${server}" != "${preferred}" ]]; then
      result+=",${server}"
    fi
  done
  echo "${result}"
}

refresh_servers_for_leader() {
  local servers="$1"
  local out=""
  local leader_addr=""
  out="$(raw_client_cmd_to_servers "${servers}" leader 2>/dev/null || true)"
  leader_addr="$(awk '{print $2}' <<<"${out}")"
  if server_list_contains "${servers}" "${leader_addr}"; then
    echo "$(prefer_server "${servers}" "${leader_addr}")"
  else
    echo "${servers}"
  fi
}

retry_client_command() {
  local step="$1"
  local servers="$2"
  shift 2
  local original_args=("$@")
  local command_args=("$@")
  local request="$*"
  local attempt=1
  local current_servers="${servers}"
  local out=""
  local err=""
  local status=0
  local op=""
  local has_client_id=0
  local has_request_id=0
  local arg
  for arg in "${original_args[@]}"; do
    if [[ "${arg}" == --client_id=* ]]; then
      has_client_id=1
    elif [[ "${arg}" == --request_id=* ]]; then
      has_request_id=1
    elif [[ "${arg}" != --* && -z "${op}" ]]; then
      op="${arg}"
    fi
  done
  if [[ "${op}" =~ ^(put|append|delete)$ ]] &&
    [[ "${has_client_id}" -eq 0 && "${has_request_id}" -eq 0 ]]; then
    local request_token
    request_token="$(printf '%s_%s_%s_%s' "${RUN_ID}" "$$" "${BASHPID}" "${RANDOM}" |
      tr -c 'A-Za-z0-9_' '_')"
    command_args=("--client_id=snapshot_retry_${request_token}" "--request_id=1" "${original_args[@]}")
    request="${command_args[*]}"
  fi
  mkdir -p "${REPORT_DIR}"
  while [[ "${attempt}" -le "${CLIENT_COMMAND_ATTEMPTS}" ]]; do
    local err_file="${REPORT_DIR}/client_attempt_${attempt}.err"
    if out="$(raw_client_cmd_to_servers "${current_servers}" "${command_args[@]}" 2>"${err_file}")"; then
      status=0
      rm -f "${err_file}"
      if client_success_response_valid "${op}" "${out}"; then
        printf 'step=%s attempt=%s servers=%s request=%q result=success status=%s response=%q\n' \
          "${step}" "${attempt}" "${current_servers}" "${request}" "${status}" "${out}" >>"${CLIENT_ATTEMPT_LOG}"
        printf '%s\n' "${out}"
        return 0
      fi
      if [[ -z "${out}" ]]; then
        err="empty response from successful client exit for op '${op}'"
      else
        err="invalid successful response for op '${op}': ${out}"
      fi
    else
      status="$?"
      err="$(cat "${err_file}" 2>/dev/null || true)"
      rm -f "${err_file}"
    fi
    local leader_probe=""
    local leader_hint=""
    leader_probe="$(raw_client_cmd_to_servers "${current_servers}" leader 2>/dev/null || true)"
    leader_hint="$(awk '{print $2}' <<<"${leader_probe}")"
    printf 'step=%s attempt=%s servers=%s request=%q result=retryable status=%s response=%q error=%q leader_hint=%q\n' \
      "${step}" "${attempt}" "${current_servers}" "${request}" "${status}" "${out}" "${err}" "${leader_probe}" >>"${CLIENT_ATTEMPT_LOG}"
    if ! is_transient_client_error "${status}" "${out}"$'\n'"${err}"; then
      write_failure_diagnostics "${step}" "${current_servers}" "${request}" "${status}" "${out}" "${err}"
      record_error "client command failed in step '${step}': request='${request}', status=${status}, stderr='${err}', stdout='${out}'"
      return 1
    fi
    if server_list_contains "${current_servers}" "${leader_hint}"; then
      current_servers="$(prefer_server "${current_servers}" "${leader_hint}")"
    else
      current_servers="$(refresh_servers_for_leader "${current_servers}")"
    fi
    sleep "${CLIENT_COMMAND_RETRY_SLEEP}"
    attempt="$((attempt + 1))"
  done
  write_failure_diagnostics "${step}" "${current_servers}" "${request}" "${status}" "${out}" "${err}"
  record_error "client command timed out in step '${step}' after ${CLIENT_COMMAND_ATTEMPTS} attempts: request='${request}', last_status=${status}, last_stderr='${err}', last_stdout='${out}'"
  return 1
}

wait_for_process_alive() {
  local id="$1"
  local pid="$2"
  for _ in $(seq 1 25); do
    if process_running "${pid}"; then
      return 0
    fi
    reap_pid "${pid}"
    sleep 0.2
  done
  record_node_log_tail "${id}"
  record_error "node${id} process did not stay alive after start: pid=${pid}"
  return 1
}

wait_for_process_exit() {
  local pid="$1"
  local timeout_ticks="${2:-50}"
  for _ in $(seq 1 "${timeout_ticks}"); do
    if ! process_running "${pid}"; then
      reap_pid "${pid}"
      return 0
    fi
    sleep 0.2
  done
  return 1
}

wait_for_port_closed() {
  local label="$1"
  local port="$2"
  for _ in $(seq 1 50); do
    if ! tcp_port_open "127.0.0.1" "${port}"; then
      return 0
    fi
    sleep 0.2
  done
  record_error "${label} port did not close in time: 127.0.0.1:${port}"
  return 1
}

wait_for_client_port() {
  local id="$1"
  local pid="$2"
  local port
  port="$(node_client_port "${id}")"
  for _ in $(seq 1 100); do
    if ! process_running "${pid}"; then
      reap_pid "${pid}"
      record_node_log_tail "${id}"
      record_error "node${id} exited before client port opened: 127.0.0.1:${port}"
      return 1
    fi
    if tcp_port_open "127.0.0.1" "${port}"; then
      return 0
    fi
    sleep 0.2
  done
  record_node_log_tail "${id}"
  record_error "node${id} client port did not open in time: 127.0.0.1:${port}"
  return 1
}

wait_for_node_ready() {
  local id="$1"
  local pid="$2"
  local from_line="${NODE_START_LOG_LINE[${id}]:-1}"
  local log_file="${NODE_LOG_DIR}/node${id}.log"
  wait_for_client_port "${id}" "${pid}"
  for _ in $(seq 1 100); do
    if ! process_running "${pid}"; then
      reap_pid "${pid}"
      record_node_log_tail "${id}"
      record_error "node${id} exited before startup log evidence was observed"
      return 1
    fi
    if sed -n "${from_line},\$p" "${log_file}" 2>/dev/null |
      grep -Eq "KV client API listening on 127.0.0.1:$(node_client_port "${id}")"; then
      return 0
    fi
    sleep 0.2
  done
  record_node_log_tail "${id}"
  record_error "node${id} did not report KV client API readiness in time"
  return 1
}

stop_pid() {
  local pid="$1"
  if [[ -z "${pid}" ]]; then
    return 0
  fi
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" || true
    if wait_for_process_exit "${pid}" 50; then
      return 0
    fi
    if process_running "${pid}"; then
      kill -9 "${pid}" || true
      wait_for_process_exit "${pid}" 25 || true
    fi
  fi
  return 0
}

cleanup() {
  local pid_file
  for pid_file in "${PID_DIR}"/node*.pid; do
    [[ -f "${pid_file}" ]] || continue
    stop_pid "$(cat "${pid_file}")"
  done
}

on_exit() {
  local status="$?"
  set +e
  cleanup
  if [[ "${status}" -eq 0 ]]; then
    rm -f "${LAST_ERROR_FILE}"
    echo "SNAPSHOT CLUSTER PASSED"
  else
    echo "SNAPSHOT CLUSTER FAILED"
    echo "run_id=${RUN_ID}"
    echo "data_dir=${CLUSTER_DATA_DIR}"
    echo "report_dir=${REPORT_DIR}"
    echo "last_error=${LAST_ERROR_FILE}"
  fi
}

on_err() {
  local line="$1"
  local command="$2"
  set +e
  if [[ ! -s "${LAST_ERROR_FILE}" ]]; then
    record_error "command failed at line ${line}: ${command}"
  else
    echo "ERROR: command failed at line ${line}: ${command}" >&2
  fi
  return 0
}

trap on_exit EXIT
trap 'on_err "${LINENO}" "${BASH_COMMAND}"' ERR

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
  max_log_entries: ${SNAPSHOT_MAX_LOG_ENTRIES}
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
  local abort_install="${2:-0}"
  local log_file="${NODE_LOG_DIR}/node${id}.log"
  local raft_port
  local client_port
  local start_line=1
  raft_port="$(node_raft_port "${id}")"
  client_port="$(node_client_port "${id}")"
  if tcp_port_open "127.0.0.1" "${raft_port}"; then
    record_error "node${id} raft port is already open before start: 127.0.0.1:${raft_port}"
    return 1
  fi
  if tcp_port_open "127.0.0.1" "${client_port}"; then
    record_error "node${id} client port is already open before start: 127.0.0.1:${client_port}"
    return 1
  fi
  if [[ -f "${log_file}" ]]; then
    start_line="$(($(wc -l <"${log_file}") + 1))"
  fi
  NODE_START_LOG_LINE["${id}"]="${start_line}"
  printf '\n== start node%s abort_install=%s ==\n' "${id}" "${abort_install}" >>"${log_file}"
  if [[ "${abort_install}" == "1" ]]; then
    env CRAFTKV_TEST_ABORT_SNAPSHOT_INSTALL_AFTER_CHUNKS="${INTERRUPT_ABORT_CHUNKS}" \
      "${SERVER}" --config="${CONFIG_DIR}/node${id}.yaml" >>"${log_file}" 2>&1 &
  else
    env -u CRAFTKV_TEST_ABORT_SNAPSHOT_INSTALL_AFTER_CHUNKS \
      "${SERVER}" --config="${CONFIG_DIR}/node${id}.yaml" >>"${log_file}" 2>&1 &
  fi
  local pid="$!"
  echo "${pid}" >"${PID_DIR}/node${id}.pid"
  wait_for_process_alive "${id}" "${pid}"
  wait_for_node_ready "${id}" "${pid}"
  echo "started node${id}: pid=${pid}, log=${log_file}, abort_install=${abort_install}"
}

stop_node() {
  local id="$1"
  local pid_file="${PID_DIR}/node${id}.pid"
  if [[ -f "${pid_file}" ]]; then
    echo "stopping node${id}: pid=$(cat "${pid_file}")"
    stop_pid "$(cat "${pid_file}")"
    if [[ -n "$(cat "${pid_file}")" ]] && process_running "$(cat "${pid_file}")"; then
      record_error "node${id} process did not exit after stop: pid=$(cat "${pid_file}")"
      return 1
    fi
    wait_for_port_closed "node${id} raft" "$(node_raft_port "${id}")"
    wait_for_port_closed "node${id} client" "$(node_client_port "${id}")"
    rm -f "${pid_file}"
  fi
}

client_servers_except_node() {
  local excluded="$1"
  local servers=""
  local id
  for id in 1 2 3; do
    if [[ "${id}" == "${excluded}" ]]; then
      continue
    fi
    if [[ -n "${servers}" ]]; then
      servers+=","
    fi
    servers+="127.0.0.1:$(node_client_port "${id}")"
  done
  echo "${servers}"
}

client_cmd_to_servers() {
  local servers="$1"
  shift
  retry_client_command "${CURRENT_STEP}" "${servers}" "$@"
}

client_cmd() {
  client_cmd_to_servers "${CLIENT_SERVERS}" "$@"
}

client_node_cmd() {
  local id="$1"
  shift
  retry_client_command "${CURRENT_STEP}:node${id}" "127.0.0.1:$(node_client_port "${id}")" "$@"
}

wait_for_leader() {
  local previous="${1:-}"
  local servers="${2:-${CLIENT_SERVERS}}"
  local out=""
  local leader=""
  local leader_addr=""
  for _ in $(seq 1 60); do
    out="$(raw_client_cmd_to_servers "${servers}" leader 2>/dev/null || true)"
    leader="$(awk '{print $1}' <<<"${out}")"
    leader_addr="$(awk '{print $2}' <<<"${out}")"
    if [[ "${leader}" =~ ^[1-3]$ ]]; then
      if server_list_contains "${servers}" "${leader_addr}" &&
        [[ -z "${previous}" || "${leader}" != "${previous}" ]]; then
        echo "${leader}"
        return 0
      fi
    fi
    sleep 1
  done
  write_failure_diagnostics "${CURRENT_STEP}:wait_for_leader" "${servers}" "leader" 1 "${out}" ""
  record_error "leader was not elected in time; last response: ${out}"
  return 1
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    record_error "${label}: expected '${expected}', got '${actual}'"
    return 1
  fi
}

write_workload() {
  local prefix="$1"
  local count="$2"
  local servers="${3:-${CLIENT_SERVERS}}"
  for i in $(seq 1 "${count}"); do
    client_cmd_to_servers "${servers}" put "${prefix}_put_${i}" "value_${i}" >/dev/null
    client_cmd_to_servers "${servers}" append "${prefix}_append_${i}" "a" >/dev/null
    client_cmd_to_servers "${servers}" append "${prefix}_append_${i}" "b" >/dev/null
  done
}

wait_for_snapshot() {
  local id="$1"
  local snapshot_file="${CLUSTER_DATA_DIR}/node${id}/snapshot.dat"
  echo "${snapshot_file}" >>"${REPORT_DIR}/snapshot_files.txt"
  for _ in $(seq 1 60); do
    if [[ -s "${snapshot_file}" ]]; then
      ls -l "${snapshot_file}" >>"${REPORT_DIR}/snapshot_files.txt"
      return 0
    fi
    sleep 1
  done
  record_error "snapshot file was not generated for node${id}: ${snapshot_file}"
  return 1
}

wait_for_install_snapshot_evidence() {
  local follower="$1"
  local internal_follower="$((follower - 1))"
  local from_line="${NODE_START_LOG_LINE[${follower}]:-1}"
  local follower_log="${NODE_LOG_DIR}/node${follower}.log"
  for _ in $(seq 1 80); do
    if sed -n "${from_line},\$p" "${follower_log}" 2>/dev/null |
      grep -Eq "now install snapshot metadata|received snapshot file OK"; then
      {
        echo "follower=${follower}"
        echo "follower_start_log_line=${from_line}"
        grep -En "send install snapshot to id\\[${internal_follower}\\]|success transfer snapshot file to id\\[${internal_follower}\\]|now install snapshot metadata|received snapshot file OK" \
          "${NODE_LOG_DIR}"/node*.log || true
      } >"${REPORT_DIR}/install_snapshot_evidence_node${follower}.txt"
      return 0
    fi
    local pid_file="${PID_DIR}/node${follower}.pid"
    if [[ -f "${pid_file}" ]] && ! process_running "$(cat "${pid_file}")"; then
      reap_pid "$(cat "${pid_file}")"
      record_node_log_tail "${follower}"
      record_error "node${follower} exited before InstallSnapshot evidence was observed"
      return 1
    fi
    sleep 1
  done
  record_error "no InstallSnapshot evidence found for follower node${follower}"
  return 1
}

wait_for_abort_evidence() {
  local follower="$1"
  local from_line="${NODE_START_LOG_LINE[${follower}]:-1}"
  local follower_log="${NODE_LOG_DIR}/node${follower}.log"
  for _ in $(seq 1 60); do
    if sed -n "${from_line},\$p" "${follower_log}" 2>/dev/null |
      grep -q "test abort snapshot install"; then
      grep -En "test abort snapshot install|Install snapshot file request timed out|TransferSnapShotFiles faild" \
        "${NODE_LOG_DIR}"/node*.log >"${REPORT_DIR}/interrupted_install_evidence_node${follower}.txt" || true
      return 0
    fi
    local pid_file="${PID_DIR}/node${follower}.pid"
    if [[ -f "${pid_file}" ]] && ! process_running "$(cat "${pid_file}")"; then
      reap_pid "$(cat "${pid_file}")"
      record_node_log_tail "${follower}"
      record_error "node${follower} exited before snapshot abort evidence was observed"
      return 1
    fi
    sleep 1
  done
  record_error "snapshot install abort was not observed on node${follower}"
  return 1
}

dump_node() {
  local id="$1"
  client_node_cmd "${id}" dump | sort >"${REPORT_DIR}/node${id}.dump"
}

check_consistency() {
  local label="$1"
  for _ in $(seq 1 60); do
    local ok=1
    for id in 1 2 3; do
      if ! dump_node "${id}"; then
        ok=0
      fi
    done
    if [[ "${ok}" -eq 1 ]] &&
      cmp -s "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node2.dump" &&
      cmp -s "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node3.dump"; then
      echo "${label}: consistency PASS"
      cp "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/${label}.dump"
      return 0
    fi
    sleep 1
  done
  diff -u "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node2.dump" >"${REPORT_DIR}/${label}_node1_node2.diff" || true
  diff -u "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node3.dump" >"${REPORT_DIR}/${label}_node1_node3.diff" || true
  record_error "${label}: cluster dumps did not converge"
  return 1
}

pick_follower() {
  local leader="$1"
  for id in 1 2 3; do
    if [[ "${id}" != "${leader}" ]]; then
      echo "${id}"
      return 0
    fi
  done
}

ensure_under_root "${RUN_DIR}" "${TEST_DATA_ROOT}"
ensure_under_root "${REPORT_DIR}" "${TEST_REPORT_ROOT}"
ensure_under_root "${NODE_LOG_DIR}" "${TEST_DATA_ROOT}"
mkdir -p "${CONFIG_DIR}" "${PID_DIR}" "${NODE_LOG_DIR}" "${REPORT_DIR}"
rm -f "${LAST_ERROR_FILE}" "${CLIENT_ATTEMPT_LOG}" "${FAILURE_CONTEXT_FILE}"

cd "${ROOT_DIR}"

{
  echo "run_id=${RUN_ID}"
  echo "data_dir=${CLUSTER_DATA_DIR}"
  echo "report_dir=${REPORT_DIR}"
  echo "node_log_dir=${NODE_LOG_DIR}"
  echo "raft_base_port=${RAFT_BASE_PORT}"
  echo "client_base_port=${CLIENT_BASE_PORT}"
  echo "snapshot_max_log_entries=${SNAPSHOT_MAX_LOG_ENTRIES}"
  echo "snapshot_workload_count=${SNAPSHOT_WORKLOAD_COUNT}"
} >"${REPORT_DIR}/run_info.txt"

echo "== Snapshot cluster integration =="
cat "${REPORT_DIR}/run_info.txt"
echo "command: cmake -S ${ROOT_DIR} -B ${BUILD_DIR} -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT=ON"
set_step "configure_build"
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT=ON

echo "command: cmake --build ${BUILD_DIR} -j${BUILD_JOBS} --target kv_server kv_client"
set_step "build_binaries"
cmake --build "${BUILD_DIR}" -j"${BUILD_JOBS}" --target kv_server kv_client

set_step "write_config"
for id in 1 2 3; do
  write_config "${id}"
done

set_step "initial_cluster_start"
for id in 1 2 3; do
  start_node "${id}"
done

set_step "initial_leader_election"
leader="$(wait_for_leader)"
echo "leader=${leader}"
recovered_follower="$(pick_follower "${leader}")"
echo "recovered_follower=${recovered_follower}"

set_step "dedup_before_snapshot"
client_cmd put dedup_key base >/dev/null
dedup_value="$(client_cmd --client_id=snapshot_dedup --request_id=7001 append dedup_key _once)"
assert_equals "base_once" "${dedup_value}" "dedup append before snapshot"

set_step "snapshot_lag_workload"
stop_node "${recovered_follower}"
live_client_servers="$(client_servers_except_node "${recovered_follower}")"
leader="$(wait_for_leader "" "${live_client_servers}")"
write_workload "snapshot_lag" "${SNAPSHOT_WORKLOAD_COUNT}" "${live_client_servers}"
leader="$(wait_for_leader "" "${live_client_servers}")"
wait_for_snapshot "${leader}"

set_step "restart_lagging_follower"
start_node "${recovered_follower}"
wait_for_install_snapshot_evidence "${recovered_follower}"
set_step "check_after_snapshot_install"
check_consistency "after_snapshot_install"

set_step "post_snapshot_ops"
client_cmd put post_snapshot_put ok >/dev/null
post_append="$(client_cmd append post_snapshot_put _append)"
assert_equals "ok_append" "${post_append}" "append after snapshot install"
client_cmd put post_snapshot_delete gone >/dev/null
client_cmd delete post_snapshot_delete >/dev/null
set_step "check_after_post_snapshot_ops"
check_consistency "after_post_snapshot_ops"

set_step "restart_recovered_follower"
stop_node "${recovered_follower}"
start_node "${recovered_follower}"
set_step "check_after_recovered_follower_restart"
check_consistency "after_recovered_follower_restart"

set_step "dedup_retry_after_restart"
dedup_retry_value="$(client_cmd --client_id=snapshot_dedup --request_id=7001 append dedup_key _once)"
assert_equals "base_once" "${dedup_retry_value}" "dedup retry result"
dedup_read_value="$(client_cmd get dedup_key)"
assert_equals "base_once" "${dedup_read_value}" "dedup retry did not mutate value"
set_step "check_after_dedup_retry"
check_consistency "after_dedup_retry"

set_step "snapshot_interrupt_workload"
stop_node "${recovered_follower}"
live_client_servers="$(client_servers_except_node "${recovered_follower}")"
leader="$(wait_for_leader "" "${live_client_servers}")"
write_workload "snapshot_interrupt" "${SNAPSHOT_WORKLOAD_COUNT}" "${live_client_servers}"
leader="$(wait_for_leader "" "${live_client_servers}")"
wait_for_snapshot "${leader}"

set_step "abort_snapshot_install"
start_node "${recovered_follower}" 1
wait_for_abort_evidence "${recovered_follower}"
set_step "restart_after_abort"
stop_node "${recovered_follower}"
start_node "${recovered_follower}"
wait_for_install_snapshot_evidence "${recovered_follower}"
set_step "check_after_interrupted_install_retry"
check_consistency "after_interrupted_install_retry"

set_step "final_artifacts"
find "${CLUSTER_DATA_DIR}" -name snapshot.dat -print >"${REPORT_DIR}/snapshot_paths.txt"
for id in 1 2 3; do
  dump_node "${id}"
done

echo "PASS"
