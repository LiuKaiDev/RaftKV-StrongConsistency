#include "kv/kv_state_machine.h"

#include <cstring>
#include <limits>
#include <sstream>
#include <utility>

namespace craftkv {
namespace {

constexpr char kSnapshotMagic[] = "KVS1";

void AppendU64(std::string* out, uint64_t value) {
    for (int i = 0; i < 8; ++i) {
        out->push_back(static_cast<char>((value >> (i * 8)) & 0xff));
    }
}

bool ReadU64(const std::string& data, std::size_t* offset, uint64_t* value) {
    if (*offset + 8 > data.size()) {
        return false;
    }
    uint64_t result = 0;
    for (int i = 0; i < 8; ++i) {
        result |= (static_cast<uint64_t>(static_cast<unsigned char>(data[*offset + i])) << (i * 8));
    }
    *offset += 8;
    *value = result;
    return true;
}

void AppendBytes(std::string* out, const std::string& value) {
    AppendU64(out, static_cast<uint64_t>(value.size()));
    out->append(value);
}

bool ReadBytes(const std::string& data, std::size_t* offset, std::string* value) {
    uint64_t size = 0;
    if (!ReadU64(data, offset, &size)) {
        return false;
    }
    if (size > static_cast<uint64_t>(std::numeric_limits<std::size_t>::max()) ||
        *offset + static_cast<std::size_t>(size) > data.size()) {
        return false;
    }
    value->assign(data.data() + *offset, static_cast<std::size_t>(size));
    *offset += static_cast<std::size_t>(size);
    return true;
}

CommandResult MakeOK(std::string value = {}) {
    return {true, KVErrorCode::kOK, std::move(value), ""};
}

CommandResult MakeError(KVErrorCode code, std::string message) {
    return {false, code, "", std::move(message)};
}

}  // namespace

CommandResult KVStateMachine::Apply(const ClientRequest& request) {
    std::lock_guard<std::mutex> lock(mutex_);

    auto last_it = last_request_.find(request.client_id);
    if (last_it != last_request_.end() && request.request_id <= last_it->second.request_id) {
        return last_it->second.result;
    }

    CommandResult result = ApplyLocked(request);
    last_request_[request.client_id] = LastRequestInfo{request.request_id, result};
    return result;
}

CommandResult KVStateMachine::ApplyLocked(const ClientRequest& request) {
    switch (request.op_type) {
        case KVOpType::kPut:
            kv_[request.key] = request.value;
            return MakeOK();
        case KVOpType::kGet: {
            auto it = kv_.find(request.key);
            if (it == kv_.end()) {
                return MakeError(KVErrorCode::kKeyNotFound, "key not found");
            }
            return MakeOK(it->second);
        }
        case KVOpType::kDelete: {
            auto it = kv_.find(request.key);
            if (it == kv_.end()) {
                return MakeError(KVErrorCode::kKeyNotFound, "key not found");
            }
            kv_.erase(it);
            return MakeOK();
        }
        case KVOpType::kAppend:
            kv_[request.key].append(request.value);
            return MakeOK(kv_[request.key]);
        case KVOpType::kUnknown:
        default:
            return MakeError(KVErrorCode::kBadRequest, "unknown operation");
    }
}

bool KVStateMachine::GetLocal(const std::string& key, std::string* value) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = kv_.find(key);
    if (it == kv_.end()) {
        return false;
    }
    *value = it->second;
    return true;
}

std::map<std::string, std::string> KVStateMachine::DumpKV() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return kv_;
}

std::string KVStateMachine::DumpKVText() const {
    std::lock_guard<std::mutex> lock(mutex_);
    std::ostringstream out;
    for (const auto& [key, value] : kv_) {
        out << EscapeField(key) << '=' << EscapeField(value) << '\n';
    }
    return out.str();
}

std::string KVStateMachine::SerializeSnapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    std::string out;
    out.append(kSnapshotMagic, std::strlen(kSnapshotMagic));

    AppendU64(&out, static_cast<uint64_t>(kv_.size()));
    for (const auto& [key, value] : kv_) {
        AppendBytes(&out, key);
        AppendBytes(&out, value);
    }

    AppendU64(&out, static_cast<uint64_t>(last_request_.size()));
    for (const auto& [client_id, request_info] : last_request_) {
        AppendBytes(&out, client_id);
        AppendU64(&out, request_info.request_id);
        AppendBytes(&out, SerializeCommandResult(request_info.result));
    }
    return out;
}

bool KVStateMachine::LoadSnapshot(const std::string& snapshot, std::string* error_msg) {
    std::size_t offset = 0;
    if (snapshot.size() < std::strlen(kSnapshotMagic) ||
        snapshot.compare(0, std::strlen(kSnapshotMagic), kSnapshotMagic) != 0) {
        if (error_msg != nullptr) {
            *error_msg = "invalid KV snapshot magic";
        }
        return false;
    }
    offset += std::strlen(kSnapshotMagic);

    std::map<std::string, std::string> kv;
    std::map<std::string, LastRequestInfo> last_request;

    uint64_t kv_count = 0;
    if (!ReadU64(snapshot, &offset, &kv_count)) {
        if (error_msg != nullptr) {
            *error_msg = "invalid KV count";
        }
        return false;
    }
    for (uint64_t i = 0; i < kv_count; ++i) {
        std::string key;
        std::string value;
        if (!ReadBytes(snapshot, &offset, &key) || !ReadBytes(snapshot, &offset, &value)) {
            if (error_msg != nullptr) {
                *error_msg = "invalid KV item";
            }
            return false;
        }
        kv.emplace(std::move(key), std::move(value));
    }

    uint64_t last_count = 0;
    if (!ReadU64(snapshot, &offset, &last_count)) {
        if (error_msg != nullptr) {
            *error_msg = "invalid dedup count";
        }
        return false;
    }
    for (uint64_t i = 0; i < last_count; ++i) {
        std::string client_id;
        std::string encoded_result;
        uint64_t request_id = 0;
        CommandResult result;
        if (!ReadBytes(snapshot, &offset, &client_id) || !ReadU64(snapshot, &offset, &request_id) ||
            !ReadBytes(snapshot, &offset, &encoded_result) ||
            !DeserializeCommandResult(encoded_result, &result, error_msg)) {
            if (error_msg != nullptr && error_msg->empty()) {
                *error_msg = "invalid dedup item";
            }
            return false;
        }
        last_request.emplace(std::move(client_id), LastRequestInfo{request_id, result});
    }

    if (offset != snapshot.size()) {
        if (error_msg != nullptr) {
            *error_msg = "trailing bytes in KV snapshot";
        }
        return false;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    kv_ = std::move(kv);
    last_request_ = std::move(last_request);
    return true;
}

void KVStateMachine::Clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    kv_.clear();
    last_request_.clear();
}

std::size_t KVStateMachine::Size() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return kv_.size();
}

std::size_t KVStateMachine::LastRequestCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return last_request_.size();
}

}  // namespace craftkv
