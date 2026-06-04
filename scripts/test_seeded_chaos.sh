#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED="${SEED:-20260604}"
DURATION_SECONDS="${DURATION_SECONDS:-60}"
OPERATION_COUNT="${OPERATION_COUNT:-300}"
CLIENT_COUNT="${CLIENT_COUNT:-4}"
TEST_DATA_ROOT="${TEST_DATA_ROOT:-/tmp/raftkv-test-data}"
TEST_REPORT_ROOT="${TEST_REPORT_ROOT:-/tmp/raftkv-test-reports}"
RUN_ID="${RUN_ID:-seeded-chaos-${SEED}-$(date +%Y%m%d-%H%M%S)-$$}"
RUN_DIR="${TEST_DATA_ROOT}/${RUN_ID}"
CLUSTER_DATA_DIR="${RUN_DIR}/seeded-chaos"
CONFIG_DIR="${CLUSTER_DATA_DIR}/config"
PID_DIR="${CLUSTER_DATA_DIR}/pids"
NODE_LOG_DIR="${CLUSTER_DATA_DIR}/logs"
REPORT_DIR="${TEST_REPORT_ROOT}/${RUN_ID}/seeded-chaos"
BUILD_DIR="${ROOT_DIR}/build/raft"
BUILD_JOBS="${BUILD_JOBS:-1}"
PORT_OFFSET="${PORT_OFFSET:-$((($$ % 1000) * 20))}"
RAFT_BASE_PORT="${RAFT_BASE_PORT:-$((26000 + PORT_OFFSET))}"
CLIENT_BASE_PORT="${CLIENT_BASE_PORT:-$((27000 + PORT_OFFSET))}"
CLIENT_TIMEOUT_MS="${CLIENT_TIMEOUT_MS:-1000}"
CLIENT_RETRIES="${CLIENT_RETRIES:-8}"
CLIENT_COMMAND_ATTEMPTS="${CLIENT_COMMAND_ATTEMPTS:-30}"
CLIENT_COMMAND_RETRY_SLEEP="${CLIENT_COMMAND_RETRY_SLEEP:-1}"
SNAPSHOT_MAX_LOG_ENTRIES="${SNAPSHOT_MAX_LOG_ENTRIES:-40}"
CLIENT="${ROOT_DIR}/bin/kv_client"
SERVER="${ROOT_DIR}/bin/kv_server"
CHECKER="${ROOT_DIR}/scripts/check_chaos_history.py"
LAST_ERROR_FILE="${REPORT_DIR}/last_error.txt"
FAILURE_CONTEXT_FILE="${REPORT_DIR}/failure_context.txt"
ATTEMPT_LOG="${REPORT_DIR}/client_attempts.log"
HISTORY_FILE="${REPORT_DIR}/history.jsonl"
FAULTS_FILE="${REPORT_DIR}/faults.jsonl"
PLAN_FILE="${REPORT_DIR}/plan.tsv"
CURRENT_STEP="initializing"
LAST_REQUEST=""
LAST_RESPONSE=""
LAST_LEADER=""
CLIENT_RESULT_STDOUT=""
CLIENT_RESULT_STDERR=""
CLIENT_RESULT_STATUS=0
CLIENT_RESULT_RESPONSE_STATUS="OK"
CLIENT_RESULT_RETRY_COUNT=0
CLIENT_RESULT_LEADER_HINT=""
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

set_step() {
  CURRENT_STEP="$1"
  echo "step=${CURRENT_STEP}"
}

node_raft_port() {
  echo "$((RAFT_BASE_PORT + $1))"
}

node_client_port() {
  echo "$((CLIENT_BASE_PORT + $1))"
}

