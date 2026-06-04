#include "raft/raft_status.h"

#include <cstdlib>
#include <sstream>
#include <utility>
#include <vector>

#include "kv/kv_command.h"

namespace craft {
namespace {

std::vector<std::string> Split(const std::string& value, char delimiter) {
    std::vector<std::string> fields;
    std::string current;
    for (char ch : value) {
        if (ch == delimiter) {
            fields.push_back(current);
            current.clear();
        } else {
            current.push_back(ch);
        }
    }
    fields.push_back(current);
    return fields;
}

bool ParseInt(const std::string& value, int* out) {
    if (value.empty()) {
        return false;
    }
    char* end = nullptr;
    long parsed = std::strtol(value.c_str(), &end, 10);
    if (end == nullptr || *end != '\0') {
        return false;
    }
    *out = static_cast<int>(parsed);
    return true;
}

bool ParseUint64(const std::string& value, std::uint64_t* out) {
    if (value.empty()) {
        return false;
    }
    char* end = nullptr;
    unsigned long long parsed = std::strtoull(value.c_str(), &end, 10);
    if (end == nullptr || *end != '\0') {
        return false;
    }
    *out = static_cast<std::uint64_t>(parsed);
    return true;
}

bool ParseSize(const std::string& value, std::size_t* out) {
    std::uint64_t parsed = 0;
    if (!ParseUint64(value, &parsed)) {
        return false;
    }
    *out = static_cast<std::size_t>(parsed);
    return true;
}

void AppendField(std::ostringstream* out, const std::string& key, const std::string& value) {
    *out << key << '=' << craftkv::EscapeField(value) << '\n';
}

void AppendField(std::ostringstream* out, const std::string& key, std::uint64_t value) {
    *out << key << '=' << value << '\n';
}

void AppendField(std::ostringstream* out, const std::string& key, int value) {
    *out << key << '=' << value << '\n';
}

}  // namespace

RaftMetricsSnapshot RaftMetrics::Snapshot() const {
    RaftMetricsSnapshot snapshot;
    snapshot.election_count = election_count_.load(std::memory_order_relaxed);
    snapshot.leader_change_count = leader_change_count_.load(std::memory_order_relaxed);
    snapshot.append_entries_sent = append_entries_sent_.load(std::memory_order_relaxed);
    snapshot.append_entries_success = append_entries_success_.load(std::memory_order_relaxed);
    snapshot.append_entries_failed = append_entries_failed_.load(std::memory_order_relaxed);
    snapshot.request_vote_sent = request_vote_sent_.load(std::memory_order_relaxed);
    snapshot.request_vote_granted = request_vote_granted_.load(std::memory_order_relaxed);
    snapshot.request_vote_rejected = request_vote_rejected_.load(std::memory_order_relaxed);
    snapshot.install_snapshot_sent = install_snapshot_sent_.load(std::memory_order_relaxed);
    snapshot.install_snapshot_success = install_snapshot_success_.load(std::memory_order_relaxed);
    snapshot.install_snapshot_failed = install_snapshot_failed_.load(std::memory_order_relaxed);
    snapshot.snapshot_created_count = snapshot_created_count_.load(std::memory_order_relaxed);
    snapshot.wal_recovery_truncated_tail_count =
        wal_recovery_truncated_tail_count_.load(std::memory_order_relaxed);
    snapshot.client_request_total = client_request_total_.load(std::memory_order_relaxed);
    snapshot.client_request_success = client_request_success_.load(std::memory_order_relaxed);
    snapshot.client_request_failed = client_request_failed_.load(std::memory_order_relaxed);
    snapshot.read_log_total = read_log_total_.load(std::memory_order_relaxed);
    snapshot.read_index_total = read_index_total_.load(std::memory_order_relaxed);
    snapshot.read_index_success = read_index_success_.load(std::memory_order_relaxed);
    snapshot.read_index_failed = read_index_failed_.load(std::memory_order_relaxed);
    snapshot.read_index_timeout = read_index_timeout_.load(std::memory_order_relaxed);
    snapshot.read_index_quorum_confirm_rounds =
        read_index_quorum_confirm_rounds_.load(std::memory_order_relaxed);
    snapshot.leader_noop_appended = leader_noop_appended_.load(std::memory_order_relaxed);
    snapshot.leader_noop_committed = leader_noop_committed_.load(std::memory_order_relaxed);
    snapshot.pre_vote_sent = pre_vote_sent_.load(std::memory_order_relaxed);
    snapshot.pre_vote_granted = pre_vote_granted_.load(std::memory_order_relaxed);
    snapshot.pre_vote_rejected = pre_vote_rejected_.load(std::memory_order_relaxed);
    snapshot.check_quorum_stepdown_count = check_quorum_stepdown_count_.load(std::memory_order_relaxed);
    snapshot.check_quorum_rounds = check_quorum_rounds_.load(std::memory_order_relaxed);
    snapshot.check_quorum_success = check_quorum_success_.load(std::memory_order_relaxed);
    snapshot.check_quorum_failed = check_quorum_failed_.load(std::memory_order_relaxed);
    return snapshot;
}

void RaftMetrics::IncrementElection() { election_count_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementLeaderChange() { leader_change_count_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementAppendEntriesSent() { append_entries_sent_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementAppendEntriesSuccess() { append_entries_success_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementAppendEntriesFailed() { append_entries_failed_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementRequestVoteSent() { request_vote_sent_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementRequestVoteGranted() { request_vote_granted_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementRequestVoteRejected() { request_vote_rejected_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementInstallSnapshotSent() { install_snapshot_sent_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementInstallSnapshotSuccess() {
    install_snapshot_success_.fetch_add(1, std::memory_order_relaxed);
}
void RaftMetrics::IncrementInstallSnapshotFailed() {
    install_snapshot_failed_.fetch_add(1, std::memory_order_relaxed);
}
void RaftMetrics::IncrementSnapshotCreated() { snapshot_created_count_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementWalRecoveryTruncatedTail() {
    wal_recovery_truncated_tail_count_.fetch_add(1, std::memory_order_relaxed);
}
void RaftMetrics::AddWalRecoveryTruncatedTail(std::uint64_t count) {
    wal_recovery_truncated_tail_count_.fetch_add(count, std::memory_order_relaxed);
}
void RaftMetrics::IncrementClientRequestTotal() { client_request_total_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementClientRequestSuccess() {
    client_request_success_.fetch_add(1, std::memory_order_relaxed);
}
void RaftMetrics::IncrementClientRequestFailed() { client_request_failed_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementReadLogTotal() { read_log_total_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementReadIndexTotal() { read_index_total_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementReadIndexSuccess() { read_index_success_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementReadIndexFailed() { read_index_failed_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementReadIndexTimeout() { read_index_timeout_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementReadIndexQuorumConfirmRounds() {
    read_index_quorum_confirm_rounds_.fetch_add(1, std::memory_order_relaxed);
}
void RaftMetrics::IncrementLeaderNoopAppended() { leader_noop_appended_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementLeaderNoopCommitted() { leader_noop_committed_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementPreVoteSent() { pre_vote_sent_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementPreVoteGranted() { pre_vote_granted_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementPreVoteRejected() { pre_vote_rejected_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementCheckQuorumStepdown() {
    check_quorum_stepdown_count_.fetch_add(1, std::memory_order_relaxed);
}
void RaftMetrics::IncrementCheckQuorumRounds() { check_quorum_rounds_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementCheckQuorumSuccess() { check_quorum_success_.fetch_add(1, std::memory_order_relaxed); }
void RaftMetrics::IncrementCheckQuorumFailed() { check_quorum_failed_.fetch_add(1, std::memory_order_relaxed); }

std::string RaftRoleCodeToString(int role_code) {
    switch (role_code) {
        case 0:
            return "FOLLOWER";
        case 1:
            return "CANDIDATE";
        case 2:
            return "LEADER";
        default:
            return "UNKNOWN";
    }
}

std::string SerializeRaftStatusSnapshot(const RaftStatusSnapshot& snapshot) {
    std::ostringstream out;
    AppendField(&out, "node_id", snapshot.node_id);
    AppendField(&out, "role", snapshot.role);
    AppendField(&out, "current_term", snapshot.current_term);
    AppendField(&out, "leader_id", snapshot.leader_id);
    AppendField(&out, "commit_index", snapshot.commit_index);
    AppendField(&out, "last_applied", snapshot.last_applied);
    AppendField(&out, "last_log_index", snapshot.last_log_index);
    AppendField(&out, "snapshot_index", snapshot.snapshot_index);
    AppendField(&out, "snapshot_term", snapshot.snapshot_term);
    AppendField(&out, "log_entry_count", static_cast<std::uint64_t>(snapshot.log_entry_count));
    AppendField(&out, "wal_bytes", snapshot.wal_bytes);
    AppendField(&out, "election_count", snapshot.metrics.election_count);
    AppendField(&out, "leader_change_count", snapshot.metrics.leader_change_count);
    AppendField(&out, "append_entries_sent", snapshot.metrics.append_entries_sent);
    AppendField(&out, "append_entries_success", snapshot.metrics.append_entries_success);
    AppendField(&out, "append_entries_failed", snapshot.metrics.append_entries_failed);
    AppendField(&out, "request_vote_sent", snapshot.metrics.request_vote_sent);
    AppendField(&out, "request_vote_granted", snapshot.metrics.request_vote_granted);
    AppendField(&out, "request_vote_rejected", snapshot.metrics.request_vote_rejected);
    AppendField(&out, "install_snapshot_sent", snapshot.metrics.install_snapshot_sent);
    AppendField(&out, "install_snapshot_success", snapshot.metrics.install_snapshot_success);
    AppendField(&out, "install_snapshot_failed", snapshot.metrics.install_snapshot_failed);
    AppendField(&out, "snapshot_created_count", snapshot.metrics.snapshot_created_count);
    AppendField(&out, "wal_recovery_truncated_tail_count",
                snapshot.metrics.wal_recovery_truncated_tail_count);
    AppendField(&out, "client_request_total", snapshot.metrics.client_request_total);
    AppendField(&out, "client_request_success", snapshot.metrics.client_request_success);
    AppendField(&out, "client_request_failed", snapshot.metrics.client_request_failed);
    AppendField(&out, "read_log_total", snapshot.metrics.read_log_total);
    AppendField(&out, "read_index_total", snapshot.metrics.read_index_total);
    AppendField(&out, "read_index_success", snapshot.metrics.read_index_success);
    AppendField(&out, "read_index_failed", snapshot.metrics.read_index_failed);
    AppendField(&out, "read_index_timeout", snapshot.metrics.read_index_timeout);
    AppendField(&out, "read_index_quorum_confirm_rounds",
                snapshot.metrics.read_index_quorum_confirm_rounds);
    AppendField(&out, "leader_noop_appended", snapshot.metrics.leader_noop_appended);
    AppendField(&out, "leader_noop_committed", snapshot.metrics.leader_noop_committed);
    AppendField(&out, "pre_vote_sent", snapshot.metrics.pre_vote_sent);
    AppendField(&out, "pre_vote_granted", snapshot.metrics.pre_vote_granted);
    AppendField(&out, "pre_vote_rejected", snapshot.metrics.pre_vote_rejected);
    AppendField(&out, "check_quorum_stepdown_count",
                snapshot.metrics.check_quorum_stepdown_count);
    AppendField(&out, "check_quorum_rounds", snapshot.metrics.check_quorum_rounds);
    AppendField(&out, "check_quorum_success", snapshot.metrics.check_quorum_success);
    AppendField(&out, "check_quorum_failed", snapshot.metrics.check_quorum_failed);
    return out.str();
}

bool DeserializeRaftStatusSnapshot(const std::string& data,
                                   RaftStatusSnapshot* snapshot,
                                   std::string* error_msg) {
    RaftStatusSnapshot parsed;
    for (const auto& line : Split(data, '\n')) {
        if (line.empty()) {
            continue;
        }
        std::size_t pos = line.find('=');
        if (pos == std::string::npos) {
            if (error_msg != nullptr) {
                *error_msg = "invalid status line: " + line;
            }
            return false;
        }
        std::string key = line.substr(0, pos);
        std::string value = line.substr(pos + 1);
        std::string decoded;
        if (!craftkv::UnescapeField(value, &decoded)) {
            if (error_msg != nullptr) {
                *error_msg = "invalid escaped status value";
            }
            return false;
        }
        bool ok = true;
        if (key == "node_id") {
            ok = ParseInt(decoded, &parsed.node_id);
        } else if (key == "role") {
            parsed.role = std::move(decoded);
        } else if (key == "current_term") {
            ok = ParseInt(decoded, &parsed.current_term);
        } else if (key == "leader_id") {
            ok = ParseInt(decoded, &parsed.leader_id);
        } else if (key == "commit_index") {
            ok = ParseInt(decoded, &parsed.commit_index);
        } else if (key == "last_applied") {
            ok = ParseInt(decoded, &parsed.last_applied);
        } else if (key == "last_log_index") {
            ok = ParseInt(decoded, &parsed.last_log_index);
        } else if (key == "snapshot_index") {
            ok = ParseInt(decoded, &parsed.snapshot_index);
        } else if (key == "snapshot_term") {
            ok = ParseInt(decoded, &parsed.snapshot_term);
        } else if (key == "log_entry_count") {
            ok = ParseSize(decoded, &parsed.log_entry_count);
        } else if (key == "wal_bytes") {
            ok = ParseUint64(decoded, &parsed.wal_bytes);
        } else if (key == "election_count") {
            ok = ParseUint64(decoded, &parsed.metrics.election_count);
        } else if (key == "leader_change_count") {
            ok = ParseUint64(decoded, &parsed.metrics.leader_change_count);
        } else if (key == "append_entries_sent") {
            ok = ParseUint64(decoded, &parsed.metrics.append_entries_sent);
        } else if (key == "append_entries_success") {
            ok = ParseUint64(decoded, &parsed.metrics.append_entries_success);
        } else if (key == "append_entries_failed") {
            ok = ParseUint64(decoded, &parsed.metrics.append_entries_failed);
        } else if (key == "request_vote_sent") {
            ok = ParseUint64(decoded, &parsed.metrics.request_vote_sent);
        } else if (key == "request_vote_granted") {
            ok = ParseUint64(decoded, &parsed.metrics.request_vote_granted);
        } else if (key == "request_vote_rejected") {
            ok = ParseUint64(decoded, &parsed.metrics.request_vote_rejected);
        } else if (key == "install_snapshot_sent") {
            ok = ParseUint64(decoded, &parsed.metrics.install_snapshot_sent);
        } else if (key == "install_snapshot_success") {
            ok = ParseUint64(decoded, &parsed.metrics.install_snapshot_success);
        } else if (key == "install_snapshot_failed") {
            ok = ParseUint64(decoded, &parsed.metrics.install_snapshot_failed);
        } else if (key == "snapshot_created_count") {
            ok = ParseUint64(decoded, &parsed.metrics.snapshot_created_count);
        } else if (key == "wal_recovery_truncated_tail_count") {
            ok = ParseUint64(decoded, &parsed.metrics.wal_recovery_truncated_tail_count);
        } else if (key == "client_request_total") {
            ok = ParseUint64(decoded, &parsed.metrics.client_request_total);
        } else if (key == "client_request_success") {
            ok = ParseUint64(decoded, &parsed.metrics.client_request_success);
        } else if (key == "client_request_failed") {
            ok = ParseUint64(decoded, &parsed.metrics.client_request_failed);
        } else if (key == "read_log_total") {
            ok = ParseUint64(decoded, &parsed.metrics.read_log_total);
        } else if (key == "read_index_total") {
            ok = ParseUint64(decoded, &parsed.metrics.read_index_total);
        } else if (key == "read_index_success") {
            ok = ParseUint64(decoded, &parsed.metrics.read_index_success);
        } else if (key == "read_index_failed") {
            ok = ParseUint64(decoded, &parsed.metrics.read_index_failed);
        } else if (key == "read_index_timeout") {
            ok = ParseUint64(decoded, &parsed.metrics.read_index_timeout);
        } else if (key == "read_index_quorum_confirm_rounds") {
            ok = ParseUint64(decoded, &parsed.metrics.read_index_quorum_confirm_rounds);
        } else if (key == "leader_noop_appended") {
            ok = ParseUint64(decoded, &parsed.metrics.leader_noop_appended);
        } else if (key == "leader_noop_committed") {
            ok = ParseUint64(decoded, &parsed.metrics.leader_noop_committed);
        } else if (key == "pre_vote_sent") {
            ok = ParseUint64(decoded, &parsed.metrics.pre_vote_sent);
        } else if (key == "pre_vote_granted") {
            ok = ParseUint64(decoded, &parsed.metrics.pre_vote_granted);
        } else if (key == "pre_vote_rejected") {
            ok = ParseUint64(decoded, &parsed.metrics.pre_vote_rejected);
        } else if (key == "check_quorum_stepdown_count") {
            ok = ParseUint64(decoded, &parsed.metrics.check_quorum_stepdown_count);
        } else if (key == "check_quorum_rounds") {
            ok = ParseUint64(decoded, &parsed.metrics.check_quorum_rounds);
        } else if (key == "check_quorum_success") {
            ok = ParseUint64(decoded, &parsed.metrics.check_quorum_success);
        } else if (key == "check_quorum_failed") {
            ok = ParseUint64(decoded, &parsed.metrics.check_quorum_failed);
        }
        if (!ok) {
            if (error_msg != nullptr) {
                *error_msg = "invalid numeric status value for " + key;
            }
            return false;
        }
    }
    *snapshot = std::move(parsed);
    return true;
}

}  // namespace craft
