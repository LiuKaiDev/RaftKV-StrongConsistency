#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DATA_ROOT="/root/raftkv-test-data"
RUN_ID="${RUN_ID:-core-$(date +%Y%m%d-%H%M%S)-$$}"
CORE_DATA_DIR="${TEST_DATA_ROOT}/${RUN_ID}/core"
BUILD_DIR="${ROOT_DIR}/build/core"
BUILD_JOBS="${BUILD_JOBS:-1}"

ensure_under_test_data() {
  local path="$1"
  case "${path}" in
    "${TEST_DATA_ROOT}"/*) ;;
    *)
      echo "ERROR: refusing to use test data path outside ${TEST_DATA_ROOT}: ${path}" >&2
      exit 1
      ;;
  esac
}

ensure_under_test_data "${CORE_DATA_DIR}"
mkdir -p "${CORE_DATA_DIR}"
export TMPDIR="${CORE_DATA_DIR}"

cd "${ROOT_DIR}"

echo "== Core test baseline =="
echo "run_id=${RUN_ID}"
echo "build_dir=${BUILD_DIR}"
echo "tmpdir=${TMPDIR}"
echo "command: cmake -S ${ROOT_DIR} -B ${BUILD_DIR} -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT=OFF"
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT=OFF

echo "command: cmake --build ${BUILD_DIR} -j${BUILD_JOBS}"
cmake --build "${BUILD_DIR}" -j"${BUILD_JOBS}"

test_count="$(ctest --test-dir "${BUILD_DIR}" -N | awk '/Total Tests:/ {print $3}')"
test_count="${test_count:-0}"

echo "command: ctest --test-dir ${BUILD_DIR} --output-on-failure"
ctest --test-dir "${BUILD_DIR}" --output-on-failure

echo "CORE TESTS PASSED: ${test_count}/${test_count}"
