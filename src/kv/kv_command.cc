#include "kv/kv_command.h"

#include <cctype>
#include <iomanip>
#include <sstream>
#include <utility>
#include <vector>

namespace craftkv {
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

bool IsSafeFieldChar(unsigned char ch) {
    return std::isalnum(ch) || ch == '_' || ch == '-' || ch == '.';
}

int HexToInt(char ch) {
    if (ch >= '0' && ch <= '9') {
        return ch - '0';
    }
    if (ch >= 'a' && ch <= 'f') {
        return ch - 'a' + 10;
    }
    if (ch >= 'A' && ch <= 'F') {
        return ch - 'A' + 10;
    }
    return -1;
}

bool ParseUint64(const std::string& value, uint64_t* out) {
    if (value.empty()) {
        return false;
    }
    uint64_t result = 0;
    for (char ch : value) {
        if (ch < '0' || ch > '9') {
            return false;
        }
        result = result * 10 + static_cast<uint64_t>(ch - '0');
    }
    *out = result;
    return true;
}

bool ParseInt(const std::string& value, int* out) {
    if (value.empty()) {
        return false;
    }
    std::size_t pos = 0;
    bool negative = false;
    if (value[0] == '-') {
        negative = true;
        pos = 1;
    }
    if (pos == value.size()) {
        return false;
    }
    int result = 0;
    for (; pos < value.size(); ++pos) {
        char ch = value[pos];
        if (ch < '0' || ch > '9') {
            return false;
        }
        result = result * 10 + (ch - '0');
    }
    *out = negative ? -result : result;
    return true;
}

std::string JoinFields(const std::vector<std::string>& fields) {
    std::string result;
    for (std::size_t i = 0; i < fields.size(); ++i) {
        if (i != 0) {
            result.push_back('|');
        }
        result.append(fields[i]);
    }
    return result;
}

}  // namespace

std::string ToString(KVOpType op_type) {
    switch (op_type) {
        case KVOpType::kPut:
            return "PUT";
        case KVOpType::kGet:
            return "GET";
        case KVOpType::kDelete:
            return "DELETE";
        case KVOpType::kAppend:
            return "APPEND";
        case KVOpType::kUnknown:
        default:
            return "UNKNOWN";
    }
}

KVOpType KVOpTypeFromString(const std::string& value) {
    if (value == "PUT" || value == "put") {
        return KVOpType::kPut;
    }
    if (value == "GET" || value == "get") {
        return KVOpType::kGet;
    }
    if (value == "DELETE" || value == "delete" || value == "DEL" || value == "del") {
        return KVOpType::kDelete;
    }
    if (value == "APPEND" || value == "append") {
        return KVOpType::kAppend;
    }
    return KVOpType::kUnknown;
}

std::string ToString(KVErrorCode code) {
    switch (code) {
        case KVErrorCode::kOK:
            return "OK";
        case KVErrorCode::kNotLeader:
            return "NOT_LEADER";
        case KVErrorCode::kTimeout:
            return "TIMEOUT";
        case KVErrorCode::kKeyNotFound:
            return "KEY_NOT_FOUND";
        case KVErrorCode::kInternalError:
            return "INTERNAL_ERROR";
        case KVErrorCode::kBadRequest:
            return "BAD_REQUEST";
        default:
            return "INTERNAL_ERROR";
    }
}

KVErrorCode KVErrorCodeFromString(const std::string& value) {
    if (value == "OK") {
        return KVErrorCode::kOK;
    }
    if (value == "NOT_LEADER") {
        return KVErrorCode::kNotLeader;
    }
    if (value == "TIMEOUT") {
        return KVErrorCode::kTimeout;
    }
    if (value == "KEY_NOT_FOUND") {
        return KVErrorCode::kKeyNotFound;
    }
    if (value == "BAD_REQUEST") {
        return KVErrorCode::kBadRequest;
    }
    return KVErrorCode::kInternalError;
}

std::string EscapeField(const std::string& value) {
    std::ostringstream out;
    out << std::uppercase << std::hex << std::setfill('0');
    for (unsigned char ch : value) {
        if (IsSafeFieldChar(ch)) {
            out << static_cast<char>(ch);
        } else {
            out << '%' << std::setw(2) << static_cast<int>(ch);
        }
    }
    return out.str();
}

