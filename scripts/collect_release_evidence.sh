#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_REPORT_ROOT="${TEST_REPORT_ROOT:-/tmp/raftkv-test-reports}"
OUTPUT_FILE="${OUTPUT_FILE:-${ROOT_DIR}/docs/release_evidence.md}"
GENERATED_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"
GIT_COMMIT="$(git -C "${ROOT_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
RUNNING_REPORT_MAX_AGE_SECONDS="${RUNNING_REPORT_MAX_AGE_SECONDS:-3600}"

summary_files_newest_first() {
  if [[ ! -d "${TEST_REPORT_ROOT}" ]]; then
    return 0
  fi
  find "${TEST_REPORT_ROOT}" -type f -name summary.txt -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | awk '{print $2}'
}

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

first_summary_value() {
  local file="$1"
  local key="$2"
  [[ -n "${file}" && -f "${file}" ]] || return 0
  awk -F= -v key="${key}" '$1 == key {print $2; exit}' "${file}"
}

last_summary_value() {
  local file="$1"
  local key="$2"
  [[ -n "${file}" && -f "${file}" ]] || return 0
  awk -F= -v key="${key}" '$1 == key {value=$2} END {print value}' "${file}"
}

normalize_status() {
  local value="$1"
  case "${value}" in
    PASS|0) echo "PASS" ;;
    FAIL|ERROR|[1-9]*|[0-9][0-9]*) echo "FAIL" ;;
    SKIPPED|"") echo "NOT RUN" ;;
    RUNNING) echo "RUNNING" ;;
    NOT\ RUN) echo "NOT RUN" ;;
    UNKNOWN) echo "UNKNOWN" ;;
    *) echo "${value}" ;;
  esac
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

stage_status_from_verify_summary() {
  local file="$1"
  local stage="$2"
  [[ -n "${file}" && -f "${file}" ]] || return 0
  awk -F= -v stage="${stage}" '
    $1 == "stage" {active=($2 == stage)}
    active && $1 == "status" {status=$2}
    END {print status}
  ' "${file}"
}

stage_log_from_verify_summary() {
  local file="$1"
  local stage="$2"
  [[ -n "${file}" && -f "${file}" ]] || return 0
  awk -F= -v stage="${stage}" '
    $1 == "stage" {active=($2 == stage)}
    active && $1 == "log" {stage_log=$2}
    END {print stage_log}
  ' "${file}"
}

summary_is_stale() {
  local file="$1"
  local now modified age
  now="$(date +%s)"
  modified="$(stat -c %Y "${file}" 2>/dev/null || echo "${now}")"
  age="$((now - modified))"
  [[ "${age}" -gt "${RUNNING_REPORT_MAX_AGE_SECONDS}" ]]
}

nightly_status_from_summary() {
  local file="$1"
  if [[ -z "${file}" || ! -f "${file}" ]]; then
    echo "NOT RUN"
    return 0
  fi
  if grep -Eq '(^|[[:space:]])VERIFY PASSED($|[[:space:]])' "${file}"; then
    echo "PASS"
    return 0
  fi
  if grep -Eq '(^|[[:space:]])VERIFY FAILED($|[[:space:]])|^failed_stage=' "${file}"; then
    echo "FAIL"
    return 0
  fi
  local final_status
  final_status="$(last_summary_value "${file}" status)"
  case "${final_status}" in
    PASS) echo "PASS" ;;
    FAIL|[1-9]*|[0-9][0-9]*) echo "FAIL" ;;
    RUNNING|"")
      if summary_is_stale "${file}"; then
        echo "UNKNOWN"
      else
        echo "RUNNING"
      fi
      ;;
    *) echo "UNKNOWN" ;;
  esac
}

latest_verify_summary_for_profile() {
  local profile="$1"
  local file
  while IFS= read -r file; do
    if [[ "$(first_summary_value "${file}" profile)" == "${profile}" ]]; then
      echo "${file}"
      return 0
    fi
  done < <(summary_files_newest_first)
  echo ""
}