node_client_addr() {
  echo "127.0.0.1:$(node_client_port "$1")"
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
  wait "$1" 2>/dev/null || true
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

alive_nodes_csv() {
  local out=""
  local id
  for id in 1 2 3; do
    local pid_file="${PID_DIR}/node${id}.pid"
    if [[ -f "${pid_file}" ]] && process_running "$(cat "${pid_file}")"; then
      if [[ -n "${out}" ]]; then
        out+=","
      fi
      out+="${id}"
    fi
  done
  echo "${out}"
}

alive_node_count() {
  local csv
  csv="$(alive_nodes_csv)"
  if [[ -z "${csv}" ]]; then
    echo 0
    return 0
  fi
  awk -F',' '{print NF}' <<<"${csv}"
}

stopped_nodes_csv() {
  local out=""
  local id
  for id in 1 2 3; do
    local pid_file="${PID_DIR}/node${id}.pid"
    if [[ ! -f "${pid_file}" ]] || ! process_running "$(cat "${pid_file}")"; then
      if [[ -n "${out}" ]]; then
        out+=","
      fi
      out+="${id}"
    fi
  done
  echo "${out}"
}

servers_for_alive_nodes() {
  local preferred="${1:-}"
  local servers=""
  local id
  if [[ -n "${preferred}" ]]; then
    local pid_file="${PID_DIR}/node${preferred}.pid"
    if [[ -f "${pid_file}" ]] && process_running "$(cat "${pid_file}")"; then
      servers="$(node_client_addr "${preferred}")"
    fi
  fi
  for id in 1 2 3; do
    local pid_file="${PID_DIR}/node${id}.pid"
    if [[ -f "${pid_file}" ]] && process_running "$(cat "${pid_file}")"; then
      local addr
      addr="$(node_client_addr "${id}")"
      if [[ ",${servers}," != *",${addr},"* ]]; then
        if [[ -n "${servers}" ]]; then
          servers+=","
        fi
        servers+="${addr}"
      fi
    fi
  done
  echo "${servers}"
}

raw_client_cmd_to_servers() {
  local servers="$1"
  shift
  "${CLIENT}" --servers="${servers}" --timeout_ms="${CLIENT_TIMEOUT_MS}" --retries="${CLIENT_RETRIES}" "$@"
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
  LAST_LEADER="${out}"
  if server_list_contains "${servers}" "${leader_addr}"; then
    echo "$(prefer_server "${servers}" "${leader_addr}")"
  else
    echo "${servers}"
  fi
}

is_transient_client_error() {
  local status="$1"
  local text="$2"
  if grep -Eiq 'NOT_LEADER|not leader|connect failed|connection refused|request failed|empty response|timed out|timeout|temporary unavailable|temporarily unavailable|unavailable|try again|broken pipe|connection reset' <<<"${text}"; then
    return 0
  fi
  [[ "${status}" -ne 0 ]] && grep -Eiq 'failed|error' <<<"${text}"
}

application_error_status() {
  local text="$1"
  if grep -Eiq 'KEY_NOT_FOUND|key not found' <<<"${text}"; then
    echo "KEY_NOT_FOUND"
    return 0
  fi
  echo ""
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

write_failure_context() {
  local step="$1"
  local request="$2"
  local status="$3"
  local stdout_text="$4"
  local stderr_text="$5"
  local leader_out=""
  local servers=""
  servers="$(servers_for_alive_nodes)"
  if [[ -n "${servers}" ]]; then
    leader_out="$(raw_client_cmd_to_servers "${servers}" leader 2>&1 || true)"
  fi
  {
    echo "current_step=${step}"
    echo "last_request=${request}"
    echo "last_response=${stdout_text}"
    echo "last_stderr=${stderr_text}"
    echo "last_status=${status}"
    echo "last_leader=${leader_out}"
    echo "alive_nodes=$(alive_nodes_csv)"
    echo "stopped_nodes=$(stopped_nodes_csv)"
    echo "history=${HISTORY_FILE}"
    echo "faults=${FAULTS_FILE}"
    echo "node_log_dir=${NODE_LOG_DIR}"
    echo "replay_command=SEED=${SEED} DURATION_SECONDS=${DURATION_SECONDS} OPERATION_COUNT=${OPERATION_COUNT} CLIENT_COUNT=${CLIENT_COUNT} bash scripts/test_seeded_chaos.sh"
  } >"${FAILURE_CONTEXT_FILE}"
  record_all_node_log_tails
}

retry_client_command() {
  local step="$1"
  local target_node="$2"
  local allow_application_error="$3"
  shift 3
  local original_args=("$@")
  local command_args=("$@")
  local op=""
  local arg
  for arg in "${original_args[@]}"; do
    if [[ "${arg}" != --* && -z "${op}" ]]; then
      op="${arg}"
    fi
  done
  CLIENT_RESULT_STDOUT=""
  CLIENT_RESULT_STDERR=""
  CLIENT_RESULT_STATUS=0
  CLIENT_RESULT_RESPONSE_STATUS="FAILED"
  CLIENT_RESULT_RETRY_COUNT=0
  CLIENT_RESULT_LEADER_HINT=""

  local current_servers=""
  current_servers="$(servers_for_alive_nodes "${target_node}")"
  if [[ -z "${current_servers}" ]]; then
    write_failure_context "${step}" "$*" 1 "" "no alive nodes"
    record_error "no alive nodes for client command in step '${step}'"
    return 1
  fi
  current_servers="$(refresh_servers_for_leader "${current_servers}")"

  local attempt=1
  local out=""
  local err=""
  local status=0
  local leader_probe=""
  local leader_hint=""
  local app_status=""
  LAST_REQUEST="${command_args[*]}"
  while [[ "${attempt}" -le "${CLIENT_COMMAND_ATTEMPTS}" ]]; do
    if [[ "${attempt}" -gt 1 ]]; then
      current_servers="$(servers_for_alive_nodes "${target_node}")"
      if [[ -z "${current_servers}" ]]; then
        err="no alive nodes"
        status=1
        printf 'step=%s attempt=%s servers=%s request=%q result=retry status=%s response=%q error=%q leader_hint=%q\n' \
          "${step}" "${attempt}" "${current_servers}" "${command_args[*]}" "${status}" "${out}" "${err}" "${LAST_LEADER}" >>"${ATTEMPT_LOG}"
        sleep "${CLIENT_COMMAND_RETRY_SLEEP}"
        attempt="$((attempt + 1))"
        continue
      fi
      current_servers="$(refresh_servers_for_leader "${current_servers}")"
    fi
    local err_file="${REPORT_DIR}/chaos_client_attempt_${attempt}.err"
    if out="$(raw_client_cmd_to_servers "${current_servers}" "${command_args[@]}" 2>"${err_file}")"; then
      status=0
      rm -f "${err_file}"
      if client_success_response_valid "${op}" "${out}"; then
        LAST_RESPONSE="${out}"
        CLIENT_RESULT_STDOUT="${out}"
        CLIENT_RESULT_STDERR=""
        CLIENT_RESULT_STATUS="${status}"
        CLIENT_RESULT_RESPONSE_STATUS="OK"
        CLIENT_RESULT_RETRY_COUNT="$((attempt - 1))"
        CLIENT_RESULT_LEADER_HINT="${LAST_LEADER}"
        printf 'step=%s attempt=%s servers=%s request=%q result=success status=%s response=%q\n' \
          "${step}" "${attempt}" "${current_servers}" "${command_args[*]}" "${status}" "${out}" >>"${ATTEMPT_LOG}"
        printf '%s\n' "${out}"
        RETRY_COUNT="$((attempt - 1))"
        LEADER_HINT="${LAST_LEADER}"
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
    leader_probe="$(raw_client_cmd_to_servers "${current_servers}" leader 2>/dev/null || true)"
    leader_hint="$(awk '{print $2}' <<<"${leader_probe}")"
    LAST_LEADER="${leader_probe}"
    app_status="$(application_error_status "${out}"$'\n'"${err}")"
    printf 'step=%s attempt=%s servers=%s request=%q result=retry status=%s response=%q error=%q leader_hint=%q\n' \
      "${step}" "${attempt}" "${current_servers}" "${command_args[*]}" "${status}" "${out}" "${err}" "${leader_probe}" >>"${ATTEMPT_LOG}"
    if [[ "${allow_application_error}" == "1" && -n "${app_status}" ]]; then
      LAST_RESPONSE="${out}"
      CLIENT_RESULT_STDOUT="${out}"
      CLIENT_RESULT_STDERR="${err}"
      CLIENT_RESULT_STATUS="${status}"
      CLIENT_RESULT_RESPONSE_STATUS="${app_status}"
      CLIENT_RESULT_RETRY_COUNT="$((attempt - 1))"
      CLIENT_RESULT_LEADER_HINT="${leader_probe}"
      RETRY_COUNT="$((attempt - 1))"
      LEADER_HINT="${leader_probe}"
      printf 'step=%s attempt=%s servers=%s request=%q result=application_error status=%s response=%q error=%q leader_hint=%q\n' \
        "${step}" "${attempt}" "${current_servers}" "${command_args[*]}" "${status}" "${out}" "${err}" "${leader_probe}" >>"${ATTEMPT_LOG}"
      return 2
    fi
    if ! is_transient_client_error "${status}" "${out}"$'\n'"${err}"; then
      write_failure_context "${step}" "${command_args[*]}" "${status}" "${out}" "${err}"
      record_error "client command failed in step '${step}': request='${command_args[*]}', status=${status}, stderr='${err}', stdout='${out}'"
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
  write_failure_context "${step}" "${command_args[*]}" "${status}" "${out}" "${err}"
  record_error "client command timed out in step '${step}': request='${command_args[*]}', last_status=${status}, stderr='${err}', stdout='${out}'"
  return 1
}

append_json_line() {
  local path="$1"
  shift
  python3 - "$path" "$@" <<'PY'
import json
import sys

path = sys.argv[1]
pairs = sys.argv[2:]
obj = {}
for pair in pairs:
    key, value = pair.split("=", 1)
    if value == "true":
        obj[key] = True
    elif value == "false":
        obj[key] = False
    else:
        try:
            obj[key] = int(value)
        except ValueError:
            obj[key] = value
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(obj, sort_keys=True) + "\n")
PY
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

stop_node() {
  local id="$1"
  local reason="${2:-chaos}"
  local pid_file="${PID_DIR}/node${id}.pid"
  if [[ -f "${pid_file}" ]]; then
    echo "stopping node${id}: reason=${reason}, pid=$(cat "${pid_file}")"
    stop_pid "$(cat "${pid_file}")"
    if [[ -n "$(cat "${pid_file}")" ]] && process_running "$(cat "${pid_file}")"; then
      record_error "node${id} process did not exit after stop"
      return 1
    fi
    wait_for_port_closed "node${id} raft" "$(node_raft_port "${id}")"
    wait_for_port_closed "node${id} client" "$(node_client_port "${id}")"
    rm -f "${pid_file}"
  fi
}

start_node() {
  local id="$1"
  local log_file="${NODE_LOG_DIR}/node${id}.log"
  local raft_port
  local client_port
  local start_line=1
  raft_port="$(node_raft_port "${id}")"
  client_port="$(node_client_port "${id}")"
  if tcp_port_open "127.0.0.1" "${raft_port}" || tcp_port_open "127.0.0.1" "${client_port}"; then
    record_error "node${id} port is already open before start"
    return 1
  fi
  if [[ -f "${log_file}" ]]; then
    start_line="$(($(wc -l <"${log_file}") + 1))"
  fi
  NODE_START_LOG_LINE["${id}"]="${start_line}"
  printf '\n== start node%s ==\n' "${id}" >>"${log_file}"
  env -u CRAFTKV_TEST_ABORT_SNAPSHOT_INSTALL_AFTER_CHUNKS \
    "${SERVER}" --config="${CONFIG_DIR}/node${id}.yaml" >>"${log_file}" 2>&1 &
  local pid="$!"
  echo "${pid}" >"${PID_DIR}/node${id}.pid"
  wait_for_process_alive "${id}" "${pid}"
  wait_for_node_ready "${id}" "${pid}"
  echo "started node${id}: pid=${pid}, log=${log_file}"
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
  if [[ "${status}" -ne 0 ]]; then
    record_all_node_log_tails
  fi
  if [[ "${status}" -ne 0 ]]; then
    {
      cat "${REPORT_DIR}/run_info.txt" 2>/dev/null || true
      echo "status=FAIL"
      echo "last_error=${LAST_ERROR_FILE}"
      echo "failure_context=${FAILURE_CONTEXT_FILE}"
      echo "last_leader=${LAST_LEADER}"
      echo "alive_nodes=$(alive_nodes_csv)"
      echo "stopped_nodes=$(stopped_nodes_csv)"
      echo "history=${HISTORY_FILE}"
      echo "faults=${FAULTS_FILE}"
      echo "attempt_log=${ATTEMPT_LOG}"
      echo "node_log_dir=${NODE_LOG_DIR}"
      echo "replay_command=SEED=${SEED} DURATION_SECONDS=${DURATION_SECONDS} OPERATION_COUNT=${OPERATION_COUNT} CLIENT_COUNT=${CLIENT_COUNT} bash scripts/test_seeded_chaos.sh"
    } >"${REPORT_DIR}/summary.txt"
  fi
  if declare -F copy_artifacts >/dev/null; then
    copy_artifacts
  fi
  cleanup
  if [[ "${status}" -eq 0 ]]; then
    echo "SEEDED CHAOS PASSED"
  else
    echo "SEEDED CHAOS FAILED"
    echo "run_id=${RUN_ID}"
    echo "data_dir=${CLUSTER_DATA_DIR}"
    echo "report_dir=${REPORT_DIR}"
    echo "last_error=${LAST_ERROR_FILE}"
    echo "replay: SEED=${SEED} DURATION_SECONDS=${DURATION_SECONDS} OPERATION_COUNT=${OPERATION_COUNT} CLIENT_COUNT=${CLIENT_COUNT} bash scripts/test_seeded_chaos.sh"
  fi
}

on_err() {
  local line="$1"
  local command="$2"
  set +e
  if [[ ! -s "${LAST_ERROR_FILE}" ]]; then
    write_failure_context "${CURRENT_STEP}" "${command}" 1 "" "command failed at line ${line}"
    record_error "command failed at line ${line}: ${command}"
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

wait_for_leader() {
  local servers=""
  local out=""
  local leader=""
  local leader_addr=""
  for _ in $(seq 1 60); do
    servers="$(servers_for_alive_nodes)"
    if [[ -n "${servers}" ]]; then
      out="$(raw_client_cmd_to_servers "${servers}" leader 2>/dev/null || true)"
      leader="$(awk '{print $1}' <<<"${out}")"
      leader_addr="$(awk '{print $2}' <<<"${out}")"
      if [[ "${leader}" =~ ^[1-3]$ ]] && server_list_contains "${servers}" "${leader_addr}"; then
        LAST_LEADER="${out}"
        echo "${leader}"
        return 0
      fi
    fi
    sleep 1
  done
  write_failure_context "${CURRENT_STEP}:wait_for_leader" "leader" 1 "${out}" ""
  record_error "leader was not elected in time; last response: ${out}"
  return 1
}

try_find_leader() {
  local servers=""
  local out=""
  local leader=""
  local leader_addr=""
  servers="$(servers_for_alive_nodes)"
  if [[ -z "${servers}" ]]; then
    echo ""
    return 0
  fi
  out="$(raw_client_cmd_to_servers "${servers}" leader 2>/dev/null || true)"
  leader="$(awk '{print $1}' <<<"${out}")"
  leader_addr="$(awk '{print $2}' <<<"${out}")"
  LAST_LEADER="${out}"
  if [[ "${leader}" =~ ^[1-3]$ ]] && server_list_contains "${servers}" "${leader_addr}"; then
    echo "${leader}"
  else
    echo ""
  fi
}

record_fault() {
  local sequence="$1"
  local event="$2"
  local node_id="$3"
  local reason="$4"
  append_json_line "${FAULTS_FILE}" \
    "sequence=${sequence}" \
    "timestamp=$(date +%s.%N)" \
    "event=${event}" \
    "node_id=${node_id}" \
    "reason=${reason}" \
    "seed=${SEED}"
}

perform_fault() {
  local sequence="$1"
  local event="$2"
  local target_node="$3"
  set_step "fault_${event}_${sequence}"
  case "${event}" in
    stop_leader)
      local leader
      leader="$(try_find_leader)"
      if [[ "${leader}" =~ ^[1-3]$ ]] && [[ "$(alive_node_count)" -eq 3 ]]; then
        stop_node "${leader}" "seeded stop leader"
        record_fault "${sequence}" "${event}" "${leader}" "seeded stop current leader"
      else
        record_fault "${sequence}" "skip_${event}" "0" "no stoppable leader"
      fi
      ;;
    stop_follower)
      local leader
      leader="$(try_find_leader)"
      local chosen=""
      local id
      for id in 1 2 3; do
        if [[ "${id}" != "${leader}" ]]; then
          local pid_file="${PID_DIR}/node${id}.pid"
          if [[ -f "${pid_file}" ]] && process_running "$(cat "${pid_file}")"; then
            chosen="${id}"
            break
          fi
        fi
      done
      if [[ -n "${chosen}" ]] && [[ "$(alive_node_count)" -eq 3 ]]; then
        stop_node "${chosen}" "seeded stop follower"
        record_fault "${sequence}" "${event}" "${chosen}" "seeded stop follower"
      else
        record_fault "${sequence}" "skip_${event}" "0" "no stoppable follower"
      fi
      ;;
    restart_node)
      local chosen=""
      local id
      for id in 1 2 3; do
        local pid_file="${PID_DIR}/node${id}.pid"
        if [[ ! -f "${pid_file}" ]] || ! process_running "$(cat "${pid_file}")"; then
          chosen="${id}"
          break
        fi
      done
      if [[ -n "${chosen}" ]]; then
        start_node "${chosen}"
        record_fault "${sequence}" "${event}" "${chosen}" "seeded restart stopped node"
      else
        record_fault "${sequence}" "skip_${event}" "0" "no stopped node"
      fi
      ;;
    short_stop)
      local node="${target_node}"
      local pid_file="${PID_DIR}/node${node}.pid"
      if [[ -f "${pid_file}" ]] && process_running "$(cat "${pid_file}")" && [[ "$(alive_node_count)" -eq 3 ]]; then
        stop_node "${node}" "seeded short stop"
        sleep 1
        start_node "${node}"
        record_fault "${sequence}" "${event}" "${node}" "seeded short stop and restart"
      else
        record_fault "${sequence}" "skip_${event}" "${node}" "node not available for short stop"
      fi
      ;;
    *)
      record_fault "${sequence}" "skip_unknown" "${target_node}" "unknown fault event ${event}"
      ;;
  esac
}

