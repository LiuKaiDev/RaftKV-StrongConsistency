#include <cassert>
#include <iostream>

#include "kv/kv_command.h"
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

    std::cout << "test_raft_log passed" << std::endl;
    return 0;
}
