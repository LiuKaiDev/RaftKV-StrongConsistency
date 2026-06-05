#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DATA_ROOT="${TEST_DATA_ROOT:-/tmp/raftkv-test-data}"
TEST_REPORT_ROOT="${TEST_REPORT_ROOT:-/tmp/raftkv-test-reports}"
RUN_ID="${RUN_ID:-batch-replication-$(date +%Y%m%d-%H%M%S)-$$}"
RUN_DIR="${TEST_DATA_ROOT}/${RUN_ID}"
CLUSTER_DATA_DIR="${RUN_DIR}/batch-replication"
CONFIG_DIR="${CLUSTER_DATA_DIR}/config"
PID_DIR="${CLUSTER_DATA_DIR}/pids"
NODE_LOG_DIR="${CLUSTER_DATA_DIR}/logs"
REPORT_DIR="${TEST_REPORT_ROOT}/${RUN_ID}/batch-replication"
BUILD_DIR="${ROOT_DIR}/build/raft"
BUILD_JOBS="${BUILD_JOBS:-1}"
PORT_OFFSET="${PORT_OFFSET:-$((($$ % 1000) * 20))}"
RAFT_BASE_PORT="${RAFT_BASE_PORT:-$((42000 + PORT_OFFSET))}"
CLIENT_BASE_PORT="${CLIENT_BASE_PORT:-$((43000 + PORT_OFFSET))}"
MAX_APPEND_ENTRIES_PER_RPC="${MAX_APPEND_ENTRIES_PER_RPC:-4}"
MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER="${MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER:-1}"
SNAPSHOT_MAX_LOG_ENTRIES="${SNAPSHOT_MAX_LOG_ENTRIES:-10}"
CLIENT="${ROOT_DIR}/bin/kv_client"
SERVER="${ROOT_DIR}/bin/kv_server"
CLIENT_SERVERS="127.0.0.1:$((CLIENT_BASE_PORT + 1)),127.0.0.1:$((CLIENT_BASE_PORT + 2)),127.0.0.1:$((CLIENT_BASE_PORT + 3))"
CURRENT_STEP="init"
LAST_ERROR_FILE="${REPORT_DIR}/last_error.txt"
SUMMARY_FILE="${REPORT_DIR}/summary.txt"
DIAG_DIR="${REPORT_DIR}/diagnostics"
REQUEST_TRACE_FILE="${REPORT_DIR}/request_trace.log"
LAST_REQUEST=""
LAST_RESPONSE=""
LAST_DISCOVERED_LEADER=""
RETRY_COUNT=0

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

node_client_addr() { echo "127.0.0.1:$((CLIENT_BASE_PORT + $1))"; }

status_value() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key {print $2; exit}'
}

status_node_block() {
  local file="$1"
  local id="$2"
  awk -v node="===== node${id} =====" '
    $0 == node {inside=1; next}
    /^===== node/ {inside=0}
    inside {print}
  ' "${file}"
}

status_node_value() {
  local file="$1"
  local id="$2"
  local key="$3"
  status_node_block "${file}" "${id}" | status_value "${key}"
}

node_status() {
  local id="$1"
  "${CLIENT}" --servers="$(node_client_addr "${id}")" --timeout_ms=1000 --retries=1 status
}

client_cmd() {
  "${CLIENT}" --servers="${CLIENT_SERVERS}" --timeout_ms=1000 --retries=20 "$@"
}

client_cmd_node() {
  local id="$1"
  shift
  "${CLIENT}" --servers="$(node_client_addr "${id}")" --timeout_ms=1000 --retries=1 "$@"
}

log_request_attempt() {
  mkdir -p "${REPORT_DIR}"
  {
    echo "step=${CURRENT_STEP}"
    echo "attempt=${1}"
    echo "target=${2}"
    echo "request=${3}"
    echo "exit_code=${4}"
    echo "stdout=${5}"
    echo "stderr=${6}"
    echo
  } >>"${REQUEST_TRACE_FILE}"
}

