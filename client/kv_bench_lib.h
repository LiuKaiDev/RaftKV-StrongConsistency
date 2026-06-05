#pragma once

#include <cstdint>
#include <map>
#include <random>
#include <string>
#include <vector>

namespace craftkv::bench {

enum class BenchOp {
    kGet,
    kPut,
    kAppend,
    kDelete,
};

struct OperationMix {
    int read_percent = 70;
    int put_percent = 20;
    int append_percent = 5;
    int delete_percent = 5;
};

struct BenchConfig {
    std::string git_commit = "unknown";
    std::string timestamp = "unknown";
    std::string hostname = "unknown";
    unsigned int cpu_count = 0;
    std::string build_type = "unknown";
    std::string read_mode = "log";
    std::uint64_t seed = 20260604;
    int threads = 4;
    int duration_seconds = 30;
    int warmup_seconds = 5;
    int key_count = 1000;
    int value_size = 128;
    int max_append_entries_per_rpc = 64;
    int max_inflight_append_entries_per_peer = 1;
    OperationMix mix;
};

struct LatencySummary {
    std::uint64_t min = 0;
    double avg = 0.0;
    std::uint64_t p50 = 0;
    std::uint64_t p95 = 0;
    std::uint64_t p99 = 0;
    std::uint64_t max = 0;
};

struct OperationSummary {
    std::uint64_t success = 0;
    std::uint64_t failed = 0;
    double ops_per_second = 0.0;
    LatencySummary latency;
};

struct BenchSummary {
    BenchConfig config;
    std::uint64_t total_operations = 0;
    std::uint64_t successful_operations = 0;
    std::uint64_t failed_operations = 0;
    std::uint64_t retry_count = 0;
    double throughput_ops_per_second = 0.0;
    LatencySummary latency;
    std::map<BenchOp, OperationSummary> by_op;
};

std::string ToString(BenchOp op);
bool ValidateOperationMix(const OperationMix& mix, std::string* error_msg = nullptr);
BenchOp ChooseOperation(const OperationMix& mix, std::mt19937_64* rng);
std::vector<BenchOp> GenerateOperationPlan(const OperationMix& mix, std::uint64_t seed, std::size_t count);
std::string GenerateValue(std::size_t value_size, std::mt19937_64* rng);
std::uint64_t RetryCountForAttempts(int attempts);

LatencySummary SummarizeLatencies(std::vector<std::uint64_t> latencies_us);
std::string WriteJsonSummary(const BenchSummary& summary);
std::string WriteCsvHeader();
std::string WriteCsvSummary(const BenchSummary& summary);

}  // namespace craftkv::bench