bool UnescapeField(const std::string& value, std::string* decoded) {
    decoded->clear();
    for (std::size_t i = 0; i < value.size(); ++i) {
        if (value[i] != '%') {
            decoded->push_back(value[i]);
            continue;
        }
        if (i + 2 >= value.size()) {
            return false;
        }
        int high = HexToInt(value[i + 1]);
        int low = HexToInt(value[i + 2]);
        if (high < 0 || low < 0) {
            return false;
        }
        decoded->push_back(static_cast<char>((high << 4) | low));
        i += 2;
    }
    return true;
}

std::string SerializeClientRequest(const ClientRequest& request) {
    return JoinFields({
        "KV1",
        EscapeField(request.client_id),
        std::to_string(request.request_id),
        ToString(request.op_type),
        EscapeField(request.key),
        EscapeField(request.value),
    });
}

bool DeserializeClientRequest(const std::string& data, ClientRequest* request, std::string* error_msg) {
    auto fields = Split(data, '|');
    if (fields.size() != 6 || fields[0] != "KV1") {
        if (error_msg != nullptr) {
            *error_msg = "invalid KV command format";
        }
        return false;
    }
    ClientRequest parsed;
    if (!UnescapeField(fields[1], &parsed.client_id) || !ParseUint64(fields[2], &parsed.request_id) ||
        !UnescapeField(fields[4], &parsed.key) || !UnescapeField(fields[5], &parsed.value)) {
        if (error_msg != nullptr) {
            *error_msg = "invalid KV command field";
        }
        return false;
    }
    parsed.op_type = KVOpTypeFromString(fields[3]);
    if (parsed.op_type == KVOpType::kUnknown || parsed.client_id.empty() || parsed.key.empty()) {
        if (error_msg != nullptr) {
            *error_msg = "unknown operation or empty client/key";
        }
        return false;
    }
    *request = std::move(parsed);
    return true;
}

std::string SerializeCommandResult(const CommandResult& result) {
    return JoinFields({
        "RES1",
        result.success ? "1" : "0",
        ToString(result.error_code),
        EscapeField(result.value),
        EscapeField(result.error_msg),
    });
}

bool DeserializeCommandResult(const std::string& data, CommandResult* result, std::string* error_msg) {
    auto fields = Split(data, '|');
    if (fields.size() != 5 || fields[0] != "RES1") {
        if (error_msg != nullptr) {
            *error_msg = "invalid command result format";
        }
        return false;
    }
    CommandResult parsed;
    parsed.success = fields[1] == "1";
    parsed.error_code = KVErrorCodeFromString(fields[2]);
    if (!UnescapeField(fields[3], &parsed.value) || !UnescapeField(fields[4], &parsed.error_msg)) {
        if (error_msg != nullptr) {
            *error_msg = "invalid command result field";
        }
        return false;
    }
    *result = std::move(parsed);
    return true;
}

std::string SerializeKVResponse(const KVResponse& response) {
    return JoinFields({
        "KVR1",
        response.success ? "1" : "0",
        ToString(response.error_code),
        std::to_string(response.leader_id),
        EscapeField(response.leader_addr),
        EscapeField(response.value),
        EscapeField(response.message),
    });
}

bool DeserializeKVResponse(const std::string& data, KVResponse* response, std::string* error_msg) {
    auto fields = Split(data, '|');
    if (fields.size() != 7 || fields[0] != "KVR1") {
        if (error_msg != nullptr) {
            *error_msg = "invalid KV response format";
        }
        return false;
    }
    KVResponse parsed;
    int leader_id = -1;
    parsed.success = fields[1] == "1";
    parsed.error_code = KVErrorCodeFromString(fields[2]);
    if (!ParseInt(fields[3], &leader_id) || !UnescapeField(fields[4], &parsed.leader_addr) ||
        !UnescapeField(fields[5], &parsed.value) || !UnescapeField(fields[6], &parsed.message)) {
        if (error_msg != nullptr) {
            *error_msg = "invalid KV response field";
        }
        return false;
    }
    parsed.leader_id = leader_id;
    *response = std::move(parsed);
    return true;
}

}  // namespace craftkv
