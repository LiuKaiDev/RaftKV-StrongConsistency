#pragma once

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

}  // namespace craft::raft_correctness
