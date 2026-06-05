# Performance Report

Status: Final v1.0 performance evidence. ReadIndex, AppendEntries batching, and the slow Follower matrix were filled from preserved report files. The `delay=100ms,batch=1` slow Follower row timed out within the default catch-up budget and is recorded as `TIMEOUT`, not as a correctness failure or a PASS.

This report uses actual report files from `scripts/run_benchmark_v2.sh` and `scripts/run_replication_matrix.sh`. No estimated numbers are included.

Single-machine results are for regression and relative optimization comparison only. They are not production benchmark claims.

## Environment

| Field | Value |
| --- | --- |
| Date | Fri Jun 5 15:39:12 CST 2026 |
| Git commit | `3fbd15c315c486916ceddb70b1a3c3691f12fd7c` |
| Machine type | Alibaba Cloud KVM VM, hostname `iZ2ze56tozb0iaxhkz9lzqZ` |
| CPU | 2 vCPU, Intel(R) Xeon(R) Platinum, 1 socket, 1 core, 2 threads |
| Memory | 1.8 GiB RAM, 4.0 GiB swap |
| Disk | `/dev/vda3` ext4, 40G total, 24G used, 14G available, 63% used |
| OS | Alibaba Cloud Linux 3.2104 U11 (OpenAnolis Edition), Linux 5.10.134-18.al8.x86_64 |
| Build type | Release |
| Notes | Benchmarks were run sequentially in normal SSH/outside sandbox because the sandbox disallows local socket binding. The host is a small 2 vCPU, low-memory server; use these numbers for local regression comparison only. |

## ReadIndex Comparison

Parameters: `SCENARIO=steady`, `THREADS=2`, `DURATION_SECONDS=30`, `WARMUP_SECONDS=5`, `KEY_COUNT=500`, `VALUE_SIZE=64`, `READ_PERCENT=100`, `PUT_PERCENT=0`, `APPEND_PERCENT=0`, `DELETE_PERCENT=0`, `SEED=20260604`.

Reports:

- log: `/tmp/raftkv-test-reports/release-read-log-20260605-150728/benchmark-v2`
- read_index: `/tmp/raftkv-test-reports/release-read-index-20260605-150937/benchmark-v2`

| Metric | READ_MODE=log | READ_MODE=read_index | Change |
| --- | ---: | ---: | ---: |
| throughput_ops_per_second | 14.633 | 197.767 | +1251.5% |
| latency_us_p50 | 100958 | 3872 | -96.2% |
| latency_us_p95 | 368709 | 24507 | -93.4% |
| latency_us_p99 | 732533 | 88235 | -88.0% |
| failed_operations | 0 | 0 | no change |
| retry_count | 0 | 0 | no change |
| wal_bytes delta | 402732 | 205668 | -48.9% |
| append_entries_sent delta | 1840 | 8661 | +370.7% |
| read_log_total | 506 | 0 | -100.0% |
| read_index_success | 0 | 6783 | N/A |
| read_index_timeout | 0 | 0 | no change |

Interpretation:

- In this run, `read_index` improved read throughput and latency substantially because successful reads did not need to append a log entry and wait for normal log replication.
- WAL bytes fell by 48.9%, which matches the expected direction for read-only traffic when ReadIndex avoids writing each read into the Raft log.
- `append_entries_sent` increased under `read_index`. This is expected: each ReadIndex still needs quorum confirmation, and that can increase heartbeat or AppendEntries-style RPC activity even while WAL writes fall.
- These results are from a small 2 vCPU single-machine setup and should only be used for regression and relative comparison on the same environment.

## AppendEntries Batching Comparison

Parameters: `SCENARIO=follower_down`, `THREADS=2`, `DURATION_SECONDS=20`, `WARMUP_SECONDS=3`, `KEY_COUNT=300`, `VALUE_SIZE=64`, `READ_PERCENT=0`, `PUT_PERCENT=100`, `APPEND_PERCENT=0`, `DELETE_PERCENT=0`, `SEED=20260604`.

Reports:

- batch=1: `/tmp/raftkv-test-reports/release-batch-1-20260605-151205/benchmark-v2`
- batch=64: `/tmp/raftkv-test-reports/release-batch-64-20260605-151350/benchmark-v2`

