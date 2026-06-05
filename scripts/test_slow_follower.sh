#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DATA_ROOT="${TEST_DATA_ROOT:-/tmp/raftkv-test-data}"
TEST_REPORT_ROOT="${TEST_REPORT_ROOT:-/tmp/raftkv-test-reports}"
RUN_ID="${RUN_ID:-slow-follower-$(date +%Y%m%d-%H%M%S)-$$}"
RUN_DIR="${TEST_DATA_ROOT}/${RUN_ID}"
REPORT_DIR="${TEST_REPORT_ROOT}/${RUN_ID}/slow-follower"
BUILD_DIR="${ROOT_DIR}/build/raft"
BUILD_JOBS="${BUILD_JOBS:-1}"
PORT_OFFSET="${PORT_OFFSET:-$((($$ % 500) * 20))}"
RAFT_BASE_PORT_ROOT="${RAFT_BASE_PORT:-$((44000 + PORT_OFFSET))}"
CLIENT_BASE_PORT_ROOT="${CLIENT_BASE_PORT:-$((45000 + PORT_OFFSET))}"
WORKLOAD_COUNT="${WORKLOAD_COUNT:-60}"
SLOW_APPEND_DELAY_MS="${SLOW_APPEND_DELAY_MS:-75}"
SLOW_SNAPSHOT_DELAY_MS="${SLOW_SNAPSHOT_DELAY_MS:-100}"
CLIENT_TIMEOUT_MS="${CLIENT_TIMEOUT_MS:-1000}"
CLIENT_RETRIES="${CLIENT_RETRIES:-10}"
MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER="${MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER:-1}"
SERVER="${ROOT_DIR}/bin/kv_server"
CLIENT="${ROOT_DIR}/bin/kv_client"
SUMMARY_FILE="${REPORT_DIR}/summary.txt"
BATCH_RESULTS_CSV="${REPORT_DIR}/batch_size_results.csv"
FAULTS_FILE="${REPORT_DIR}/faults.jsonl"
LAST_ERROR_FILE="${REPORT_DIR}/last_error.txt"
CURRENT_STEP="init"
CURRENT_CASE=""
CASE_INDEX=0
CASE_DIR=""
CASE_REPORT_DIR=""
CONFIG_DIR=""
PID_DIR=""
NODE_LOG_DIR=""
RAFT_BASE_PORT_CASE=0
CLIENT_BASE_PORT_CASE=0
CLIENT_SERVERS=""
CURRENT_BATCH_SIZE=8
CURRENT_SNAPSHOT_MAX_LOG_ENTRIES=100000
LAST_DISCOVERED_LEADER=""
LAST_REQUEST=""
LAST_RESPONSE=""
RETRY_COUNT=0
CASE_PID_DIRS=()

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

copy_case_artifacts() {
  [[ -n "${CASE_REPORT_DIR}" ]] || return 0
  mkdir -p "${CASE_REPORT_DIR}/node_logs" "${CASE_REPORT_DIR}/config"
  local log_file cfg_file
  for log_file in "${NODE_LOG_DIR}"/node*.log; do
    [[ -f "${log_file}" ]] && cp "${log_file}" "${CASE_REPORT_DIR}/node_logs/" || true
  done
  for cfg_file in "${CONFIG_DIR}"/node*.yaml; do
    [[ -f "${cfg_file}" ]] && cp "${cfg_file}" "${CASE_REPORT_DIR}/config/" || true
  done
}

stop_case_nodes() {
  local pid_file
  for pid_file in "${PID_DIR}"/node*.pid; do
    [[ -f "${pid_file}" ]] || continue
    stop_pid "$(cat "${pid_file}")"
    rm -f "${pid_file}"
  done
}

cleanup_all() {
  local pid_dir pid_file
  for pid_dir in "${CASE_PID_DIRS[@]}"; do
    for pid_file in "${pid_dir}"/node*.pid; do
      [[ -f "${pid_file}" ]] || continue
      stop_pid "$(cat "${pid_file}")"
      rm -f "${pid_file}"
    done
  done
  copy_case_artifacts || true
}

