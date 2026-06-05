#include <algorithm>
#include <atomic>
#include <chrono>
#include <ctime>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <map>
#include <mutex>
#include <random>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "kv/kv_command.h"
#include "kv_bench_lib.h"

#ifndef _WIN32
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace {

using Clock = std::chrono::steady_clock;

struct Args {
    std::vector<std::string> servers{"127.0.0.1:9001", "127.0.0.1:9002", "127.0.0.1:9003"};
    craftkv::bench::BenchConfig config;
    std::string output_json;
    std::string output_csv;
    int timeout_ms = 1000;
    int max_retries = 5;
    bool preload_keys = true;
};

struct RequestSample {
    craftkv::bench::BenchOp op = craftkv::bench::BenchOp::kGet;
    bool success = false;
    std::uint64_t latency_us = 0;
    std::uint64_t retries = 0;
};

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

std::string NowIso8601() {
    auto now = std::chrono::system_clock::now();
    std::time_t time = std::chrono::system_clock::to_time_t(now);
    std::tm tm{};
#ifndef _WIN32
    gmtime_r(&time, &tm);
#else
    gmtime_s(&tm, &time);
#endif
    char buffer[32];
    std::strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &tm);
    return buffer;
}

std::string Hostname() {
#ifndef _WIN32
    char buffer[256];
    if (gethostname(buffer, sizeof(buffer)) == 0) {
        buffer[sizeof(buffer) - 1] = '\0';
        return buffer;
    }
#endif
    return "unknown";
}

std::string BuildType() {
#ifdef NDEBUG
    return "Release";
#else
    return "Debug";
#endif
}

