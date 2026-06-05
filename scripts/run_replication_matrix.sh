#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DATA_ROOT="${TEST_DATA_ROOT:-/tmp/raftkv-test-data}"
TEST_REPORT_ROOT="${TEST_REPORT_ROOT:-/tmp/raftkv-test-reports}"
RUN_ID="${RUN_ID:-replication-matrix-$(date +%Y%m%d-%H%M%S)-$$}"
DELAY_MS_LIST="${DELAY_MS_LIST:-0 10 50 100}"
BATCH_SIZE_LIST="${BATCH_SIZE_LIST:-1 8 64}"
WORKLOAD_COUNT="${WORKLOAD_COUNT:-200}"
BUILD_JOBS="${BUILD_JOBS:-1}"
PORT_OFFSET="${PORT_OFFSET:-$((($$ % 500) * 20))}"
RAFT_BASE_PORT_ROOT="${RAFT_BASE_PORT:-$((52000 + PORT_OFFSET))}"
CLIENT_BASE_PORT_ROOT="${CLIENT_BASE_PORT:-$((53000 + PORT_OFFSET))}"
MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER="${MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER:-1}"
CLIENT_TIMEOUT_MS="${CLIENT_TIMEOUT_MS:-1000}"
CLIENT_RETRIES="${CLIENT_RETRIES:-10}"
TEST_DATA_DIR="${TEST_DATA_ROOT}/${RUN_ID}"
REPORT_DIR="${TEST_REPORT_ROOT}/${RUN_ID}/replication-matrix"
BUILD_DIR="${ROOT_DIR}/build/raft"
SERVER="${ROOT_DIR}/bin/kv_server"
CLIENT="${ROOT_DIR}/bin/kv_client"
SUMMARY_FILE="${REPORT_DIR}/summary.txt"
RESULTS_CSV="${REPORT_DIR}/results.csv"
RESULTS_MD="${REPORT_DIR}/results.md"
FAULTS_FILE="${REPORT_DIR}/faults.jsonl"
CURRENT_GROUP=""
CURRENT_GROUP_DIR=""
CURRENT_REPORT_DIR=""
CONFIG_DIR=""
PID_DIR=""
NODE_LOG_DIR=""
RAFT_BASE_PORT_CASE=0
CLIENT_BASE_PORT_CASE=0
CLIENT_SERVERS=""
CASE_INDEX=0
CURRENT_STEP="init"
LAST_ERROR=""
LAST_DISCOVERED_LEADER=""
GROUP_PID_DIRS=()

