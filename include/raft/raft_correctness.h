#pragma once

#include <algorithm>
#include <cstddef>
#include <string>
#include <vector>

namespace craft::raft_correctness {

inline bool IsValidPeerIndex(int peer_index, int peer_count) {
    return peer_index >= 0 && peer_index < peer_count;
}

inline bool IsRemotePeerIndex(int peer_index, int self_index, int peer_count) {
    return IsValidPeerIndex(peer_index, peer_count) && peer_index != self_index;
}

inline std::string PeerAddressForLog(int peer_index, const std::vector<std::string>& peer_addresses) {
    if (!IsValidPeerIndex(peer_index, static_cast<int>(peer_addresses.size()))) {
        return "<invalid-peer>";
    }
    return peer_addresses[static_cast<std::size_t>(peer_index)];
}

inline bool InitializeLeaderReplicationState(int peer_count,
                                             int self_index,
                                             int leader_last_log_index,
                                             std::vector<int>* next_index,
                                             std::vector<int>* match_index) {
    if (next_index == nullptr || match_index == nullptr ||
        !IsValidPeerIndex(self_index, peer_count) || peer_count < 0) {
        return false;
    }

    next_index->assign(static_cast<std::size_t>(peer_count), leader_last_log_index + 1);
    match_index->assign(static_cast<std::size_t>(peer_count), 0);
    (*match_index)[static_cast<std::size_t>(self_index)] = leader_last_log_index;
    return true;
}

inline bool PrepareLeaderTransition(int peer_count,
                                    int self_index,
                                    int leader_last_log_index,
                                    int* leader_id,
                                    std::vector<int>* next_index,
                                    std::vector<int>* match_index) {
    if (leader_id == nullptr) {
        return false;
    }
    if (!InitializeLeaderReplicationState(peer_count, self_index, leader_last_log_index,
                                          next_index, match_index)) {
        return false;
    }
    *leader_id = self_index;
    return true;
}

inline bool ApplyRequestVoteTerm(int request_term, int* current_term, int* voted_for) {
    if (current_term == nullptr || voted_for == nullptr || request_term <= *current_term) {
        return false;
    }
    *current_term = request_term;
    *voted_for = -1;
    return true;
}

inline bool IsCandidateLogAtLeastUpToDate(int local_last_log_term,
                                          int local_last_log_index,
                                          int candidate_last_log_term,
                                          int candidate_last_log_index) {
    return candidate_last_log_term > local_last_log_term ||
           (candidate_last_log_term == local_last_log_term &&
            candidate_last_log_index >= local_last_log_index);
}

inline bool ShouldGrantPreVote(int current_term,
                               bool local_is_leader,
                               bool has_recent_leader_contact,
                               int local_last_log_term,
                               int local_last_log_index,
                               int request_term,
                               int candidate_last_log_term,
                               int candidate_last_log_index) {
    if (request_term < current_term || local_is_leader || has_recent_leader_contact) {
        return false;
    }
    return IsCandidateLogAtLeastUpToDate(local_last_log_term, local_last_log_index,
                                         candidate_last_log_term, candidate_last_log_index);
}

inline bool HasRecentQuorum(const std::vector<bool>& recent_contact, int self_index) {
    if (!IsValidPeerIndex(self_index, static_cast<int>(recent_contact.size()))) {
        return false;
    }
    int count = 0;
    for (bool recent : recent_contact) {
        if (recent) {
            ++count;
        }
    }
    return count > static_cast<int>(recent_contact.size()) / 2;
}

inline std::size_t BoundedAppendEntriesCount(int next_index,
                                             int last_log_index,
                                             int max_entries_per_rpc) {
    if (max_entries_per_rpc <= 0 || next_index > last_log_index) {
        return 0;
    }
    int available = last_log_index - next_index + 1;
    if (available <= 0) {
        return 0;
    }
    return static_cast<std::size_t>(std::min(available, max_entries_per_rpc));
}

inline bool NeedsInstallSnapshot(int next_index, int snapshot_index) {
    return next_index <= snapshot_index;
}

inline bool AdvanceReplicationOnAppendSuccess(int peer_index,
                                              int prev_log_index,
                                              int entries_size,
                                              std::vector<int>* next_index,
                                              std::vector<int>* match_index) {
    if (next_index == nullptr || match_index == nullptr ||
        !IsValidPeerIndex(peer_index, static_cast<int>(next_index->size())) ||
        !IsValidPeerIndex(peer_index, static_cast<int>(match_index->size())) ||
        entries_size <= 0) {
        return false;
    }
    int last_batch_index = prev_log_index + entries_size;
    int& peer_match = (*match_index)[static_cast<std::size_t>(peer_index)];
    int& peer_next = (*next_index)[static_cast<std::size_t>(peer_index)];
    if (last_batch_index <= peer_match) {
        return false;
    }
    peer_match = last_batch_index;
    peer_next = std::max(peer_next, last_batch_index + 1);
    return true;
}

inline bool BackoffReplicationOnAppendFailure(int peer_index,
                                              int reply_next_log_index,
                                              int snapshot_index,
                                              std::vector<int>* next_index,
                                              const std::vector<int>& match_index) {
    if (next_index == nullptr ||
        !IsValidPeerIndex(peer_index, static_cast<int>(next_index->size())) ||
        !IsValidPeerIndex(peer_index, static_cast<int>(match_index.size())) ||
        reply_next_log_index == 0) {
        return false;
    }
    int safe_min_next = snapshot_index + 1;
    int proposed_next = std::max(reply_next_log_index, safe_min_next);
    int current_next = (*next_index)[static_cast<std::size_t>(peer_index)];
    if (proposed_next < match_index[static_cast<std::size_t>(peer_index)] + 1 ||
        proposed_next >= current_next) {
        return false;
    }
    (*next_index)[static_cast<std::size_t>(peer_index)] = proposed_next;
    return true;
}

inline bool AdvanceReplicationOnSnapshotInstall(int peer_index,
                                                int snapshot_index,
                                                std::vector<int>* next_index,
                                                std::vector<int>* match_index) {
    if (next_index == nullptr || match_index == nullptr ||
        !IsValidPeerIndex(peer_index, static_cast<int>(next_index->size())) ||
        !IsValidPeerIndex(peer_index, static_cast<int>(match_index->size())) ||
        snapshot_index < 0) {
        return false;
    }
    int& peer_match = (*match_index)[static_cast<std::size_t>(peer_index)];
    int& peer_next = (*next_index)[static_cast<std::size_t>(peer_index)];
    bool changed = false;
    if (snapshot_index > peer_match) {
        peer_match = snapshot_index;
        changed = true;
    }
    if (peer_next < snapshot_index + 1) {
        peer_next = snapshot_index + 1;
        changed = true;
    }
    return changed;
}

}  // namespace craft::raft_correctness
