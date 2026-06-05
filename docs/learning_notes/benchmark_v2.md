# Benchmark v2

This task added a reproducible performance-baseline stage before ReadIndex. It now also records `read_mode` so the same benchmark harness can compare the original log-read baseline with ReadIndex mode.

## What changed

- `client/kv_bench.cc` is a persistent C++ benchmark client.
- `client/kv_bench_lib.*` contains operation mix validation, deterministic operation selection, latency summaries, and JSON/CSV formatting.
- `scripts/run_benchmark_v2.sh` starts an isolated three-node cluster, captures Admin Status before and after, runs `kv_bench`, records metrics deltas, and saves a report directory. `READ_MODE=log|read_index` controls generated node configs.
- `scripts/test_benchmark_smoke.sh` runs a short benchmark and validates JSON, CSV, throughput, success count, and percentile ordering.
- `scripts/test_all.sh` exposes the smoke test through `RUN_BENCHMARK_SMOKE=1`.

## Client model

`kv_bench` starts multiple worker threads inside one process. Each worker has its own RNG, `client_id`, request sequence, and client object. A retry keeps the same `client_id + request_id`, operation type, key, and value. This preserves the deduplication contract while allowing leader redirection and transient connection failures.

The server TCP API currently closes a connection after each request, so `kv_bench` cannot keep one OS socket open across requests without changing server behavior. It still avoids shell/process startup overhead by keeping the benchmark process and worker state resident, reconnecting from worker code as needed.

## Metrics and reports

The benchmark reports read mode, throughput, success/failure counts, retry count, min/avg/p50/p95/p99/max latency, and per-operation summaries for get/put/append/delete. `status_before.txt` and `status_after.txt` use the existing Admin Status path. `metrics_delta.txt` sums selected node metrics across the cluster.

Metrics deltas include preload and warmup traffic because they measure actual server work between status snapshots. JSON/CSV latency and throughput include only the formal measurement window after warmup.

## Scenarios

- `steady`: no injected fault.
- `follower_down`: stops one follower during the measurement window.
- `leader_failover`: stops the current leader during the measurement window and records the new leader event.

Fault events are written to `faults.jsonl`. Only PIDs started by the current script run are stopped.

## Limits

`READ_MODE=log` is the original baseline where reads enter the Raft log. `READ_MODE=read_index` is the ReadIndex comparison mode. Results from a small single VM are useful for regression and learning, not production performance claims.