bool SendLine(const std::string& addr,
              const std::string& line,
              int timeout_ms,
              std::string* reply,
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

craftkv::KVOpType ToKVOp(craftkv::bench::BenchOp op) {
    switch (op) {
        case craftkv::bench::BenchOp::kGet:
            return craftkv::KVOpType::kGet;
        case craftkv::bench::BenchOp::kPut:
            return craftkv::KVOpType::kPut;
        case craftkv::bench::BenchOp::kAppend:
            return craftkv::KVOpType::kAppend;
        case craftkv::bench::BenchOp::kDelete:
            return craftkv::KVOpType::kDelete;
    }
    return craftkv::KVOpType::kUnknown;
}

class BenchClient {
public:
    BenchClient(std::vector<std::string> servers, int timeout_ms, int max_retries)
        : servers_(std::move(servers)), timeout_ms_(timeout_ms), max_retries_(max_retries) {}

    bool Send(const craftkv::ClientRequest& request,
              std::uint64_t* retries,
              std::string* last_error) {
        const std::string payload = craftkv::SerializeClientRequest(request);
        for (int attempt = 0; attempt < max_retries_; ++attempt) {
            std::string raw_reply;
            const std::string target = servers_[server_index_ % servers_.size()];
            if (!SendLine(target, payload, timeout_ms_, &raw_reply, last_error)) {
                ++server_index_;
                continue;
            }

            craftkv::KVResponse response;
            std::string parse_error;
            if (!craftkv::DeserializeKVResponse(raw_reply, &response, &parse_error)) {
                *last_error = parse_error;
                ++server_index_;
                continue;
            }

            if (response.error_code == craftkv::KVErrorCode::kNotLeader) {
                *last_error = "not leader";
                if (!response.leader_addr.empty()) {
                    auto it = std::find(servers_.begin(), servers_.end(), response.leader_addr);
                    if (it == servers_.end()) {
                        servers_.insert(servers_.begin(), response.leader_addr);
                        server_index_ = 0;
                    } else {
                        server_index_ = static_cast<std::size_t>(std::distance(servers_.begin(), it));
                    }
                } else {
                    ++server_index_;
                }
                continue;
            }

            if (!response.success) {
                *last_error = craftkv::ToString(response.error_code) + ": " + response.message;
                ++server_index_;
                continue;
            }

            *retries = craftkv::bench::RetryCountForAttempts(attempt + 1);
            return true;
        }
        *retries = craftkv::bench::RetryCountForAttempts(max_retries_);
        return false;
    }

private:
    std::vector<std::string> servers_;
    int timeout_ms_ = 1000;
    int max_retries_ = 5;
    std::size_t server_index_ = 0;
};

void PrintUsage() {
    std::cerr
        << "Usage: kv_bench --servers=a,b,c --threads=4 --duration_seconds=30 --warmup_seconds=5 "
        << "--key_count=1000 --value_size=128 --read_percent=70 --put_percent=20 "
        << "--append_percent=5 --delete_percent=5 --seed=20260604 "
        << "--read_mode=log --max_append_entries_per_rpc=64 --max_inflight_append_entries_per_peer=1 "
        << "--output_json=/tmp/result.json --output_csv=/tmp/result.csv\n";
}

bool ParseArgs(int argc, char** argv, Args* args, std::string* error) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        auto value = [&arg](const std::string& name) {
            return arg.substr(name.size());
        };
        try {
            if (arg.rfind("--servers=", 0) == 0) {
                args->servers = Split(value("--servers="), ',');
            } else if (arg.rfind("--threads=", 0) == 0) {
                args->config.threads = std::stoi(value("--threads="));
            } else if (arg.rfind("--duration_seconds=", 0) == 0) {
                args->config.duration_seconds = std::stoi(value("--duration_seconds="));
            } else if (arg.rfind("--warmup_seconds=", 0) == 0) {
                args->config.warmup_seconds = std::stoi(value("--warmup_seconds="));
            } else if (arg.rfind("--key_count=", 0) == 0) {
                args->config.key_count = std::stoi(value("--key_count="));
            } else if (arg.rfind("--value_size=", 0) == 0) {
                args->config.value_size = std::stoi(value("--value_size="));
            } else if (arg.rfind("--read_percent=", 0) == 0) {
                args->config.mix.read_percent = std::stoi(value("--read_percent="));
            } else if (arg.rfind("--put_percent=", 0) == 0) {
                args->config.mix.put_percent = std::stoi(value("--put_percent="));
            } else if (arg.rfind("--append_percent=", 0) == 0) {
                args->config.mix.append_percent = std::stoi(value("--append_percent="));
            } else if (arg.rfind("--delete_percent=", 0) == 0) {
                args->config.mix.delete_percent = std::stoi(value("--delete_percent="));
            } else if (arg.rfind("--seed=", 0) == 0) {
                args->config.seed = static_cast<std::uint64_t>(std::stoull(value("--seed=")));
            } else if (arg.rfind("--read_mode=", 0) == 0) {
                args->config.read_mode = value("--read_mode=");
            } else if (arg.rfind("--max_append_entries_per_rpc=", 0) == 0) {
                args->config.max_append_entries_per_rpc = std::stoi(value("--max_append_entries_per_rpc="));
            } else if (arg.rfind("--max_inflight_append_entries_per_peer=", 0) == 0) {
                args->config.max_inflight_append_entries_per_peer =
                    std::stoi(value("--max_inflight_append_entries_per_peer="));
            } else if (arg.rfind("--output_json=", 0) == 0) {
                args->output_json = value("--output_json=");
            } else if (arg.rfind("--output_csv=", 0) == 0) {
                args->output_csv = value("--output_csv=");
            } else if (arg.rfind("--timeout_ms=", 0) == 0) {
                args->timeout_ms = std::stoi(value("--timeout_ms="));
            } else if (arg.rfind("--max_retries=", 0) == 0) {
                args->max_retries = std::stoi(value("--max_retries="));
            } else if (arg.rfind("--git_commit=", 0) == 0) {
                args->config.git_commit = value("--git_commit=");
            } else if (arg.rfind("--preload_keys=", 0) == 0) {
                args->preload_keys = value("--preload_keys=") != "0";
            } else {
                *error = "unknown argument: " + arg;
                return false;
            }
        } catch (const std::exception& ex) {
            *error = "invalid argument " + arg + ": " + ex.what();
            return false;
        }
    }

    if (args->servers.empty()) {
        *error = "at least one server is required";
        return false;
    }
    if (args->config.threads <= 0 || args->config.duration_seconds <= 0 || args->config.warmup_seconds < 0 ||
        args->config.key_count <= 0 || args->config.value_size < 0 || args->timeout_ms <= 0 ||
        args->max_retries <= 0) {
        *error = "threads, duration, key_count, timeout, and retries must be positive";
        return false;
    }
    if (args->config.read_mode != "log" && args->config.read_mode != "read_index") {
        *error = "read_mode must be log or read_index";
        return false;
    }
    if (args->config.max_append_entries_per_rpc <= 0 ||
        args->config.max_inflight_append_entries_per_peer != 1) {
        *error = "max_append_entries_per_rpc must be positive and max_inflight_append_entries_per_peer must be 1";
        return false;
    }
    return craftkv::bench::ValidateOperationMix(args->config.mix, error);
}

craftkv::ClientRequest MakeRequest(const std::string& client_id,
                                   std::uint64_t request_id,
                                   craftkv::bench::BenchOp op,
                                   const std::string& key,
                                   const std::string& value) {
    craftkv::ClientRequest request;
    request.client_id = client_id;
    request.request_id = request_id;
    request.op_type = ToKVOp(op);
    request.key = key;
    request.value = value;
    return request;
}

void PreloadKeys(const Args& args) {
    BenchClient client(args.servers, args.timeout_ms, args.max_retries);
    std::mt19937_64 rng(args.config.seed ^ 0xBADC0FFEEULL);
    for (int i = 0; i < args.config.key_count; ++i) {
        std::uint64_t retries = 0;
        std::string error;
        auto request = MakeRequest("kv_bench_preload", static_cast<std::uint64_t>(i + 1), craftkv::bench::BenchOp::kPut,
                                   "key_" + std::to_string(i),
                                   craftkv::bench::GenerateValue(static_cast<std::size_t>(args.config.value_size), &rng));
        client.Send(request, &retries, &error);
    }
}

