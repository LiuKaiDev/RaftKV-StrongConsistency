#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_REPORT_ROOT="${TEST_REPORT_ROOT:-/tmp/raftkv-test-reports}"
RUN_ID="${RUN_ID:-benchmark-smoke-$(date +%Y%m%d-%H%M%S)-$$}"
REPORT_DIR="${TEST_REPORT_ROOT}/${RUN_ID}/benchmark-v2"

cd "${ROOT_DIR}"

echo "== Benchmark v2 smoke test =="
echo "run_id=${RUN_ID}"

RUN_ID="${RUN_ID}" \
SCENARIO=steady \
THREADS=2 \
DURATION_SECONDS=3 \
WARMUP_SECONDS=1 \
KEY_COUNT=20 \
VALUE_SIZE=32 \
READ_PERCENT=70 \
PUT_PERCENT=20 \
APPEND_PERCENT=5 \
DELETE_PERCENT=5 \
SEED=20260604 \
bash "${ROOT_DIR}/scripts/run_benchmark_v2.sh"

[[ -f "${REPORT_DIR}/result.json" ]] || { echo "missing result.json" >&2; exit 1; }
[[ -f "${REPORT_DIR}/result.csv" ]] || { echo "missing result.csv" >&2; exit 1; }
[[ -f "${REPORT_DIR}/status_before.txt" ]] || { echo "missing status_before.txt" >&2; exit 1; }
[[ -f "${REPORT_DIR}/status_after.txt" ]] || { echo "missing status_after.txt" >&2; exit 1; }

python3 - "${REPORT_DIR}/result.json" "${REPORT_DIR}/result.csv" <<'PY'
import csv
import json
import sys

json_path, csv_path = sys.argv[1], sys.argv[2]
with open(json_path, "r", encoding="utf-8") as f:
    data = json.load(f)

required = [
    "throughput_ops_per_second",
    "successful_operations",
    "latency_us_p50",
    "latency_us_p95",
    "latency_us_p99",
    "latency_us_max",
]
missing = [field for field in required if field not in data]
if missing:
    raise SystemExit(f"missing JSON fields: {missing}")
if data["throughput_ops_per_second"] <= 0:
    raise SystemExit("throughput must be > 0")
if data["successful_operations"] <= 0:
    raise SystemExit("successful_operations must be > 0")
if not (data["latency_us_p50"] <= data["latency_us_p95"] <= data["latency_us_p99"] <= data["latency_us_max"]):
    raise SystemExit("latency percentiles are not ordered")

with open(csv_path, "r", encoding="utf-8", newline="") as f:
    rows = list(csv.DictReader(f))
if len(rows) != 1:
    raise SystemExit("CSV must contain exactly one result row")
for field in required:
    if field not in rows[0]:
        raise SystemExit(f"missing CSV field: {field}")
PY

echo "BENCHMARK SMOKE PASSED"
