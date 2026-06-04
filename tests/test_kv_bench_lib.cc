#include <cassert>
#include <iostream>
#include <random>
#include <string>
#include <vector>

#include "kv_bench_lib.h"

int main() {
    std::vector<std::uint64_t> latencies{100, 10, 50, 30, 20};
    auto summary = craftkv::bench::SummarizeLatencies(latencies);
    assert(summary.min == 10);
    assert(summary.max == 100);
    assert(summary.p50 == 30);
    assert(summary.p95 == 100);
    assert(summary.p99 == 100);
    assert(summary.avg == 42.0);

    craftkv::bench::OperationMix valid_mix{70, 20, 5, 5};
    std::string error;
    assert(craftkv::bench::ValidateOperationMix(valid_mix, &error));
    craftkv::bench::OperationMix invalid_mix{70, 20, 5, 4};
    assert(!craftkv::bench::ValidateOperationMix(invalid_mix, &error));

    auto plan1 = craftkv::bench::GenerateOperationPlan(valid_mix, 20260604, 20);
    auto plan2 = craftkv::bench::GenerateOperationPlan(valid_mix, 20260604, 20);
    assert(plan1 == plan2);
    assert(!plan1.empty());

    std::mt19937_64 rng(123);
    std::string value = craftkv::bench::GenerateValue(32, &rng);
    assert(value.size() == 32);
    assert(craftkv::bench::RetryCountForAttempts(1) == 0);
    assert(craftkv::bench::RetryCountForAttempts(4) == 3);

    craftkv::bench::BenchSummary bench;
    bench.config.git_commit = "abc123";
    bench.config.timestamp = "2026-06-04T00:00:00Z";
    bench.config.hostname = "host";
    bench.config.cpu_count = 2;
    bench.config.build_type = "Release";
    bench.config.read_mode = "read_index";
    bench.config.seed = 20260604;
    bench.config.threads = 2;
    bench.config.duration_seconds = 3;
    bench.config.warmup_seconds = 1;
    bench.config.key_count = 20;
    bench.config.value_size = 32;
    bench.total_operations = 2;
    bench.successful_operations = 2;
    bench.failed_operations = 0;
    bench.retry_count = 1;
    bench.throughput_ops_per_second = 10.5;
    bench.latency = summary;
    bench.by_op[craftkv::bench::BenchOp::kGet].success = 1;
    bench.by_op[craftkv::bench::BenchOp::kGet].latency = summary;
    bench.by_op[craftkv::bench::BenchOp::kPut].success = 1;
    bench.by_op[craftkv::bench::BenchOp::kPut].latency = summary;

    std::string json = craftkv::bench::WriteJsonSummary(bench);
    assert(json.find("\"git_commit\"") != std::string::npos);
    assert(json.find("\"read_mode\": \"read_index\"") != std::string::npos);
    assert(json.find("\"latency_us_p50\"") != std::string::npos);
    assert(json.find("\"get_success\"") != std::string::npos);
    assert(json.find("\"put_latency_us_p99\"") != std::string::npos);

    std::string csv_header = craftkv::bench::WriteCsvHeader();
    std::string csv_row = craftkv::bench::WriteCsvSummary(bench);
    assert(csv_header.find("git_commit") != std::string::npos);
    assert(csv_header.find("read_mode") != std::string::npos);
    assert(csv_header.find("delete_latency_us_p99") != std::string::npos);
    assert(csv_row.find("\"abc123\"") != std::string::npos);
    assert(csv_row.find("\"read_index\"") != std::string::npos);
    assert(csv_row.find("10.500") != std::string::npos);

    std::cout << "test_kv_bench_lib passed" << std::endl;
    return 0;
}
