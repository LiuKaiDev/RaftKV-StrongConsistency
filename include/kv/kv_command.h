#pragma once

#include <cstdint>
#include <string>

namespace craftkv {

enum class KVOpType {
    kPut,
    kGet,
    kDelete,
    kAppend,
    kUnknown,
};

enum class KVErrorCode {
    kOK,
    kNotLeader,
    kTimeout,
    kKeyNotFound,
    kInternalError,
    kBadRequest,
};

struct ClientRequest {
    std::string client_id;
    uint64_t request_id = 0;
    KVOpType op_type = KVOpType::kUnknown;
    std::string key;
    std::string value;
};

struct CommandResult {
    bool success = false;
    KVErrorCode error_code = KVErrorCode::kInternalError;
    std::string value;
    std::string error_msg;
};

struct LastRequestInfo {
    uint64_t request_id = 0;
    CommandResult result;
};

struct KVResponse {
    bool success = false;
    KVErrorCode error_code = KVErrorCode::kInternalError;
    int leader_id = -1;
    std::string leader_addr;
    std::string value;
    std::string message;
};

std::string ToString(KVOpType op_type);
KVOpType KVOpTypeFromString(const std::string& value);

std::string ToString(KVErrorCode code);
KVErrorCode KVErrorCodeFromString(const std::string& value);

std::string SerializeClientRequest(const ClientRequest& request);
bool DeserializeClientRequest(const std::string& data, ClientRequest* request, std::string* error_msg = nullptr);

std::string SerializeCommandResult(const CommandResult& result);
bool DeserializeCommandResult(const std::string& data, CommandResult* result, std::string* error_msg = nullptr);

std::string SerializeKVResponse(const KVResponse& response);
bool DeserializeKVResponse(const std::string& data, KVResponse* response, std::string* error_msg = nullptr);

std::string EscapeField(const std::string& value);
bool UnescapeField(const std::string& value, std::string* decoded);

}  // namespace craftkv