void WorkerMain(const Args& args,
                int worker_id,
                Clock::time_point warmup_end,
                Clock::time_point run_end,
                std::mutex* samples_mutex,
                std::vector<RequestSample>* samples) {
    BenchClient client(args.servers, args.timeout_ms, args.max_retries);
    std::mt19937_64 rng(args.config.seed ^ (0x9E3779B97F4A7C15ULL + static_cast<std::uint64_t>(worker_id)));
    const std::string client_id = "kv_bench_" + std::to_string(worker_id);
    std::uint64_t request_id = 1;
    std::vector<RequestSample> local_samples;

    while (Clock::now() < run_end) {
        const auto op = craftkv::bench::ChooseOperation(args.config.mix, &rng);
        std::uniform_int_distribution<int> key_dist(0, args.config.key_count - 1);
        std::string key = "key_" + std::to_string(key_dist(rng));
        std::string value = craftkv::bench::GenerateValue(static_cast<std::size_t>(args.config.value_size), &rng);
        craftkv::ClientRequest request = MakeRequest(client_id, request_id++, op, key, value);

        auto start = Clock::now();
        std::uint64_t retries = 0;
        std::string error;
        bool success = client.Send(request, &retries, &error);
        auto end = Clock::now();

        if (start >= warmup_end) {
            auto latency_us =
                static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(end - start).count());
            local_samples.push_back(RequestSample{op, success, latency_us, retries});
        }
    }

    std::lock_guard<std::mutex> lock(*samples_mutex);
    samples->insert(samples->end(), local_samples.begin(), local_samples.end());
}

craftkv::bench::BenchSummary BuildSummary(const Args& args, const std::vector<RequestSample>& samples) {
    craftkv::bench::BenchSummary summary;
    summary.config = args.config;
    summary.total_operations = samples.size();
    std::map<craftkv::bench::BenchOp, std::vector<std::uint64_t>> op_latencies;
    std::vector<std::uint64_t> all_latencies;
    all_latencies.reserve(samples.size());

    for (const auto& sample : samples) {
        auto& op_summary = summary.by_op[sample.op];
        if (sample.success) {
            ++op_summary.success;
            ++summary.successful_operations;
        } else {
            ++op_summary.failed;
            ++summary.failed_operations;
        }
        summary.retry_count += sample.retries;
        all_latencies.push_back(sample.latency_us);
        op_latencies[sample.op].push_back(sample.latency_us);
    }

    double seconds = static_cast<double>(args.config.duration_seconds);
    summary.throughput_ops_per_second = seconds > 0 ? static_cast<double>(summary.successful_operations) / seconds : 0.0;
    summary.latency = craftkv::bench::SummarizeLatencies(std::move(all_latencies));
    for (auto op : {craftkv::bench::BenchOp::kGet, craftkv::bench::BenchOp::kPut, craftkv::bench::BenchOp::kAppend,
                    craftkv::bench::BenchOp::kDelete}) {
        auto& op_summary = summary.by_op[op];
        op_summary.ops_per_second = seconds > 0 ? static_cast<double>(op_summary.success) / seconds : 0.0;
        op_summary.latency = craftkv::bench::SummarizeLatencies(std::move(op_latencies[op]));
    }
    return summary;
}

bool WriteFile(const std::string& path, const std::string& data, std::string* error) {
    std::ofstream out(path);
    if (!out) {
        *error = "failed to open output file: " + path;
        return false;
    }
    out << data;
    if (!out) {
        *error = "failed to write output file: " + path;
        return false;
    }
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    Args args;
    std::string error;
    if (!ParseArgs(argc, argv, &args, &error)) {
        std::cerr << "error: " << error << std::endl;
        PrintUsage();
        return 1;
    }

    args.config.timestamp = NowIso8601();
    args.config.hostname = Hostname();
    args.config.cpu_count = std::thread::hardware_concurrency();
    args.config.build_type = BuildType();

    if (args.preload_keys) {
        PreloadKeys(args);
    }

    const auto now = Clock::now();
    const auto warmup_end = now + std::chrono::seconds(args.config.warmup_seconds);
    const auto run_end = warmup_end + std::chrono::seconds(args.config.duration_seconds);

    std::mutex samples_mutex;
    std::vector<RequestSample> samples;
    std::vector<std::thread> workers;
    workers.reserve(static_cast<std::size_t>(args.config.threads));
    for (int i = 0; i < args.config.threads; ++i) {
        workers.emplace_back(WorkerMain, std::cref(args), i, warmup_end, run_end, &samples_mutex, &samples);
    }
    for (auto& worker : workers) {
        worker.join();
    }

    auto summary = BuildSummary(args, samples);
    std::string json = craftkv::bench::WriteJsonSummary(summary);
    std::string csv = craftkv::bench::WriteCsvHeader() + craftkv::bench::WriteCsvSummary(summary);

    if (!args.output_json.empty() && !WriteFile(args.output_json, json, &error)) {
        std::cerr << "error: " << error << std::endl;
        return 2;
    }
    if (!args.output_csv.empty() && !WriteFile(args.output_csv, csv, &error)) {
        std::cerr << "error: " << error << std::endl;
        return 2;
    }
    if (args.output_json.empty() && args.output_csv.empty()) {
        std::cout << json;
    }
    return summary.successful_operations > 0 ? 0 : 3;
}
