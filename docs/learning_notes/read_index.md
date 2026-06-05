# ReadIndex

This task added an explicit `read_index` read mode while keeping `log` as the default.

## Original Get path

`kv_client get` sends a TCP request to a server. The Leader serializes the GET as a normal client command, calls `Raft::submitCommand`, appends it to WAL and the Raft log, replicates it with AppendEntries, commits it after a majority, applies it through `KVServer::ApplyLoop`, reads in `KVStateMachine::Apply`, and returns the applied result.

This is linearizable but every read grows the log and WAL.

## ReadIndex path

With:

```yaml
read:
  mode: read_index
```

GET uses `KVServer::HandleReadIndexGet`:

1. Only the current Leader attempts ReadIndex. Followers return `NOT_LEADER` with the existing Leader hint.
2. The Leader verifies it has a committed entry in the current term.
3. The Leader sends empty AppendEntries heartbeats in the current term and waits for a majority response.
4. It records `read_index` from the committed index protected by that quorum confirmation.
5. KVServer waits until its state machine has applied at least that index.
6. It reads with `KVStateMachine::GetLocal`.

The ReadIndex request itself does not enter the Raft log, does not write WAL, and does not trigger snapshot creation.

## Safety notes

Checking only `role == LEADER` is not enough: an isolated old Leader may not yet know a newer term exists. The heartbeat quorum round confirms that a majority still accepts this node as Leader in the current term.

Waiting for KV state-machine apply is also required. Raft may have advanced an internal applied index after handing an apply message to KVServer; the direct local read must wait for KVServer's own applied index to reach the ReadIndex barrier.

This implementation does not implement Lease Read. The later Leader stability stage adds a Leader no-op barrier, so a new Leader commits an internal current-term entry before serving ReadIndex successfully. Without that barrier, ReadIndex must fail conservatively until a normal log command establishes the current-term commit point.

## Validation

```bash
bash scripts/test_read_index.sh

READ_MODE=read_index SEED=20260604 DURATION_SECONDS=60 OPERATION_COUNT=300 CLIENT_COUNT=4 \
  bash scripts/test_seeded_chaos.sh

READ_MODE=read_index SEED=20260604 CLIENT_COUNT=4 OPERATIONS_PER_CLIENT=40 KEY_COUNT=3 \
  bash scripts/test_concurrent_linearizability.sh
```

Benchmark comparison:

```bash
READ_MODE=log SCENARIO=steady READ_PERCENT=100 PUT_PERCENT=0 APPEND_PERCENT=0 DELETE_PERCENT=0 \
  bash scripts/run_benchmark_v2.sh

READ_MODE=read_index SCENARIO=steady READ_PERCENT=100 PUT_PERCENT=0 APPEND_PERCENT=0 DELETE_PERCENT=0 \
  bash scripts/run_benchmark_v2.sh
```

Compare throughput, p50/p95/p99, `wal_bytes`, `append_entries_sent`, `snapshot_created_count`, `read_log_total`, and `read_index_success`.

## Nightly Stability Fix

A nightly regression failed after restoring two followers:

```text
NOT_LEADER: not leader
FAIL: post-restore barrier put failed
```

The failure happened in the test harness, not in the ReadIndex algorithm. The script restarted the stopped followers and immediately issued a barrier `put` through the generic client server list. During that recovery window the previous Leader had already stepped down because CheckQuorum could not contact a majority, while the restored nodes had not yet converged on a stable Leader. The write therefore legitimately hit a non-Leader and returned `NOT_LEADER`.

The script now treats this as a transient routing condition:

- `discover_leader` queries all three node status endpoints and accepts only exactly one `role=LEADER`.
- `wait_for_stable_leader` waits for that Leader's no-op barrier metric, `commit_index`, `last_log_index`, and `last_applied` to show a usable current-term barrier.
- `retry_write_to_leader` sends retries with the same `client_id + request_id`, follows leader hints, refreshes Leader discovery, and falls back to other alive nodes on connection failure.
- Failure diagnostics include current step, last request, last response, discovered Leader, alive nodes, retry count, status snapshots, node log tails, and replay command.

No client CLI behavior or Raft core logic changed for this fix.