run_operation() {
  local sequence="$1"
  local op="$2"
  local client_slot="$3"
  local request_id="$4"
  local key="$5"
  local value="$6"
  local target_node="$7"
  local duplicate="$8"
  set_step "operation_${sequence}_${op}"
  local client_id="chaos_client_${client_slot}"
  local ts_start
  local ts_end
  local status="OK"
  local response=""
  local final_success=true
  local retry_count=0
  local allow_application_error=0
  RETRY_COUNT=0
  LEADER_HINT=""
  ts_start="$(date +%s.%N)"
  local args=("--client_id=${client_id}" "--request_id=${request_id}" "${op}")
  case "${op}" in
    put|append)
      args+=("${key}" "${value}")
      ;;
    get|delete)
      args+=("${key}")
      allow_application_error=1
      ;;
  esac
  local response_file="${REPORT_DIR}/operation_${sequence}.out"
  if retry_client_command "${CURRENT_STEP}" "${target_node}" "${allow_application_error}" "${args[@]}" >"${response_file}"; then
    response="$(cat "${response_file}")"
    final_success=true
    retry_count="${CLIENT_RESULT_RETRY_COUNT}"
    case "${op}" in
      put|delete)
        status="OK"
        ;;
      get|append)
        status="OK"
        ;;
    esac
  else
    final_success=false
    retry_count="${CLIENT_RESULT_RETRY_COUNT:-0}"
    status="${CLIENT_RESULT_RESPONSE_STATUS:-FAILED}"
    response="${CLIENT_RESULT_STDOUT}"
  fi
  rm -f "${response_file}"
  ts_end="$(date +%s.%N)"
  append_json_line "${HISTORY_FILE}" \
    "sequence=${sequence}" \
    "timestamp_start=${ts_start}" \
    "timestamp_end=${ts_end}" \
    "client_id=${client_id}" \
    "request_id=${request_id}" \
    "operation=${op}" \
    "key=${key}" \
    "input_value=${value}" \
    "response_status=${status}" \
    "response_value=${response}" \
    "target_node=${target_node}" \
    "leader_hint=${LEADER_HINT}" \
    "retry_count=${retry_count}" \
    "final_success=${final_success}" \
    "duplicate=${duplicate}"
  if [[ "${final_success}" != "true" && "${status}" == "FAILED" ]]; then
    return 1
  fi
}

