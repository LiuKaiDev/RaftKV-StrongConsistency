#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DATA_ROOT="${TEST_DATA_ROOT:-/tmp/raftkv-test-data}"
TEST_REPORT_ROOT="${TEST_REPORT_ROOT:-/tmp/raftkv-test-reports}"
RUN_ID="${RUN_ID:-admin-status-$(date +%Y%m%d-%H%M%S)-$$}"
RUN_DIR="${TEST_DATA_ROOT}/${RUN_ID}"
CLUSTER_DATA_DIR="${RUN_DIR}/admin-status"
CONFIG_DIR="${CLUSTER_DATA_DIR}/config"
PID_DIR="${CLUSTER_DATA_DIR}/pids"
NODE_LOG_DIR="${CLUSTER_DATA_DIR}/logs"
REPORT_DIR="${TEST_REPORT_ROOT}/${RUN_ID}/admin-status"
BUILD_DIR="${ROOT_DIR}/build/raft"
BUILD_JOBS="${BUILD_JOBS:-1}"
RAFT_BASE_PORT="${RAFT_BASE_PORT:-28000}"
CLIENT_BASE_PORT="${CLIENT_BASE_PORT:-29000}"
CLIENT_SERVERS="127.0.0.1:$((CLIENT_BASE_PORT + 1)),127.0.0.1:$((CLIENT_BASE_PORT + 2)),127.0.0.1:$((CLIENT_BASE_PORT + 3))"
CLIENT="${ROOT_DIR}/bin/kv_client"
SERVER="${ROOT_DIR}/bin/kv_server"
SHOW_STATUS="${ROOT_DIR}/scripts/show_cluster_status.sh"
CURRENT_STEP="init"
LAST_REQUEST=""
LAST_RESPONSE=""
LAST_DISCOVERED_LEADER=""
LAST_ALIVE_NODES=""
RETRY_COUNT=0
DISCOVERED_LEADER=""
DISCOVERED_LEADER_ADDR=""
DISCOVERED_LEADER_TERM=0
DISCOVERED_LEADER_COMMIT=0
DISCOVERED_LEADER_APPLIED=0
DISCOVERED_LEADER_LAST_LOG=0

