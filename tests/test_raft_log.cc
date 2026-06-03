#include <cassert>
#include <iostream>

#include "kv/kv_command.h"
#include "raft/raft_correctness.h"
#include "storage/wal.h"

int main() {
    craftkv::ClientRequest request{"client-a", 42, craftkv::KVOpType::kPut, "hello|key", "value with spaces"};
    std::string encoded = craftkv::SerializeClientRequest(request);
    craftkv::ClientRequest decoded;
    std::string error;
    assert(craftkv::DeserializeClientRequest(encoded, &decoded, &error));
    assert(decoded.client_id == request.client_id);
    assert(decoded.request_id == request.request_id);
    assert(decoded.key == request.key);
    assert(decoded.value == request.value);

    craftkv::storage::RaftLogRecord log{10, 3, encoded};
    std::string payload = craftkv::storage::EncodeLogRecordPayload(log);
    craftkv::storage::RaftLogRecord restored;
    assert(craftkv::storage::DecodeLogRecordPayload(payload, &restored));
    assert(restored.index == 10);
    assert(restored.term == 3);
    assert(restored.command == encoded);

    std::vector<int> next_index;
    std::vector<int> match_index;
    assert(craft::raft_correctness::InitializeLeaderReplicationState(3, 1, 10, &next_index, &match_index));
    assert(next_index.size() == 3);
    assert(match_index.size() == 3);
    assert(next_index[0] == 11);
    assert(next_index[1] == 11);
    assert(next_index[2] == 11);
    assert(match_index[0] == 0);
    assert(match_index[1] == 10);
    assert(match_index[2] == 0);

    assert(!craft::raft_correctness::IsValidPeerIndex(-1, 3));
    assert(craft::raft_correctness::IsValidPeerIndex(0, 3));
    assert(craft::raft_correctness::IsValidPeerIndex(2, 3));
    assert(!craft::raft_correctness::IsValidPeerIndex(3, 3));
    assert(!craft::raft_correctness::IsValidPeerIndex(4, 3));
    assert(!craft::raft_correctness::IsRemotePeerIndex(1, 1, 3));
    assert(craft::raft_correctness::IsRemotePeerIndex(2, 1, 3));
    assert(!craft::raft_correctness::InitializeLeaderReplicationState(3, 3, 10, &next_index, &match_index));

    int current_term = 2;
    int voted_for = 1;
    assert(craft::raft_correctness::ApplyRequestVoteTerm(5, &current_term, &voted_for));
    assert(current_term == 5);
    assert(voted_for == -1);
    int response_term = current_term;
    assert(response_term == 5);
    assert(!craft::raft_correctness::ApplyRequestVoteTerm(4, &current_term, &voted_for));
    assert(current_term == 5);

    std::cout << "test_raft_log passed" << std::endl;
    return 0;
}