latest_completed_nightly_summary() {
  local file status
  while IFS= read -r file; do
    [[ "$(first_summary_value "${file}" profile)" == "nightly" ]] || continue
    status="$(nightly_status_from_summary "${file}")"
    if [[ "${status}" == "PASS" || "${status}" == "FAIL" ]]; then
      echo "${file}"
      return 0
    fi
  done < <(summary_files_newest_first)
  echo ""
}

latest_stage_verify_summary() {
  local stage="$1"
  local file status
  while IFS= read -r file; do
    [[ "$(first_summary_value "${file}" profile)" == "stage" ]] || continue
    status="$(normalize_status "$(stage_status_from_verify_summary "${file}" "${stage}")")"
    case "${status}" in
      PASS|FAIL|UNKNOWN)
        echo "${file}"
        return 0
        ;;
    esac
  done < <(summary_files_newest_first)
  echo ""
}

latest_test_all_summary() {
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
  done < <(summary_files_newest_first)
  echo ""
}

summary_status_key() {
  local file="$1"
  local key="$2"
  normalize_status "$(last_summary_value "${file}" "${key}")"
}

summary_log_key() {
  local file="$1"
  local key="$2"
  last_summary_value "${file}" "${key}"
}

stage_result_from_nightly() {
  local summary="$1"
  local stage="$2"
  local pass_pattern="$3"
  local fail_pattern="$4"
  local status log_file
  if [[ -z "${summary}" || ! -f "${summary}" ]]; then
    printf 'NOT RUN|\n'
    return 0
  fi
  status="$(normalize_status "$(stage_status_from_verify_summary "${summary}" "${stage}")")"
  log_file="$(stage_log_from_verify_summary "${summary}" "${stage}")"
  if [[ "${status}" != "NOT RUN" ]]; then
    if [[ "${status}" == "RUNNING" ]]; then
      status="UNKNOWN"
    fi
    printf '%s|%s\n' "${status}" "${log_file:-${summary}}"
    return 0
  fi
  if [[ -n "${log_file}" ]]; then
    status="$(status_from_log "${log_file}" "${pass_pattern}" "${fail_pattern}")"
    printf '%s|%s\n' "${status}" "${log_file}"
    return 0
  fi
  printf 'NOT RUN|\n'
}

stage_result_from_stage_verify() {
  local stage="$1"
  local summary status log_file
  summary="$(latest_stage_verify_summary "${stage}")"
  if [[ -z "${summary}" ]]; then
    printf 'NOT RUN|\n'
    return 0
  fi
  status="$(normalize_status "$(stage_status_from_verify_summary "${summary}" "${stage}")")"
  log_file="$(stage_log_from_verify_summary "${summary}" "${stage}")"
  printf '%s|%s\n' "${status}" "${log_file:-${summary}}"
}

stage_result_from_test_all() {
  local summary="$1"
  local status_key="$2"
  local log_key="$3"
  local status log_file
  if [[ -z "${summary}" || ! -f "${summary}" ]]; then
    printf 'NOT RUN|\n'
    return 0
  fi
  status="$(summary_status_key "${summary}" "${status_key}")"
  log_file="$(summary_log_key "${summary}" "${log_key}")"
  printf '%s|%s\n' "${status}" "${log_file:-${summary}}"
}