generate_plan() {
  python3 - "${SEED}" "${OPERATION_COUNT}" "${CLIENT_COUNT}" >"${PLAN_FILE}" <<'PY'
import random
import sys

seed = int(sys.argv[1])
operation_count = int(sys.argv[2])
client_count = int(sys.argv[3])
rng = random.Random(seed)
dedup_pairs = []
seq = 1
for i in range(1, operation_count + 1):
    if i % 17 == 0:
        event = rng.choice(["stop_leader", "stop_follower", "restart_node", "short_stop"])
        print("\t".join([str(seq), "fault", event, str(rng.randint(1, 3)), "", "", "", "", "0"]))
        seq += 1
    op = rng.choice(["put", "get", "append", "delete"])
    client_slot = rng.randint(1, client_count)
    key = f"chaos_key_{rng.randint(1, 24)}"
    value = f"value_{rng.randint(1, 999)}"
    target = rng.randint(1, 3)
    duplicate = 0
    if op == "append" and dedup_pairs and rng.random() < 0.25:
        client_slot, request_id, key, value = rng.choice(dedup_pairs)
        duplicate = 1
    else:
        request_id = i * 1000 + rng.randint(1, 999)
        if op == "append" and rng.random() < 0.35:
            dedup_pairs.append((client_slot, request_id, key, value))
    print("\t".join([str(seq), "op", op, str(target), str(client_slot), str(request_id), key, value, str(duplicate)]))
    seq += 1
PY
}

