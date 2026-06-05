# Test Profiles

This task added `scripts/verify.sh` as a thin orchestration layer for existing validation scripts.

## Why

The project had many focused test entry points, which is useful for debugging but costly to run by hand in the right order. The new verifier keeps the individual scripts as the source of truth and adds four conservative profiles:

- `fast`: after each code change.
- `stage <stage_name>`: one focused integration stage.
- `pre_push`: baseline checks before commit or push.
- `nightly`: full serial regression for overnight or release validation.

## Boundary

`verify.sh` does not reimplement cluster startup, workload generation, failure diagnostics, WAL recovery checks, Snapshot behavior, ReadIndex checks, metrics checks, or benchmark logic. It only schedules existing scripts, records timing, preserves logs, and prints a replay command.

This keeps the orchestration change outside Raft consensus logic, WAL, Snapshot, ReadIndex, Metrics, and KV business behavior.

## Stage Map

| Stage | Script |
| --- | --- |
| `snapshot` | `scripts/test_snapshot_cluster.sh` |
| `seeded_chaos` | `scripts/test_seeded_chaos.sh` |
| `linearizability` | `scripts/test_concurrent_linearizability.sh` |
| `admin_status` | `scripts/test_admin_status.sh` |
| `benchmark_smoke` | `scripts/test_benchmark_smoke.sh` |
| `read_index` | `scripts/test_read_index.sh` |
| `leader_stability` | `scripts/test_leader_stability.sh` |
| `batch_replication` | `scripts/test_batch_replication.sh` |

## Failure Handling

Each verifier run gets its own report directory under `TEST_REPORT_ROOT`, defaulting to `/tmp/raftkv-test-reports/<verify_run_id>/`. Child scripts receive that report root and a matching isolated data root, so their own reports and failure diagnostics remain grouped under the verifier run.

For every stage, `summary.txt` records:

- stage name
- status
- start time
- end time
- duration
- log file
- replay command

The verifier stops on the first failure and does not delete the data or report directories. Ctrl+C records an interrupted summary and relies on the foreground child script's existing traps to stop only the processes it started.

## Daily Use

Use `fast` after normal edits:

```bash
bash scripts/verify.sh fast
```

Use `stage` when a change touches a known feature area or when replaying a failure:

```bash
bash scripts/verify.sh stage batch_replication
```

Use `pre_push` before publishing changes. Add only the current task's relevant slow stages:

```bash
VERIFY_EXTRA_STAGES="batch_replication read_index" \
  bash scripts/verify.sh pre_push
```

Use `nightly` in a normal SSH session, preferably inside `tmux` or `screen`, because it starts several socket-listening integration clusters in sequence:

```bash
VERIFY_RUN_ID="nightly-$(date +%Y%m%d-%H%M%S)" \
  bash scripts/verify.sh nightly
```

Slow stages such as snapshot, chaos, linearizability, ReadIndex, leader stability, batch replication, admin status, and benchmark smoke do not need to be run manually after every small edit. They should be selected by changed area, pre-push risk, or scheduled regression.