ensure_under_root() {
  local path="$1"
  local root="$2"
  case "${path}" in
    "${root}"/*) ;;
    *) echo "ERROR: refusing path outside ${root}: ${path}" >&2; exit 1 ;;
  esac
}

now_ms() {
  date +%s%3N
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
    for _ in $(seq 1 40); do
      ! process_running "${pid}" && return 0
      sleep 0.2
    done
    kill -9 "${pid}" || true
  fi
}

stop_group_nodes() {
  local pid_file
  for pid_file in "${PID_DIR}"/node*.pid; do
    [[ -f "${pid_file}" ]] || continue
    stop_pid "$(cat "${pid_file}")"
    rm -f "${pid_file}"
  done
}

cleanup_all() {
  local pid_dir pid_file
  for pid_dir in "${GROUP_PID_DIRS[@]}"; do
    for pid_file in "${pid_dir}"/node*.pid; do
      [[ -f "${pid_file}" ]] || continue
      stop_pid "$(cat "${pid_file}")"
      rm -f "${pid_file}"
    done
  done
  copy_group_logs || true
}

on_signal() {
  LAST_ERROR="interrupted at ${CURRENT_STEP}"
  write_summary "INTERRUPTED" || true
  cleanup_all || true
  exit 130
}

trap cleanup_all EXIT
trap on_signal INT TERM

fail() {
  LAST_ERROR="$*"
  echo "FAIL: $*" >&2
  capture_status "${CURRENT_REPORT_DIR}/status_on_failure.txt" || true
  copy_group_logs || true
  write_summary "FAIL" || true
  exit 1
}

set_step() {
  CURRENT_STEP="$1"
  echo "step=${CURRENT_STEP}"
}

write_summary() {
  local status="${1:-RUNNING}"
  {
    echo "run_id=${RUN_ID}"
    echo "status=${status}"
    echo "current_step=${CURRENT_STEP}"
    echo "current_group=${CURRENT_GROUP}"
    echo "report_dir=${REPORT_DIR}"
    echo "data_dir=${TEST_DATA_DIR}"
    echo "delay_ms_list=${DELAY_MS_LIST}"
    echo "batch_size_list=${BATCH_SIZE_LIST}"
    echo "workload_count=${WORKLOAD_COUNT}"
    echo "max_inflight_append_entries_per_peer=${MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER}"
    echo "last_error=${LAST_ERROR}"
    echo "replay_command=$(cat "${REPORT_DIR}/replay_command.txt" 2>/dev/null || true)"
  } >"${SUMMARY_FILE}"
}

record_fault() {
  local group="$1"
  local event="$2"
  local node="$3"
  local note="$4"
  printf '{"time":"%s","group":"%s","event":"%s","node":%s,"note":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${group}" "${event}" "${node}" "${note}" >>"${FAULTS_FILE}"
}

node_client_addr() {
  echo "127.0.0.1:$((CLIENT_BASE_PORT_CASE + $1))"
}

status_value() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key {print $2; exit}'
}

node_status() {
  local id="$1"
  "${CLIENT}" --servers="$(node_client_addr "${id}")" --timeout_ms="${CLIENT_TIMEOUT_MS}" --retries=1 status
}

metric_sum() {
  local file="$1"
  local key="$2"
  awk -F= -v key="${key}" '$1 == key {sum += $2} END {print sum + 0}' "${file}"
}

metric_max() {
  local file="$1"
  local key="$2"
  awk -F= -v key="${key}" '$1 == key && $2 > max {max = $2} END {print max + 0}' "${file}"
}

metric_delta() {
  local before_file="$1"
  local after_file="$2"
  local key="$3"
  local before after
  before="$(metric_sum "${before_file}" "${key}")"
  after="$(metric_sum "${after_file}" "${key}")"
  echo "$((after - before))"
}

capture_status() {
  local output_file="$1"
  mkdir -p "$(dirname "${output_file}")"
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
    install_snapshot_sent \
    install_snapshot_success \
    install_snapshot_failed \
    snapshot_created_count \
    append_entries_batch_rpc_count \
    append_entries_entries_sent \
    append_entries_empty_heartbeat_count \
    append_entries_max_batch_observed \
    follower_catchup_attempts \
    follower_catchup_success \
    append_entries_stale_response_ignored \
    append_entries_inflight_rejected; do
    before="$(metric_sum "${before_file}" "${metric}")"
    after="$(metric_sum "${after_file}" "${metric}")"
    echo "${metric}=$((after - before))" >>"${output_file}"
  done
}

copy_group_logs() {
  [[ -n "${CURRENT_REPORT_DIR}" ]] || return 0
  mkdir -p "${CURRENT_REPORT_DIR}/node_logs"
  local log_file
  for log_file in "${NODE_LOG_DIR}"/node*.log; do
    [[ -f "${log_file}" ]] && cp "${log_file}" "${CURRENT_REPORT_DIR}/node_logs/" || true
  done
}

begin_group() {
  local delay_ms="$1"
  local batch_size="$2"
  CASE_INDEX=$((CASE_INDEX + 1))
  CURRENT_GROUP="delay_${delay_ms}_batch_${batch_size}"
  CURRENT_GROUP_DIR="${TEST_DATA_DIR}/${CURRENT_GROUP}"
  CURRENT_REPORT_DIR="${REPORT_DIR}/${CURRENT_GROUP}"
  CONFIG_DIR="${CURRENT_GROUP_DIR}/config"
  PID_DIR="${CURRENT_GROUP_DIR}/pids"
  NODE_LOG_DIR="${CURRENT_GROUP_DIR}/logs"
  RAFT_BASE_PORT_CASE=$((RAFT_BASE_PORT_ROOT + CASE_INDEX * 200))
  CLIENT_BASE_PORT_CASE=$((CLIENT_BASE_PORT_ROOT + CASE_INDEX * 200))
  CLIENT_SERVERS="127.0.0.1:$((CLIENT_BASE_PORT_CASE + 1)),127.0.0.1:$((CLIENT_BASE_PORT_CASE + 2)),127.0.0.1:$((CLIENT_BASE_PORT_CASE + 3))"
  GROUP_PID_DIRS+=("${PID_DIR}")
  mkdir -p "${CONFIG_DIR}" "${PID_DIR}" "${NODE_LOG_DIR}" "${CURRENT_REPORT_DIR}"
  {
    echo "group=${CURRENT_GROUP}"
    echo "delay_ms=${delay_ms}"
    echo "batch_size=${batch_size}"
    echo "workload_count=${WORKLOAD_COUNT}"
    echo "raft_base_port=${RAFT_BASE_PORT_CASE}"
    echo "client_base_port=${CLIENT_BASE_PORT_CASE}"
    echo "client_servers=${CLIENT_SERVERS}"
    echo "max_inflight_append_entries_per_peer=${MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER}"
  } >"${CURRENT_REPORT_DIR}/config.txt"
}

write_config() {
  local id="$1"
  local batch_size="$2"
  local data_dir="${CURRENT_GROUP_DIR}/node${id}"
  cat >"${CONFIG_DIR}/node${id}.yaml" <<EOF
node_id: ${id}
listen_addr: 127.0.0.1:$((RAFT_BASE_PORT_CASE + id))
client_addr: 127.0.0.1:$((CLIENT_BASE_PORT_CASE + id))
data_dir: ${data_dir}

peers:
  - id: 1
    addr: 127.0.0.1:$((RAFT_BASE_PORT_CASE + 1))
    client_addr: 127.0.0.1:$((CLIENT_BASE_PORT_CASE + 1))
  - id: 2
    addr: 127.0.0.1:$((RAFT_BASE_PORT_CASE + 2))
    client_addr: 127.0.0.1:$((CLIENT_BASE_PORT_CASE + 2))
  - id: 3
    addr: 127.0.0.1:$((RAFT_BASE_PORT_CASE + 3))
    client_addr: 127.0.0.1:$((CLIENT_BASE_PORT_CASE + 3))

snapshot:
  max_log_entries: 100000
  snapshot_dir: ${data_dir}

raft:
  election_timeout_ms_min: 300
  election_timeout_ms_max: 600
  heartbeat_interval_ms: 100
  rpc_timeout_ms: 300
  pre_vote: true
  check_quorum: true
  max_append_entries_per_rpc: ${batch_size}
  max_inflight_append_entries_per_peer: ${MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER}

read:
  mode: log
EOF
}

start_node() {
  local id="$1"
  local delay_ms="${2:-0}"
  local log_file="${NODE_LOG_DIR}/node${id}.log"
  env CRAFTKV_TEST_APPEND_ENTRIES_DELAY_MS="${delay_ms}" \
    CRAFTKV_TEST_INSTALL_SNAPSHOT_DELAY_MS=0 \
    "${SERVER}" --config="${CONFIG_DIR}/node${id}.yaml" >"${log_file}" 2>&1 &
  echo "$!" >"${PID_DIR}/node${id}.pid"
}

start_cluster() {
  local batch_size="$1"
  local id
  for id in 1 2 3; do
    write_config "${id}" "${batch_size}"
  done
  for id in 1 2 3; do
    start_node "${id}" 0
  done
}

discover_leader() {
  local id out role node_id leader="" leader_count=0
  for id in 1 2 3; do
    out="$(node_status "${id}" 2>/dev/null || true)"
    role="$(status_value role <<<"${out}")"
    node_id="$(status_value node_id <<<"${out}")"
    if [[ "${role}" == "LEADER" && "${node_id}" =~ ^[1-3]$ ]]; then
      leader="${node_id}"
      leader_count=$((leader_count + 1))
    fi
  done
  if [[ "${leader_count}" -eq 1 ]]; then
    LAST_DISCOVERED_LEADER="${leader}"
    echo "${leader}"
    return 0
  fi
  return 1
}

wait_for_leader() {
  local leader
  for _ in $(seq 1 90); do
    leader="$(discover_leader 2>/dev/null || true)"
    if [[ "${leader}" =~ ^[1-3]$ ]]; then
      echo "${leader}"
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_node_unavailable() {
  local id="$1"
  local pid_file="${PID_DIR}/node${id}.pid"
  local pid=""
  [[ -f "${pid_file}" ]] && pid="$(cat "${pid_file}")"
  for _ in $(seq 1 60); do
    if { [[ -z "${pid}" ]] || ! process_running "${pid}"; } && ! node_status "${id}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

choose_follower() {
  local leader="$1"
  [[ "${leader}" != "1" ]] && echo 1 || echo 2
}

leader_from_hint() {
  local text="$1"
  if [[ "${text}" =~ leader[[:space:]]hint:[[:space:]]([1-3]) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

client_cmd_node() {
  local id="$1"
  shift
  "${CLIENT}" --servers="$(node_client_addr "${id}")" --timeout_ms="${CLIENT_TIMEOUT_MS}" --retries=1 "$@"
}

retry_write_to_leader() {
  local key="$1"
  local value="$2"
  local leader="${LAST_DISCOVERED_LEADER}"
  local attempt target stdout stderr rc hinted
  for attempt in $(seq 1 90); do
    if [[ ! "${leader}" =~ ^[1-3]$ ]]; then
      leader="$(discover_leader 2>/dev/null || true)"
    fi
    if [[ "${leader}" =~ ^[1-3]$ ]]; then
      target="${leader}"
    else
      target="$(( (attempt - 1) % 3 + 1 ))"
    fi
    set +e
    stdout="$(client_cmd_node "${target}" put "${key}" "${value}" 2>"${CURRENT_REPORT_DIR}/last_client_stderr.txt")"
    rc=$?
    set -e
    stderr="$(cat "${CURRENT_REPORT_DIR}/last_client_stderr.txt" 2>/dev/null || true)"
    if [[ "${rc}" -eq 0 && "${stdout}" == "OK" ]]; then
      LAST_DISCOVERED_LEADER="${target}"
      return 0
    fi
    hinted="$(leader_from_hint "${stdout} ${stderr}" 2>/dev/null || true)"
    if [[ "${hinted}" =~ ^[1-3]$ ]]; then
      leader="${hinted}"
    else
      leader="$(discover_leader 2>/dev/null || true)"
    fi
    sleep 0.4
  done
  return 1
}

put_workload() {
  local prefix="$1"
  local i
  for i in $(seq 1 "${WORKLOAD_COUNT}"); do
    retry_write_to_leader "${prefix}_${i}" "value_${i}" || return 1
  done
}

wait_status_caught_up() {
  local target="$1"
  local leader="$2"
  local leader_status target_status leader_commit leader_applied leader_last target_commit target_applied target_last
  for _ in $(seq 1 150); do
    leader_status="$(node_status "${leader}" 2>/dev/null || true)"
    target_status="$(node_status "${target}" 2>/dev/null || true)"
    leader_commit="$(status_value commit_index <<<"${leader_status}")"
    leader_applied="$(status_value last_applied <<<"${leader_status}")"
    leader_last="$(status_value last_log_index <<<"${leader_status}")"
    target_commit="$(status_value commit_index <<<"${target_status}")"
    target_applied="$(status_value last_applied <<<"${target_status}")"
    target_last="$(status_value last_log_index <<<"${target_status}")"
    if [[ "${leader_commit}" =~ ^[0-9]+$ && "${leader_applied}" =~ ^[0-9]+$ &&
          "${leader_last}" =~ ^[0-9]+$ && "${target_commit}" =~ ^[0-9]+$ &&
          "${target_applied}" =~ ^[0-9]+$ && "${target_last}" =~ ^[0-9]+$ &&
          "${target_commit}" -ge "${leader_commit}" &&
          "${target_applied}" -ge "${leader_applied}" &&
          "${target_last}" -ge "${leader_last}" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

dump_node() {
  local id="$1"
  "${CLIENT}" --servers="$(node_client_addr "${id}")" --timeout_ms="${CLIENT_TIMEOUT_MS}" --retries=3 dump \
    | sort >"${CURRENT_REPORT_DIR}/node${id}.dump"
}

wait_consistency() {
  for _ in $(seq 1 120); do
    if dump_node 1 && dump_node 2 && dump_node 3 &&
      cmp -s "${CURRENT_REPORT_DIR}/node1.dump" "${CURRENT_REPORT_DIR}/node2.dump" &&
      cmp -s "${CURRENT_REPORT_DIR}/node1.dump" "${CURRENT_REPORT_DIR}/node3.dump"; then
      return 0
    fi
    sleep 1
  done
  diff -u "${CURRENT_REPORT_DIR}/node1.dump" "${CURRENT_REPORT_DIR}/node2.dump" >"${CURRENT_REPORT_DIR}/node1_node2.diff" || true
  diff -u "${CURRENT_REPORT_DIR}/node1.dump" "${CURRENT_REPORT_DIR}/node3.dump" >"${CURRENT_REPORT_DIR}/node1_node3.diff" || true
  return 1
}

append_result() {
  local delay_ms="$1"
  local batch_size="$2"
  local duration_ms="$3"
  local final_consistency="$4"
  local before_file="${CURRENT_REPORT_DIR}/status_before.txt"
  local after_file="${CURRENT_REPORT_DIR}/status_after.txt"
  local rpc_delta entries_delta max_batch attempts_delta success_delta install_delta snapshot_used
  rpc_delta="$(metric_delta "${before_file}" "${after_file}" append_entries_batch_rpc_count)"
  entries_delta="$(metric_delta "${before_file}" "${after_file}" append_entries_entries_sent)"
  max_batch="$(metric_max "${after_file}" append_entries_max_batch_observed)"
  attempts_delta="$(metric_delta "${before_file}" "${after_file}" follower_catchup_attempts)"
  success_delta="$(metric_delta "${before_file}" "${after_file}" follower_catchup_success)"
  install_delta="$(metric_delta "${before_file}" "${after_file}" install_snapshot_sent)"
  snapshot_used=false
  [[ "${install_delta}" -gt 0 ]] && snapshot_used=true
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${delay_ms}" "${batch_size}" "${WORKLOAD_COUNT}" "${duration_ms}" "${rpc_delta}" \
    "${entries_delta}" "${max_batch}" "${attempts_delta}" "${success_delta}" \
    "${snapshot_used}" "${final_consistency}" >>"${RESULTS_CSV}"
}

run_group() {
  local delay_ms="$1"
  local batch_size="$2"
  local leader follower start_ms end_ms duration_ms final_consistency
  set_step "group delay=${delay_ms} batch=${batch_size}"
  begin_group "${delay_ms}" "${batch_size}"
  start_cluster "${batch_size}"
  leader="$(wait_for_leader)" || fail "leader was not elected"
  LAST_DISCOVERED_LEADER="${leader}"
  follower="$(choose_follower "${leader}")"
  capture_status "${CURRENT_REPORT_DIR}/status_before.txt"
  record_fault "${CURRENT_GROUP}" "stop_follower" "${follower}" "create backlog"
  stop_pid "$(cat "${PID_DIR}/node${follower}.pid")"
  rm -f "${PID_DIR}/node${follower}.pid"
  wait_node_unavailable "${follower}" || fail "follower node${follower} did not stop"
  put_workload "matrix_d${delay_ms}_b${batch_size}" || fail "workload failed"
  record_fault "${CURRENT_GROUP}" "restart_with_append_entries_delay" "${follower}" "delay_ms=${delay_ms}"
  start_ms="$(now_ms)"
  start_node "${follower}" "${delay_ms}"
  leader="$(wait_for_leader)" || fail "leader missing after follower restart"
  wait_status_caught_up "${follower}" "${leader}" || fail "follower catch-up timed out"
  end_ms="$(now_ms)"
  duration_ms=$((end_ms - start_ms))
  if wait_consistency; then
    final_consistency=true
  else
    final_consistency=false
    fail "final consistency failed"
  fi
  capture_status "${CURRENT_REPORT_DIR}/status_after.txt"
  write_metrics_delta "${CURRENT_REPORT_DIR}/status_before.txt" "${CURRENT_REPORT_DIR}/status_after.txt" "${CURRENT_REPORT_DIR}/metrics_delta.txt"
  append_result "${delay_ms}" "${batch_size}" "${duration_ms}" "${final_consistency}"
  copy_group_logs
  stop_group_nodes
}

write_results_md() {
  {
    echo "| delay_ms | batch_size | workload_count | catchup_duration_ms | append_entries_batch_rpc_count | append_entries_entries_sent | append_entries_max_batch_observed | follower_catchup_attempts | follower_catchup_success | snapshot_used | final_consistency |"
    echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    tail -n +2 "${RESULTS_CSV}" | awk -F, '{printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11}'
  } >"${RESULTS_MD}"
}

for value in ${DELAY_MS_LIST}; do
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: DELAY_MS_LIST contains non-negative integer only: ${value}" >&2
    exit 2
  fi
done
for value in ${BATCH_SIZE_LIST}; do
  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: BATCH_SIZE_LIST contains positive integer only: ${value}" >&2
    exit 2
  fi
done
if [[ ! "${WORKLOAD_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: WORKLOAD_COUNT must be positive" >&2
  exit 2
fi
if [[ "${MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER}" != "1" ]]; then
  echo "ERROR: MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER must be 1 in this stage" >&2
  exit 2
fi

ensure_under_root "${TEST_DATA_DIR}" "${TEST_DATA_ROOT}"
ensure_under_root "${REPORT_DIR}" "${TEST_REPORT_ROOT}"
mkdir -p "${TEST_DATA_DIR}" "${REPORT_DIR}"
: >"${FAULTS_FILE}"
cat >"${RESULTS_CSV}" <<'EOF'
delay_ms,batch_size,workload_count,catchup_duration_ms,append_entries_batch_rpc_count,append_entries_entries_sent,append_entries_max_batch_observed,follower_catchup_attempts,follower_catchup_success,snapshot_used,final_consistency
EOF
{
  echo "RUN_ID=${RUN_ID} DELAY_MS_LIST=\"${DELAY_MS_LIST}\" BATCH_SIZE_LIST=\"${BATCH_SIZE_LIST}\" WORKLOAD_COUNT=${WORKLOAD_COUNT} RAFT_BASE_PORT=${RAFT_BASE_PORT_ROOT} CLIENT_BASE_PORT=${CLIENT_BASE_PORT_ROOT} bash scripts/run_replication_matrix.sh"
} >"${REPORT_DIR}/replay_command.txt"
{
  echo "run_id=${RUN_ID}"
  echo "delay_ms_list=${DELAY_MS_LIST}"
  echo "batch_size_list=${BATCH_SIZE_LIST}"
  echo "workload_count=${WORKLOAD_COUNT}"
  echo "raft_base_port_root=${RAFT_BASE_PORT_ROOT}"
  echo "client_base_port_root=${CLIENT_BASE_PORT_ROOT}"
  echo "max_inflight_append_entries_per_peer=${MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER}"
} >"${REPORT_DIR}/config.txt"
write_summary "RUNNING"

cd "${ROOT_DIR}"

set_step "build"
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT=ON
cmake --build "${BUILD_DIR}" -j"${BUILD_JOBS}" --target kv_server kv_client

for delay_ms in ${DELAY_MS_LIST}; do
  for batch_size in ${BATCH_SIZE_LIST}; do
    run_group "${delay_ms}" "${batch_size}"
  done
done

write_results_md
write_summary "PASS"

echo "REPLICATION MATRIX PASSED"
echo "summary=${SUMMARY_FILE}"
echo "results_csv=${RESULTS_CSV}"
