#pragma once

#include <cstdint>
#include <map>
#include <mutex>
#include <string>

#include "kv/kv_command.h"

namespace craftkv {

class KVStateMachine {
public:
    CommandResult Apply(const ClientRequest& request);

    bool GetLocal(const std::string& key, std::string* value) const;
    std::map<std::string, std::string> DumpKV() const;
    std::string DumpKVText() const;

    std::string SerializeSnapshot() const;
    bool LoadSnapshot(const std::string& snapshot, std::string* error_msg = nullptr);

    void Clear();
    std::size_t Size() const;
    std::size_t LastRequestCount() const;

private:
    CommandResult ApplyLocked(const ClientRequest& request);

    mutable std::mutex mutex_;
    std::map<std::string, std::string> kv_;
    std::map<std::string, LastRequestInfo> last_request_;
};

}  // namespace craftkv
