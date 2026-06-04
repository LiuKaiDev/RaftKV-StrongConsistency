# Seeded Chaos Test

This task added a reproducible three-node seeded chaos integration stage.

Key points:

- `scripts/test_seeded_chaos.sh` starts an isolated three-node cluster with generated configs, isolated data directories, and per-run ports derived from the process id unless overridden.
- The random plan is generated with Python `random.Random(SEED)`, so the same seed, operation count, client count, duration, and code revision produce the same planned operation and fault order.
- The workload includes `put`, `get`, `append`, and `delete`. Some `append` operations deliberately reuse the same `client_id + request_id` to exercise KV deduplication.
- The KV API model is shared with the linearizability checker: `put` overwrites or creates a key; `get` returns `KEY_NOT_FOUND` only when the key is absent; `append` appends to an existing value or creates an absent key from an empty initial value; `delete` removes an existing key and returns `KEY_NOT_FOUND` only when absent.
- Client requests use a retry wrapper that rebuilds the live node list, refreshes the leader, retries `NOT_LEADER`, connection failures, empty responses, timeout-like errors, and temporary unavailable responses, and writes `last_error.txt` only after an exhausted or non-retryable final failure.
- Random `get` and `delete` operations may legitimately return `KEY_NOT_FOUND`; those application results are recorded in history and do not fail the chaos run. `append` must not return `KEY_NOT_FOUND` under the current API contract. Unknown application errors, client argument errors, and exhausted transport retries still fail the run.
- Fault events currently stop the current leader, stop a follower, restart a stopped node, or briefly stop and restart one node. Long stop events are only injected while all three nodes are alive, so the workload keeps a majority available.
- The script kills only PIDs recorded in its own run directory. It does not use `pkill -f`, `killall`, root network rules, iptables, network namespaces, or disk fault injection.
- Every operation is appended to `history.jsonl`, and every fault decision is appended to `faults.jsonl`. On pass or fail, the report preserves run info, generated configs, PID files, node logs, attempt logs, dumps, history, faults, and a replay command.
- `scripts/check_chaos_history.py` performs a basic consistency check: JSONL parsing, required fields, duplicate successful append dedup behavior, final three-node dump equality, post-recovery write/read evidence, expected final state from successful sequential operations, and unexplained final keys.
- This is not a formal linearizability checker. The workload is sequential from the script's perspective, and the checker validates a basic history model and final convergence, not every possible concurrent real-time ordering.
- `scripts/test_all.sh` keeps this stage opt-in through `RUN_SEEDED_CHAOS=1` so default validation remains fast.

Useful commands:

```bash
SEED=20260604 DURATION_SECONDS=60 OPERATION_COUNT=300 CLIENT_COUNT=4 \
  bash scripts/test_seeded_chaos.sh

RUN_SEEDED_CHAOS=1 bash scripts/test_all.sh
```
