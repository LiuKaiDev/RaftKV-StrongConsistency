#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED="${SEED:-20260604}"
CLIENT_COUNT="${CLIENT_COUNT:-4}"
OPERATIONS_PER_CLIENT="${OPERATIONS_PER_CLIENT:-40}"
KEY_COUNT="${KEY_COUNT:-3}"
TEST_DATA_ROOT="${TEST_DATA_ROOT:-/tmp/raftkv-test-data}"
TEST_REPORT_ROOT="${TEST_REPORT_ROOT:-/tmp/raftkv-test-reports}"
RUN_ID="${RUN_ID:-linearizability-${SEED}-$(date +%Y%m%d-%H%M%S)-$$}"
RUN_DIR="${TEST_DATA_ROOT}/${RUN_ID}"
CLUSTER_DATA_DIR="${RUN_DIR}/linearizability"
CONFIG_DIR="${CLUSTER_DATA_DIR}/config"
PID_DIR="${CLUSTER_DATA_DIR}/pids"
NODE_LOG_DIR="${CLUSTER_DATA_DIR}/logs"
WORKER_DIR="${CLUSTER_DATA_DIR}/workers"
REPORT_DIR="${TEST_REPORT_ROOT}/${RUN_ID}/linearizability"
BUILD_DIR="${ROOT_DIR}/build/raft"
PORT_OFFSET="${PORT_OFFSET:-$((($$ % 1000) * 20))}"
RAFT_BASE_PORT="${RAFT_BASE_PORT:-$((28000 + PORT_OFFSET))}"
CLIENT_BASE_PORT="${CLIENT_BASE_PORT:-$((29000 + PORT_OFFSET))}"
CLIENT_TIMEOUT_MS="${CLIENT_TIMEOUT_MS:-1000}"
CLIENT_RETRIES="${CLIENT_RETRIES:-3}"
CLIENT_COMMAND_ATTEMPTS="${CLIENT_COMMAND_ATTEMPTS:-30}"
CLIENT_COMMAND_RETRY_SLEEP_MS="${CLIENT_COMMAND_RETRY_SLEEP_MS:-200}"
WORKER_JITTER_MS="${WORKER_JITTER_MS:-75}"
SNAPSHOT_MAX_LOG_ENTRIES="${SNAPSHOT_MAX_LOG_ENTRIES:-40}"
READ_MODE="${READ_MODE:-log}"
CHECKER_TIMEOUT_SECONDS="${CHECKER_TIMEOUT_SECONDS:-10}"
CHECKER_TIMEOUT_MS="${CHECKER_TIMEOUT_MS:-$((CHECKER_TIMEOUT_SECONDS * 1000))}"
CHECKER_MAX_RECORDS_PER_KEY="${CHECKER_MAX_RECORDS_PER_KEY:-200}"
FAULT_MODE="${FAULT_MODE:-full}"
SAVE_NORMALIZED_HISTORY="${SAVE_NORMALIZED_HISTORY:-1}"
SERVER="${ROOT_DIR}/bin/kv_server"
CLIENT="${ROOT_DIR}/bin/kv_client"
CHECKER="${ROOT_DIR}/scripts/check_linearizability.py"
HISTORY_FILE="${REPORT_DIR}/history.jsonl"
NORMALIZED_HISTORY_FILE="${REPORT_DIR}/normalized_history.jsonl"
FAULTS_FILE="${REPORT_DIR}/faults.jsonl"
ATTEMPT_LOG="${REPORT_DIR}/client_attempts.log"
FAILURE_JSON_FILE="${REPORT_DIR}/linearizability_failure.json"
FAILURE_TEXT_FILE="${REPORT_DIR}/linearizability_failure.txt"
FAILURE_FRAGMENT_FILE="${REPORT_DIR}/linearizability_failure.jsonl"
LAST_ERROR_FILE="${REPORT_DIR}/last_error.txt"
FAILURE_CONTEXT_FILE="${REPORT_DIR}/failure_context.txt"
CURRENT_STEP="initializing"
LAST_LEADER=""
declare -A NODE_START_LOG_LINE=()
declare -a WORKER_PIDS=()