copy_artifacts() {
  cp -r "${CONFIG_DIR}" "${REPORT_DIR}/config" 2>/dev/null || true
  cp -r "${PID_DIR}" "${REPORT_DIR}/pids" 2>/dev/null || true
  cp -r "${NODE_LOG_DIR}" "${REPORT_DIR}/logs" 2>/dev/null || true
}

dump_node() {
  local id="$1"
  local servers
  local out=""
  local err=""
  local status=0
  local err_file="${REPORT_DIR}/node${id}.dump.err"
  servers="$(node_client_addr "${id}")"
  for attempt in $(seq 1 30); do
    if out="$(raw_client_cmd_to_servers "${servers}" dump 2>"${err_file}")"; then
      status=0
      err=""
      if client_success_response_valid "dump" "${out}"; then
        printf '%s\n' "${out}" | sort >"${REPORT_DIR}/node${id}.dump"
        rm -f "${err_file}"
        return 0
      fi
      err="invalid dump response from node${id}: ${out}"
    else
      status="$?"
      err="$(cat "${err_file}" 2>/dev/null || true)"
    fi
    printf 'step=final_dump attempt=%s target=node%s servers=%s result=retry status=%s response=%q error=%q\n' \
      "${attempt}" "${id}" "${servers}" "${status}" "${out}" "${err}" >>"${ATTEMPT_LOG}"
    sleep 1
  done
  write_failure_context "final_dump_node${id}" "dump" "${status}" "${out}" "${err}"
  record_error "final dump failed for node${id}: status=${status}, stderr='${err}', stdout='${out}'"
  return 1
}

