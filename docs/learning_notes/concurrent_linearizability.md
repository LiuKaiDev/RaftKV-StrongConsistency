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

## Failure diagnostics

- On `FAIL`, the checker now writes `linearizability_failure.json` and `linearizability_failure.txt`.
- The diagnostic includes the failing key, normalized per-key history, real-time order edges, the search frontier where all candidates were lost, model state at that frontier, remaining candidate operations, and a per-candidate reason.
- The legacy `linearizability_failure.jsonl` file now contains a minimized failure fragment when the checker can identify one.
- `normalized_history.jsonl` can be saved by the test script with `SAVE_NORMALIZED_HISTORY=1`.

## Layered reproduction

`scripts/test_concurrent_linearizability.sh` supports `FAULT_MODE`:

- `none`: run only concurrent clients.
- `follower_restart`: restart one follower during the workload.
- `leader_restart`: stop the current leader during the workload, wait for a new leader, then restart the old leader.
- `full`: run both follower and leader restart faults.

The checker timeout can be configured with `CHECKER_TIMEOUT_SECONDS`.

## Current diagnostic result

The captured failure for run `linearizability-debug-20260604-171054` fails on key `k1`.

The minimal fragment is:

1. `seq=5`, worker 3, `append k1 w3_r2_7588`, returns `SUCCESS/OK` with `w3_r2_7588`.
2. `seq=6`, worker 1, `get k1`, returns `SUCCESS/OK` with `w3_r2_7588`.

Before this fragment, completed `k1` operations only observed `KEY_NOT_FOUND`, so the old checker model state was `ABSENT`. The server state-machine code appends through `kv_[key].append(value)`, which creates the key when absent. The checker now treats that behavior as the formal API contract, so the fragment is legal under the corrected model.

## Limits

This is a bounded checker for concrete test histories. Passing the checker means the recorded execution has at least one legal linearization under the modeled operations; it is not a formal proof that all possible RaftKV executions are linearizable.
