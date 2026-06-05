# Leader Stability

This task added Leader no-op barrier, PreVote, and CheckQuorum for the single-Raft-group KV prototype.

## Leader no-op barrier

When a node becomes Leader, `Raft::changeToState(LEADER)` initializes replication state, marks the local node as Leader, appends an internal no-op with `appendLeaderNoop()`, writes it through the existing WAL append path, and resets the AppendEntries timer for immediate replication.

The no-op is not a client command. It is marked as `LogEntry::NO_OP` in protobuf traffic and uses a binary internal command marker for WAL replay compatibility. WAL frame format remains unchanged: the WAL still stores index, term, and command bytes.

Apply safety is handled in `KVServer::ApplyLoop`: internal no-op entries only advance the KV layer applied index and notify waiters. They do not call `KVStateMachine::Apply`, do not modify the dedup table, and do not create a client response. This gives ReadIndex a current-term committed entry even when no business write has happened after election.

## PreVote

On election timeout, `startElection()` first runs `startPreVote()` when `raft.pre_vote` is enabled. PreVote sends `preVoteRPC` with `current_term + 1` and the candidate's last log term/index. Receivers apply the same up-to-date log rule as RequestVote, but they do not update `current_term`, do not change `voted_for`, and do not persist Raft meta.

Only after a majority PreVote grant does the node enter the normal Candidate path, bump term, vote for itself, persist meta, and send RequestVote. Before that formal transition, the node rechecks recent valid Leader contact under the Raft mutex so a heartbeat received during the PreVote round can still suppress the election.

## CheckQuorum

When `raft.check_quorum` is enabled, a Leader records successful AppendEntries/heartbeat replies in `m_lastPeerContact_` using `steady_clock`. Each heartbeat tick checks whether self plus recently contacted peers form a majority inside the election-timeout window. If not, the Leader increments CheckQuorum metrics, steps down to Follower, clears its leader hint, and resets the election timer.

This is not Lease Read. ReadIndex still performs an explicit majority heartbeat confirmation for each read barrier.

## Configuration

The new options are under `raft:`:

```yaml
raft:
  pre_vote: true
  check_quorum: true
```

Both default to `false` when omitted, preserving old configs. Invalid boolean values are rejected during config loading.

## Metrics

- `leader_noop_appended`: internal no-op entries appended by this node after becoming Leader.
- `leader_noop_committed`: internal no-op entries committed by this node.
- `pre_vote_sent`: outgoing PreVote RPC attempts.
- `pre_vote_granted`: granted PreVote replies.
- `pre_vote_rejected`: rejected PreVote replies or failed PreVote RPCs.
- `check_quorum_stepdown_count`: Leader stepdowns caused by missing recent majority contact.
- `check_quorum_rounds`: CheckQuorum evaluation rounds.
- `check_quorum_success`: CheckQuorum rounds with recent majority contact.
- `check_quorum_failed`: CheckQuorum rounds without recent majority contact.

Metrics are atomic, process-local, and not persisted.

## Validation

Core validation:

```bash
bash scripts/test_core.sh
```

Three-node integration:

```bash
bash scripts/test_leader_stability.sh
```

Optional batch entry:

```bash
RUN_LEADER_STABILITY=1 bash scripts/test_all.sh
```

The integration script verifies no-op barrier before business writes, ReadIndex immediately after Leader failover, PreVote term stability in a stop/restart scenario, and CheckQuorum behavior after stopping two followers.

## Limits

The test script uses process stop/restart, not real packet loss or asymmetric partitions. The project still does not implement Lease Read, inflight replication, dynamic membership, sharding, Multi-Raft, MVCC, or transactions.