ensure_under_root() {
  local path="$1"
  local root="$2"
  case "${path}" in
    "${root}"/*) ;;
    *) echo "ERROR: refusing to use path outside ${root}: ${path}" >&2; exit 1 ;;
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

node_raft_port() { echo "$((RAFT_BASE_PORT + $1))"; }
node_client_port() { echo "$((CLIENT_BASE_PORT + $1))"; }
node_client_addr() { echo "127.0.0.1:$(node_client_port "$1")"; }
all_servers() { echo "127.0.0.1:$((CLIENT_BASE_PORT + 1)),127.0.0.1:$((CLIENT_BASE_PORT + 2)),127.0.0.1:$((CLIENT_BASE_PORT + 3))"; }

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

reap_pid() { wait "$1" 2>/dev/null || true; }

record_node_log_tail() {
  local id="$1"
  local log_file="${NODE_LOG_DIR}/node${id}.log"
  [[ -f "${log_file}" ]] && tail -n 160 "${log_file}" >"${REPORT_DIR}/node${id}_last_log_tail.txt" || true
}

record_all_node_log_tails() {
  local id
  for id in 1 2 3; do record_node_log_tail "${id}"; done
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

alive_nodes_csv() {
  local out=""
  local id
  for id in 1 2 3; do
    local pid_file="${PID_DIR}/node${id}.pid"
    if [[ -f "${pid_file}" ]] && process_running "$(cat "${pid_file}")"; then
      [[ -n "${out}" ]] && out+=","
      out+="${id}"
    fi
  done
  echo "${out}"
}

append_json_line() {
  local path="$1"
  shift
  python3 - "$path" "$@" <<'PY'
import json
import sys

path = sys.argv[1]
obj = {}
for pair in sys.argv[2:]:
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

write_failure_context() {
  {
    echo "current_step=${CURRENT_STEP}"
    echo "alive_nodes=$(alive_nodes_csv)"
    echo "last_leader=${LAST_LEADER}"
    echo "history=${HISTORY_FILE}"
    echo "normalized_history=${NORMALIZED_HISTORY_FILE}"
    echo "faults=${FAULTS_FILE}"
    echo "node_log_dir=${NODE_LOG_DIR}"
    echo "replay_command=SEED=${SEED} CLIENT_COUNT=${CLIENT_COUNT} OPERATIONS_PER_CLIENT=${OPERATIONS_PER_CLIENT} KEY_COUNT=${KEY_COUNT} FAULT_MODE=${FAULT_MODE} CHECKER_TIMEOUT_SECONDS=${CHECKER_TIMEOUT_SECONDS} SAVE_NORMALIZED_HISTORY=${SAVE_NORMALIZED_HISTORY} RUN_ID=${RUN_ID} bash scripts/test_concurrent_linearizability.sh"
  } >"${FAILURE_CONTEXT_FILE}"
}

write_failure_summary() {
  {
    [[ -f "${REPORT_DIR}/run_info.txt" ]] && cat "${REPORT_DIR}/run_info.txt"
    echo "status=FAIL"
    echo "current_step=${CURRENT_STEP}"
    echo "last_error=$(cat "${LAST_ERROR_FILE}" 2>/dev/null || true)"
    echo "history=${HISTORY_FILE}"
    echo "normalized_history=${NORMALIZED_HISTORY_FILE}"
    echo "faults=${FAULTS_FILE}"
    echo "checker_output=${REPORT_DIR}/checker_output.txt"
    echo "linearizability_failure_json=${FAILURE_JSON_FILE}"
    echo "linearizability_failure_text=${FAILURE_TEXT_FILE}"
    echo "attempt_log=${ATTEMPT_LOG}"
    echo "failure_context=${FAILURE_CONTEXT_FILE}"
    echo "node_log_dir=${NODE_LOG_DIR}"
  } >"${REPORT_DIR}/summary.txt"
}

wait_for_process_alive() {
  local id="$1"
  local pid="$2"
  for _ in $(seq 1 25); do
    process_running "${pid}" && return 0
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
    ! tcp_port_open "127.0.0.1" "${port}" && return 0
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
    tcp_port_open "127.0.0.1" "${port}" && return 0
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
  [[ -z "${pid}" ]] && return 0
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" || true
    wait_for_process_exit "${pid}" 50 || {
      process_running "${pid}" && kill -9 "${pid}" || true
      wait_for_process_exit "${pid}" 25 || true
    }
  fi
}

stop_node() {
  local id="$1"
  local reason="${2:-linearizability}"
  local pid_file="${PID_DIR}/node${id}.pid"
  [[ -f "${pid_file}" ]] || return 0
  local pid
  pid="$(cat "${pid_file}")"
  append_json_line "${FAULTS_FILE}" sequence="$(date +%s%N)" timestamp_ns="$(date +%s%N)" event="stop_node" node_id="${id}" reason="${reason}" seed="${SEED}"
  echo "stopping node${id}: reason=${reason}, pid=${pid}"
  stop_pid "${pid}"
  wait_for_port_closed "node${id} raft" "$(node_raft_port "${id}")"
  wait_for_port_closed "node${id} client" "$(node_client_port "${id}")"
  rm -f "${pid_file}"
}

start_node() {
  local id="$1"
  local log_file="${NODE_LOG_DIR}/node${id}.log"
  local start_line=1
  if tcp_port_open "127.0.0.1" "$(node_raft_port "${id}")" || tcp_port_open "127.0.0.1" "$(node_client_port "${id}")"; then
    record_error "node${id} port is already open before start"
    return 1
  fi
  [[ -f "${log_file}" ]] && start_line="$(($(wc -l <"${log_file}") + 1))"
  NODE_START_LOG_LINE["${id}"]="${start_line}"
  printf '\n== start node%s ==\n' "${id}" >>"${log_file}"
  "${SERVER}" --config="${CONFIG_DIR}/node${id}.yaml" >>"${log_file}" 2>&1 &
  local pid="$!"
  echo "${pid}" >"${PID_DIR}/node${id}.pid"
  append_json_line "${FAULTS_FILE}" sequence="$(date +%s%N)" timestamp_ns="$(date +%s%N)" event="start_node" node_id="${id}" reason="start" seed="${SEED}"
  wait_for_process_alive "${id}" "${pid}"
  wait_for_node_ready "${id}" "${pid}"
  echo "started node${id}: pid=${pid}, log=${log_file}"
}

cleanup() {
  local pid
  for pid in "${WORKER_PIDS[@]:-}"; do
    if [[ -n "${pid}" ]] && process_running "${pid}"; then
      kill "${pid}" 2>/dev/null || true
      wait_for_process_exit "${pid}" 25 || {
        process_running "${pid}" && kill -9 "${pid}" 2>/dev/null || true
        wait_for_process_exit "${pid}" 10 || true
      }
    fi
  done
  local pid_file
  for pid_file in "${PID_DIR}"/node*.pid; do
    [[ -f "${pid_file}" ]] || continue
    stop_pid "$(cat "${pid_file}")"
  done
}

on_exit() {
  local status="$?"
  set +e
  [[ "${status}" -ne 0 ]] && record_all_node_log_tails
  cp -R "${CONFIG_DIR}" "${REPORT_DIR}/config" 2>/dev/null || true
  cp -R "${PID_DIR}" "${REPORT_DIR}/pids" 2>/dev/null || true
  cp -R "${NODE_LOG_DIR}" "${REPORT_DIR}/logs" 2>/dev/null || true
  cp -R "${WORKER_DIR}" "${REPORT_DIR}/workers" 2>/dev/null || true
  cleanup
  if [[ "${status}" -eq 0 ]]; then
    echo "CONCURRENT LINEARIZABILITY PASSED"
  else
    write_failure_context
    write_failure_summary
    echo "CONCURRENT LINEARIZABILITY FAILED"
    echo "run_id=${RUN_ID}"
    echo "data_dir=${CLUSTER_DATA_DIR}"
    echo "report_dir=${REPORT_DIR}"
    echo "replay: SEED=${SEED} CLIENT_COUNT=${CLIENT_COUNT} OPERATIONS_PER_CLIENT=${OPERATIONS_PER_CLIENT} KEY_COUNT=${KEY_COUNT} FAULT_MODE=${FAULT_MODE} CHECKER_TIMEOUT_SECONDS=${CHECKER_TIMEOUT_SECONDS} SAVE_NORMALIZED_HISTORY=${SAVE_NORMALIZED_HISTORY} RUN_ID=${RUN_ID} bash scripts/test_concurrent_linearizability.sh"
  fi
}

on_err() {
  local line="$1"
  local command="$2"
  set +e
  [[ -s "${LAST_ERROR_FILE}" ]] || record_error "command failed at line ${line}: ${command}"
}

trap on_exit EXIT
trap 'on_err "${LINENO}" "${BASH_COMMAND}"' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

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
  mode: ${READ_MODE}
EOF
}

wait_for_leader() {
  local servers=""
  local out=""
  local leader=""
  local leader_addr=""
  for _ in $(seq 1 60); do
    servers="$(all_servers)"
    out="$(raw_client_cmd_to_servers "${servers}" leader 2>/dev/null || true)"
    leader="$(awk '{print $1}' <<<"${out}")"
    leader_addr="$(awk '{print $2}' <<<"${out}")"
    if [[ "${leader}" =~ ^[1-3]$ ]] && server_list_contains "${servers}" "${leader_addr}"; then
      LAST_LEADER="${out}"
      echo "${leader}"
      return 0
    fi
    sleep 1
  done
  record_error "leader was not elected in time; last response: ${out}"
  return 1
}

choose_follower() {
  local leader="$1"
  local id
  for id in 1 2 3; do
    [[ "${id}" != "${leader}" ]] && echo "${id}" && return 0
  done
}

run_worker() {
  local worker_id="$1"
  local out_file="${WORKER_DIR}/worker${worker_id}.jsonl"
  local traceback_file="${WORKER_DIR}/worker${worker_id}.traceback"
  python3 - "${worker_id}" "${out_file}" "${CLIENT}" "$(all_servers)" "${SEED}" "${OPERATIONS_PER_CLIENT}" "${KEY_COUNT}" "${CLIENT_TIMEOUT_MS}" "${CLIENT_RETRIES}" "${CLIENT_COMMAND_ATTEMPTS}" "${CLIENT_COMMAND_RETRY_SLEEP_MS}" "${WORKER_JITTER_MS}" "${ATTEMPT_LOG}" "${traceback_file}" <<'PY'
import json
import random
import subprocess
import sys
import time
import traceback

worker_id = int(sys.argv[1])
out_file = sys.argv[2]
client = sys.argv[3]
servers = sys.argv[4]
seed = int(sys.argv[5]) + worker_id * 1000003
operation_count = int(sys.argv[6])
key_count = int(sys.argv[7])
timeout_ms = sys.argv[8]
client_retries = sys.argv[9]
attempts = int(sys.argv[10])
retry_sleep_ms = int(sys.argv[11])
jitter_ms = int(sys.argv[12])
attempt_log = sys.argv[13]
traceback_file = sys.argv[14]
rng = random.Random(seed)
client_id = "linear_worker_%s_%s" % (worker_id, seed)

def write_uncaught_traceback(exc_type, exc_value, exc_traceback):
    with open(traceback_file, "w", encoding="utf-8") as f:
        traceback.print_exception(exc_type, exc_value, exc_traceback, file=f)
    traceback.print_exception(exc_type, exc_value, exc_traceback)

sys.excepthook = write_uncaught_traceback

def monotonic_ns():
    if hasattr(time, "monotonic_ns"):
        return int(time.monotonic_ns())
    return int(time.monotonic() * 1000000000)

def classify(status, stdout, stderr, op):
    text = (stdout + "\n" + stderr).strip()
    if status == 0:
        if op in ("put", "delete") and stdout.strip() == "OK":
            return "SUCCESS", "OK", stdout.strip(), True
        if op in ("get", "append") and stdout.strip():
            return "SUCCESS", "OK", stdout.strip(), True
    if "KEY_NOT_FOUND" in text or "key not found" in text:
        return "EXPECTED_APPLICATION_ERROR", "KEY_NOT_FOUND", "", False
    transient_words = [
        "NOT_LEADER", "not leader", "connect failed", "connection refused",
        "request failed", "empty response", "timed out", "timeout",
        "unavailable", "broken pipe", "connection reset",
    ]
    if any(word.lower() in text.lower() for word in transient_words):
        return "RETRIABLE_INFRASTRUCTURE_ERROR", "INFRASTRUCTURE_ERROR", text, False
    return "FATAL_ERROR", "UNKNOWN", text, False

with open(out_file, "w", encoding="utf-8") as history:
    for request_id in range(1, operation_count + 1):
        op = rng.choice(["put", "get", "append", "delete"])
        key = "k%s" % rng.randint(1, key_count)
        value = ""
        if op in ("put", "append"):
            value = "w%s_r%s_%s" % (worker_id, request_id, rng.randint(0, 9999))
        args = [
            client, "--servers=" + servers, "--timeout_ms=" + timeout_ms,
            "--retries=" + client_retries, "--client_id=" + client_id,
            "--request_id=" + str(request_id), op, key,
        ]
        if op in ("put", "append"):
            args.append(value)
        invoke = monotonic_ns()
        final = ("RETRIABLE_INFRASTRUCTURE_ERROR", "INFRASTRUCTURE_ERROR", "", False)
        retry_count = 0
        for attempt in range(1, attempts + 1):
            proc = subprocess.run(
                args,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
            )
            stdout = proc.stdout.strip()
            stderr = proc.stderr.strip()
            result_class, app_status, response, success = classify(proc.returncode, stdout, stderr, op)
            with open(attempt_log, "a", encoding="utf-8") as attempts_file:
                attempts_file.write(
                    "worker=%s request_id=%s attempt=%s op=%s key=%s status=%s result=%s stdout=%r stderr=%r\n"
                    % (worker_id, request_id, attempt, op, key, proc.returncode, result_class, stdout, stderr)
                )
            final = (result_class, app_status, response, success)
            retry_count = attempt - 1
            if result_class in ("SUCCESS", "EXPECTED_APPLICATION_ERROR"):
                break
            if result_class == "FATAL_ERROR":
                break
            time.sleep(retry_sleep_ms / 1000.0)
        complete = monotonic_ns()
        record = {
            "sequence": worker_id * 1000000 + request_id,
            "worker_id": worker_id,
            "client_id": client_id,
            "request_id": request_id,
            "operation": op,
            "key": key,
            "input_value": value,
            "invoke_time_ns": invoke,
            "complete_time_ns": complete,
            "result_class": final[0],
            "application_status": final[1],
            "response_value": final[2],
            "final_success": final[3],
            "retry_count": retry_count,
        }
        history.write(json.dumps(record, sort_keys=True) + "\n")
        history.flush()
        if final[0] == "FATAL_ERROR":
            sys.exit(1)
        if jitter_ms > 0:
            time.sleep(rng.randint(0, jitter_ms) / 1000.0)
PY
}

merge_history() {
  python3 - "${HISTORY_FILE}" "${WORKER_DIR}"/worker*.jsonl <<'PY'
import json
import sys

records = []
for path in sys.argv[2:]:
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                records.append(json.loads(line))
records.sort(key=lambda r: (int(r["invoke_time_ns"]), int(r["complete_time_ns"]), int(r["worker_id"]), int(r["request_id"])))
with open(sys.argv[1], "w", encoding="utf-8") as out:
    for seq, record in enumerate(records, 1):
        record["sequence"] = seq
        out.write(json.dumps(record, sort_keys=True) + "\n")
PY
}

wait_for_worker_progress() {
  local min_records="$1"
  local deadline="$((SECONDS + 20))"
  local worker
  local file
  while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    local ready=0
    for worker in $(seq 1 "${CLIENT_COUNT}"); do
      file="${WORKER_DIR}/worker${worker}.jsonl"
      if [[ -f "${file}" ]] && [[ "$(wc -l <"${file}")" -ge "${min_records}" ]]; then
        ready="$((ready + 1))"
      fi
    done
    [[ "${ready}" -eq "${CLIENT_COUNT}" ]] && return 0
    sleep 0.1
  done
  record_error "workers did not all reach ${min_records} recorded operations before fault injection"
  return 1
}

dump_node() {
  local id="$1"
  local out=""
  local err_file="${REPORT_DIR}/node${id}.dump.err"
  for _ in $(seq 1 30); do
    if out="$(raw_client_cmd_to_servers "$(node_client_addr "${id}")" dump 2>"${err_file}")"; then
      printf '%s\n' "${out}" | sort >"${REPORT_DIR}/node${id}.dump"
      rm -f "${err_file}"
      return 0
    fi
    sleep 1
  done
  record_error "final dump failed for node${id}: $(cat "${err_file}" 2>/dev/null || true)"
  return 1
}

check_final_consistency() {
  set_step "final_consistency"
  local attempt
  local id
  for attempt in $(seq 1 60); do
    for id in 1 2 3; do dump_node "${id}"; done
    if cmp -s "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node2.dump" &&
      cmp -s "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node3.dump"; then
      return 0
    fi
    sleep 1
  done
  diff -u "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node2.dump" >"${REPORT_DIR}/node1_node2.diff" 2>/dev/null || true
  diff -u "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node3.dump" >"${REPORT_DIR}/node1_node3.diff" 2>/dev/null || true
  record_error "final dumps did not converge"
  return 1
}

ensure_under_root "${RUN_DIR}" "${TEST_DATA_ROOT}"
ensure_under_root "${REPORT_DIR}" "${TEST_REPORT_ROOT}"
case "${FAULT_MODE}" in
  none|follower_restart|leader_restart|full) ;;
  *) record_error "unsupported FAULT_MODE=${FAULT_MODE}; expected none, follower_restart, leader_restart, or full"; exit 1 ;;
esac
mkdir -p "${CONFIG_DIR}" "${PID_DIR}" "${NODE_LOG_DIR}" "${WORKER_DIR}" "${REPORT_DIR}"
rm -f "${HISTORY_FILE}" "${NORMALIZED_HISTORY_FILE}" "${FAULTS_FILE}" "${ATTEMPT_LOG}" \
  "${FAILURE_JSON_FILE}" "${FAILURE_TEXT_FILE}" "${FAILURE_FRAGMENT_FILE}" \
  "${LAST_ERROR_FILE}" "${FAILURE_CONTEXT_FILE}"
touch "${FAULTS_FILE}" "${ATTEMPT_LOG}"

cd "${ROOT_DIR}"

if [[ ! -x "${SERVER}" || ! -x "${CLIENT}" ]]; then
  cmake --build "${BUILD_DIR}" -j1 --target kv_server kv_client
fi

{
  echo "run_id=${RUN_ID}"
  echo "seed=${SEED}"
  echo "client_count=${CLIENT_COUNT}"
  echo "operations_per_client=${OPERATIONS_PER_CLIENT}"
  echo "key_count=${KEY_COUNT}"
  echo "raft_base_port=${RAFT_BASE_PORT}"
  echo "client_base_port=${CLIENT_BASE_PORT}"
  echo "client_timeout_ms=${CLIENT_TIMEOUT_MS}"
  echo "client_retries=${CLIENT_RETRIES}"
  echo "client_command_attempts=${CLIENT_COMMAND_ATTEMPTS}"
  echo "client_command_retry_sleep_ms=${CLIENT_COMMAND_RETRY_SLEEP_MS}"
  echo "worker_jitter_ms=${WORKER_JITTER_MS}"
  echo "snapshot_max_log_entries=${SNAPSHOT_MAX_LOG_ENTRIES}"
  echo "fault_mode=${FAULT_MODE}"
  echo "checker_timeout_seconds=${CHECKER_TIMEOUT_SECONDS}"
  echo "checker_timeout_ms=${CHECKER_TIMEOUT_MS}"
  echo "checker_max_records_per_key=${CHECKER_MAX_RECORDS_PER_KEY}"
  echo "save_normalized_history=${SAVE_NORMALIZED_HISTORY}"
  echo "data_dir=${CLUSTER_DATA_DIR}"
  echo "report_dir=${REPORT_DIR}"
  echo "replay_command=SEED=${SEED} CLIENT_COUNT=${CLIENT_COUNT} OPERATIONS_PER_CLIENT=${OPERATIONS_PER_CLIENT} KEY_COUNT=${KEY_COUNT} FAULT_MODE=${FAULT_MODE} CHECKER_TIMEOUT_SECONDS=${CHECKER_TIMEOUT_SECONDS} SAVE_NORMALIZED_HISTORY=${SAVE_NORMALIZED_HISTORY} RUN_ID=${RUN_ID} bash scripts/test_concurrent_linearizability.sh"
} >"${REPORT_DIR}/run_info.txt"
cp "${REPORT_DIR}/run_info.txt" "${REPORT_DIR}/config.txt"

set_step "write_config"
for id in 1 2 3; do write_config "${id}"; done

set_step "start_cluster"
for id in 1 2 3; do start_node "${id}"; done
leader="$(wait_for_leader)"
follower="$(choose_follower "${leader}")"

set_step "run_concurrent_workers"
for worker in $(seq 1 "${CLIENT_COUNT}"); do
  run_worker "${worker}" &
  WORKER_PIDS+=("$!")
done

if [[ "${FAULT_MODE}" == "follower_restart" || "${FAULT_MODE}" == "full" ]]; then
  wait_for_worker_progress 1
  stop_node "${follower}" "follower_down_during_workload"
  sleep 1
  start_node "${follower}"
fi

if [[ "${FAULT_MODE}" == "leader_restart" || "${FAULT_MODE}" == "full" ]]; then
  wait_for_worker_progress 2
  leader="$(wait_for_leader)"
  stop_node "${leader}" "leader_down_during_workload"
  wait_for_leader >/dev/null
  sleep 1
  start_node "${leader}"
  wait_for_leader >/dev/null
fi

worker_status=0
for pid in "${WORKER_PIDS[@]}"; do
  if ! wait "${pid}"; then
    worker_status=1
  fi
done
WORKER_PIDS=()
[[ "${worker_status}" -eq 0 ]] || { record_error "one or more workers failed"; exit 1; }

merge_history

set_step "checker"
checker_args=(
  "${CHECKER}"
  --history "${HISTORY_FILE}"
  --timeout_ms "${CHECKER_TIMEOUT_MS}"
  --max-records-per-key "${CHECKER_MAX_RECORDS_PER_KEY}"
  --failure-fragment "${FAILURE_FRAGMENT_FILE}"
  --failure-json "${FAILURE_JSON_FILE}"
  --failure-text "${FAILURE_TEXT_FILE}"
)
if [[ "${SAVE_NORMALIZED_HISTORY}" == "1" ]]; then
  checker_args+=(--normalized-history "${NORMALIZED_HISTORY_FILE}")
fi
if python3 "${checker_args[@]}" >"${REPORT_DIR}/checker_output.txt" 2>&1; then
  :
else
  status="$?"
  cat "${REPORT_DIR}/checker_output.txt"
  record_error "linearizability checker failed with status ${status}"
  exit "${status}"
fi

set_step "recover_all_nodes"
for id in 1 2 3; do
  pid_file="${PID_DIR}/node${id}.pid"
  if [[ ! -f "${pid_file}" ]] || ! process_running "$(cat "${pid_file}")"; then
    start_node "${id}"
  fi
done
wait_for_leader >/dev/null
check_final_consistency

{
  cat "${REPORT_DIR}/run_info.txt"
  echo "status=PASS"
  echo "history=${HISTORY_FILE}"
  echo "normalized_history=${NORMALIZED_HISTORY_FILE}"
  echo "faults=${FAULTS_FILE}"
  echo "checker_output=${REPORT_DIR}/checker_output.txt"
  echo "linearizability_failure_json=${FAILURE_JSON_FILE}"
  echo "linearizability_failure_text=${FAILURE_TEXT_FILE}"
  echo "attempt_log=${ATTEMPT_LOG}"
  echo "node_log_dir=${NODE_LOG_DIR}"
} >"${REPORT_DIR}/summary.txt"