ensure_under_root() {
  local path="$1"
  local root="$2"
  case "${path}" in
    "${root}"/*) ;;
    *)
      echo "FAIL: refusing to use path outside ${root}: ${path}" >&2
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

cleanup() {
  local pid_file
  for pid_file in "${PID_DIR}"/node*.pid; do
    [[ -f "${pid_file}" ]] || continue
    stop_pid "$(cat "${pid_file}")"
  done
}

client_addr_for_node() {
  local id="$1"
  echo "127.0.0.1:$((CLIENT_BASE_PORT + id))"
}

write_failure_diagnostics() {
  local reason="$1"
  mkdir -p "${REPORT_DIR}" 2>/dev/null || true
  {
    echo "reason=${reason}"
    echo "current_step=${CURRENT_STEP}"
    echo "last_request=${LAST_REQUEST}"
    echo "last_response=${LAST_RESPONSE}"
    echo "last_discovered_leader=${LAST_DISCOVERED_LEADER}"
    echo "alive_nodes=${LAST_ALIVE_NODES}"
    echo "retry_count=${RETRY_COUNT}"
    echo
    echo "status_of_each_node:"
    local id
    LAST_ALIVE_NODES=""
    for id in 1 2 3; do
      echo "===== node${id} ====="
      if node_status "${id}"; then
        LAST_ALIVE_NODES="${LAST_ALIVE_NODES} ${id}"
      else
        echo "UNAVAILABLE"
      fi
    done
    echo
    echo "node_log_tails:"
    local log_file
    for log_file in "${NODE_LOG_DIR}"/node*.log; do
      [[ -f "${log_file}" ]] || continue
      echo "===== ${log_file} ====="
      tail -n 200 "${log_file}" || true
    done
  } >"${REPORT_DIR}/last_error.txt"
}

fail() {
  write_failure_diagnostics "$*"
  echo "FAIL: $*" >&2
  echo "diagnostics=${REPORT_DIR}/last_error.txt" >&2
  exit 1
}

trap cleanup EXIT

write_config() {
  local id="$1"
  local max_log_entries="$2"
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
  max_log_entries: ${max_log_entries}
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

client_cmd() {
  "${CLIENT}" --servers="${CLIENT_SERVERS}" --timeout_ms=1000 --retries=10 "$@"
}

node_status() {
  local id="$1"
  "${CLIENT}" --servers="$(client_addr_for_node "${id}")" --timeout_ms=1000 --retries=1 status
}

status_value() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key {print $2; exit}'
}

wait_for_leader() {
  local previous="${1:-}"
  local last_status=""
  for _ in $(seq 1 60); do
    if discover_leader_once; then
      if [[ -z "${previous}" || "${DISCOVERED_LEADER}" != "${previous}" ]]; then
        echo "${DISCOVERED_LEADER}"
        return 0
      fi
    fi
    last_status="${LAST_RESPONSE}"
    sleep 1
  done
  LAST_RESPONSE="${last_status}"
  return 1
}

discover_leader_once() {
  local id status role node_id term commit applied last_log
  local leader_count=0
  local leader=""
  local leader_addr=""
  local leader_term=0
  local leader_commit=0
  local leader_applied=0
  local leader_last_log=0
  local alive=""
  local summary=""

  for id in 1 2 3; do
    status="$(node_status "${id}" 2>&1)"
    if [[ "$?" -ne 0 ]]; then
      summary+="node${id}=UNAVAILABLE ${status}"$'\n'
      continue
    fi
    node_id="$(status_value node_id <<<"${status}")"
    role="$(status_value role <<<"${status}")"
    term="$(status_value current_term <<<"${status}")"
    commit="$(status_value commit_index <<<"${status}")"
    applied="$(status_value last_applied <<<"${status}")"
    last_log="$(status_value last_log_index <<<"${status}")"
    alive="${alive} ${node_id:-${id}}"
    summary+="node${id}=id:${node_id:-?},role:${role:-?},term:${term:-?},leader:$(status_value leader_id <<<"${status}"),commit:${commit:-?},applied:${applied:-?},last_log:${last_log:-?}"$'\n'
    if [[ "${role}" == "LEADER" ]]; then
      leader_count="$((leader_count + 1))"
      leader="${node_id:-${id}}"
      leader_addr="$(client_addr_for_node "${leader}")"
      leader_term="${term:-0}"
      leader_commit="${commit:-0}"
      leader_applied="${applied:-0}"
      leader_last_log="${last_log:-0}"
    fi
  done

  LAST_RESPONSE="${summary}"
  LAST_ALIVE_NODES="${alive# }"
  if [[ "${leader_count}" -eq 1 && "${leader}" =~ ^[1-3]$ ]]; then
    DISCOVERED_LEADER="${leader}"
    DISCOVERED_LEADER_ADDR="${leader_addr}"
    DISCOVERED_LEADER_TERM="${leader_term}"
    DISCOVERED_LEADER_COMMIT="${leader_commit}"
    DISCOVERED_LEADER_APPLIED="${leader_applied}"
    DISCOVERED_LEADER_LAST_LOG="${leader_last_log}"
    LAST_DISCOVERED_LEADER="${leader}"
    return 0
  fi
  DISCOVERED_LEADER=""
  DISCOVERED_LEADER_ADDR=""
  return 1
}

retry_write_to_leader() {
  local key="$1"
  local value="$2"
  local attempt output rc leader_addr
  LAST_REQUEST="put ${key} ${value}"
  LAST_RESPONSE=""
  for attempt in $(seq 1 60); do
    RETRY_COUNT="${attempt}"
    if ! discover_leader_once; then
      sleep 1
      continue
    fi
    leader_addr="${DISCOVERED_LEADER_ADDR}"
    LAST_REQUEST="put ${key} ${value} via ${leader_addr}"
    output="$("${CLIENT}" --servers="${leader_addr}" --timeout_ms=1000 --retries=1 put "${key}" "${value}" 2>&1)"
    rc="$?"
    LAST_RESPONSE="${output}"
    if [[ "${rc}" -eq 0 ]]; then
      return 0
    fi
    if grep -q "NOT_LEADER\|not leader\|connect failed\|request failed" <<<"${output}"; then
      sleep 1
      continue
    fi
    sleep 1
  done
  return 1
}

wait_recovered_node_caught_up() {
  local recovered_id="$1"
  local status role term commit applied last_log
  for _ in $(seq 1 60); do
    if ! discover_leader_once; then
      sleep 1
      continue
    fi
    status="$(node_status "${recovered_id}" 2>&1)"
    if [[ "$?" -ne 0 ]]; then
      LAST_RESPONSE="${status}"
      sleep 1
      continue
    fi
    role="$(status_value role <<<"${status}")"
    term="$(status_value current_term <<<"${status}")"
    commit="$(status_value commit_index <<<"${status}")"
    applied="$(status_value last_applied <<<"${status}")"
    last_log="$(status_value last_log_index <<<"${status}")"
    LAST_RESPONSE="recovered=node${recovered_id},role=${role},term=${term},commit=${commit},applied=${applied},last_log=${last_log}; leader=node${DISCOVERED_LEADER},term=${DISCOVERED_LEADER_TERM},commit=${DISCOVERED_LEADER_COMMIT},applied=${DISCOVERED_LEADER_APPLIED},last_log=${DISCOVERED_LEADER_LAST_LOG}"
    if [[ "${recovered_id}" != "${DISCOVERED_LEADER}" && "${role}" != "FOLLOWER" ]]; then
      sleep 1
      continue
    fi
    if [[ "${term}" =~ ^[0-9]+$ && "${commit}" =~ ^[0-9]+$ && "${applied}" =~ ^[0-9]+$ &&
          "${last_log}" =~ ^[0-9]+$ &&
          "${term}" -ge "${DISCOVERED_LEADER_TERM}" &&
          "${commit}" -ge "${DISCOVERED_LEADER_COMMIT}" &&
          "${applied}" -ge "${DISCOVERED_LEADER_APPLIED}" &&
          "${last_log}" -ge "${DISCOVERED_LEADER_COMMIT}" ]]; then
      echo "${LAST_RESPONSE}"
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_status_converged() {
  local target_key="$1"
  for _ in $(seq 1 60); do
    local v1 v2 v3
    v1="$(node_status 1 | status_value "${target_key}" || true)"
    v2="$(node_status 2 | status_value "${target_key}" || true)"
    v3="$(node_status 3 | status_value "${target_key}" || true)"
    if [[ -n "${v1}" && "${v1}" == "${v2}" && "${v2}" == "${v3}" ]]; then
      echo "${v1}"
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_snapshot_advanced() {
  for _ in $(seq 1 60); do
    for id in 1 2 3; do
      local snapshot_index
      snapshot_index="$(node_status "${id}" | status_value snapshot_index || true)"
      if [[ "${snapshot_index}" =~ ^[1-9][0-9]*$ ]]; then
        echo "${snapshot_index}"
        return 0
      fi
    done
    sleep 1
  done
  return 1
}

ensure_under_root "${RUN_DIR}" "${TEST_DATA_ROOT}"
ensure_under_root "${REPORT_DIR}" "${TEST_REPORT_ROOT}"
ensure_under_root "${NODE_LOG_DIR}" "${TEST_DATA_ROOT}"
mkdir -p "${CONFIG_DIR}" "${PID_DIR}" "${NODE_LOG_DIR}" "${REPORT_DIR}"

cd "${ROOT_DIR}"

echo "== Admin Status integration test =="
echo "run_id=${RUN_ID}"
echo "data_dir=${RUN_DIR}"
echo "report_dir=${REPORT_DIR}"

echo "command: cmake -S ${ROOT_DIR} -B ${BUILD_DIR} -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT=ON"
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT=ON || fail "configure failed"

echo "command: cmake --build ${BUILD_DIR} -j${BUILD_JOBS} --target kv_server kv_client"
cmake --build "${BUILD_DIR}" -j"${BUILD_JOBS}" --target kv_server kv_client || fail "build failed"

for id in 1 2 3; do
  write_config "${id}" 8
  start_node "${id}"
done

leader="$(wait_for_leader)" || fail "leader was not elected"
echo "leader=${leader}"

CURRENT_STEP="verify initial leader"
leader_count=0
for id in 1 2 3; do
  node_status "${id}" >"${REPORT_DIR}/node${id}.status" || fail "status failed for node${id}"
  role="$(status_value role <"${REPORT_DIR}/node${id}.status")"
  term="$(status_value current_term <"${REPORT_DIR}/node${id}.status")"
  [[ "${term}" =~ ^[0-9]+$ && "${term}" -gt 0 ]] || fail "invalid term for node${id}: ${term}"
  [[ "${role}" == "LEADER" ]] && leader_count="$((leader_count + 1))"
done
[[ "${leader_count}" -eq 1 ]] || fail "expected exactly one LEADER, got ${leader_count}"

CURRENT_STEP="initial writes"
for i in $(seq 1 20); do
  retry_write_to_leader "admin_key_${i}" "value_${i}" >/dev/null || fail "put ${i} failed"
done

CURRENT_STEP="wait initial commit convergence"
commit_before="$(wait_status_converged commit_index)" || fail "commit_index did not converge"
applied_before="$(wait_status_converged last_applied)" || fail "last_applied did not converge"
[[ "${commit_before}" -ge 20 ]] || fail "commit_index did not advance enough: ${commit_before}"
[[ "${applied_before}" -ge 20 ]] || fail "last_applied did not advance enough: ${applied_before}"

old_leader="${leader}"
old_pid="$(cat "${PID_DIR}/node${old_leader}.pid")"
echo "stopping leader node${old_leader}: pid=${old_pid}"
CURRENT_STEP="stop old leader"
stop_pid "${old_pid}"

CURRENT_STEP="wait new leader"
new_leader="$(wait_for_leader "${old_leader}")" || fail "new leader was not elected"
echo "new_leader=${new_leader}"
CURRENT_STEP="verify failover metrics"
status_after_failover="$(node_status "${new_leader}")" || fail "new leader status failed"
election_count="$(status_value election_count <<<"${status_after_failover}")"
leader_change_count="$(status_value leader_change_count <<<"${status_after_failover}")"
if [[ "${election_count}" -lt 1 && "${leader_change_count}" -lt 1 ]]; then
  fail "expected election_count or leader_change_count to increase"
fi

echo "restarting old leader node${old_leader}"
CURRENT_STEP="restart old leader"
start_node "${old_leader}"

CURRENT_STEP="wait old leader catch-up"
wait_recovered_node_caught_up "${old_leader}" >/dev/null || fail "old leader did not catch up after restart"

CURRENT_STEP="post-restart writes"
for i in $(seq 21 40); do
  retry_write_to_leader "admin_key_${i}" "value_${i}" >/dev/null || fail "post-restart put ${i} failed"
done

CURRENT_STEP="wait final convergence"
commit_final="$(wait_status_converged commit_index)" || fail "commit_index did not reconverge"
applied_final="$(wait_status_converged last_applied)" || fail "last_applied did not reconverge"
last_log_final="$(wait_status_converged last_log_index)" || fail "last_log_index did not reconverge"
echo "commit_final=${commit_final}"
echo "applied_final=${applied_final}"
echo "last_log_final=${last_log_final}"

CURRENT_STEP="wait snapshot"
snapshot_index="$(wait_snapshot_advanced)" || fail "snapshot_index did not advance"
echo "snapshot_index=${snapshot_index}"

CURRENT_STEP="verify wal bytes"
for id in 1 2 3; do
  wal_bytes="$(node_status "${id}" | status_value wal_bytes || true)"
  [[ "${wal_bytes}" =~ ^[0-9]+$ ]] || fail "invalid wal_bytes for node${id}: ${wal_bytes}"
done

CURRENT_STEP="verify unavailable display"
stop_pid "$(cat "${PID_DIR}/node3.pid")"
bash "${SHOW_STATUS}" \
  "127.0.0.1:$((CLIENT_BASE_PORT + 1))" \
  "127.0.0.1:$((CLIENT_BASE_PORT + 2))" \
  "127.0.0.1:$((CLIENT_BASE_PORT + 3))" >"${REPORT_DIR}/show_cluster_status.out"
grep -q "UNAVAILABLE" "${REPORT_DIR}/show_cluster_status.out" || fail "show_cluster_status did not show UNAVAILABLE"

echo "PASS"
