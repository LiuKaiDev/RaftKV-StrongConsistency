#include <chrono>
#include <algorithm>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>

#include "kv/kv_command.h"

#ifndef _WIN32
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace {

std::vector<std::string> Split(const std::string& value, char delimiter) {
    std::vector<std::string> out;
    std::string current;
    for (char ch : value) {
        if (ch == delimiter) {
            if (!current.empty()) {
                out.push_back(current);
            }
            current.clear();
        } else {
            current.push_back(ch);
        }
    }
    if (!current.empty()) {
        out.push_back(current);
    }
    return out;
}

bool ParseHostPort(const std::string& addr, std::string* host, int* port) {
    std::size_t pos = addr.rfind(':');
    if (pos == std::string::npos) {
        return false;
    }
    *host = addr.substr(0, pos);
    try {
        *port = std::stoi(addr.substr(pos + 1));
    } catch (...) {
        return false;
    }
    return *port > 0 && *port <= 65535;
}

uint64_t NextRequestId() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::system_clock::now().time_since_epoch())
            .count());
}

std::string DefaultClientId() {
#ifndef _WIN32
    return "kv_client_" + std::to_string(getpid());
#else
    return "kv_client";
#endif
}

bool SendLine(const std::string& addr, const std::string& line, int timeout_ms, std::string* reply,
              std::string* error) {
#ifdef _WIN32
    (void)addr;
    (void)line;
    (void)timeout_ms;
    (void)reply;
    *error = "POSIX socket client is required";
    return false;
#else
    std::string host;
    int port = 0;
    if (!ParseHostPort(addr, &host, &port)) {
        *error = "invalid server address: " + addr;
        return false;
    }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        *error = "failed to create socket";
        return false;
    }
    timeval tv{};
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    sockaddr_in server{};
    server.sin_family = AF_INET;
    server.sin_port = htons(static_cast<uint16_t>(port));
    if (inet_pton(AF_INET, host.c_str(), &server.sin_addr) != 1) {
        close(fd);
        *error = "invalid host: " + host;
        return false;
    }
    if (connect(fd, reinterpret_cast<sockaddr*>(&server), sizeof(server)) != 0) {
        close(fd);
        *error = "connect failed: " + addr;
        return false;
    }

    std::string outbound = line;
    outbound.push_back('\n');
    if (send(fd, outbound.data(), outbound.size(), 0) < 0) {
        close(fd);
        *error = "send failed: " + addr;
        return false;
    }

    reply->clear();
    char ch = 0;
    while (true) {
        ssize_t n = recv(fd, &ch, 1, 0);
        if (n <= 0) {
            break;
        }
        if (ch == '\n') {
            break;
        }
        if (ch != '\r') {
            reply->push_back(ch);
        }
    }
    close(fd);
    if (reply->empty()) {
        *error = "empty response from: " + addr;
        return false;
    }
    return true;
#endif
}

void PrintUsage() {
    std::cerr
        << "Usage:\n"
        << "  kv_client [--servers=a,b,c] [--client_id=id] [--request_id=n] put <key> <value>\n"
        << "  kv_client [--servers=a,b,c] get <key>\n"
        << "  kv_client [--servers=a,b,c] delete <key>\n"
        << "  kv_client [--servers=a,b,c] append <key> <value>\n"
        << "  kv_client [--servers=a,b,c] dump\n"
        << "  kv_client [--servers=a,b,c] leader\n";
}

}  // namespace

int main(int argc, char** argv) {
    std::vector<std::string> servers = {"127.0.0.1:9001", "127.0.0.1:9002", "127.0.0.1:9003"};
    std::string client_id = DefaultClientId();
    uint64_t request_id = NextRequestId();
    int timeout_ms = 1000;
    int retries = 5;

    std::vector<std::string> args;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg.rfind("--servers=", 0) == 0) {
            servers = Split(arg.substr(std::string("--servers=").size()), ',');
        } else if (arg.rfind("--client_id=", 0) == 0) {
            client_id = arg.substr(std::string("--client_id=").size());
        } else if (arg.rfind("--request_id=", 0) == 0) {
            request_id = std::stoull(arg.substr(std::string("--request_id=").size()));
        } else if (arg.rfind("--timeout_ms=", 0) == 0) {
            timeout_ms = std::stoi(arg.substr(std::string("--timeout_ms=").size()));
        } else if (arg.rfind("--retries=", 0) == 0) {
            retries = std::stoi(arg.substr(std::string("--retries=").size()));
        } else {
            args.push_back(arg);
        }
    }

    if (args.empty() || servers.empty()) {
        PrintUsage();
        return 1;
    }

    std::string op = args[0];
    bool local_dump = op == "dump";
    bool leader_query = op == "leader";

    craftkv::ClientRequest request;
    request.client_id = client_id;
    request.request_id = request_id;
    if (!local_dump && !leader_query) {
        request.op_type = craftkv::KVOpTypeFromString(op);
        if (request.op_type == craftkv::KVOpType::kUnknown) {
            PrintUsage();
            return 1;
        }
        if ((request.op_type == craftkv::KVOpType::kGet || request.op_type == craftkv::KVOpType::kDelete) &&
            args.size() != 2) {
            PrintUsage();
            return 1;
        }
        if ((request.op_type == craftkv::KVOpType::kPut || request.op_type == craftkv::KVOpType::kAppend) &&
            args.size() != 3) {
            PrintUsage();
            return 1;
        }
        request.key = args[1];
        if (args.size() >= 3) {
            request.value = args[2];
        }
    }

    std::string payload = local_dump ? "LOCAL_DUMP" : (leader_query ? "LEADER" : craftkv::SerializeClientRequest(request));
    std::string last_error;
    int server_index = 0;
    for (int attempt = 0; attempt < retries; ++attempt) {
        const std::string target = servers[server_index % servers.size()];
        std::string raw_reply;
        if (!SendLine(target, payload, timeout_ms, &raw_reply, &last_error)) {
            ++server_index;
            continue;
        }

        craftkv::KVResponse response;
        std::string parse_error;
        if (!craftkv::DeserializeKVResponse(raw_reply, &response, &parse_error)) {
            last_error = parse_error;
            ++server_index;
            continue;
        }

        if (response.error_code == craftkv::KVErrorCode::kNotLeader && !response.leader_addr.empty()) {
            auto it = std::find(servers.begin(), servers.end(), response.leader_addr);
            if (it == servers.end()) {
                servers.insert(servers.begin(), response.leader_addr);
                server_index = 0;
            } else {
                server_index = static_cast<int>(std::distance(servers.begin(), it));
            }
            continue;
        }

        if (leader_query) {
            std::cout << response.leader_id << " " << response.leader_addr << std::endl;
            return 0;
        }
        if (local_dump) {
            std::cout << response.value;
            return response.success ? 0 : 2;
        }
        if (!response.success) {
            std::cerr << craftkv::ToString(response.error_code) << ": " << response.message << std::endl;
            return 2;
        }
        if (request.op_type == craftkv::KVOpType::kGet || request.op_type == craftkv::KVOpType::kAppend) {
            std::cout << response.value << std::endl;
        } else {
            std::cout << "OK" << std::endl;
        }
        return 0;
    }

    std::cerr << "request failed: " << last_error << std::endl;
    return 2;
}
