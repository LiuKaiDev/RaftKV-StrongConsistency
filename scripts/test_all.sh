#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEST_DATA_ROOT="${TEST_DATA_ROOT:-/tmp/raftkv-test-data}"
export TEST_REPORT_ROOT="${TEST_REPORT_ROOT:-/tmp/raftkv-test-reports}"
RUN_ID="${RUN_ID:-all-$(date +%Y%m%d-%H%M%S)-$$}"
REPORT_DIR="${TEST_REPORT_ROOT}/${RUN_ID}"

case "${REPORT_DIR}" in
  "${TEST_REPORT_ROOT}"/*) ;;
  *)
    echo "ERROR: refusing to write reports outside ${TEST_REPORT_ROOT}: ${REPORT_DIR}" >&2
    exit 1
    ;;
esac

mkdir -p "${REPORT_DIR}"

echo "== Batch 1 test run =="
echo "run_id=${RUN_ID}"
echo "report_dir=${REPORT_DIR}"

core_status=0
cluster_status=0
snapshot_cluster_status=SKIPPED
seeded_chaos_status=SKIPPED
linearizability_status=SKIPPED
admin_status_status=SKIPPED

echo "running core tests..."
if RUN_ID="${RUN_ID}" bash "${ROOT_DIR}/scripts/test_core.sh" >"${REPORT_DIR}/test_core.log" 2>&1; then
  echo "core tests: PASS"
else
  core_status=$?
  echo "core tests: FAIL (${core_status})"
  echo "log: ${REPORT_DIR}/test_core.log"
  exit "${core_status}"
fi

echo "running cluster smoke test..."
if RUN_ID="${RUN_ID}" bash "${ROOT_DIR}/scripts/test_cluster_smoke.sh" >"${REPORT_DIR}/test_cluster_smoke.log" 2>&1; then
  echo "cluster smoke: PASS"
else
  cluster_status=$?
  echo "cluster smoke: FAIL (${cluster_status})"
  echo "log: ${REPORT_DIR}/test_cluster_smoke.log"
  exit "${cluster_status}"
fi

if [[ "${RUN_SNAPSHOT_CLUSTER:-0}" == "1" ]]; then
  echo "running snapshot cluster test..."
  if RUN_ID="${RUN_ID}" bash "${ROOT_DIR}/scripts/test_snapshot_cluster.sh" >"${REPORT_DIR}/test_snapshot_cluster.log" 2>&1; then
    echo "snapshot cluster: PASS"
    snapshot_cluster_status=PASS
  else
    snapshot_cluster_status=$?
    echo "snapshot cluster: FAIL (${snapshot_cluster_status})"
    echo "log: ${REPORT_DIR}/test_snapshot_cluster.log"
    exit "${snapshot_cluster_status}"
  fi
else
  echo "snapshot cluster: SKIPPED (set RUN_SNAPSHOT_CLUSTER=1 to run)"
fi

if [[ "${RUN_SEEDED_CHAOS:-0}" == "1" ]]; then
  echo "running seeded chaos test..."
  if RUN_ID="${RUN_ID}" bash "${ROOT_DIR}/scripts/test_seeded_chaos.sh" >"${REPORT_DIR}/test_seeded_chaos.log" 2>&1; then
    echo "seeded chaos: PASS"
    seeded_chaos_status=PASS
  else
    seeded_chaos_status=$?
    echo "seeded chaos: FAIL (${seeded_chaos_status})"
    echo "log: ${REPORT_DIR}/test_seeded_chaos.log"
    exit "${seeded_chaos_status}"
  fi
else
  echo "seeded chaos: SKIPPED (set RUN_SEEDED_CHAOS=1 to run)"
fi

if [[ "${RUN_LINEARIZABILITY:-0}" == "1" ]]; then
  echo "running concurrent linearizability test..."
  if RUN_ID="${RUN_ID}" bash "${ROOT_DIR}/scripts/test_concurrent_linearizability.sh" >"${REPORT_DIR}/test_concurrent_linearizability.log" 2>&1; then
    echo "concurrent linearizability: PASS"
    linearizability_status=PASS
  else
    linearizability_status=$?
    echo "concurrent linearizability: FAIL (${linearizability_status})"
    echo "log: ${REPORT_DIR}/test_concurrent_linearizability.log"
    exit "${linearizability_status}"
  fi
else
  echo "concurrent linearizability: SKIPPED (set RUN_LINEARIZABILITY=1 to run)"
fi

if [[ "${RUN_ADMIN_STATUS:-0}" == "1" ]]; then
  echo "running admin status integration test..."
  if RUN_ID="${RUN_ID}" bash "${ROOT_DIR}/scripts/test_admin_status.sh" >"${REPORT_DIR}/test_admin_status.log" 2>&1; then
    echo "admin status: PASS"
    admin_status_status=PASS
  else
    admin_status_status=$?
    echo "admin status: FAIL (${admin_status_status})"
    echo "log: ${REPORT_DIR}/test_admin_status.log"
    exit "${admin_status_status}"
  fi
else
  echo "admin status: SKIPPED (set RUN_ADMIN_STATUS=1 to run)"
fi

cat >"${REPORT_DIR}/summary.txt" <<EOF
run_id=${RUN_ID}
core_status=PASS
cluster_smoke_status=PASS
snapshot_cluster_status=${snapshot_cluster_status}
seeded_chaos_status=${seeded_chaos_status}
linearizability_status=${linearizability_status}
admin_status_status=${admin_status_status}
core_log=${REPORT_DIR}/test_core.log
cluster_smoke_log=${REPORT_DIR}/test_cluster_smoke.log
snapshot_cluster_log=${REPORT_DIR}/test_snapshot_cluster.log
seeded_chaos_log=${REPORT_DIR}/test_seeded_chaos.log
linearizability_log=${REPORT_DIR}/test_concurrent_linearizability.log
admin_status_log=${REPORT_DIR}/test_admin_status.log
EOF

echo "ALL TESTS PASSED"
echo "summary=${REPORT_DIR}/summary.txt"
