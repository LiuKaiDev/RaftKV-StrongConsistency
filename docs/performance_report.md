# Performance Report

Status: 待在普通 SSH 环境中运行命令后填写。

This report is a template for v1.0 performance evidence. Do not fill it with estimated numbers. Use actual report files from `scripts/run_benchmark_v2.sh`, `scripts/test_slow_follower.sh`, and `scripts/run_replication_matrix.sh`.

Single-machine results are for regression and optimization comparison only. They are not production benchmark claims.

## Environment

| Field | Value |
| --- | --- |
| Date | TBD |
| Git commit | TBD |
| Machine type | TBD |
| CPU | TBD |
| Memory | TBD |
| Disk | TBD |
| OS | TBD |
| Build type | Release |
| Notes | TBD |

## ReadIndex Comparison

Run on the same machine and code revision:

```bash
READ_MODE=log SCENARIO=steady READ_PERCENT=100 PUT_PERCENT=0 APPEND_PERCENT=0 DELETE_PERCENT=0 \
  bash scripts/run_benchmark_v2.sh

READ_MODE=read_index SCENARIO=steady READ_PERCENT=100 PUT_PERCENT=0 APPEND_PERCENT=0 DELETE_PERCENT=0 \
  bash scripts/run_benchmark_v2.sh
```

| Metric | READ_MODE=log | READ_MODE=read_index | Report path |
| --- | --- | --- | --- |
| throughput_ops_per_second | TBD | TBD | TBD |
| latency_us_p50 | TBD | TBD | TBD |
| latency_us_p95 | TBD | TBD | TBD |
| latency_us_p99 | TBD | TBD | TBD |
| failed_operations | TBD | TBD | TBD |
| retry_count | TBD | TBD | TBD |
| wal_bytes delta | TBD | TBD | TBD |
| append_entries_sent delta | TBD | TBD | TBD |
| read_log_total | TBD | TBD | TBD |
| read_index_success | TBD | TBD | TBD |

Interpretation:

- TBD after reports are generated.
- Do not compare runs from different machines or different commits as optimization evidence.

## Batching Comparison

Run a write-heavy workload with the same parameters except batch size:

```bash
MAX_APPEND_ENTRIES_PER_RPC=1 \
SCENARIO=steady THREADS=2 READ_PERCENT=0 PUT_PERCENT=100 APPEND_PERCENT=0 DELETE_PERCENT=0 \
  bash scripts/run_benchmark_v2.sh

MAX_APPEND_ENTRIES_PER_RPC=64 \
SCENARIO=steady THREADS=2 READ_PERCENT=0 PUT_PERCENT=100 APPEND_PERCENT=0 DELETE_PERCENT=0 \
  bash scripts/run_benchmark_v2.sh
```

Follower catch-up comparison can also use:

```bash
bash scripts/test_slow_follower.sh
```

| Metric | MAX_APPEND_ENTRIES_PER_RPC=1 | MAX_APPEND_ENTRIES_PER_RPC=64 | Report path |
| --- | --- | --- | --- |
| follower catchup duration | TBD | TBD | TBD |
| append_entries_batch_rpc_count | TBD | TBD | TBD |
| append_entries_entries_sent | TBD | TBD | TBD |
| append_entries_max_batch_observed | TBD | TBD | TBD |
| latency_us_p95 | TBD | TBD | TBD |
| latency_us_p99 | TBD | TBD | TBD |

Interpretation:

- TBD after reports are generated.
- Batching reduces round trips for lagging follower catch-up, especially when each AppendEntries response has non-trivial delay.

## Slow Follower Matrix

Run:

```bash
DELAY_MS_LIST="0 10 50 100" \
BATCH_SIZE_LIST="1 8 64" \
WORKLOAD_COUNT=200 \
  bash scripts/run_replication_matrix.sh
```

Copy rows from `results.csv`:

| delay_ms | batch_size | workload_count | catchup_duration_ms | append_entries_batch_rpc_count | append_entries_entries_sent | append_entries_max_batch_observed | follower_catchup_attempts | follower_catchup_success | snapshot_used | final_consistency |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 1 | 200 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| 0 | 8 | 200 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| 0 | 64 | 200 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| 10 | 1 | 200 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| 10 | 8 | 200 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| 10 | 64 | 200 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| 50 | 1 | 200 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| 50 | 8 | 200 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| 50 | 64 | 200 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| 100 | 1 | 200 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| 100 | 8 | 200 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| 100 | 64 | 200 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |

## Notes

- These measurements are single-Raft-group prototype measurements.
- They should be used to catch regressions and guide optimization tradeoffs.
- They should not be described as production-grade database performance.
- Current implementation still has `max_inflight_append_entries_per_peer=1`; inflight pipeline is not implemented.
