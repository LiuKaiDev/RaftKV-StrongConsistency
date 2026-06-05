#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_REPORT_ROOT="${TEST_REPORT_ROOT:-/tmp/raftkv-test-reports}"
OUTPUT_FILE="${OUTPUT_FILE:-${ROOT_DIR}/docs/release_evidence.md}"
GENERATED_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"
GIT_COMMIT="$(git -C "${ROOT_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"

latest_top_report_dir() {
  if [[ ! -d "${TEST_REPORT_ROOT}" ]]; then
    echo ""
    return 0
  fi
  find "${TEST_REPORT_ROOT}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | awk 'NR == 1 {print $2}'
}

latest_matching_file() {
  local pattern="$1"
  if [[ ! -d "${TEST_REPORT_ROOT}" ]]; then
    echo ""
    return 0
  fi
  find "${TEST_REPORT_ROOT}" -type f -path "${pattern}" -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | awk 'NR == 1 {print $2}'
}

status_from_log() {
  local file="$1"
  local pass_pattern="$2"
  local fail_pattern="$3"
  if [[ -z "${file}" || ! -f "${file}" ]]; then
    echo "NOT RUN"
  elif grep -Eq "${fail_pattern}" "${file}"; then
    echo "FAIL"
  elif grep -Eq "${pass_pattern}" "${file}"; then
    echo "PASS"
  else
    echo "UNKNOWN"
  fi
}

status_from_summary_key() {
  local file="$1"
  local key="$2"
  if [[ -z "${file}" || ! -f "${file}" ]]; then
    echo "NOT RUN"
    return 0
  fi
  local value
  value="$(awk -F= -v key="${key}" '$1 == key {print $2; exit}' "${file}")"
  case "${value}" in
    PASS) echo "PASS" ;;
    FAIL|[1-9]*|[0-9][0-9]*) echo "FAIL" ;;
    SKIPPED|"") echo "NOT RUN" ;;
    *) echo "${value}" ;;
  esac
}

latest_test_all_summary() {
  if [[ ! -d "${TEST_REPORT_ROOT}" ]]; then
    echo ""
    return 0
  fi
  local file
  while IFS= read -r file; do
    if awk -F= '
      $1 == "core_status" {core=1}
      $1 == "cluster_smoke_status" {cluster=1}
      END {exit (core && cluster) ? 0 : 1}
    ' "${file}"; then
      echo "${file}"
      return 0
    fi
  done < <(find "${TEST_REPORT_ROOT}" -mindepth 2 -maxdepth 2 -type f -name summary.txt -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}')
  echo ""
}

latest_verify_summary_for_profile() {
  local profile="$1"
  if [[ ! -d "${TEST_REPORT_ROOT}" ]]; then
    echo ""
    return 0
  fi
  local file
  while IFS= read -r file; do
    if awk -F= -v profile="${profile}" '$1 == "profile" && $2 == profile {found=1} END {exit found ? 0 : 1}' "${file}"; then
      echo "${file}"
      return 0
    fi
  done < <(find "${TEST_REPORT_ROOT}" -type f -name summary.txt -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}')
  echo ""
}

stage_result_from_test_all() {
  local stage_key="$1"
  local summary
  summary="$(latest_test_all_summary)"
  status_from_summary_key "${summary}" "${stage_key}"
}

stage_result_from_log_or_test_all() {
  local stage_key="$1"
  local log_pattern="$2"
  local pass_pattern="$3"
  local fail_pattern="$4"
  local log_file status
  log_file="$(latest_matching_file "${log_pattern}")"
  status="$(status_from_log "${log_file}" "${pass_pattern}" "${fail_pattern}")"
  if [[ "${status}" == "NOT RUN" ]]; then
    status="$(stage_result_from_test_all "${stage_key}")"
  fi
  printf '%s|%s\n' "${status}" "${log_file:-$(latest_test_all_summary)}"
}

write_row() {
  local name="$1"
  local status="$2"
  local report="$3"
  [[ -n "${report}" ]] || report="-"
  printf '| %s | %s | `%s` |\n' "${name}" "${status}" "${report}" >>"${OUTPUT_FILE}"
}

mkdir -p "$(dirname "${OUTPUT_FILE}")"

recent_dir="$(latest_top_report_dir)"
test_all_summary="$(latest_test_all_summary)"
nightly_summary="$(latest_verify_summary_for_profile nightly)"

cat >"${OUTPUT_FILE}" <<EOF
# v1.0 Release Evidence

Generated at: ${GENERATED_AT}

