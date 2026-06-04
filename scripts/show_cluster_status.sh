#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KV_CLIENT="${RAFTKV_KV_CLIENT:-${ROOT_DIR}/bin/kv_client}"

if [[ "$#" -ne 3 ]]; then
  echo "Usage: $0 host1:port host2:port host3:port" >&2
  exit 1
fi

value_of() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key {print $2; exit}'
}

query_node() {
  local addr="$1"
  local out
  if ! out="$("${KV_CLIENT}" --servers="${addr}" --timeout_ms="${RAFTKV_STATUS_TIMEOUT_MS:-800}" --retries=1 status 2>/dev/null)"; then
    return 1
  fi
  printf '%s\n' "${out}"
}

printf '%-5s %-10s %-5s %-7s %-7s %-8s %-9s %-9s %-9s\n' \
  "NODE" "ROLE" "TERM" "LEADER" "COMMIT" "APPLIED" "LAST_LOG" "SNAPSHOT" "WAL_BYTES"

for addr in "$@"; do
  status="$(query_node "${addr}")"
  rc="$?"
  if [[ "${rc}" -ne 0 ]]; then
    printf '%-5s %-10s %-5s %-7s %-7s %-8s %-9s %-9s %-9s\n' \
      "${addr}" "UNAVAILABLE" "-" "-" "-" "-" "-" "-" "-"
    continue
  fi

  node="$(value_of node_id <<<"${status}")"
  role="$(value_of role <<<"${status}")"
  term="$(value_of current_term <<<"${status}")"
  leader="$(value_of leader_id <<<"${status}")"
  commit="$(value_of commit_index <<<"${status}")"
  applied="$(value_of last_applied <<<"${status}")"
  last_log="$(value_of last_log_index <<<"${status}")"
  snapshot="$(value_of snapshot_index <<<"${status}")"
  wal_bytes="$(value_of wal_bytes <<<"${status}")"

  printf '%-5s %-10s %-5s %-7s %-7s %-8s %-9s %-9s %-9s\n' \
    "${node:-${addr}}" "${role:-UNKNOWN}" "${term:-?}" "${leader:-?}" "${commit:-?}" \
    "${applied:-?}" "${last_log:-?}" "${snapshot:-?}" "${wal_bytes:-?}"
done
