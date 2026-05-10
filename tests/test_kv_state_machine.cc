#include <cassert>
#include <iostream>

#include "kv/kv_state_machine.h"

int main() {
    craftkv::KVStateMachine sm;

    auto put = sm.Apply({"client-a", 1, craftkv::KVOpType::kPut, "name", "chaos"});
    assert(put.success);

    auto get = sm.Apply({"client-a", 2, craftkv::KVOpType::kGet, "name", ""});
    assert(get.success);
    assert(get.value == "chaos");

    auto append = sm.Apply({"client-a", 3, craftkv::KVOpType::kAppend, "name", "_raft"});
    assert(append.success);
    assert(append.value == "chaos_raft");

    auto duplicate = sm.Apply({"client-a", 3, craftkv::KVOpType::kAppend, "name", "_again"});
    assert(duplicate.success);
    assert(duplicate.value == "chaos_raft");

    auto del = sm.Apply({"client-a", 4, craftkv::KVOpType::kDelete, "name", ""});
    assert(del.success);

    auto miss = sm.Apply({"client-a", 5, craftkv::KVOpType::kGet, "name", ""});
    assert(!miss.success);
    assert(miss.error_code == craftkv::KVErrorCode::kKeyNotFound);

    sm.Apply({"client-b", 1, craftkv::KVOpType::kPut, "k1", "v1"});
    std::string snapshot = sm.SerializeSnapshot();

    craftkv::KVStateMachine restored;
    std::string error;
    assert(restored.LoadSnapshot(snapshot, &error));
    auto restored_get = restored.Apply({"client-b", 2, craftkv::KVOpType::kGet, "k1", ""});
    assert(restored_get.success);
    assert(restored_get.value == "v1");

    auto dedup = restored.Apply({"client-b", 1, craftkv::KVOpType::kPut, "k1", "v2"});
    assert(dedup.success);
    auto final_get = restored.Apply({"client-b", 3, craftkv::KVOpType::kGet, "k1", ""});
    assert(final_get.value == "v1");

    std::cout << "test_kv_state_machine passed" << std::endl;
    return 0;
}