stage_result_from_history_log() {
  local log_name="$1"
  local pass_pattern="$2"
  local fail_pattern="$3"
  local log_file status
  log_file="$(latest_matching_file "${TEST_REPORT_ROOT}/*/${log_name}")"
  status="$(status_from_log "${log_file}" "${pass_pattern}" "${fail_pattern}")"
  printf '%s|%s\n' "${status}" "${log_file}"
}

stage_result() {
  local stage="$1"
  local status_key="$2"
  local log_key="$3"
  local legacy_log_name="$4"
  local pass_pattern="$5"
  local fail_pattern="$6"
  local status report

  IFS='|' read -r status report < <(stage_result_from_nightly "${completed_nightly_summary}" "${stage}" "${pass_pattern}" "${fail_pattern}")
  if [[ "${status}" != "NOT RUN" ]]; then
    printf '%s|%s\n' "${status}" "${report}"
    return 0
  fi

  IFS='|' read -r status report < <(stage_result_from_stage_verify "${stage}")
  if [[ "${status}" != "NOT RUN" ]]; then
    printf '%s|%s\n' "${status}" "${report}"
    return 0
  fi

  IFS='|' read -r status report < <(stage_result_from_test_all "${test_all_summary}" "${status_key}" "${log_key}")
  if [[ "${status}" != "NOT RUN" ]]; then
    printf '%s|%s\n' "${status}" "${report}"
    return 0
  fi

  IFS='|' read -r status report < <(stage_result_from_history_log "${legacy_log_name}" "${pass_pattern}" "${fail_pattern}")
  printf '%s|%s\n' "${status}" "${report}"
}

write_row() {
  local name="$1"
  local status="$2"
  local report="$3"
  [[ -n "${report}" ]] || report="-"
  printf '| %s | %s | `%s` |\n' "${name}" "${status}" "${report}" >>"${OUTPUT_FILE}"
}

generate_release_evidence() {
  mkdir -p "$(dirname "${OUTPUT_FILE}")"

  recent_dir="$(latest_top_report_dir)"
  test_all_summary="$(latest_test_all_summary)"
  latest_nightly_summary="$(latest_verify_summary_for_profile nightly)"
  completed_nightly_summary="$(latest_completed_nightly_summary)"
  nightly_status="$(nightly_status_from_summary "${latest_nightly_summary}")"

  cat >"${OUTPUT_FILE}" <<EOF
# v1.0 Release Evidence

Generated at: ${GENERATED_AT}

Git commit: \`${GIT_COMMIT}\`

Report root: \`${TEST_REPORT_ROOT}\`

Most recent top-level report directory: \`${recent_dir:-NOT FOUND}\`

Preferred completed nightly report: \`${completed_nightly_summary:-NOT FOUND}\`

This file summarizes existing reports only. It does not run tests and does not infer PASS when no report is found.

Report source priority: latest completed nightly, latest completed single-stage verify report, latest test_all report, then other historical stage logs.

| Stage | Status | Report |
| --- | --- | --- |
EOF

  local status report
  IFS='|' read -r status report < <(stage_result core core_status core_log test_core.log "CORE TESTS PASSED|100% tests passed" "FAIL:|[1-9][0-9]* tests failed|[1-9][0-9]*% tests failed")
  write_row "core tests" "${status}" "${report}"

  IFS='|' read -r status report < <(stage_result cluster_smoke cluster_smoke_status cluster_smoke_log test_cluster_smoke.log "CLUSTER SMOKE PASSED|PASSED" "FAIL|ERROR")
  write_row "cluster smoke" "${status}" "${report}"

  IFS='|' read -r status report < <(stage_result snapshot snapshot_cluster_status snapshot_cluster_log test_snapshot_cluster.log "SNAPSHOT.*PASSED|PASSED" "FAIL|ERROR")
  write_row "snapshot cluster" "${status}" "${report}"

  IFS='|' read -r status report < <(stage_result seeded_chaos seeded_chaos_status seeded_chaos_log test_seeded_chaos.log "SEEDED CHAOS.*PASSED|PASSED" "FAIL|ERROR")
  write_row "seeded chaos" "${status}" "${report}"

  IFS='|' read -r status report < <(stage_result linearizability linearizability_status linearizability_log test_concurrent_linearizability.log "LINEARIZABILITY PASSED|PASSED" "FAIL|LINEARIZABILITY FAILED|LINEARIZABILITY_SAFETY_FAIL|WORKLOAD_LIVENESS_FAIL|INFRASTRUCTURE_FAIL")
  write_row "linearizability" "${status}" "${report}"

  IFS='|' read -r status report < <(stage_result admin_status admin_status_status admin_status_log test_admin_status.log "ADMIN STATUS.*PASSED|PASSED" "FAIL")
  write_row "admin status" "${status}" "${report}"

  IFS='|' read -r status report < <(stage_result benchmark_smoke benchmark_smoke_status benchmark_smoke_log test_benchmark_smoke.log "BENCHMARK SMOKE PASSED|PASSED" "FAIL|missing")
  write_row "benchmark smoke" "${status}" "${report}"

  IFS='|' read -r status report < <(stage_result read_index read_index_status read_index_log test_read_index.log "READINDEX.*PASSED|ReadIndex.*PASS|PASSED" "FAIL")
  write_row "read index" "${status}" "${report}"

  IFS='|' read -r status report < <(stage_result leader_stability leader_stability_status leader_stability_log test_leader_stability.log "LEADER STABILITY.*PASSED|PASSED" "FAIL")
  write_row "leader stability" "${status}" "${report}"

  IFS='|' read -r status report < <(stage_result batch_replication batch_replication_status batch_replication_log test_batch_replication.log "BATCH REPLICATION TEST PASSED|PASSED" "FAIL")
  write_row "batch replication" "${status}" "${report}"

  IFS='|' read -r status report < <(stage_result slow_follower slow_follower_status slow_follower_log test_slow_follower.log "SLOW FOLLOWER TEST PASSED|PASSED" "FAIL")
  write_row "slow follower" "${status}" "${report}"

  write_row "nightly" "${nightly_status}" "${latest_nightly_summary}"

  cat >>"${OUTPUT_FILE}" <<EOF

## Notes

- \`NOT RUN\` means no existing report was found, or every higher-priority source marked the stage as skipped and no lower-priority stage report exists.
- \`UNKNOWN\` means a report exists, but the script did not find a clear PASS/FAIL marker, or a stale nightly summary has no finish marker.
- \`RUNNING\` means the latest nightly summary has no finish marker and is still fresh enough to plausibly be in progress.
- Regenerate after running validation:

\`\`\`bash
bash scripts/collect_release_evidence.sh
\`\`\`
EOF

  echo "release_evidence=${OUTPUT_FILE}"
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  if ! grep -Eq "${pattern}" "${file}"; then
    echo "self-test assertion failed: ${pattern}" >&2
    echo "file=${file}" >&2
    sed -n '1,220p' "${file}" >&2
    return 1
  fi
}

write_nightly_summary_fixture() {
  local dir="$1"
  local final_status="$2"
  mkdir -p "${dir}/logs"
  {
    echo "profile=nightly"
    echo "report_dir=${dir}"
    for stage in core read_index slow_follower; do
      echo "stage=${stage}"
      echo "status=RUNNING"
      echo "log=${dir}/logs/${stage}.log"
      if [[ "${final_status}" == "PASS" ]]; then
        echo "stage=${stage}"
        echo "status=PASS"
      fi
    done
    if [[ "${final_status}" == "PASS" ]]; then
      echo "VERIFY PASSED"
      echo "status=PASS"
      echo "finished_at=fixture"
    elif [[ "${final_status}" == "FAIL" ]]; then
      echo "failed_stage=read_index"
      echo "status=FAIL"
      echo "finished_at=fixture"
    fi
  } >"${dir}/summary.txt"
  echo "CORE TESTS PASSED" >"${dir}/logs/core.log"
  echo "READINDEX TEST PASSED" >"${dir}/logs/read_index.log"
  echo "SLOW FOLLOWER TEST PASSED" >"${dir}/logs/slow_follower.log"
}

run_self_test() {
  local tmp output
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/raftkv-release-evidence-test.XXXXXX")"
  trap "rm -rf '${tmp}'" EXIT

  mkdir -p "${tmp}/all-old"
  {
    echo "run_id=all-old"
    echo "core_status=PASS"
    echo "read_index_status=FAIL"
    echo "slow_follower_status=SKIPPED"
    echo "core_log=${tmp}/all-old/test_core.log"
    echo "read_index_log=${tmp}/all-old/test_read_index.log"
    echo "slow_follower_log=${tmp}/all-old/test_slow_follower.log"
  } >"${tmp}/all-old/summary.txt"
  echo "FAIL" >"${tmp}/all-old/test_read_index.log"
  write_nightly_summary_fixture "${tmp}/nightly-pass" PASS
  touch -d '2026-01-01 00:00:00' "${tmp}/all-old/summary.txt" "${tmp}/all-old/test_read_index.log"
  touch -d '2026-01-02 00:00:00' "${tmp}/nightly-pass/summary.txt" "${tmp}/nightly-pass/logs/read_index.log" "${tmp}/nightly-pass/logs/slow_follower.log"
  output="${tmp}/evidence-pass.md"
  TEST_REPORT_ROOT="${tmp}" OUTPUT_FILE="${output}" COLLECT_RELEASE_EVIDENCE_SELF_TEST=0 bash "${BASH_SOURCE[0]}" >/dev/null
  assert_file_contains "${output}" '\| read index \| PASS \| `'"${tmp}"'/nightly-pass/logs/read_index.log` \|'
  assert_file_contains "${output}" '\| slow follower \| PASS \| `'"${tmp}"'/nightly-pass/logs/slow_follower.log` \|'
  assert_file_contains "${output}" '\| nightly \| PASS \| `'"${tmp}"'/nightly-pass/summary.txt` \|'

  rm -rf "${tmp:?}"/*
  write_nightly_summary_fixture "${tmp}/nightly-fail" FAIL
  output="${tmp}/evidence-fail.md"
  TEST_REPORT_ROOT="${tmp}" OUTPUT_FILE="${output}" COLLECT_RELEASE_EVIDENCE_SELF_TEST=0 bash "${BASH_SOURCE[0]}" >/dev/null
  assert_file_contains "${output}" '\| nightly \| FAIL \| `'"${tmp}"'/nightly-fail/summary.txt` \|'

  rm -rf "${tmp:?}"/*
  write_nightly_summary_fixture "${tmp}/nightly-running" RUNNING
  output="${tmp}/evidence-running.md"
  TEST_REPORT_ROOT="${tmp}" OUTPUT_FILE="${output}" RUNNING_REPORT_MAX_AGE_SECONDS=3600 COLLECT_RELEASE_EVIDENCE_SELF_TEST=0 bash "${BASH_SOURCE[0]}" >/dev/null
  assert_file_contains "${output}" '\| nightly \| RUNNING \| `'"${tmp}"'/nightly-running/summary.txt` \|'
  touch -d '2000-01-01 00:00:00' "${tmp}/nightly-running/summary.txt"
  output="${tmp}/evidence-unknown.md"
  TEST_REPORT_ROOT="${tmp}" OUTPUT_FILE="${output}" RUNNING_REPORT_MAX_AGE_SECONDS=1 COLLECT_RELEASE_EVIDENCE_SELF_TEST=0 bash "${BASH_SOURCE[0]}" >/dev/null
  assert_file_contains "${output}" '\| nightly \| UNKNOWN \| `'"${tmp}"'/nightly-running/summary.txt` \|'

  rm -rf "${tmp:?}"/*
  output="${tmp}/evidence-empty.md"
  TEST_REPORT_ROOT="${tmp}" OUTPUT_FILE="${output}" COLLECT_RELEASE_EVIDENCE_SELF_TEST=0 bash "${BASH_SOURCE[0]}" >/dev/null
  assert_file_contains "${output}" '\| read index \| NOT RUN \| `-` \|'
  assert_file_contains "${output}" '\| nightly \| NOT RUN \| `-` \|'

  echo "SELF TEST PASSED"
}

if [[ "${COLLECT_RELEASE_EVIDENCE_SELF_TEST:-0}" == "1" ]]; then
  run_self_test
  exit 0
fi

generate_release_evidence