Git commit: \`${GIT_COMMIT}\`

Report root: \`${TEST_REPORT_ROOT}\`

Most recent top-level report directory: \`${recent_dir:-NOT FOUND}\`

This file summarizes existing reports only. It does not run tests and does not infer PASS when no report is found.

| Stage | Status | Report |
| --- | --- | --- |
EOF

core_file="$(latest_matching_file "${TEST_REPORT_ROOT}/*/logs/core.log")"
if [[ -z "${core_file}" ]]; then
  core_file="$(latest_matching_file "${TEST_REPORT_ROOT}/*/test_core.log")"
fi
core_status="$(status_from_log "${core_file}" "CORE TESTS PASSED|100% tests passed" "FAIL:|[1-9][0-9]* tests failed|[1-9][0-9]*% tests failed")"
if [[ "${core_status}" == "NOT RUN" ]]; then
  core_status="$(stage_result_from_test_all core_status)"
  core_file="${test_all_summary}"
fi
write_row "core tests" "${core_status}" "${core_file}"

cluster_status="$(stage_result_from_test_all cluster_smoke_status)"
cluster_file="$(latest_matching_file "${TEST_REPORT_ROOT}/*/test_cluster_smoke.log")"
write_row "cluster smoke" "${cluster_status}" "${cluster_file:-${test_all_summary}}"

IFS='|' read -r snapshot_status snapshot_file < <(stage_result_from_log_or_test_all \
  snapshot_cluster_status "${TEST_REPORT_ROOT}/*/test_snapshot_cluster.log" "SNAPSHOT.*PASSED|PASSED" "FAIL|ERROR")
write_row "snapshot cluster" "${snapshot_status}" "${snapshot_file}"

IFS='|' read -r chaos_status chaos_file < <(stage_result_from_log_or_test_all \
  seeded_chaos_status "${TEST_REPORT_ROOT}/*/test_seeded_chaos.log" "SEEDED CHAOS.*PASSED|PASSED" "FAIL|ERROR")
write_row "seeded chaos" "${chaos_status}" "${chaos_file}"

IFS='|' read -r linear_status linear_file < <(stage_result_from_log_or_test_all \
  linearizability_status "${TEST_REPORT_ROOT}/*/test_concurrent_linearizability.log" "LINEARIZABILITY PASSED|PASSED" "FAIL|LINEARIZABILITY FAILED")
write_row "linearizability" "${linear_status}" "${linear_file}"

IFS='|' read -r admin_status admin_file < <(stage_result_from_log_or_test_all \
  admin_status_status "${TEST_REPORT_ROOT}/*/test_admin_status.log" "ADMIN STATUS.*PASSED|PASSED" "FAIL")
write_row "admin status" "${admin_status}" "${admin_file}"

IFS='|' read -r bench_status bench_file < <(stage_result_from_log_or_test_all \
  benchmark_smoke_status "${TEST_REPORT_ROOT}/*/test_benchmark_smoke.log" "BENCHMARK SMOKE PASSED" "FAIL|missing")
write_row "benchmark smoke" "${bench_status}" "${bench_file}"

IFS='|' read -r read_index_status read_index_file < <(stage_result_from_log_or_test_all \
  read_index_status "${TEST_REPORT_ROOT}/*/test_read_index.log" "READINDEX.*PASSED|ReadIndex.*PASS|PASSED" "FAIL")
write_row "read index" "${read_index_status}" "${read_index_file}"

IFS='|' read -r leader_status leader_file < <(stage_result_from_log_or_test_all \
  leader_stability_status "${TEST_REPORT_ROOT}/*/test_leader_stability.log" "LEADER STABILITY.*PASSED|PASSED" "FAIL")
write_row "leader stability" "${leader_status}" "${leader_file}"

IFS='|' read -r batch_status batch_file < <(stage_result_from_log_or_test_all \
  batch_replication_status "${TEST_REPORT_ROOT}/*/test_batch_replication.log" "BATCH REPLICATION TEST PASSED" "FAIL")
write_row "batch replication" "${batch_status}" "${batch_file}"

IFS='|' read -r slow_status slow_file < <(stage_result_from_log_or_test_all \
  slow_follower_status "${TEST_REPORT_ROOT}/*/test_slow_follower.log" "SLOW FOLLOWER TEST PASSED" "FAIL")
write_row "slow follower" "${slow_status}" "${slow_file}"

nightly_status="$(status_from_summary_key "${nightly_summary}" status)"
write_row "nightly" "${nightly_status}" "${nightly_summary}"

cat >>"${OUTPUT_FILE}" <<EOF

## Notes

- \`NOT RUN\` means no existing report was found or the latest batch summary marked the stage as skipped.
- \`UNKNOWN\` means a report exists, but the script did not find a clear PASS/FAIL marker.
- Regenerate after running validation:

\`\`\`bash
bash scripts/collect_release_evidence.sh
\`\`\`
EOF

echo "release_evidence=${OUTPUT_FILE}"
