# Slow Follower Replication Matrix

This task added a reproducible validation layer for slow followers, delayed snapshot installation, and lagging follower catch-up.

## Test-Only Delay Injection

Two environment variables are recognized by `kv_server`:

- `CRAFTKV_TEST_APPEND_ENTRIES_DELAY_MS`
- `CRAFTKV_TEST_INSTALL_SNAPSHOT_DELAY_MS`

Both default to `0`. Invalid values are logged as warnings and treated as `0`. The values are read from the process environment, so only nodes explicitly started with the variable are delayed.

The delay is injected at the follower-side RPC service handler entry, before taking the Raft mutex:

- `RpcServiceImpl::appendEntries`
- `RpcServiceImpl::installSnapshot`

This simulates a slow follower RPC response without changing the Raft RPC schema, WAL frame format, Snapshot file format, or normal production configuration.

## Why Not Global Network Rules

The tests run multiple nodes on the same host. Global `tc qdisc` or `iptables` rules can affect unrelated services, other tests, and even the test controller itself. The scripts avoid `pkill` and `killall` for the same reason: cleanup must target only PIDs created by the current run.

## Slow Follower Test

`scripts/test_slow_follower.sh` covers four cases:

1. One delayed follower while the leader and the other follower remain normal. The cluster must still commit writes and the leader must not step down just because one follower is slow.
2. Batch size comparison for `max_append_entries_per_rpc=1`, `8`, and `64` under the same append delay and workload.
3. Snapshot boundary catch-up: stop a follower, generate enough log entries for snapshotting, restart it with `CRAFTKV_TEST_INSTALL_SNAPSHOT_DELAY_MS`, then verify InstallSnapshot and subsequent AppendEntries catch-up.
4. Leader switch during catch-up: restart a lagging delayed follower, stop the current leader during catch-up, elect a new leader, restart the old leader, and verify final consistency.

The script stores status, metrics delta, configs, node logs, dumps, faults, and replay context under:

```text
/tmp/raftkv-test-reports/<run_id>/slow-follower/
```

## Replication Matrix

`scripts/run_replication_matrix.sh` is a measurement-oriented runner. Defaults:

```bash
DELAY_MS_LIST="${DELAY_MS_LIST:-0 10 50 100}"
BATCH_SIZE_LIST="${BATCH_SIZE_LIST:-1 8 64}"
WORKLOAD_COUNT="${WORKLOAD_COUNT:-200}"
```

For each delay and batch size pair, it creates an isolated three-node cluster, stops one follower, writes a backlog, restarts that follower with AppendEntries delay, measures catch-up duration, checks final consistency, and records metrics deltas.

The output includes:

- `summary.txt`
- `results.csv`
- `results.md`
- `config.txt`
- `faults.jsonl`
- `replay_command.txt`
- per-group `status_before.txt`
- per-group `status_after.txt`
- per-group `metrics_delta.txt`
- per-group node logs

The key comparison fields are `catchup_duration_ms`, `append_entries_batch_rpc_count`, `append_entries_entries_sent`, `append_entries_max_batch_observed`, `follower_catchup_attempts`, and `follower_catchup_success`.

## Pipeline Decision Boundary

The current implementation still has `max_inflight_append_entries_per_peer=1`; inflight pipeline is intentionally not implemented in this stage.

The matrix gives enough data to decide whether batching alone is sufficient for the expected RTT range or whether pipelining is worth the added correctness risk. Pipeline work would need separate handling for request sequence numbers, overlapping ranges, stale responses, and monotonic `matchIndex` updates.

## Limits

This stage does not cover packet loss, packet reordering, asymmetric network partitions, bandwidth limits, disk latency injection, cross-machine RTT, dynamic membership, sharding, or multi-Raft behavior.
