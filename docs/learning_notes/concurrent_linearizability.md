# Concurrent Linearizability

This task added an opt-in concurrent client validation stage for the three-node RaftKV prototype.

## What changed

- `scripts/test_concurrent_linearizability.sh` starts a fresh three-node cluster and multiple background worker processes.
- Each worker uses its own `client_id`, monotonically increasing `request_id`, and a deterministic RNG derived from the run seed.
- Workers issue random `put`, `get`, `append`, and `delete` requests against a small key set. Transient infrastructure errors are retried with the same `client_id + request_id` and the same operation parameters.
- The script records `history.jsonl` with invocation and completion timestamps from a monotonic high-resolution clock, final response classification, application status, response value, retry count, and worker/request identity.
- During the workload the script stops one follower, restores it, stops the current leader, waits for reelection, restores the stopped leader, then verifies final local dumps converge.
- `scripts/check_linearizability.py` checks the recorded history per key against a single-key KV model and real-time ordering constraints.
- `scripts/test_all.sh` keeps this stage opt-in through `RUN_LINEARIZABILITY=1`.

## Checker model

- `Put` overwrites or creates the key and must return `OK`.
- `Get` returns the current value, or `KEY_NOT_FOUND` only when the key is absent.
- `Append` appends to an existing value and returns the new value. If the key is absent, it treats the old value as an empty string, creates the key, and returns the appended value.
- `Delete` removes an existing key and returns `OK`, or returns `KEY_NOT_FOUND` only when the key is absent.
- Replayed records with the same `client_id + request_id` must have identical operation parameters and final results.

## Search strategy

- Histories are split by key because the model has no multi-key operation.
- If operation A completes before operation B starts, A is required to appear before B in any candidate serial order.
- Overlapping operations are explored through backtracking.
- The search memoizes `(completed_mask, model_state)` states and checks independent quiescent components in order.
- The checker returns `INCONCLUSIVE` instead of `PASS` when the timeout expires or a key exceeds the configured record limit.

## Result classification

The checker now separates safety, liveness, infrastructure, timeout, and pass outcomes:

- `PASS`: every checked operation has a definitive result and the bounded search found a legal linearization.
- `LINEARIZABILITY_SAFETY_FAIL`: a definitive completed history has no legal linearization, or duplicate `client_id + request_id` records disagree.
- `WORKLOAD_LIVENESS_FAIL`: at least one operation exhausted the retry window with only retriable infrastructure errors, while the completed prefix before the first uncertain operation is linearizable.
- `INFRASTRUCTURE_FAIL`: the history or checker run hit a fatal infrastructure error rather than a KV semantic contradiction.
- `INCONCLUSIVE`: the checker timed out or hit the configured per-key record limit.

When an operation ends with `RETRIABLE_INFRASTRUCTURE_ERROR`, the checker must not pretend that operation has a KV result. It also must not simply drop the uncertain operation and declare the rest of the history safe: an uncertain write may have committed and affected later reads. For workload liveness failures, the checker therefore runs the safety search only on definitive operations that completed before the first uncertain operation began, then reports the uncertain operation and attempt timeline separately.

## Failure diagnostics

- On non-`PASS`, the checker writes `linearizability_failure.json` and `linearizability_failure.txt`.
- The diagnostic includes the failing key, normalized per-key history, real-time order edges, the search frontier where all candidates were lost, model state at that frontier, remaining candidate operations, and a per-candidate reason.
- Workload liveness diagnostics include `completed_history_linearizable`, incomplete operation count, retriable error count, exhausted retry count, failed sequence, client/request identity, last error, attempt timeline, and fault timeline.
- The legacy `linearizability_failure.jsonl` file now contains a minimized failure fragment when the checker can identify one.
- `normalized_history.jsonl` can be saved by the test script with `SAVE_NORMALIZED_HISTORY=1`.

## Layered reproduction

`scripts/test_concurrent_linearizability.sh` supports `FAULT_MODE`:

- `none`: run only concurrent clients.
- `follower_restart`: restart one follower during the workload.
- `leader_restart`: stop the current leader during the workload, wait for a new leader, then restart the old leader.
- `full`: run both follower and leader restart faults.

The checker timeout can be configured with `CHECKER_TIMEOUT_SECONDS`.

Each worker retries transient errors within a bounded operation window, defaulting to:

```bash
OPERATION_RETRY_TIMEOUT_SECONDS=10
OPERATION_RETRY_INTERVAL_MS=100
```

Retries keep the same `client_id`, `request_id`, operation, key, and value. Leader hints are followed only after the hinted node's `status` confirms `role=LEADER`; otherwise the worker polls reachable status endpoints and sends to the unique discovered Leader, or to all reachable nodes when no unique Leader is visible. This keeps the workload concurrent through fault windows without retrying forever or trusting stale hints.

Failure reports include `status_on_failure.txt`, per-node log tails, `client_attempts.log`, `faults.jsonl`, and recovery status snapshots after follower and Leader restarts when those phases run.

## Nightly liveness diagnosis

A nightly run failed at sequence 52:

```text
operation=GET key=k3
client_id=linear_worker_3_23260613
request_id=15
result_class=RETRIABLE_INFRASTRUCTURE_ERROR
```

The operation retried 30 times under the old fixed-attempt budget. Attempts 1-7 returned `not leader` with leader hint `2 127.0.0.1:30362`, attempts 9-24 hit `empty response from 127.0.0.1:30363`, and the final attempts returned `NOT_LEADER`. The fault timeline had stopped and restarted a follower, then stopped and restarted the original Leader. Node logs showed node2 later stepped down after CheckQuorum lost majority, while node3 could only pre-vote as a single node. That is a workload availability/liveness failure under the injected fault window, not proof of a KV safety violation.

## Current diagnostic result

The captured failure for run `linearizability-debug-20260604-171054` fails on key `k1`.

The minimal fragment is:

1. `seq=5`, worker 3, `append k1 w3_r2_7588`, returns `SUCCESS/OK` with `w3_r2_7588`.
2. `seq=6`, worker 1, `get k1`, returns `SUCCESS/OK` with `w3_r2_7588`.

Before this fragment, completed `k1` operations only observed `KEY_NOT_FOUND`, so the old checker model state was `ABSENT`. The server state-machine code appends through `kv_[key].append(value)`, which creates the key when absent. The checker now treats that behavior as the formal API contract, so the fragment is legal under the corrected model.

## Limits

This is a bounded checker for concrete test histories. Passing the checker means the recorded execution has at least one legal linearization under the modeled operations; it is not a formal proof that all possible RaftKV executions are linearizable.
