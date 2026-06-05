# v1.0 Release Evidence

Generated at: 2026-06-05T14:41:57+0800

Git commit: `8a999364575300d07812cdadfe900f07c9d07cb1`

Report root: `/tmp/raftkv-test-reports`

Most recent top-level report directory: `/tmp/raftkv-test-reports/nightly-20260605-142226`

Preferred completed nightly report: `/tmp/raftkv-test-reports/nightly-20260605-142226/summary.txt`

This file summarizes existing reports only. It does not run tests and does not infer PASS when no report is found.

Report source priority: latest completed nightly, latest completed single-stage verify report, latest test_all report, then other historical stage logs.

| Stage | Status | Report |
| --- | --- | --- |
| core tests | PASS | `/tmp/raftkv-test-reports/nightly-20260605-142226/logs/core.log` |
| cluster smoke | PASS | `/tmp/raftkv-test-reports/nightly-20260605-142226/logs/cluster_smoke.log` |
| snapshot cluster | PASS | `/tmp/raftkv-test-reports/nightly-20260605-142226/logs/snapshot.log` |
| seeded chaos | PASS | `/tmp/raftkv-test-reports/nightly-20260605-142226/logs/seeded_chaos.log` |
| linearizability | PASS | `/tmp/raftkv-test-reports/nightly-20260605-142226/logs/linearizability.log` |
| admin status | PASS | `/tmp/raftkv-test-reports/nightly-20260605-142226/logs/admin_status.log` |
| benchmark smoke | PASS | `/tmp/raftkv-test-reports/nightly-20260605-142226/logs/benchmark_smoke.log` |
| read index | PASS | `/tmp/raftkv-test-reports/nightly-20260605-142226/logs/read_index.log` |
| leader stability | PASS | `/tmp/raftkv-test-reports/nightly-20260605-142226/logs/leader_stability.log` |
| batch replication | PASS | `/tmp/raftkv-test-reports/nightly-20260605-142226/logs/batch_replication.log` |
| slow follower | PASS | `/tmp/raftkv-test-reports/nightly-20260605-142226/logs/slow_follower.log` |
| nightly | PASS | `/tmp/raftkv-test-reports/nightly-20260605-142226/summary.txt` |

## Notes

- `NOT RUN` means no existing report was found, or every higher-priority source marked the stage as skipped and no lower-priority stage report exists.
- `UNKNOWN` means a report exists, but the script did not find a clear PASS/FAIL marker, or a stale nightly summary has no finish marker.
- `RUNNING` means the latest nightly summary has no finish marker and is still fresh enough to plausibly be in progress.
- Regenerate after running validation:

```bash
bash scripts/collect_release_evidence.sh
```