| Metric | MAX_APPEND_ENTRIES_PER_RPC=1 | MAX_APPEND_ENTRIES_PER_RPC=64 | Change |
| --- | ---: | ---: | ---: |
| throughput_ops_per_second | 9.100 | 16.550 | +81.9% |
| latency_us_p50 | 200656 | 100698 | -49.8% |
| latency_us_p95 | 427757 | 279077 | -34.8% |
| latency_us_p99 | 525197 | 389994 | -25.7% |
| failed_operations | 0 | 0 | no change |
| retry_count | 0 | 0 | no change |
| append_entries_batch_rpc_count | 1124 | 1138 | +1.2% |
| append_entries_entries_sent | 1052 | 27682 | +2531.4% |
| append_entries_empty_heartbeat_count | 72 | 111 | +54.2% |
| append_entries_max_batch_observed | 0 | 63 | N/A |
| follower_catchup_attempts | 1052 | 1027 | -2.4% |
| follower_catchup_success | 608 | 571 | -6.1% |

Interpretation:

- The write-heavy follower-down run was faster with `MAX_APPEND_ENTRIES_PER_RPC=64`, with throughput up 81.9% and tail latency lower in this specific run.
- `append_entries_max_batch_observed=63` confirms that multi-entry AppendEntries batches were actually observed in the batch=64 run.
- The total RPC count did not fall meaningfully in this benchmark window because it includes heartbeats, retries, and normal replication traffic, not only non-empty catch-up batches.
- Batching is most useful when a follower is behind and each response has non-trivial delay: more log entries can be shipped per successful round trip.

## Slow Follower Matrix

Main matrix report: `/tmp/raftkv-test-reports/release-replication-matrix-20260605-151542/replication-matrix`

Supplemental 100ms batched report: `/tmp/raftkv-test-reports/release-replication-matrix-100ms-batched-20260605-153408/replication-matrix`

The main matrix stopped at `delay=100ms,batch=1` with `last_error=follower catch-up timed out`. That row is a timeout within the default catch-up budget, not a linearizability or final-consistency correctness failure. The supplemental matrix then ran `delay=100ms,batch=8` and `delay=100ms,batch=64`; both completed with `final_consistency=true`.

Rows copied from `results.csv`; completed rows use `PASS` for the CSV value `final_consistency=true`.

| delay_ms | batch_size | workload_count | catchup_duration_ms | append_entries_batch_rpc_count | append_entries_entries_sent | append_entries_max_batch_observed | follower_catchup_attempts | follower_catchup_success | snapshot_used | final_consistency |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| 0 | 1 | 200 | 54228 | 1564 | 952 | 1 | 952 | 400 | false | PASS |
| 0 | 8 | 200 | 8395 | 798 | 3299 | 8 | 594 | 224 | false | PASS |
| 0 | 64 | 200 | 4608 | 546 | 15172 | 64 | 471 | 204 | false | PASS |
| 10 | 1 | 200 | 24074 | 886 | 641 | 1 | 641 | 400 | false | PASS |
| 10 | 8 | 200 | 3353 | 530 | 2230 | 8 | 458 | 225 | false | PASS |
| 10 | 64 | 200 | 2361 | 528 | 13780 | 64 | 453 | 204 | false | PASS |
| 50 | 1 | 200 | 24804 | 890 | 636 | 1 | 636 | 400 | false | PASS |
| 50 | 8 | 200 | 4858 | 544 | 2252 | 8 | 460 | 225 | false | PASS |
| 50 | 64 | 200 | 3875 | 514 | 13498 | 64 | 446 | 204 | false | PASS |
| 100 | 1 | 200 | N/A | N/A | N/A | N/A | N/A | N/A | N/A | TIMEOUT within default catch-up budget |
| 100 | 8 | 200 | 114257 | 2430 | 2492 | 8 | 490 | 225 | false | PASS |
| 100 | 64 | 200 | 7379 | 548 | 15536 | 64 | 472 | 204 | false | PASS |

Interpretation:

- For completed rows, larger batches reduced catch-up duration sharply at delay 0, 10, and 50 ms. For example, at 10 ms delay, catch-up duration moved from 24074 ms at batch=1 to 2361 ms at batch=64.
- At 100 ms injected follower response delay, batch=1 timed out within the default catch-up budget. Batch=8 and batch=64 both completed in the supplemental run, with batch=64 much faster than batch=8 in that run.
- This result shows batching has practical value for lagging follower catch-up under higher response delay. It does not make a production-grade network performance claim.
- The v1.0 release does not need inflight pipeline implementation as a blocking item; `max_inflight_append_entries_per_peer=1` remains documented as a prototype limitation.

## Notes

- These measurements are single-Raft-group prototype measurements from one small VM.
- They should be used to catch regressions and guide optimization tradeoffs.
- They should not be described as production-grade database performance.
- Current implementation still has `max_inflight_append_entries_per_peer=1`; inflight pipeline is not implemented.