write_summary() {
  {
    echo "run_id=${RUN_ID}"
    echo "current_step=${CURRENT_STEP}"
    echo "current_case=${CURRENT_CASE}"
    echo "report_dir=${REPORT_DIR}"
    echo "data_dir=${RUN_DIR}"
    echo "workload_count=${WORKLOAD_COUNT}"
    echo "slow_append_delay_ms=${SLOW_APPEND_DELAY_MS}"
    echo "slow_snapshot_delay_ms=${SLOW_SNAPSHOT_DELAY_MS}"
    echo "max_inflight_append_entries_per_peer=${MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER}"
    echo "replay_command=RUN_ID=${RUN_ID} RAFT_BASE_PORT=${RAFT_BASE_PORT_ROOT} CLIENT_BASE_PORT=${CLIENT_BASE_PORT_ROOT} bash scripts/test_slow_follower.sh"
    echo "last_error=$(cat "${LAST_ERROR_FILE}" 2>/dev/null || true)"
    echo "last_request=${LAST_REQUEST}"
    echo "last_response=${LAST_RESPONSE}"
    echo "last_discovered_leader=${LAST_DISCOVERED_LEADER}"
  } >"${SUMMARY_FILE}"
}

record_fault() {
  local case_name="$1"
  local event="$2"
  local node="$3"
  local note="$4"
  printf '{"time":"%s","case":"%s","event":"%s","node":%s,"note":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${case_name}" "${event}" "${node}" "${note}" >>"${FAULTS_FILE}"
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
    check_quorum_stepdown_count \
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

fail() {
  mkdir -p "${REPORT_DIR}" "${CASE_REPORT_DIR:-${REPORT_DIR}}"
  echo "$*" >"${LAST_ERROR_FILE}"
  echo "FAIL: $*" >&2
  capture_status "${CASE_REPORT_DIR}/status_on_failure.txt" || true
  copy_case_artifacts || true
  write_summary || true
  exit 1
}

on_signal() {
  echo "INTERRUPTED: ${CURRENT_STEP}" >&2
  cleanup_all || true
  write_summary || true
  exit 130
}

trap cleanup_all EXIT
trap on_signal INT TERM

set_step() {
  CURRENT_STEP="$1"
  echo "step=${CURRENT_STEP}"
}

begin_case() {
  CURRENT_CASE="$1"
  CURRENT_BATCH_SIZE="$2"
  CURRENT_SNAPSHOT_MAX_LOG_ENTRIES="$3"
  CASE_INDEX=$((CASE_INDEX + 1))
  CASE_DIR="${RUN_DIR}/${CURRENT_CASE}"
  CASE_REPORT_DIR="${REPORT_DIR}/${CURRENT_CASE}"
  CONFIG_DIR="${CASE_DIR}/config"
  PID_DIR="${CASE_DIR}/pids"
  NODE_LOG_DIR="${CASE_DIR}/logs"
  RAFT_BASE_PORT_CASE=$((RAFT_BASE_PORT_ROOT + CASE_INDEX * 200))
  CLIENT_BASE_PORT_CASE=$((CLIENT_BASE_PORT_ROOT + CASE_INDEX * 200))
  CLIENT_SERVERS="127.0.0.1:$((CLIENT_BASE_PORT_CASE + 1)),127.0.0.1:$((CLIENT_BASE_PORT_CASE + 2)),127.0.0.1:$((CLIENT_BASE_PORT_CASE + 3))"
  CASE_PID_DIRS+=("${PID_DIR}")
  mkdir -p "${CONFIG_DIR}" "${PID_DIR}" "${NODE_LOG_DIR}" "${CASE_REPORT_DIR}"
  {
    echo "case=${CURRENT_CASE}"
    echo "batch_size=${CURRENT_BATCH_SIZE}"
    echo "snapshot_max_log_entries=${CURRENT_SNAPSHOT_MAX_LOG_ENTRIES}"
    echo "raft_base_port=${RAFT_BASE_PORT_CASE}"
    echo "client_base_port=${CLIENT_BASE_PORT_CASE}"
    echo "client_servers=${CLIENT_SERVERS}"
  } >"${CASE_REPORT_DIR}/config.txt"
}

write_config() {
  local id="$1"
  local data_dir="${CASE_DIR}/node${id}"
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
  max_log_entries: ${CURRENT_SNAPSHOT_MAX_LOG_ENTRIES}
  snapshot_dir: ${data_dir}

raft:
  election_timeout_ms_min: 300
  election_timeout_ms_max: 600
  heartbeat_interval_ms: 100
  rpc_timeout_ms: 300
  pre_vote: true
  check_quorum: true
  max_append_entries_per_rpc: ${CURRENT_BATCH_SIZE}
  max_inflight_append_entries_per_peer: ${MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER}

read:
  mode: log
EOF
}

start_node() {
  local id="$1"
  local append_delay_ms="${2:-0}"
  local snapshot_delay_ms="${3:-0}"
  local log_file="${NODE_LOG_DIR}/node${id}.log"
  env CRAFTKV_TEST_APPEND_ENTRIES_DELAY_MS="${append_delay_ms}" \
    CRAFTKV_TEST_INSTALL_SNAPSHOT_DELAY_MS="${snapshot_delay_ms}" \
    "${SERVER}" --config="${CONFIG_DIR}/node${id}.yaml" >"${log_file}" 2>&1 &
  echo "$!" >"${PID_DIR}/node${id}.pid"
  echo "started node${id}: pid=$(cat "${PID_DIR}/node${id}.pid"), append_delay_ms=${append_delay_ms}, snapshot_delay_ms=${snapshot_delay_ms}"
}

start_cluster() {
  local id
  for id in 1 2 3; do
    write_config "${id}"
  done
  for id in 1 2 3; do
    start_node "${id}"
  done
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

discover_leader() {
  local previous="${1:-}"
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
  if [[ "${leader_count}" -eq 1 && ( -z "${previous}" || "${leader}" != "${previous}" ) ]]; then
    LAST_DISCOVERED_LEADER="${leader}"
    echo "${leader}"
    return 0
  fi
  return 1
}

wait_for_leader() {
  local previous="${1:-}"
  local leader
  for _ in $(seq 1 90); do
    leader="$(discover_leader "${previous}" 2>/dev/null || true)"
    if [[ "${leader}" =~ ^[1-3]$ ]]; then
      echo "${leader}"
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_stable_leader() {
  local previous="${1:-}"
  local leader status role noop_committed
  for _ in $(seq 1 90); do
    leader="$(discover_leader "${previous}" 2>/dev/null || true)"
    if [[ "${leader}" =~ ^[1-3]$ ]]; then
      status="$(node_status "${leader}" 2>/dev/null || true)"
      role="$(status_value role <<<"${status}")"
      noop_committed="$(status_value leader_noop_committed <<<"${status}")"
      if [[ "${role}" == "LEADER" && "${noop_committed}" =~ ^[0-9]+$ && "${noop_committed}" -gt 0 ]]; then
        echo "${leader}"
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

choose_follower() {
  local leader="$1"
  [[ "${leader}" != "1" ]] && echo 1 || echo 2
}

other_follower() {
  local leader="$1"
  local follower="$2"
  local id
  for id in 1 2 3; do
    if [[ "${id}" != "${leader}" && "${id}" != "${follower}" ]]; then
      echo "${id}"
      return 0
    fi
  done
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
    RETRY_COUNT="${attempt}"
    if [[ ! "${leader}" =~ ^[1-3]$ ]]; then
      leader="$(discover_leader 2>/dev/null || true)"
    fi
    if [[ "${leader}" =~ ^[1-3]$ ]]; then
      target="${leader}"
    else
      target="$(( (attempt - 1) % 3 + 1 ))"
    fi
    LAST_REQUEST="put ${key} ${value}"
    set +e
    stdout="$(client_cmd_node "${target}" put "${key}" "${value}" 2>"${CASE_REPORT_DIR}/last_client_stderr.txt")"
    rc=$?
    set -e
    stderr="$(cat "${CASE_REPORT_DIR}/last_client_stderr.txt" 2>/dev/null || true)"
    LAST_RESPONSE="target=node${target} rc=${rc} stdout=${stdout} stderr=${stderr}"
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

put_range() {
  local prefix="$1"
  local from="$2"
  local to="$3"
  local i
  for i in $(seq "${from}" "${to}"); do
    retry_write_to_leader "${prefix}_${i}" "value_${i}" || fail "put ${prefix}_${i} failed"
  done
}

dump_node() {
  local id="$1"
  "${CLIENT}" --servers="$(node_client_addr "${id}")" --timeout_ms="${CLIENT_TIMEOUT_MS}" --retries=3 dump \
    | sort >"${CASE_REPORT_DIR}/node${id}.dump"
}

wait_consistency() {
  local label="$1"
  for _ in $(seq 1 120); do
    if dump_node 1 && dump_node 2 && dump_node 3 &&
      cmp -s "${CASE_REPORT_DIR}/node1.dump" "${CASE_REPORT_DIR}/node2.dump" &&
      cmp -s "${CASE_REPORT_DIR}/node1.dump" "${CASE_REPORT_DIR}/node3.dump"; then
      cp "${CASE_REPORT_DIR}/node1.dump" "${CASE_REPORT_DIR}/${label}.dump"
      return 0
    fi
    sleep 1
  done
  diff -u "${CASE_REPORT_DIR}/node1.dump" "${CASE_REPORT_DIR}/node2.dump" >"${CASE_REPORT_DIR}/${label}_node1_node2.diff" || true
  diff -u "${CASE_REPORT_DIR}/node1.dump" "${CASE_REPORT_DIR}/node3.dump" >"${CASE_REPORT_DIR}/${label}_node1_node3.diff" || true
  return 1
}

wait_status_caught_up() {
  local target="$1"
  local leader="$2"
  local leader_status target_status leader_commit leader_applied leader_last target_commit target_applied target_last
  for _ in $(seq 1 120); do
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

append_batch_result() {
  local batch_size="$1"
  local duration_ms="$2"
  local before_file="$3"
  local after_file="$4"
  local final_consistency="$5"
  local rpc_delta entries_delta max_batch attempts_delta success_delta
  rpc_delta="$(metric_delta "${before_file}" "${after_file}" append_entries_batch_rpc_count)"
  entries_delta="$(metric_delta "${before_file}" "${after_file}" append_entries_entries_sent)"
  max_batch="$(metric_max "${after_file}" append_entries_max_batch_observed)"
  attempts_delta="$(metric_delta "${before_file}" "${after_file}" follower_catchup_attempts)"
  success_delta="$(metric_delta "${before_file}" "${after_file}" follower_catchup_success)"
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${batch_size}" "${duration_ms}" "${rpc_delta}" "${entries_delta}" "${max_batch}" \
    "${attempts_delta}" "${success_delta}" "${final_consistency}" >>"${BATCH_RESULTS_CSV}"
}

scenario_single_slow_follower() {
  set_step "scenario_single_slow_follower"
  begin_case "single_slow_follower" 8 100000
  start_cluster
  local leader slow fast before_stepdowns after_stepdowns role
  leader="$(wait_for_leader)" || fail "leader was not elected"
  LAST_DISCOVERED_LEADER="${leader}"
  slow="$(choose_follower "${leader}")"
  fast="$(other_follower "${leader}" "${slow}")"
  capture_status "${CASE_REPORT_DIR}/status_before.txt"
  before_stepdowns="$(metric_sum "${CASE_REPORT_DIR}/status_before.txt" check_quorum_stepdown_count)"
  record_fault "${CURRENT_CASE}" "restart_with_append_entries_delay" "${slow}" "delay_ms=${SLOW_APPEND_DELAY_MS}, fast_follower=${fast}"
  stop_pid "$(cat "${PID_DIR}/node${slow}.pid")"
  wait_node_unavailable "${slow}" || fail "slow follower node${slow} did not stop"
  start_node "${slow}" "${SLOW_APPEND_DELAY_MS}" 0
  put_range "single_slow" 1 "${WORKLOAD_COUNT}"
  role="$(status_value role <<<"$(node_status "${leader}" 2>/dev/null || true)")"
  [[ "${role}" == "LEADER" ]] || fail "leader node${leader} stepped down while only node${slow} was slow"
  wait_status_caught_up "${slow}" "${leader}" || fail "slow follower node${slow} did not catch up"
  wait_consistency "single_slow_consistency" || fail "single slow follower final consistency failed"
  capture_status "${CASE_REPORT_DIR}/status_after.txt"
  after_stepdowns="$(metric_sum "${CASE_REPORT_DIR}/status_after.txt" check_quorum_stepdown_count)"
  [[ "$((after_stepdowns - before_stepdowns))" -eq 0 ]] ||
    fail "unexpected CheckQuorum stepdown with one slow follower"
  write_metrics_delta "${CASE_REPORT_DIR}/status_before.txt" "${CASE_REPORT_DIR}/status_after.txt" "${CASE_REPORT_DIR}/metrics_delta.txt"
  copy_case_artifacts
  stop_case_nodes
}

scenario_batch_size_impact() {
  local batch leader lagging start_ms end_ms duration_ms final_consistency
  for batch in 1 8 64; do
    set_step "scenario_batch_size_${batch}"
    begin_case "batch_size_${batch}" "${batch}" 100000
    start_cluster
    leader="$(wait_for_leader)" || fail "leader was not elected for batch size ${batch}"
    LAST_DISCOVERED_LEADER="${leader}"
    lagging="$(choose_follower "${leader}")"
    capture_status "${CASE_REPORT_DIR}/status_before.txt"
    record_fault "${CURRENT_CASE}" "stop_follower" "${lagging}" "create backlog before delayed catch-up"
    stop_pid "$(cat "${PID_DIR}/node${lagging}.pid")"
    wait_node_unavailable "${lagging}" || fail "lagging follower node${lagging} did not stop"
    put_range "batch_${batch}" 1 "${WORKLOAD_COUNT}"
    record_fault "${CURRENT_CASE}" "restart_with_append_entries_delay" "${lagging}" "delay_ms=${SLOW_APPEND_DELAY_MS}"
    start_ms="$(now_ms)"
    start_node "${lagging}" "${SLOW_APPEND_DELAY_MS}" 0
    leader="$(wait_for_leader)" || fail "leader missing after lagging follower restart"
    wait_status_caught_up "${lagging}" "${leader}" || fail "batch size ${batch} follower catch-up did not complete"
    end_ms="$(now_ms)"
    duration_ms=$((end_ms - start_ms))
    if wait_consistency "batch_size_${batch}_consistency"; then
      final_consistency=true
    else
      final_consistency=false
      fail "batch size ${batch} final consistency failed"
    fi
    capture_status "${CASE_REPORT_DIR}/status_after.txt"
    write_metrics_delta "${CASE_REPORT_DIR}/status_before.txt" "${CASE_REPORT_DIR}/status_after.txt" "${CASE_REPORT_DIR}/metrics_delta.txt"
    append_batch_result "${batch}" "${duration_ms}" "${CASE_REPORT_DIR}/status_before.txt" "${CASE_REPORT_DIR}/status_after.txt" "${final_consistency}"
    copy_case_artifacts
    stop_case_nodes
  done
}

scenario_snapshot_after_catchup() {
  set_step "scenario_snapshot_after_catchup"
  begin_case "snapshot_after_catchup" 8 8
  start_cluster
  local leader lagging snapshot_index install_delta entries_delta
  leader="$(wait_for_leader)" || fail "leader was not elected"
  LAST_DISCOVERED_LEADER="${leader}"
  lagging="$(choose_follower "${leader}")"
  capture_status "${CASE_REPORT_DIR}/status_before.txt"
  record_fault "${CURRENT_CASE}" "stop_follower" "${lagging}" "force snapshot boundary"
  stop_pid "$(cat "${PID_DIR}/node${lagging}.pid")"
  wait_node_unavailable "${lagging}" || fail "snapshot follower node${lagging} did not stop"
  put_range "snapshot_backlog" 1 "$((WORKLOAD_COUNT + 20))"
  sleep 2
  record_fault "${CURRENT_CASE}" "restart_with_install_snapshot_delay" "${lagging}" "delay_ms=${SLOW_SNAPSHOT_DELAY_MS}"
  start_node "${lagging}" 0 "${SLOW_SNAPSHOT_DELAY_MS}"
  put_range "snapshot_post" 1 12
  leader="$(wait_for_leader)" || fail "leader missing after snapshot follower restart"
  wait_status_caught_up "${lagging}" "${leader}" || fail "snapshot follower did not catch up"
  wait_consistency "snapshot_consistency" || fail "snapshot catch-up final consistency failed"
  capture_status "${CASE_REPORT_DIR}/status_after.txt"
  write_metrics_delta "${CASE_REPORT_DIR}/status_before.txt" "${CASE_REPORT_DIR}/status_after.txt" "${CASE_REPORT_DIR}/metrics_delta.txt"
  install_delta="$(metric_delta "${CASE_REPORT_DIR}/status_before.txt" "${CASE_REPORT_DIR}/status_after.txt" install_snapshot_sent)"
  entries_delta="$(metric_delta "${CASE_REPORT_DIR}/status_before.txt" "${CASE_REPORT_DIR}/status_after.txt" append_entries_entries_sent)"
  snapshot_index="$(status_value snapshot_index <<<"$(node_status "${lagging}")")"
  [[ "${install_delta}" -gt 0 ]] || fail "expected InstallSnapshot to be sent"
  [[ "${entries_delta}" -gt 0 ]] || fail "expected AppendEntries after snapshot"
  [[ "${snapshot_index}" =~ ^[1-9][0-9]*$ ]] || fail "recovered follower snapshot_index did not advance"
  copy_case_artifacts
  stop_case_nodes
}

scenario_leader_switch_during_catchup() {
  set_step "scenario_leader_switch_during_catchup"
  begin_case "leader_switch_during_catchup" 8 100000
  start_cluster
  local leader lagging old_leader new_leader final_leader old_sample final_last
  leader="$(wait_for_leader)" || fail "leader was not elected"
  LAST_DISCOVERED_LEADER="${leader}"
  lagging="$(choose_follower "${leader}")"
  capture_status "${CASE_REPORT_DIR}/status_before.txt"
  record_fault "${CURRENT_CASE}" "stop_follower" "${lagging}" "create backlog before failover"
  stop_pid "$(cat "${PID_DIR}/node${lagging}.pid")"
  wait_node_unavailable "${lagging}" || fail "lagging follower node${lagging} did not stop"
  put_range "failover_backlog" 1 "${WORKLOAD_COUNT}"
  record_fault "${CURRENT_CASE}" "restart_with_append_entries_delay" "${lagging}" "delay_ms=${SLOW_APPEND_DELAY_MS}"
  start_node "${lagging}" "${SLOW_APPEND_DELAY_MS}" 0
  sleep 1
  old_sample="$(status_value last_log_index <<<"$(node_status "${lagging}" 2>/dev/null || true)")"
  old_leader="${leader}"
  record_fault "${CURRENT_CASE}" "stop_leader" "${old_leader}" "during lagging follower catch-up"
  stop_pid "$(cat "${PID_DIR}/node${old_leader}.pid")"
  wait_node_unavailable "${old_leader}" || fail "old leader node${old_leader} did not stop"
  new_leader="$(wait_for_stable_leader "${old_leader}")" || fail "new leader did not stabilize during catch-up"
  LAST_DISCOVERED_LEADER="${new_leader}"
  record_fault "${CURRENT_CASE}" "restart_old_leader" "${old_leader}" "after new leader=${new_leader}"
  start_node "${old_leader}"
  put_range "post_failover" 1 12
  final_leader="$(wait_for_leader)" || fail "leader missing after old leader restart"
  wait_status_caught_up "${lagging}" "${final_leader}" || fail "lagging follower did not catch up after leader switch"
  wait_status_caught_up "${old_leader}" "${final_leader}" || fail "old leader did not catch up after restart"
  wait_consistency "leader_switch_consistency" || fail "leader switch final consistency failed"
  capture_status "${CASE_REPORT_DIR}/status_after.txt"
  write_metrics_delta "${CASE_REPORT_DIR}/status_before.txt" "${CASE_REPORT_DIR}/status_after.txt" "${CASE_REPORT_DIR}/metrics_delta.txt"
  final_last="$(status_value last_log_index <<<"$(node_status "${lagging}")")"
  if [[ "${old_sample}" =~ ^[0-9]+$ && "${final_last}" =~ ^[0-9]+$ ]]; then
    [[ "${final_last}" -ge "${old_sample}" ]] || fail "lagging follower last_log_index regressed from ${old_sample} to ${final_last}"
  fi
  copy_case_artifacts
  stop_case_nodes
}

if [[ ! "${WORKLOAD_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: WORKLOAD_COUNT must be positive" >&2
  exit 2
fi
if [[ ! "${SLOW_APPEND_DELAY_MS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: SLOW_APPEND_DELAY_MS must be a non-negative integer" >&2
  exit 2
fi
if [[ ! "${SLOW_SNAPSHOT_DELAY_MS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: SLOW_SNAPSHOT_DELAY_MS must be a non-negative integer" >&2
  exit 2
fi
if [[ "${MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER}" != "1" ]]; then
  echo "ERROR: MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER must be 1 in this stage" >&2
  exit 2
fi

ensure_under_root "${RUN_DIR}" "${TEST_DATA_ROOT}"
ensure_under_root "${REPORT_DIR}" "${TEST_REPORT_ROOT}"
mkdir -p "${RUN_DIR}" "${REPORT_DIR}"
: >"${FAULTS_FILE}"
cat >"${BATCH_RESULTS_CSV}" <<'EOF'
batch_size,catchup_duration_ms,append_entries_batch_rpc_count,append_entries_entries_sent,append_entries_max_batch_observed,follower_catchup_attempts,follower_catchup_success,final_consistency
EOF
write_summary

cd "${ROOT_DIR}"

set_step "build"
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT=ON
cmake --build "${BUILD_DIR}" -j"${BUILD_JOBS}" --target kv_server kv_client

scenario_single_slow_follower
scenario_batch_size_impact
scenario_snapshot_after_catchup
scenario_leader_switch_during_catchup

write_summary
echo "SLOW FOLLOWER TEST PASSED"
echo "summary=${SUMMARY_FILE}"
