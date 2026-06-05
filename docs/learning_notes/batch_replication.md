# AppendEntries Batch Replication

This task made AppendEntries batching explicit and bounded. The previous Leader already sent all entries from `nextIndex[peer]` to the local tail in one RPC, so a badly lagging follower could receive an unbounded request. The new path keeps batching but limits each RPC with `raft.max_append_entries_per_rpc`.

## Replication Chain

The write path is unchanged until replication:

1. The Leader appends the command locally through `Raft::submitCommand`.
2. The entry is written to the existing WAL frame format.
3. `co_appendAentries` builds AppendEntries from `nextIndex[peer]`.
4. `getAppendLogs()` returns at most `max_append_entries_per_rpc` contiguous entries.
5. The follower checks `prevLogIndex/prevLogTerm`.
6. The follower merges entries, truncating only at the first conflict.
7. The Leader updates `matchIndex/nextIndex` from the request context on success.
8. `tryCommitLog()` advances commit when a majority has replicated current-term entries.

No WAL frame or Snapshot file format changed.

## Progress Rules

For a non-empty successful batch:

```text
last_batch_index = prevLogIndex + entries_size
matchIndex[peer] = max(matchIndex[peer], last_batch_index)
nextIndex[peer] = max(nextIndex[peer], matchIndex[peer] + 1)
```

Heartbeat success does not advance `matchIndex`; it only confirms the peer is reachable for CheckQuorum. This prevents a follower's `nextLogIndex` reply from making the Leader believe a log entry was replicated when no entry was sent.

Failed AppendEntries responses can only move `nextIndex` backward, never below `snapshot_index + 1` or already confirmed `matchIndex + 1`. Old responses that cannot safely update progress are ignored and counted.

## Snapshot Boundary

When `nextIndex[peer] <= snapshot_index`, the Leader uses the existing InstallSnapshot path. After snapshot installation, normal bounded AppendEntries resumes for logs after the snapshot. Internal no-op entries are ordinary log entries for replication; the `NO_OP` type is carried in protobuf and the binary marker still preserves WAL replay compatibility.

## Pipeline Audit

`max_inflight_append_entries_per_peer` is parsed and reported but currently only accepts `1`. The current replication loop sends the RPC while holding the Raft mutex, which keeps response order simple but is not a good base for safe inflight > 1. Supporting pipeline later should track per-peer request sequence numbers, ranges, and inflight bounds, then ignore or reconcile out-of-order success and failure responses without rolling back `matchIndex`.

## Metrics

- `append_entries_batch_rpc_count`: outgoing AppendEntries RPC batches, including empty heartbeat RPCs.
- `append_entries_entries_sent`: log entries sent in AppendEntries.
- `append_entries_empty_heartbeat_count`: empty heartbeat RPCs.
- `append_entries_max_batch_observed`: max non-empty batch size observed by this process.
- `follower_catchup_attempts`: non-empty AppendEntries attempts.
- `follower_catchup_success`: non-empty batches that advanced follower progress.
- `append_entries_stale_response_ignored`: old or non-advancing responses ignored.
- `append_entries_inflight_rejected`: reserved for future pipeline; should remain zero in this stage.

Metrics are process-local atomics and not persisted.

## Ordinary Catch-up Metrics Assertion

A nightly run failed in `ordinary_batch_catchup` with:

```text
FAIL: expected entries_sent delta > batch_rpc_count delta, got 59 <= 82
```

That assertion was testing the script, not the Raft algorithm. `append_entries_batch_rpc_count` counts every outgoing AppendEntries RPC, including empty heartbeats and retries, while `append_entries_entries_sent` counts only the entries carried by those RPCs. A healthy catch-up window can therefore have more total RPCs than entries even when batching is working.

The assertion now reads the before/after metrics from the same Leader node and checks:

- `batch_rpc_count_delta >= empty_heartbeat_count_delta`.
- `non_empty_batch_rpc_count_delta = batch_rpc_count_delta - empty_heartbeat_count_delta`.
- `non_empty_batch_rpc_count_delta > 0`.
- `entries_sent_delta >= non_empty_batch_rpc_count_delta`.
- `append_entries_max_batch_observed > 1`.
- `follower_catchup_attempts_delta > 0`.
- `follower_catchup_success_delta > 0`.
- The existing final consistency dump still passes before metrics are asserted.

`append_entries_max_batch_observed > 1` is the main evidence that at least one AppendEntries RPC carried multiple log entries. The non-empty RPC and catch-up deltas prove the metric window actually covered follower catch-up activity.

## Validation

```bash
bash scripts/test_core.sh
bash scripts/test_batch_replication.sh
RUN_BATCH_REPLICATION=1 bash scripts/test_all.sh
```

The failover part of `test_batch_replication.sh` deliberately treats `NOT_LEADER` as a transient routing signal. After stopping the old Leader it waits for the old process and client port to become unavailable, discovers the single current Leader from per-node `status`, waits for the new Leader no-op barrier to commit, then sends post-failover writes to the discovered Leader. If a request still hits an outdated follower or a restarting old Leader, the script records the attempt, refreshes Leader discovery, and retries until the bounded timeout.

Failure diagnostics are saved under the batch replication report directory: `request_trace.log`, `diagnostics/failure_context.txt`, `diagnostics/status_of_each_node.txt`, and per-node log tails.

Benchmark comparison:

```bash
MAX_APPEND_ENTRIES_PER_RPC=1 SCENARIO=steady THREADS=2 \
  READ_PERCENT=0 PUT_PERCENT=100 APPEND_PERCENT=0 DELETE_PERCENT=0 \
  bash scripts/run_benchmark_v2.sh

MAX_APPEND_ENTRIES_PER_RPC=64 SCENARIO=steady THREADS=2 \
  READ_PERCENT=0 PUT_PERCENT=100 APPEND_PERCENT=0 DELETE_PERCENT=0 \
  bash scripts/run_benchmark_v2.sh
```

Compare throughput, p50/p95/p99, `append_entries_batch_rpc_count`, `append_entries_entries_sent`, and `append_entries_max_batch_observed`.

## Limits

This does not implement inflight pipeline, high-RTT network simulation, packet loss, or asymmetric partitions. The integration test uses process stop/restart to create lagging followers.
