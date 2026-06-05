# v1.0 Release Evidence

Generated at: 2026-06-05T11:13:32+0800

Git commit: `618dfa8d4280b3e2c5e24bb0d2ee01ec9158ab32`

Report root: `/tmp/raftkv-test-reports`

Most recent top-level report directory: `/tmp/raftkv-test-reports/verify-fast-20260605-111316-2`

This file summarizes existing reports only. It does not run tests and does not infer PASS when no report is found.

| Stage | Status | Report |
| --- | --- | --- |
| core tests | PASS | `/tmp/raftkv-test-reports/verify-fast-20260605-111316-2/logs/core.log` |
| cluster smoke | PASS | `/tmp/raftkv-test-reports/all-20260605-095027-1695296/test_cluster_smoke.log` |
| snapshot cluster | PASS | `/tmp/raftkv-test-reports/all-20260604-221150-1245604/test_snapshot_cluster.log` |
| seeded chaos | NOT RUN | `/tmp/raftkv-test-reports/all-20260605-095027-1695296/summary.txt` |
| linearizability | PASS | `/tmp/raftkv-test-reports/all-20260604-184222-1046607/test_concurrent_linearizability.log` |
| admin status | UNKNOWN | `/tmp/raftkv-test-reports/all-20260604-222126-1270210/test_admin_status.log` |
| benchmark smoke | PASS | `/tmp/raftkv-test-reports/all-20260604-222215-1274053/test_benchmark_smoke.log` |
| read index | FAIL | `/tmp/raftkv-test-reports/all-20260604-222114-1269551/test_read_index.log` |
| leader stability | PASS | `/tmp/raftkv-test-reports/all-20260604-222049-1268599/test_leader_stability.log` |
| batch replication | PASS | `/tmp/raftkv-test-reports/all-20260605-095027-1695296/test_batch_replication.log` |
| slow follower | NOT RUN | `/tmp/raftkv-test-reports/all-20260605-095027-1695296/summary.txt` |
| nightly | NOT RUN | `-` |

## Notes

- `NOT RUN` means no existing report was found or the latest batch summary marked the stage as skipped.
- `UNKNOWN` means a report exists, but the script did not find a clear PASS/FAIL marker.
- Regenerate after running validation:

```bash
bash scripts/collect_release_evidence.sh
```
