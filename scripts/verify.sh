#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-}"
STAGE_NAME="${2:-}"

TEST_DATA_ROOT_BASE="${TEST_DATA_ROOT:-/tmp/raftkv-test-data}"
TEST_REPORT_ROOT_BASE="${TEST_REPORT_ROOT:-/tmp/raftkv-test-reports}"
BUILD_JOBS="${BUILD_JOBS:-1}"
export BUILD_JOBS

usage() {
  cat <<'EOF'
Usage:
  bash scripts/verify.sh fast
  bash scripts/verify.sh stage <stage_name>
  bash scripts/verify.sh pre_push
  bash scripts/verify.sh nightly

Stages:
  snapshot
  seeded_chaos
  linearizability
  admin_status
  benchmark_smoke
  read_index
  leader_stability
  batch_replication
EOF
}

timestamp() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

shell_quote() {
  printf '%q' "$1"
}

if [[ -z "${PROFILE}" ]]; then
  usage >&2
  exit 2
fi

case "${PROFILE}" in
  fast|stage|pre_push|nightly) ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "ERROR: unknown profile: ${PROFILE}" >&2
    usage >&2
    exit 2
    ;;
esac

if [[ "${PROFILE}" == "stage" && -z "${STAGE_NAME}" ]]; then
  echo "ERROR: missing stage name" >&2
  usage >&2
  exit 2
fi

if [[ "${PROFILE}" != "stage" && -n "${STAGE_NAME}" ]]; then
  echo "ERROR: ${PROFILE} does not accept a stage name" >&2
  usage >&2
  exit 2
fi

VERIFY_RUN_ID="${VERIFY_RUN_ID:-verify-${PROFILE}-$(date +%Y%m%d-%H%M%S)-$$}"
VERIFY_REPORT_DIR="${VERIFY_REPORT_DIR:-${TEST_REPORT_ROOT_BASE}/${VERIFY_RUN_ID}}"
VERIFY_DATA_DIR="${VERIFY_DATA_DIR:-${TEST_DATA_ROOT_BASE}/${VERIFY_RUN_ID}}"
LOG_DIR="${VERIFY_REPORT_DIR}/logs"
SUMMARY_FILE="${VERIFY_REPORT_DIR}/summary.txt"
CURRENT_STAGE=""

mkdir -p "${LOG_DIR}" "${VERIFY_DATA_DIR}"

cd "${ROOT_DIR}"

{
  echo "profile=${PROFILE}"
  echo "verify_run_id=${VERIFY_RUN_ID}"
  echo "started_at=$(timestamp)"
  echo "root_dir=${ROOT_DIR}"
  echo "report_dir=${VERIFY_REPORT_DIR}"
  echo "data_dir=${VERIFY_DATA_DIR}"
  echo "build_jobs=${BUILD_JOBS}"
  echo
} >"${SUMMARY_FILE}"

handle_interrupt() {
  {
    echo "status=INTERRUPTED"
    echo "interrupted_stage=${CURRENT_STAGE:-none}"
    echo "interrupted_at=$(timestamp)"
    echo "note=child test scripts receive the same interrupt and keep their own cleanup behavior"
  } >>"${SUMMARY_FILE}"
  echo
  echo "INTERRUPTED: stage=${CURRENT_STAGE:-none}"
  echo "summary=${SUMMARY_FILE}"
  exit 130
}

trap handle_interrupt INT TERM

run_step() {
  local name="$1"
  local replay="$2"
  shift 2

  local log_file="${LOG_DIR}/${name}.log"
  local started_at ended_at start_epoch end_epoch elapsed status
  started_at="$(timestamp)"
  start_epoch="$(date +%s)"
  CURRENT_STAGE="${name}"

  echo "== ${name} =="
  echo "start=${started_at}"
  echo "log=${log_file}"
  echo "replay=${replay}"

  {
    echo "stage=${name}"
    echo "status=RUNNING"
    echo "start=${started_at}"
    echo "log=${log_file}"
    echo "replay=${replay}"
  } >>"${SUMMARY_FILE}"

  set +e
  "$@" 2>&1 | tee "${log_file}"
  status=${PIPESTATUS[0]}
  set -e

  ended_at="$(timestamp)"
  end_epoch="$(date +%s)"
  elapsed=$((end_epoch - start_epoch))

  if [[ "${status}" -eq 0 ]]; then
    echo "end=${ended_at}"
    echo "duration_seconds=${elapsed}"
    echo "result=PASS"
    echo
    {
      echo "stage=${name}"
      echo "status=PASS"
      echo "end=${ended_at}"
      echo "duration_seconds=${elapsed}"
      echo
    } >>"${SUMMARY_FILE}"
    CURRENT_STAGE=""
    return 0
  fi

  echo "end=${ended_at}"
  echo "duration_seconds=${elapsed}"
  echo "result=FAIL"
  echo "failed_stage=${name}"
  echo "replay=${replay}"
  echo "summary=${SUMMARY_FILE}"
  {
    echo "stage=${name}"
    echo "status=FAIL"
    echo "exit_code=${status}"
    echo "end=${ended_at}"
    echo "duration_seconds=${elapsed}"
    echo "failed_stage=${name}"
    echo "replay=${replay}"
    echo
    echo "status=FAIL"
    echo "failed_stage=${name}"
    echo "finished_at=${ended_at}"
  } >>"${SUMMARY_FILE}"
  exit "${status}"
}