check_final_consistency() {
  set_step "final_consistency"
  local attempt
  local id
  for attempt in $(seq 1 60); do
    for id in 1 2 3; do
      dump_node "${id}"
    done
    if cmp -s "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node2.dump" &&
      cmp -s "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node3.dump" &&
      python3 "${CHECKER}" \
        --history "${HISTORY_FILE}" \
        --faults "${FAULTS_FILE}" \
        --dump "${REPORT_DIR}/node1.dump" \
        --dump "${REPORT_DIR}/node2.dump" \
        --dump "${REPORT_DIR}/node3.dump" >"${REPORT_DIR}/history_check.out" 2>"${REPORT_DIR}/history_check.err"; then
      return 0
    fi
    printf 'step=final_consistency attempt=%s result=retry alive_nodes=%s last_leader=%q\n' \
      "${attempt}" "$(alive_nodes_csv)" "${LAST_LEADER}" >>"${ATTEMPT_LOG}"
    sleep 1
  done
  diff -u "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node2.dump" >"${REPORT_DIR}/node1_node2.diff" 2>/dev/null || true
  diff -u "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node3.dump" >"${REPORT_DIR}/node1_node3.diff" 2>/dev/null || true
  write_failure_context "final_consistency" "dump/history_check" 1 "$(cat "${REPORT_DIR}/history_check.out" 2>/dev/null || true)" "$(cat "${REPORT_DIR}/history_check.err" 2>/dev/null || true)"
  record_error "final dumps or basic history consistency did not converge"
  return 1
}

