#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_REPORT_ROOT="/root/raftkv-test-reports"
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

cat >"${REPORT_DIR}/summary.txt" <<EOF
run_id=${RUN_ID}
core_status=PASS
cluster_smoke_status=PASS
core_log=${REPORT_DIR}/test_core.log
cluster_smoke_log=${REPORT_DIR}/test_cluster_smoke.log
EOF

echo "ALL TESTS PASSED"
echo "summary=${REPORT_DIR}/summary.txt"