child_env_args() {
  local child_run_id="$1"
  printf 'TEST_DATA_ROOT=%s TEST_REPORT_ROOT=%s RUN_ID=%s BUILD_JOBS=%s' \
    "$(shell_quote "${VERIFY_DATA_DIR}")" \
    "$(shell_quote "${VERIFY_REPORT_DIR}")" \
    "$(shell_quote "${child_run_id}")" \
    "$(shell_quote "${BUILD_JOBS}")"
}

run_child_script() {
  local name="$1"
  local script="$2"
  local child_run_id="${VERIFY_RUN_ID}-${name}"
  local replay
  replay="$(child_env_args "${child_run_id}") bash scripts/${script}"
  run_step "${name}" "${replay}" \
    env TEST_DATA_ROOT="${VERIFY_DATA_DIR}" \
      TEST_REPORT_ROOT="${VERIFY_REPORT_DIR}" \
      RUN_ID="${child_run_id}" \
      BUILD_JOBS="${BUILD_JOBS}" \
      bash "${ROOT_DIR}/scripts/${script}"
}

run_git_diff_check() {
  run_step "git_diff_check" "git diff --check" git diff --check
}

run_core() {
  run_child_script "core" "test_core.sh"
}

run_cluster_smoke() {
  run_child_script "cluster_smoke" "test_cluster_smoke.sh"
}

run_stage() {
  local stage="$1"
  case "${stage}" in
    snapshot)
      run_child_script "snapshot" "test_snapshot_cluster.sh"
      ;;
    seeded_chaos)
      run_child_script "seeded_chaos" "test_seeded_chaos.sh"
      ;;
    linearizability)
      run_child_script "linearizability" "test_concurrent_linearizability.sh"
      ;;
    admin_status)
      run_child_script "admin_status" "test_admin_status.sh"
      ;;
    benchmark_smoke)
      run_child_script "benchmark_smoke" "test_benchmark_smoke.sh"
      ;;
    read_index)
      run_child_script "read_index" "test_read_index.sh"
      ;;
    leader_stability)
      run_child_script "leader_stability" "test_leader_stability.sh"
      ;;
    batch_replication)
      run_child_script "batch_replication" "test_batch_replication.sh"
      ;;
    *)
      echo "ERROR: unknown stage: ${stage}" >&2
      usage >&2
      exit 2
      ;;
  esac
}

run_test_all() {
  run_child_script "test_all" "test_all.sh"
}

run_fast_build_targets() {
  run_step "raft_targets" \
    "cmake --build build/raft -j1 --target kv_server kv_client kv_bench" \
    cmake --build "${ROOT_DIR}/build/raft" -j1 --target kv_server kv_client kv_bench
}

finish_success() {
  local finished_at
  finished_at="$(timestamp)"
  {
    echo "status=PASS"
    echo "finished_at=${finished_at}"
  } >>"${SUMMARY_FILE}"
  echo "VERIFY PASSED"
  echo "summary=${SUMMARY_FILE}"
  echo "report_dir=${VERIFY_REPORT_DIR}"
}

case "${PROFILE}" in
  fast)
    run_git_diff_check
    run_core
    run_fast_build_targets
    ;;
  stage)
    run_stage "${STAGE_NAME}"
    ;;
  pre_push)
    run_git_diff_check
    run_core
    run_test_all
    for extra_stage in ${VERIFY_EXTRA_STAGES:-}; do
      run_stage "${extra_stage}"
    done
    ;;
  nightly)
    run_core
    run_cluster_smoke
    run_stage "snapshot"
    run_stage "seeded_chaos"
    run_stage "linearizability"
    run_stage "admin_status"
    run_stage "benchmark_smoke"
    run_stage "read_index"
    run_stage "leader_stability"
    run_stage "batch_replication"
    ;;
esac

finish_success
