#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>

namespace craft {

struct RaftMetricsSnapshot {
    std::uint64_t election_count = 0;
    std::uint64_t leader_change_count = 0;
    std::uint64_t append_entries_sent = 0;
    std::uint64_t append_entries_success = 0;
    std::uint64_t append_entries_failed = 0;
    std::uint64_t request_vote_sent = 0;
    std::uint64_t request_vote_granted = 0;
    std::uint64_t request_vote_rejected = 0;
    std::uint64_t install_snapshot_sent = 0;
    std::uint64_t install_snapshot_success = 0;
    std::uint64_t install_snapshot_failed = 0;
    std::uint64_t snapshot_created_count = 0;
    std::uint64_t wal_recovery_truncated_tail_count = 0;
    std::uint64_t client_request_total = 0;
    std::uint64_t client_request_success = 0;
    std::uint64_t client_request_failed = 0;
};

class RaftMetrics {
public:
    RaftMetricsSnapshot Snapshot() const;

    void IncrementElection();
    void IncrementLeaderChange();
    void IncrementAppendEntriesSent();
    void IncrementAppendEntriesSuccess();
    void IncrementAppendEntriesFailed();
    void IncrementRequestVoteSent();
    void IncrementRequestVoteGranted();
    void IncrementRequestVoteRejected();
    void IncrementInstallSnapshotSent();
    void IncrementInstallSnapshotSuccess();
    void IncrementInstallSnapshotFailed();
    void IncrementSnapshotCreated();
    void IncrementWalRecoveryTruncatedTail();
    void AddWalRecoveryTruncatedTail(std::uint64_t count);
    void IncrementClientRequestTotal();
    void IncrementClientRequestSuccess();
    void IncrementClientRequestFailed();

private:
    std::atomic<std::uint64_t> election_count_{0};
    std::atomic<std::uint64_t> leader_change_count_{0};
    std::atomic<std::uint64_t> append_entries_sent_{0};
    std::atomic<std::uint64_t> append_entries_success_{0};
    std::atomic<std::uint64_t> append_entries_failed_{0};
    std::atomic<std::uint64_t> request_vote_sent_{0};
    std::atomic<std::uint64_t> request_vote_granted_{0};
    std::atomic<std::uint64_t> request_vote_rejected_{0};
    std::atomic<std::uint64_t> install_snapshot_sent_{0};
    std::atomic<std::uint64_t> install_snapshot_success_{0};
    std::atomic<std::uint64_t> install_snapshot_failed_{0};
    std::atomic<std::uint64_t> snapshot_created_count_{0};
    std::atomic<std::uint64_t> wal_recovery_truncated_tail_count_{0};
    std::atomic<std::uint64_t> client_request_total_{0};
    std::atomic<std::uint64_t> client_request_success_{0};
    std::atomic<std::uint64_t> client_request_failed_{0};
};

struct RaftStatusSnapshot {
    int node_id = -1;
    std::string role = "FOLLOWER";
    int current_term = 0;
    int leader_id = -1;
    int commit_index = 0;
    int last_applied = 0;
    int last_log_index = 0;
    int snapshot_index = 0;
    int snapshot_term = 0;
    std::size_t log_entry_count = 0;
    std::uint64_t wal_bytes = 0;
    RaftMetricsSnapshot metrics;
};

std::string RaftRoleCodeToString(int role_code);
std::string SerializeRaftStatusSnapshot(const RaftStatusSnapshot& snapshot);
bool DeserializeRaftStatusSnapshot(const std::string& data,
                                   RaftStatusSnapshot* snapshot,
                                   std::string* error_msg = nullptr);

}  // namespace craft