ensure_under_root "${RUN_DIR}" "${TEST_DATA_ROOT}"
ensure_under_root "${REPORT_DIR}" "${TEST_REPORT_ROOT}"
ensure_under_root "${NODE_LOG_DIR}" "${TEST_DATA_ROOT}"
mkdir -p "${CONFIG_DIR}" "${PID_DIR}" "${NODE_LOG_DIR}" "${REPORT_DIR}"
rm -f "${LAST_ERROR_FILE}" "${FAILURE_CONTEXT_FILE}" "${ATTEMPT_LOG}" "${HISTORY_FILE}" "${FAULTS_FILE}" "${PLAN_FILE}"
touch "${HISTORY_FILE}" "${FAULTS_FILE}" "${ATTEMPT_LOG}"

cd "${ROOT_DIR}"

{
  echo "run_id=${RUN_ID}"
  echo "seed=${SEED}"
  echo "duration_seconds=${DURATION_SECONDS}"
  echo "operation_count=${OPERATION_COUNT}"
  echo "client_count=${CLIENT_COUNT}"
  echo "data_dir=${CLUSTER_DATA_DIR}"
  echo "report_dir=${REPORT_DIR}"
  echo "node_log_dir=${NODE_LOG_DIR}"
  echo "raft_base_port=${RAFT_BASE_PORT}"
  echo "client_base_port=${CLIENT_BASE_PORT}"
  echo "replay_command=SEED=${SEED} DURATION_SECONDS=${DURATION_SECONDS} OPERATION_COUNT=${OPERATION_COUNT} CLIENT_COUNT=${CLIENT_COUNT} bash scripts/test_seeded_chaos.sh"
} >"${REPORT_DIR}/run_info.txt"

