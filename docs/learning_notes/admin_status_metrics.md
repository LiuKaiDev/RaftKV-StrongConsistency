# Admin Status Metrics

This task added a read-only Admin Status surface and low-cost core metrics for the single-Raft-group prototype.

## What changed

- `GetNodeStatus` was added to the existing Raft gRPC service.
- `kv_client status` was added to query one node through the existing TCP client API.
- `scripts/show_cluster_status.sh` prints a three-node status table and marks unavailable nodes without failing the whole command.
- `scripts/test_admin_status.sh` exercises election, status reads, failover, restart catch-up, snapshot progress, WAL byte visibility, and unavailable-node display.
- `scripts/test_all.sh` can include the integration test with `RUN_ADMIN_STATUS=1`.

## Status snapshot

`Raft::getStatusSnapshot()` constructs a single `RaftStatusSnapshot` under the existing Raft mutex, then releases the lock before serialization. The snapshot copies scalar fields only and does not expose internal containers.

Field sources:

- `node_id`: current node's configured external peer id.
- `role`: current `m_state_`, converted to `FOLLOWER`, `CANDIDATE`, or `LEADER`.
- `current_term`: `m_current_term_`.
- `leader_id`: `m_leaderId_` mapped through configured external peer ids.
- `commit_index`: `m_commitIndex_`.
- `last_applied`: `m_lastApplied_`.
- `last_log_index`: `getLastLogIndex()`.
- `snapshot_index`: `m_snapShotIndex`.
- `snapshot_term`: `m_snapShotTerm`.
- `log_entry_count`: `m_logs_.size() - 1`, excluding the sentinel entry.
- `wal_bytes`: current WAL log file size from the persister.

## Metrics

Metrics are atomics and are not persisted. Restarting a node resets them to zero.

- Election metrics are incremented when a node starts an election and when it becomes leader.
- AppendEntries metrics are incremented after each attempted outgoing RPC and classified by RPC status plus reply success.
- RequestVote metrics are incremented after each attempted outgoing RPC and classified by vote grant or rejection/RPC failure.
- InstallSnapshot metrics are incremented after each outgoing metadata RPC and classified by whether the follower allows file transfer.
- Snapshot creation increments only after local snapshot creation succeeds.
- WAL recovery truncated-tail count is read from the WAL instance after crash recovery repairs a truncated or corrupted tail.
- Client request metrics count only Put/Get/Append/Delete through the TCP API, not status, leader, or dump commands.

## Safety

Status and metrics are observability-only. They do not enter the Raft log, do not trigger replication, and do not change command application order. The status RPC serializes a copied snapshot, avoiding long lock holds during protobuf or key=value formatting.

## Limits

This is not a complete monitoring system. Metrics are process-local, reset on restart, and do not include histograms, labels, scrape endpoints, or persistence. That is intentional for this prototype stage: the goal is stable data for benchmark setup, ReadIndex work, and fault diagnosis without introducing Prometheus or an HTTP server.
