# Optimization Baseline

This document records the Batch 1 baseline. It must not contain invented benchmark or performance data.

## Git Commit

- Commit: `21e82190890fa4b2d25fb6832a0b3a0e2dac9513`
- Branch checked before changes: `codex/raft-hardening`
- Initial working tree: clean

## Environment

- OS: `Linux iZ2ze56tozb0iaxhkz9lzqZ 5.10.134-18.al8.x86_64 #1 SMP Fri Dec 13 16:56:53 CST 2024 x86_64 x86_64 x86_64 GNU/Linux`
- Compiler: `c++ (GCC) 10.2.1 20200825 (Alibaba 10.2.1-3.9 2.32)`
- Full Raft dependency prefix: `/opt/grpc`
- Full Raft dependency environment:

```bash
export CMAKE_PREFIX_PATH="/opt/grpc${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export PATH="/opt/grpc/bin:$PATH"
export LD_LIBRARY_PATH="/opt/grpc/lib:/opt/grpc/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

- Cold full builds should use single-threaded compilation by default because this server has limited memory.

## Existing Script Risk Review

Existing cluster scripts are useful for manual local development but are not safe enough for isolated baseline testing:

- `scripts/start_cluster.sh` writes runtime files under the repository: `data/`, `logs/`, and `run/`.
- `scripts/restart_node.sh` writes repository logs and pid files, and can terminate a process referenced by an existing repository pid file.
- `scripts/kill_leader.sh` terminates the pid stored in `run/node<id>.pid`.
- `scripts/stop_cluster.sh` terminates all pids found in repository `run/node*.pid`.
- `scripts/chaos_test.sh` calls the above scripts and can terminate pids from repository pid files.
- `scripts/benchmark.sh` writes only a temporary latency file, but it operates against the default cluster and does not isolate data.
- `scripts/build.sh` writes build outputs under repository `build/`, `bin/`, and `lib/`.
- No reviewed existing script uses `rm -rf`, `pkill`, `killall`, or process-name bulk termination, but the repository pid-file based scripts are still not safe for this Batch because they can stop processes recorded by historical pid files.

Batch 1 uses new isolated test scripts instead of the existing cluster start/stop/fault scripts.
The isolated cluster script redirects node WAL, snapshot data, generated configs, pid files, and node runtime logs under `/root/raftkv-test-data/<run-id>`.

## Build Command

Full Raft build:

```bash
export CMAKE_PREFIX_PATH="/opt/grpc${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export PATH="/opt/grpc/bin:$PATH"
export LD_LIBRARY_PATH="/opt/grpc/lib:/opt/grpc/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cmake -S . -B build/raft -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT=ON
cmake --build build/raft -j1
```

Core tests:

```bash
bash scripts/test_core.sh
```

Cluster smoke test:

```bash
bash scripts/test_cluster_smoke.sh
```

All tests:

```bash
bash scripts/test_all.sh
```

## Unit Test Result

- Status: passed.
- Command: `bash scripts/test_core.sh`
- Result: 5 passed, 0 failed.
- Passed tests:
  - `test_kv_state_machine`
  - `test_wal`
  - `test_snapshot`
  - `test_raft_log`
  - `test_restart_replay`

## Three-Node Smoke Test Result

- Status: passed.
- Command: `bash scripts/test_cluster_smoke.sh`
- Result:
  - Three nodes started successfully.
  - Initial Leader: `node3`.
  - After terminating `node3`, new Leader: `node2`.
  - After restarting `node3`, final consistency check: PASS.

## All Test Result

- Status: passed.
- Command: `bash scripts/test_all.sh`
- Result:
  - `core tests: PASS`
  - `cluster smoke: PASS`
  - `ALL TESTS PASSED`
- Summary file: `/root/raftkv-test-reports/all-20260603-163310-567349/summary.txt`

## Known Limitations

- Core tests cover storage, command encoding, snapshot serialization, state machine behavior, and simple replay, but not full Raft timing or network behavior.
- Three-node smoke testing is functional, not exhaustive.
- Existing full-cluster scripts are not isolated from repository runtime directories.
- No performance benchmark is recorded in this baseline.

## Tests Not Yet Completed

- Long-running chaos regression.
- Crash during WAL append or snapshot write.
- Follower catch-up across multiple snapshot generations.
- Concurrent client load with duplicate and out-of-order request ids.
- Network partition simulation.

## Recommendations

- Keep isolated test data under `/root/raftkv-test-data`.
- Keep reports under `/root/raftkv-test-reports`.
- Add regression tests before changing Raft logic.
- Do not report benchmark numbers until a benchmark is explicitly run and logged.
