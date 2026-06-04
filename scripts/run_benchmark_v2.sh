#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DATA_ROOT="${TEST_DATA_ROOT:-/tmp/raftkv-test-data}"
TEST_REPORT_ROOT="${TEST_REPORT_ROOT:-/tmp/raftkv-test-reports}"
RUN_ID="${RUN_ID:-benchmark-v2-$(date +%Y%m%d-%H%M%S)-$$}"
SCENARIO="${SCENARIO:-steady}"
THREADS="${THREADS:-4}"
DURATION_SECONDS="${DURATION_SECONDS:-30}"
WARMUP_SECONDS="${WARMUP_SECONDS:-5}"
KEY_COUNT="${KEY_COUNT:-1000}"
VALUE_SIZE="${VALUE_SIZE:-128}"
READ_PERCENT="${READ_PERCENT:-70}"
PUT_PERCENT="${PUT_PERCENT:-20}"
APPEND_PERCENT="${APPEND_PERCENT:-5}"
DELETE_PERCENT="${DELETE_PERCENT:-5}"
SEED="${SEED:-20260604}"
BUILD_JOBS="${BUILD_JOBS:-1}"
RAFT_BASE_PORT="${RAFT_BASE_PORT:-38000}"
CLIENT_BASE_PORT="${CLIENT_BASE_PORT:-39000}"

RUN_DIR="${TEST_DATA_ROOT}/${RUN_ID}"
CLUSTER_DATA_DIR="${RUN_DIR}/benchmark-v2"
CONFIG_DIR="${CLUSTER_DATA_DIR}/config"
PID_DIR="${CLUSTER_DATA_DIR}/pids"
NODE_LOG_DIR="${CLUSTER_DATA_DIR}/logs"
REPORT_DIR="${TEST_REPORT_ROOT}/${RUN_ID}/benchmark-v2"
BUILD_DIR="${ROOT_DIR}/build/raft"
CLIENT_SERVERS="127.0.0.1:$((CLIENT_BASE_PORT + 1)),127.0.0.1:$((CLIENT_BASE_PORT + 2)),127.0.0.1:$((CLIENT_BASE_PORT + 3))"
CLIENT="${ROOT_DIR}/bin/kv_client"
BENCH="${ROOT_DIR}/bin/kv_bench"
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
    for _ in $(seq 1 30); do
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

copy_node_logs() {
  mkdir -p "${REPORT_DIR}/node_logs"
  local log_file
  for log_file in "${NODE_LOG_DIR}"/node*.log; do
    [[ -f "${log_file}" ]] || continue
    cp "${log_file}" "${REPORT_DIR}/node_logs/" || true
  done
}

cleanup() {
  copy_node_logs || true
  local pid_file
  for pid_file in "${PID_DIR}"/node*.pid; do
    [[ -f "${pid_file}" ]] || continue
    stop_pid "$(cat "${pid_file}")"
  done
}

on_signal() {
  cleanup
  exit 130
}

trap cleanup EXIT
trap on_signal INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

client_addr_for_node() {
  local id="$1"
  echo "127.0.0.1:$((CLIENT_BASE_PORT + id))"
}

status_value() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key {print $2; exit}'
}

node_status() {
  local id="$1"
  "${CLIENT}" --servers="$(client_addr_for_node "${id}")" --timeout_ms=1000 --retries=1 status
}

metric_sum() {
  local file="$1"
  local key="$2"
  awk -F= -v key="${key}" '$1 == key {sum += $2} END {print sum + 0}' "${file}"
}

capture_status() {
  local output_file="$1"
  : >"${output_file}"
  local id
  for id in 1 2 3; do
    {
      echo "===== node${id} ====="
      node_status "${id}" || echo "UNAVAILABLE"
      echo
    } >>"${output_file}"
  done
}

write_metrics_delta() {
  local before_file="$1"
  local after_file="$2"
  local output_file="$3"
  local metric before after
  : >"${output_file}"
  for metric in \
    append_entries_sent \
    append_entries_success \
    append_entries_failed \
    request_vote_sent \
    install_snapshot_sent \
    snapshot_created_count \
    client_request_total \
    client_request_success \
    client_request_failed; do
    before="$(metric_sum "${before_file}" "${metric}")"
    after="$(metric_sum "${after_file}" "${metric}")"
    echo "${metric}=$((after - before))" >>"${output_file}"
  done
}

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
  max_log_entries: 100000
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

