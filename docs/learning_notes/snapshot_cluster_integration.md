# Snapshot Cluster Integration Test

This task added a deterministic three-node Snapshot integration script.

Key points:

- A follower is stopped before enough writes are committed to force the leader to create and compact a Snapshot.
- The restarted follower must recover through InstallSnapshot, not ordinary log replay; the script records leader and follower logs that mention InstallSnapshot and Snapshot file transfer.
- The script keeps test data, generated configs, PID files, node logs, dumps, and reports under isolated `TEST_DATA_ROOT` and `TEST_REPORT_ROOT` paths.
- InstallSnapshot file reception now writes the official Snapshot only after the complete stream is received and atomically persisted.
- `CRAFTKV_TEST_ABORT_SNAPSHOT_INSTALL_AFTER_CHUNKS` is a default-off test injection hook used by the integration script to simulate an interrupted install before the official Snapshot file is replaced.
- The test is opt-in for `scripts/test_all.sh` through `RUN_SNAPSHOT_CLUSTER=1` so normal core and smoke validation stays fast.
- The cluster script now treats node stop/start as state transitions with explicit evidence: stop waits for process exit and raft/client port closure, while start waits for process liveness, client port readiness, and a fresh `KV client API listening` log line.
- During follower-down phases, workload and leader queries use only the two live client ports. Temporary connection or leader-query failures are retried, but timeout without a live leader, missing Snapshot evidence, missing abort evidence, process crash, or stuck ports still fails the run and writes `last_error.txt`.
- Client operations now go through one retry wrapper so `NOT_LEADER`, temporary connect failures, empty responses, and timeout-like errors are treated as retryable during leader changes and follower restarts. The wrapper refreshes the leader hint between attempts, logs attempts to `client_attempts.log`, and writes `last_error.txt` only after a final timeout or non-retryable failure.
- Retried mutating commands use a stable `client_id + request_id` for the logical operation, so a request that committed but lost its response is retried through the KV dedup path instead of applying an append/delete twice.
- Bash status capture matters for retry correctness: after `if out="$(cmd)"; then ... fi`, `$?` outside the `if` can describe the compound `if`, not the failed command. Capture the command status in the `else` branch. The script also validates stdout for expected success shapes so exit status alone cannot mark `request failed`, `NOT_LEADER`, or an empty response as success.
- `kv_client` now preserves a non-empty `not leader` error with leader hint when retries are exhausted after follower responses, making CLI failures diagnosable without changing service-side Raft behavior.
