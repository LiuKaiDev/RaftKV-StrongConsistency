# Release Hardening

## Stop Adding Features

At v1.0, the project already demonstrates the important single-Raft-group storage behaviors: election, replication, persistence, snapshotting, read optimization, observability, chaos validation, linearizability checks, benchmark tooling, and slow follower measurement.

Continuing to add features would make the prototype harder to explain and harder to verify. The better engineering move is to freeze the scope, document the boundaries, and make the existing behavior reproducible.

## Evidence Over Feature Count

For a storage system, a feature list is not enough. Reviewers need evidence that committed entries survive restart, uncommitted entries are not applied, dedup survives snapshot recovery, and slow or lagging followers do not break majority progress.

Validation evidence is what turns the project from "implemented code" into an auditable engineering artifact.

## Do Not Fake Benchmarks

Benchmark numbers are only useful when they come from a real command, a real commit, a real machine, and preserved reports. Estimated numbers create false confidence and make later regressions impossible to reason about.

The performance report is therefore a template until ordinary SSH runs generate actual data.

## Why GitHub Actions Runs Fast Only

GitHub-hosted runners do not necessarily have the full gRPC, libgo, Protobuf, and server runtime environment used by the Raft cluster tests. Fast CI should catch whitespace problems and core correctness regressions without pretending to validate the full distributed system.

The full three-node validation remains in normal Linux/SSH where sockets, ports, process cleanup, and reports are controlled.

## Nightly Belongs In SSH

Nightly starts multiple three-node clusters, injects process failures, runs chaos and linearizability checks, and preserves reports. A normal SSH session inside `tmux` or `screen` is a better fit than a constrained CI runner.

## v1.0 Boundary

RaftKV v1.0 is not production storage. It has no dynamic membership, sharding, Multi-Raft, transactions, MVCC, Lease Read, authentication, Kubernetes deployment, or production operations system.

The value of v1.0 is that one focused Raft group can be built, tested, recovered, observed, benchmarked, and explained end to end.