wait_for_leader() {
  local previous="${1:-}"
  local id status role node_id leader=""
  for _ in $(seq 1 60); do
    leader=""
    for id in 1 2 3; do
      status="$(node_status "${id}" 2>/dev/null || true)"
      role="$(status_value role <<<"${status}")"
      node_id="$(status_value node_id <<<"${status}")"
      if [[ "${role}" == "LEADER" ]]; then
        if [[ -n "${leader}" ]]; then
          leader=""
          break
        fi
        leader="${node_id:-${id}}"
      fi
    done
    if [[ "${leader}" =~ ^[1-3]$ ]]; then
      if [[ -z "${previous}" || "${leader}" != "${previous}" ]]; then
        echo "${leader}"
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

record_fault() {
  local event="$1"
  local node="$2"
  local note="$3"
  printf '{"time":"%s","scenario":"%s","event":"%s","node":%s,"note":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SCENARIO}" "${event}" "${node}" "${note}" >>"${REPORT_DIR}/faults.jsonl"
}

choose_follower() {
  local leader="$1"
  if [[ "${leader}" != "1" ]]; then
    echo 1
  else
    echo 2
  fi
}

run_fault_controller() {
  local leader="$1"
  local sleep_seconds=$((WARMUP_SECONDS + DURATION_SECONDS / 2))
  sleep "${sleep_seconds}"
  if [[ "${SCENARIO}" == "follower_down" ]]; then
    local follower
    follower="$(choose_follower "${leader}")"
    record_fault "stop_follower" "${follower}" "benchmark midpoint"
    stop_pid "$(cat "${PID_DIR}/node${follower}.pid")"
  elif [[ "${SCENARIO}" == "leader_failover" ]]; then
    record_fault "stop_leader" "${leader}" "benchmark midpoint"
    stop_pid "$(cat "${PID_DIR}/node${leader}.pid")"
    local start_ns end_ns new_leader
    start_ns="$(date +%s%N)"
    new_leader="$(wait_for_leader "${leader}" || true)"
    end_ns="$(date +%s%N)"
    if [[ "${new_leader}" =~ ^[1-3]$ ]]; then
      record_fault "new_leader" "${new_leader}" "recovery_ms=$(((end_ns - start_ns) / 1000000))"
    else
      record_fault "new_leader_timeout" 0 "leader was not recovered in time"
    fi
  fi
}

case "${SCENARIO}" in
  steady|follower_down|leader_failover) ;;
  *) fail "unknown SCENARIO: ${SCENARIO}" ;;
esac

ensure_under_root "${RUN_DIR}" "${TEST_DATA_ROOT}"
ensure_under_root "${REPORT_DIR}" "${TEST_REPORT_ROOT}"
mkdir -p "${CONFIG_DIR}" "${PID_DIR}" "${NODE_LOG_DIR}" "${REPORT_DIR}"
: >"${REPORT_DIR}/faults.jsonl"

cd "${ROOT_DIR}"

cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT=ON
cmake --build "${BUILD_DIR}" -j"${BUILD_JOBS}" --target kv_server kv_client kv_bench

for id in 1 2 3; do
  write_config "${id}"
  start_node "${id}"
done

leader="$(wait_for_leader)" || fail "leader was not elected"

git rev-parse HEAD >"${REPORT_DIR}/git_commit.txt" 2>/dev/null || echo "unknown" >"${REPORT_DIR}/git_commit.txt"
git_commit="$(cat "${REPORT_DIR}/git_commit.txt")"

{
  echo "run_id=${RUN_ID}"
  echo "scenario=${SCENARIO}"
  echo "threads=${THREADS}"
  echo "duration_seconds=${DURATION_SECONDS}"
  echo "warmup_seconds=${WARMUP_SECONDS}"
  echo "key_count=${KEY_COUNT}"
  echo "value_size=${VALUE_SIZE}"
  echo "read_percent=${READ_PERCENT}"
  echo "put_percent=${PUT_PERCENT}"
  echo "append_percent=${APPEND_PERCENT}"
  echo "delete_percent=${DELETE_PERCENT}"
  echo "seed=${SEED}"
  echo "client_servers=${CLIENT_SERVERS}"
} >"${REPORT_DIR}/config.txt"

{
  hostname || true
  uname -a || true
  nproc || true
  awk '/model name|cpu cores|MemTotal|SwapTotal/ {print}' /proc/cpuinfo /proc/meminfo 2>/dev/null || true
} >"${REPORT_DIR}/machine_info.txt"

capture_status "${REPORT_DIR}/status_before.txt"

fault_pid=""
if [[ "${SCENARIO}" != "steady" ]]; then
  run_fault_controller "${leader}" &
  fault_pid="$!"
fi

"${BENCH}" \
  --servers="${CLIENT_SERVERS}" \
  --threads="${THREADS}" \
  --duration_seconds="${DURATION_SECONDS}" \
  --warmup_seconds="${WARMUP_SECONDS}" \
  --key_count="${KEY_COUNT}" \
  --value_size="${VALUE_SIZE}" \
  --read_percent="${READ_PERCENT}" \
  --put_percent="${PUT_PERCENT}" \
  --append_percent="${APPEND_PERCENT}" \
  --delete_percent="${DELETE_PERCENT}" \
  --seed="${SEED}" \
  --git_commit="${git_commit}" \
  --output_json="${REPORT_DIR}/result.json" \
  --output_csv="${REPORT_DIR}/result.csv"

if [[ -n "${fault_pid}" ]]; then
  wait "${fault_pid}" || true
fi

capture_status "${REPORT_DIR}/status_after.txt"
write_metrics_delta "${REPORT_DIR}/status_before.txt" "${REPORT_DIR}/status_after.txt" "${REPORT_DIR}/metrics_delta.txt"

{
  echo "run_id=${RUN_ID}"
  echo "scenario=${SCENARIO}"
  echo "report_dir=${REPORT_DIR}"
  echo "data_dir=${RUN_DIR}"
  awk -F[:,] '/"throughput_ops_per_second"/ || /"successful_operations"/ || /"failed_operations"/ || /"retry_count"/ || /"latency_us_p99"/ {gsub(/[ \"]/,""); print}' "${REPORT_DIR}/result.json"
} >"${REPORT_DIR}/summary.txt"

copy_node_logs

echo "BENCHMARK V2 PASSED"
echo "report_dir=${REPORT_DIR}"