echo "== Seeded chaos integration =="
cat "${REPORT_DIR}/run_info.txt"

set_step "configure_build"
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT=ON

set_step "build_binaries"
cmake --build "${BUILD_DIR}" -j"${BUILD_JOBS}" --target kv_server kv_client

set_step "write_config"
for id in 1 2 3; do
  write_config "${id}"
done

set_step "start_cluster"
for id in 1 2 3; do
  start_node "${id}"
done
wait_for_leader >/dev/null

set_step "generate_plan"
generate_plan

set_step "execute_plan"
start_epoch="$(date +%s)"
while IFS=$'\t' read -r sequence kind action target client_slot request_id key value duplicate; do
  now_epoch="$(date +%s)"
  if [[ "$((now_epoch - start_epoch))" -ge "${DURATION_SECONDS}" ]]; then
    break
  fi
  if [[ "${kind}" == "fault" ]]; then
    perform_fault "${sequence}" "${action}" "${target}"
  else
    run_operation "${sequence}" "${action}" "${client_slot}" "${request_id}" "${key}" "${value}" "${target}" "${duplicate}"
  fi
done <"${PLAN_FILE}"

set_step "recover_all_nodes"
for id in 1 2 3; do
  pid_file="${PID_DIR}/node${id}.pid"
  if [[ ! -f "${pid_file}" ]] || ! process_running "$(cat "${pid_file}")"; then
    start_node "${id}"
    record_fault "999000${id}" "final_restart" "${id}" "restore all nodes before final check"
  fi
done
wait_for_leader >/dev/null

set_step "post_recovery_probe"
probe_value="probe_${SEED}_${OPERATION_COUNT}"
retry_client_command "${CURRENT_STEP}" "1" "0" --client_id=chaos_probe --request_id=1 put chaos_probe_key "${probe_value}" >/dev/null
probe_read="$(retry_client_command "${CURRENT_STEP}" "2" "0" --client_id=chaos_probe --request_id=2 get chaos_probe_key)"
if [[ "${probe_read}" != "${probe_value}" ]]; then
  record_error "post recovery probe read mismatch: expected ${probe_value}, got ${probe_read}"
  exit 1
fi
append_json_line "${HISTORY_FILE}" \
  "sequence=999001" \
  "timestamp_start=$(date +%s.%N)" \
  "timestamp_end=$(date +%s.%N)" \
  "client_id=chaos_probe" \
  "request_id=1" \
  "operation=put" \
  "key=chaos_probe_key" \
  "input_value=${probe_value}" \
  "response_status=OK" \
  "response_value=OK" \
  "target_node=1" \
  "leader_hint=${LAST_LEADER}" \
  "retry_count=0" \
  "final_success=true"
append_json_line "${HISTORY_FILE}" \
  "sequence=999002" \
  "timestamp_start=$(date +%s.%N)" \
  "timestamp_end=$(date +%s.%N)" \
  "client_id=chaos_probe" \
  "request_id=2" \
  "operation=get" \
  "key=chaos_probe_key" \
  "input_value=" \
  "response_status=OK" \
  "response_value=${probe_read}" \
  "target_node=2" \
  "leader_hint=${LAST_LEADER}" \
  "retry_count=0" \
  "final_success=true"

check_final_consistency
copy_artifacts

{
  cat "${REPORT_DIR}/run_info.txt"
  echo "status=PASS"
  echo "last_leader=${LAST_LEADER}"
  echo "alive_nodes=$(alive_nodes_csv)"
  echo "stopped_nodes=$(stopped_nodes_csv)"
  echo "history=${HISTORY_FILE}"
  echo "faults=${FAULTS_FILE}"
  echo "history_check=${REPORT_DIR}/history_check.out"
} >"${REPORT_DIR}/summary.txt"

echo "PASS"
