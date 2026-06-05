# Architecture

RaftKV v1.0 is a fixed three-node, single-Raft-group KV prototype. The diagrams below are intentionally implementation-level enough for review, but avoid low-level source detail.

## Three-Node Architecture

```mermaid
flowchart TB
  C["kv_client<br/>Put/Get/Append/Delete/status"] --> A["Any node client port"]

  subgraph G["Single Raft Group"]
    N1["node1<br/>KVServer + Raft"]
    N2["node2<br/>KVServer + Raft"]
    N3["node3<br/>KVServer + Raft"]
  end

  A --> N1
  A --> N2
  A --> N3

  N1 <-->|RequestVote<br/>AppendEntries<br/>InstallSnapshot| N2
  N2 <-->|RequestVote<br/>AppendEntries<br/>InstallSnapshot| N3
  N1 <-->|RequestVote<br/>AppendEntries<br/>InstallSnapshot| N3

  N1 --> P1["WAL<br/>Snapshot"]
  N2 --> P2["WAL<br/>Snapshot"]
  N3 --> P3["WAL<br/>Snapshot"]
```

## Write Request

```mermaid
sequenceDiagram
  autonumber
  participant C as Client
  participant K as KVServer
  participant L as Raft Leader
  participant W as WAL
  participant F as Followers
  participant A as Apply Loop
  participant S as KV State Machine

  C->>K: Put/Append/Delete
  alt Request reaches follower
    K-->>C: NOT_LEADER + leader hint
    C->>K: Retry leader
  end
  K->>L: submitCommand(command)
  L->>W: append entry + persist metadata
  L->>F: AppendEntries
  F-->>L: majority replicated
  L->>L: advance commit_index
  L->>A: notify committed entry
  A->>S: apply in log-index order
  S-->>A: command result
  A-->>K: wake pending request
  K-->>C: OK/result
```

## Log Read

```mermaid
sequenceDiagram
  autonumber
  participant C as Client
  participant K as KVServer
  participant L as Raft Leader
  participant F as Followers
  participant A as Apply Loop
  participant S as KV State Machine

  C->>K: Get(key)
  alt Request reaches follower
    K-->>C: NOT_LEADER + leader hint
    C->>K: Retry leader
  end
  K->>L: submitCommand(Get)
  L->>F: AppendEntries for read log entry
  F-->>L: majority replicated
  L->>A: committed Get entry
  A->>S: apply/read key
  S-->>A: value or KEY_NOT_FOUND
  A-->>K: result
  K-->>C: result
```

## ReadIndex

```mermaid
sequenceDiagram
  autonumber
  participant C as Client
  participant K as KVServer
  participant L as Raft Leader
  participant F as Followers
  participant S as KV State Machine

  C->>K: Get(key)
  alt Request reaches follower
    K-->>C: NOT_LEADER + leader hint
    C->>K: Retry leader
  end
  K->>L: readIndex()
  L->>L: require current-term commit barrier
  L->>F: quorum heartbeat confirmation
  F-->>L: majority confirms current leadership
  L->>L: read_index = commit_index
  L->>L: wait last_applied >= read_index
  L->>S: local Get(key)
  S-->>K: value or KEY_NOT_FOUND
  K-->>C: result
```

## WAL + Snapshot Restart Recovery

```mermaid
flowchart TD
  Start["Process start"] --> LoadSnap["Load snapshot metadata and snapshot.dat"]
  LoadSnap --> RestoreSM["Restore KV data and dedup table"]
  RestoreSM --> LoadMeta["Load WAL metadata<br/>term/voted_for/commit/applied"]
  LoadMeta --> CheckMeta{"Metadata valid?"}
  CheckMeta -- no --> FailClosed["Fail closed"]
  CheckMeta -- yes --> LoadWal["Load WAL log entries"]
  LoadWal --> Tail{"Corrupted/truncated tail?"}
  Tail -- yes --> Truncate["Truncate bad tail"]
  Tail -- no --> Replay
  Truncate --> Replay["Replay committed entries after snapshot"]
  Replay --> Ready["Node ready"]
```

## Lagging Follower InstallSnapshot

```mermaid
sequenceDiagram
  autonumber
  participant L as Leader
  participant F as Lagging Follower
  participant FS as Follower Storage
  participant S as State Machine

  L->>L: nextIndex[follower] <= snapshot_index
  L->>F: InstallSnapshot metadata
  F-->>L: can receive snapshot file
  L->>F: TransferSnapshotFile chunks
  F->>FS: write snapshot file
  F->>F: install snapshot metadata idempotently
  F->>S: restore state machine
  L->>F: AppendEntries after snapshot index
  F-->>L: catch-up success
```

## Leader Switch + No-Op Barrier

```mermaid
sequenceDiagram
  autonumber
  participant O as Old Leader
  participant N as New Leader
  participant F1 as Follower 1
  participant F2 as Follower 2
  participant C as Client

  O--xF1: loses leadership or stops
  F1->>F2: RequestVote / PreVote flow
  F1-->>N: votes establish new term
  N->>N: become leader
  N->>F1: append internal no-op
  N->>F2: append internal no-op
  F1-->>N: replicated
  F2-->>N: replicated
  N->>N: commit current-term no-op barrier
  C->>N: ReadIndex or write
  N-->>C: safe after barrier/quorum rules
```
