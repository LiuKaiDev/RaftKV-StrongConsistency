#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CLIENT="${ROOT_DIR}/bin/kv_client"
MODE="${1:-mixed}"
N="${2:-1000}"

if [[ "${MODE}" != "put" && "${MODE}" != "get" && "${MODE}" != "mixed" ]]; then
  echo "usage: benchmark.sh [put|get|mixed] [request_count]"
  exit 1
fi

if ! [[ "${N}" =~ ^[0-9]+$ ]] || [[ "${N}" -le 0 ]]; then
  echo "request_count must be a positive integer"
  exit 1
fi

latencies_file="$(mktemp)"
trap 'rm -f "${latencies_file}"' EXIT

if [[ "${MODE}" == "get" || "${MODE}" == "mixed" ]]; then
  echo "prefill ${N} benchmark keys"
  for i in $(seq 1 "${N}"); do
    "${CLIENT}" put "bench${i}" "value${i}" >/dev/null
  done
fi

success=0
fail=0
start_ns="$(date +%s%N)"

for i in $(seq 1 "${N}"); do
  begin_ns="$(date +%s%N)"
  if [[ "${MODE}" == "put" ]]; then
    "${CLIENT}" put "bench${i}" "value${i}" >/dev/null && rc=0 || rc=$?
  elif [[ "${MODE}" == "get" ]]; then
    "${CLIENT}" get "bench${i}" >/dev/null && rc=0 || rc=$?
  else
    if (( i % 2 == 0 )); then
      "${CLIENT}" put "bench_write${i}" "value${i}" >/dev/null && rc=0 || rc=$?
    else
      key_id=$(((i % N) + 1))
      "${CLIENT}" get "bench${key_id}" >/dev/null && rc=0 || rc=$?
    fi
  fi
  end_ns="$(date +%s%N)"
  echo "$(((end_ns - begin_ns) / 1000000))" >>"${latencies_file}"
  if [[ "${rc}" -eq 0 ]]; then
    success=$((success + 1))
  else
    fail=$((fail + 1))
  fi
done

end_ns="$(date +%s%N)"
elapsed_ms="$(((end_ns - start_ns) / 1000000))"
qps="$(awk -v n="${N}" -v ms="${elapsed_ms}" 'BEGIN { if (ms == 0) print 0; else printf "%.2f", n * 1000 / ms }')"
avg="$(awk '{sum += $1} END { if (NR == 0) print 0; else printf "%.2f", sum / NR }' "${latencies_file}")"
p99="$(sort -n "${latencies_file}" | awk -v n="${N}" 'BEGIN { idx = int(n * 0.99); if (idx < 1) idx = 1 } NR == idx { print $1 }')"

echo "mode=${MODE}"
echo "requests=${N}"
echo "qps=${qps}"
echo "avg_latency_ms=${avg}"
echo "p99_latency_ms=${p99:-0}"
echo "success=${success}"
echo "failed=${fail}"
echo "leader_unavailable_ms=not_collected"