capture_status() {
  local out="$1"
  : >"${out}"
  local id
  for id in 1 2 3; do
    {
      echo "===== node${id} ====="
      node_status "${id}" || echo "UNAVAILABLE"
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

alive_nodes() {
  local id pid_file pid out alive=()
  for id in 1 2 3; do
    pid_file="${PID_DIR}/node${id}.pid"
    if [[ -f "${pid_file}" ]]; then
      pid="$(cat "${pid_file}")"
      if process_running "${pid}"; then
        out="$(node_status "${id}" 2>/dev/null || true)"
        if [[ -n "${out}" && "${out}" != "UNAVAILABLE" ]]; then
          alive+=("${id}")
        fi
      fi
    fi
  done
  echo "${alive[*]}"
}

write_diagnostics() {
  mkdir -p "${DIAG_DIR}"
  {
    echo "current_step=${CURRENT_STEP}"
    echo "last_request=${LAST_REQUEST}"
    echo "last_response=${LAST_RESPONSE}"
    echo "last_discovered_leader=${LAST_DISCOVERED_LEADER}"
    echo "alive_nodes=$(alive_nodes)"
    echo "retry_count=${RETRY_COUNT}"
    echo "report_dir=${REPORT_DIR}"
    echo "replay_command=TEST_DATA_ROOT=${TEST_DATA_ROOT} TEST_REPORT_ROOT=${TEST_REPORT_ROOT} RUN_ID=${RUN_ID} BUILD_JOBS=${BUILD_JOBS} RAFT_BASE_PORT=${RAFT_BASE_PORT} CLIENT_BASE_PORT=${CLIENT_BASE_PORT} bash scripts/test_batch_replication.sh"
    if [[ -f "${REPORT_DIR}/ordinary_batch_metrics.txt" ]]; then
      echo
      echo "ordinary_batch_metrics:"
      cat "${REPORT_DIR}/ordinary_batch_metrics.txt"
    fi
  } >"${DIAG_DIR}/failure_context.txt"
  capture_status "${DIAG_DIR}/status_of_each_node.txt" || true
  local log_file base
  for log_file in "${NODE_LOG_DIR}"/node*.log; do
    if [[ -f "${log_file}" ]]; then
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
    echo "max_append_entries_per_rpc=${MAX_APPEND_ENTRIES_PER_RPC}"
    echo "max_inflight_append_entries_per_peer=${MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER}"
    echo "replay_command=TEST_DATA_ROOT=${TEST_DATA_ROOT} TEST_REPORT_ROOT=${TEST_REPORT_ROOT} RUN_ID=${RUN_ID} BUILD_JOBS=${BUILD_JOBS} RAFT_BASE_PORT=${RAFT_BASE_PORT} CLIENT_BASE_PORT=${CLIENT_BASE_PORT} bash scripts/test_batch_replication.sh"
    echo "last_error=$(cat "${LAST_ERROR_FILE}" 2>/dev/null || true)"
    echo "last_request=${LAST_REQUEST}"
    echo "last_response=${LAST_RESPONSE}"
    echo "last_discovered_leader=${LAST_DISCOVERED_LEADER}"
    echo "alive_nodes=$(alive_nodes)"
    echo "retry_count=${RETRY_COUNT}"
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
  mkdir -p "$(dirname "${LAST_ERROR_FILE}")"
  echo "$*" >"${LAST_ERROR_FILE}"
  write_diagnostics || true
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
  max_append_entries_per_rpc: ${MAX_APPEND_ENTRIES_PER_RPC}
  max_inflight_append_entries_per_peer: ${MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER}

read:
  mode: log
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

wait_node_unavailable() {
  local id="$1"
  local pid_file="${PID_DIR}/node${id}.pid"
  local pid=""
  [[ -f "${pid_file}" ]] && pid="$(cat "${pid_file}")"
  for _ in $(seq 1 50); do
    if [[ -z "${pid}" ]] || ! process_running "${pid}"; then
      if ! node_status "${id}" >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 0.2
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
      if [[ "${role}" == "LEADER" && "${noop_committed}" =~ ^[0-9]+$ &&
            "${noop_committed}" -gt 0 ]]; then
        LAST_DISCOVERED_LEADER="${leader}"
        echo "${leader}"
        return 0
      fi
    fi
    sleep 1
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

retry_write_to_leader() {
  local key="$1"
  local value="$2"
  local leader="${LAST_DISCOVERED_LEADER}"
  local attempt target stdout stderr rc hinted alive
  mkdir -p "${DIAG_DIR}"
  for attempt in $(seq 1 80); do
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

    LAST_REQUEST="put ${key} ${value}"
    local stdout_file="${DIAG_DIR}/attempt_${attempt}_stdout.txt"
    local stderr_file="${DIAG_DIR}/attempt_${attempt}_stderr.txt"
    set +e
    stdout="$(client_cmd_node "${target}" put "${key}" "${value}" >"${stdout_file}" 2>"${stderr_file}")"
    rc=$?
    set -e
    stdout="$(cat "${stdout_file}" 2>/dev/null || true)"
    stderr="$(cat "${stderr_file}" 2>/dev/null || true)"
    LAST_RESPONSE="target=node${target} rc=${rc} stdout=${stdout} stderr=${stderr}"
    log_request_attempt "${attempt}" "node${target}" "${LAST_REQUEST}" "${rc}" "${stdout}" "${stderr}"
    if [[ "${rc}" -eq 0 ]]; then
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
  return 1
}

choose_follower() {
  local leader="$1"
  [[ "${leader}" != "1" ]] && echo 1 || echo 2
}

put_range() {
  local prefix="$1"
  local from="$2"
  local to="$3"
  local i
  for i in $(seq "${from}" "${to}"); do
    client_cmd put "${prefix}_${i}" "value_${i}" >/dev/null || fail "put ${prefix}_${i} failed"
  done
}

dump_node() {
  local id="$1"
  "${CLIENT}" --servers="$(node_client_addr "${id}")" --timeout_ms=1000 --retries=3 dump \
    | sort >"${REPORT_DIR}/node${id}.dump"
}

wait_consistency() {
  local label="$1"
  for _ in $(seq 1 90); do
    if dump_node 1 && dump_node 2 && dump_node 3 &&
      cmp -s "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node2.dump" &&
      cmp -s "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node3.dump"; then
      cp "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/${label}.dump"
      return 0
    fi
    sleep 1
  done
  diff -u "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node2.dump" >"${REPORT_DIR}/${label}_node1_node2.diff" || true
  diff -u "${REPORT_DIR}/node1.dump" "${REPORT_DIR}/node3.dump" >"${REPORT_DIR}/${label}_node1_node3.diff" || true
  return 1
}

wait_status_caught_up() {
  local target="$1"
  local leader="$2"
  local leader_status target_status leader_commit leader_applied leader_last target_commit target_applied target_last
  for _ in $(seq 1 90); do
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

assert_batch_metrics() {
  local before_file="$1"
  local after_file="$2"
  local leader_id="$3"
  local before_role after_role before_node_id after_node_id
  local before_rpc after_rpc before_empty after_empty before_entries after_entries
  local before_attempts after_attempts before_success after_success
  local rpc_delta empty_delta non_empty_delta entries_delta attempts_delta success_delta
  local max_batch metrics_report leader_before_report leader_after_report replay_command
  local metrics_summary

  before_role="$(status_node_value "${before_file}" "${leader_id}" role)"
  after_role="$(status_node_value "${after_file}" "${leader_id}" role)"
  before_node_id="$(status_node_value "${before_file}" "${leader_id}" node_id)"
  after_node_id="$(status_node_value "${after_file}" "${leader_id}" node_id)"
  before_rpc="$(status_node_value "${before_file}" "${leader_id}" append_entries_batch_rpc_count)"
  after_rpc="$(status_node_value "${after_file}" "${leader_id}" append_entries_batch_rpc_count)"
  before_empty="$(status_node_value "${before_file}" "${leader_id}" append_entries_empty_heartbeat_count)"
  after_empty="$(status_node_value "${after_file}" "${leader_id}" append_entries_empty_heartbeat_count)"
  before_entries="$(status_node_value "${before_file}" "${leader_id}" append_entries_entries_sent)"
  after_entries="$(status_node_value "${after_file}" "${leader_id}" append_entries_entries_sent)"
  before_attempts="$(status_node_value "${before_file}" "${leader_id}" follower_catchup_attempts)"
  after_attempts="$(status_node_value "${after_file}" "${leader_id}" follower_catchup_attempts)"
  before_success="$(status_node_value "${before_file}" "${leader_id}" follower_catchup_success)"
  after_success="$(status_node_value "${after_file}" "${leader_id}" follower_catchup_success)"
  max_batch="$(status_node_value "${after_file}" "${leader_id}" append_entries_max_batch_observed)"

  if [[ "${before_role}" != "LEADER" || "${after_role}" != "LEADER" ||
        "${before_node_id}" != "${leader_id}" || "${after_node_id}" != "${leader_id}" ]]; then
    fail "ordinary_batch_catchup metrics window did not read the same Leader: leader_id=${leader_id} before_role=${before_role} after_role=${after_role} before_node_id=${before_node_id} after_node_id=${after_node_id}"
  fi

  for value in "${before_rpc}" "${after_rpc}" "${before_empty}" "${after_empty}" \
               "${before_entries}" "${after_entries}" "${before_attempts}" \
               "${after_attempts}" "${before_success}" "${after_success}" "${max_batch}"; do
    [[ "${value}" =~ ^[0-9]+$ ]] || fail "ordinary_batch_catchup metrics contained a non-numeric value for leader_id=${leader_id}"
  done

  rpc_delta=$((after_rpc - before_rpc))
  empty_delta=$((after_empty - before_empty))
  entries_delta=$((after_entries - before_entries))
  attempts_delta=$((after_attempts - before_attempts))
  success_delta=$((after_success - before_success))
  non_empty_delta=$((rpc_delta - empty_delta))

  leader_before_report="${REPORT_DIR}/leader_status_before_ordinary.txt"
  leader_after_report="${REPORT_DIR}/leader_status_after_ordinary.txt"
  status_node_block "${before_file}" "${leader_id}" >"${leader_before_report}"
  status_node_block "${after_file}" "${leader_id}" >"${leader_after_report}"
  replay_command="TEST_DATA_ROOT=${TEST_DATA_ROOT} TEST_REPORT_ROOT=${TEST_REPORT_ROOT} RUN_ID=${RUN_ID} BUILD_JOBS=${BUILD_JOBS} RAFT_BASE_PORT=${RAFT_BASE_PORT} CLIENT_BASE_PORT=${CLIENT_BASE_PORT} bash scripts/test_batch_replication.sh"
  metrics_report="${REPORT_DIR}/ordinary_batch_metrics.txt"
  {
    echo "leader_id=${leader_id}"
    echo "batch_rpc_count_delta=${rpc_delta}"
    echo "empty_heartbeat_count_delta=${empty_delta}"
    echo "non_empty_batch_rpc_count_delta=${non_empty_delta}"
    echo "entries_sent_delta=${entries_delta}"
    echo "max_batch_observed=${max_batch}"
    echo "follower_catchup_attempts_delta=${attempts_delta}"
    echo "follower_catchup_success_delta=${success_delta}"
    echo "final_consistency=PASS"
    echo "leader_status_before=${leader_before_report}"
    echo "leader_status_after=${leader_after_report}"
    echo "report_dir=${REPORT_DIR}"
    echo "replay_command=${replay_command}"
  } >"${metrics_report}"

  metrics_summary="batch_rpc_count_delta=${rpc_delta} empty_heartbeat_count_delta=${empty_delta} non_empty_batch_rpc_count_delta=${non_empty_delta} entries_sent_delta=${entries_delta} max_batch_observed=${max_batch} follower_catchup_attempts_delta=${attempts_delta} follower_catchup_success_delta=${success_delta} final_consistency=PASS leader_status_before=${leader_before_report} leader_status_after=${leader_after_report} report_dir=${REPORT_DIR} replay_command=${replay_command}"

  [[ "${rpc_delta}" -ge 0 ]] || fail "batch_rpc_count_delta=${rpc_delta} is negative; metrics window changed process or reset; ${metrics_summary}"
  [[ "${empty_delta}" -ge 0 ]] || fail "empty_heartbeat_count_delta=${empty_delta} is negative; metrics window changed process or reset; ${metrics_summary}"
  [[ "${entries_delta}" -ge 0 ]] || fail "entries_sent_delta=${entries_delta} is negative; metrics window changed process or reset; ${metrics_summary}"
  [[ "${attempts_delta}" -ge 0 ]] || fail "follower_catchup_attempts_delta=${attempts_delta} is negative; metrics window changed process or reset; ${metrics_summary}"
  [[ "${success_delta}" -ge 0 ]] || fail "follower_catchup_success_delta=${success_delta} is negative; metrics window changed process or reset; ${metrics_summary}"
  [[ "${rpc_delta}" -ge "${empty_delta}" ]] || fail "expected batch_rpc_count_delta >= empty_heartbeat_count_delta; ${metrics_summary}"
  [[ "${non_empty_delta}" -gt 0 ]] || fail "expected non_empty_batch_rpc_count_delta > 0; ${metrics_summary}"
  [[ "${entries_delta}" -ge "${non_empty_delta}" ]] || fail "expected entries_sent_delta >= non_empty_batch_rpc_count_delta; ${metrics_summary}"
  [[ "${max_batch}" -gt 1 ]] || fail "expected append_entries_max_batch_observed > 1; ${metrics_summary}"
  [[ "${attempts_delta}" -gt 0 ]] || fail "expected follower_catchup_attempts_delta > 0; ${metrics_summary}"
  [[ "${success_delta}" -gt 0 ]] || fail "expected follower_catchup_success_delta > 0; ${metrics_summary}"
}

if [[ ! "${MAX_APPEND_ENTRIES_PER_RPC}" =~ ^[1-9][0-9]*$ ]]; then
  fail "MAX_APPEND_ENTRIES_PER_RPC must be positive"
fi
if [[ "${MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER}" != "1" ]]; then
  fail "MAX_INFLIGHT_APPEND_ENTRIES_PER_PEER must be 1 in this stage"
fi

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
follower="$(choose_follower "${leader}")"
capture_status "${REPORT_DIR}/status_initial.txt"

set_step "ordinary_batch_catchup"
ordinary_leader="${leader}"
capture_status "${REPORT_DIR}/status_before_ordinary.txt"
stop_pid "$(cat "${PID_DIR}/node${follower}.pid")"
put_range ordinary 1 24
start_node "${follower}"
leader="$(wait_for_leader)" || fail "leader missing after follower restart"
[[ "${leader}" == "${ordinary_leader}" ]] || fail "ordinary_batch_catchup Leader changed during metrics window: before=${ordinary_leader} after=${leader}"
wait_status_caught_up "${follower}" "${leader}" || fail "ordinary follower catch-up did not complete"
wait_consistency "ordinary_catchup" || fail "ordinary catch-up consistency failed"
capture_status "${REPORT_DIR}/status_after_ordinary.txt"
assert_batch_metrics "${REPORT_DIR}/status_before_ordinary.txt" "${REPORT_DIR}/status_after_ordinary.txt" "${leader}"

set_step "snapshot_boundary_catchup"
leader="$(wait_for_leader)" || fail "leader missing before snapshot scenario"
follower="$(choose_follower "${leader}")"
stop_pid "$(cat "${PID_DIR}/node${follower}.pid")"
put_range snapshot 1 40
sleep 2
start_node "${follower}"
leader="$(wait_for_leader)" || fail "leader missing after snapshot follower restart"
wait_status_caught_up "${follower}" "${leader}" || fail "snapshot follower catch-up did not complete"
wait_consistency "snapshot_catchup" || fail "snapshot catch-up consistency failed"
capture_status "${REPORT_DIR}/status_after_snapshot.txt"
snapshot_index="$(status_value snapshot_index <<<"$(node_status "${follower}")")"
[[ "${snapshot_index}" =~ ^[1-9][0-9]*$ ]] || fail "snapshot_index did not advance on recovered follower"

set_step "leader_failover_during_catchup"
leader="$(wait_for_leader)" || fail "leader missing before failover scenario"
follower="$(choose_follower "${leader}")"
stop_pid "$(cat "${PID_DIR}/node${follower}.pid")"
put_range failover 1 30
start_node "${follower}"
sleep 1
old_leader="${leader}"
stop_pid "$(cat "${PID_DIR}/node${old_leader}.pid")"
wait_node_unavailable "${old_leader}" || fail "old leader node${old_leader} did not stop cleanly"
new_leader="$(wait_for_stable_leader "${old_leader}")" || fail "new leader was not stable during catch-up"
LAST_DISCOVERED_LEADER="${new_leader}"
start_node "${old_leader}"
for i in $(seq 1 10); do
  retry_write_to_leader "post_failover_${i}" "value_${i}" ||
    fail "put post_failover_${i} failed after leader rediscovery retries"
done
wait_status_caught_up "${follower}" "${new_leader}" || fail "follower did not catch up after leader failover"
wait_consistency "failover_catchup" || fail "failover catch-up consistency failed"
capture_status "${REPORT_DIR}/status_final.txt"

echo "BATCH REPLICATION TEST PASSED"
