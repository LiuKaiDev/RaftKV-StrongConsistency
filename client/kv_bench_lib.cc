#include "kv_bench_lib.h"

#include <algorithm>
#include <iomanip>
#include <numeric>
#include <sstream>

namespace craftkv::bench {
namespace {

std::uint64_t Percentile(const std::vector<std::uint64_t>& sorted, double percentile) {
    if (sorted.empty()) {
        return 0;
    }
    double rank = percentile * static_cast<double>(sorted.size() - 1);
    return sorted[static_cast<std::size_t>(rank + 0.5)];
}

std::string JsonEscape(const std::string& value) {
    std::ostringstream out;
    for (char ch : value) {
        switch (ch) {
            case '\\':
                out << "\\\\";
                break;
            case '"':
                out << "\\\"";
                break;
            case '\n':
                out << "\\n";
                break;
            case '\r':
                out << "\\r";
                break;
            case '\t':
                out << "\\t";
                break;
            default:
                out << ch;
                break;
        }
    }
    return out.str();
}

void AppendJsonString(std::ostringstream* out, const std::string& key, const std::string& value, bool comma = true) {
    *out << "  \"" << key << "\": \"" << JsonEscape(value) << "\"";
    if (comma) {
        *out << ",";
    }
    *out << "\n";
}

void AppendJsonUint(std::ostringstream* out, const std::string& key, std::uint64_t value, bool comma = true) {
    *out << "  \"" << key << "\": " << value;
    if (comma) {
        *out << ",";
    }
    *out << "\n";
}

void AppendJsonDouble(std::ostringstream* out, const std::string& key, double value, bool comma = true) {
    *out << "  \"" << key << "\": " << std::fixed << std::setprecision(3) << value;
    if (comma) {
        *out << ",";
    }
    *out << "\n";
}

const OperationSummary& SummaryFor(const BenchSummary& summary, BenchOp op) {
    static const OperationSummary empty;
    auto it = summary.by_op.find(op);
    if (it == summary.by_op.end()) {
        return empty;
    }
    return it->second;
}

void AppendOpJson(std::ostringstream* out, const std::string& prefix, const OperationSummary& summary) {
    AppendJsonUint(out, prefix + "_success", summary.success);
    AppendJsonUint(out, prefix + "_failed", summary.failed);
    AppendJsonDouble(out, prefix + "_ops_per_second", summary.ops_per_second);
    AppendJsonUint(out, prefix + "_latency_us_p50", summary.latency.p50);
    AppendJsonUint(out, prefix + "_latency_us_p95", summary.latency.p95);
    AppendJsonUint(out, prefix + "_latency_us_p99", summary.latency.p99);
}

void AppendCsvValue(std::ostringstream* out, const std::string& value) {
    *out << '"';
    for (char ch : value) {
        if (ch == '"') {
            *out << "\"\"";
        } else {
            *out << ch;
        }
    }
    *out << '"';
}

}  // namespace

std::string ToString(BenchOp op) {
    switch (op) {
        case BenchOp::kGet:
            return "get";
        case BenchOp::kPut:
            return "put";
        case BenchOp::kAppend:
            return "append";
        case BenchOp::kDelete:
            return "delete";
    }
    return "unknown";
}

bool ValidateOperationMix(const OperationMix& mix, std::string* error_msg) {
    if (mix.read_percent < 0 || mix.put_percent < 0 || mix.append_percent < 0 || mix.delete_percent < 0) {
        if (error_msg != nullptr) {
            *error_msg = "operation percentages must be non-negative";
        }
        return false;
    }
    int total = mix.read_percent + mix.put_percent + mix.append_percent + mix.delete_percent;
    if (total != 100) {
        if (error_msg != nullptr) {
            *error_msg = "operation percentages must sum to 100";
        }
        return false;
    }
    return true;
}

BenchOp ChooseOperation(const OperationMix& mix, std::mt19937_64* rng) {
    std::uniform_int_distribution<int> dist(1, 100);
    int value = dist(*rng);
    if (value <= mix.read_percent) {
        return BenchOp::kGet;
    }
    value -= mix.read_percent;
    if (value <= mix.put_percent) {
        return BenchOp::kPut;
    }
    value -= mix.put_percent;
    if (value <= mix.append_percent) {
        return BenchOp::kAppend;
    }
    return BenchOp::kDelete;
}

std::vector<BenchOp> GenerateOperationPlan(const OperationMix& mix, std::uint64_t seed, std::size_t count) {
    std::mt19937_64 rng(seed);
    std::vector<BenchOp> plan;
    plan.reserve(count);
    for (std::size_t i = 0; i < count; ++i) {
        plan.push_back(ChooseOperation(mix, &rng));
    }
    return plan;
}

std::string GenerateValue(std::size_t value_size, std::mt19937_64* rng) {
    static constexpr char kAlphabet[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    std::uniform_int_distribution<std::size_t> dist(0, sizeof(kAlphabet) - 2);
    std::string value;
    value.reserve(value_size);
    for (std::size_t i = 0; i < value_size; ++i) {
        value.push_back(kAlphabet[dist(*rng)]);
    }
    return value;
}

std::uint64_t RetryCountForAttempts(int attempts) {
    return attempts > 0 ? static_cast<std::uint64_t>(attempts - 1) : 0;
}

LatencySummary SummarizeLatencies(std::vector<std::uint64_t> latencies_us) {
    LatencySummary summary;
    if (latencies_us.empty()) {
        return summary;
    }
    std::sort(latencies_us.begin(), latencies_us.end());
    summary.min = latencies_us.front();
    summary.max = latencies_us.back();
    std::uint64_t total = std::accumulate(latencies_us.begin(), latencies_us.end(), std::uint64_t{0});
    summary.avg = static_cast<double>(total) / static_cast<double>(latencies_us.size());
    summary.p50 = Percentile(latencies_us, 0.50);
    summary.p95 = Percentile(latencies_us, 0.95);
    summary.p99 = Percentile(latencies_us, 0.99);
    return summary;
}

std::string WriteJsonSummary(const BenchSummary& summary) {
    std::ostringstream out;
    const auto& config = summary.config;
    out << "{\n";
    AppendJsonString(&out, "git_commit", config.git_commit);
    AppendJsonString(&out, "timestamp", config.timestamp);
    AppendJsonString(&out, "hostname", config.hostname);
    AppendJsonUint(&out, "cpu_count", config.cpu_count);
    AppendJsonString(&out, "build_type", config.build_type);
    AppendJsonString(&out, "read_mode", config.read_mode);
    AppendJsonUint(&out, "seed", config.seed);
    AppendJsonUint(&out, "threads", config.threads);
    AppendJsonUint(&out, "duration_seconds", config.duration_seconds);
    AppendJsonUint(&out, "warmup_seconds", config.warmup_seconds);
    AppendJsonUint(&out, "key_count", config.key_count);
    AppendJsonUint(&out, "value_size", config.value_size);
    AppendJsonUint(&out, "max_append_entries_per_rpc", config.max_append_entries_per_rpc);
    AppendJsonUint(&out, "max_inflight_append_entries_per_peer",
                   config.max_inflight_append_entries_per_peer);
    AppendJsonUint(&out, "read_percent", config.mix.read_percent);
    AppendJsonUint(&out, "put_percent", config.mix.put_percent);
    AppendJsonUint(&out, "append_percent", config.mix.append_percent);
    AppendJsonUint(&out, "delete_percent", config.mix.delete_percent);
    AppendJsonUint(&out, "total_operations", summary.total_operations);
    AppendJsonUint(&out, "successful_operations", summary.successful_operations);
    AppendJsonUint(&out, "failed_operations", summary.failed_operations);
    AppendJsonUint(&out, "retry_count", summary.retry_count);
    AppendJsonDouble(&out, "throughput_ops_per_second", summary.throughput_ops_per_second);
    AppendJsonUint(&out, "latency_us_min", summary.latency.min);
    AppendJsonDouble(&out, "latency_us_avg", summary.latency.avg);
    AppendJsonUint(&out, "latency_us_p50", summary.latency.p50);
    AppendJsonUint(&out, "latency_us_p95", summary.latency.p95);
    AppendJsonUint(&out, "latency_us_p99", summary.latency.p99);
    AppendJsonUint(&out, "latency_us_max", summary.latency.max);
    AppendOpJson(&out, "get", SummaryFor(summary, BenchOp::kGet));
    AppendOpJson(&out, "put", SummaryFor(summary, BenchOp::kPut));
    AppendOpJson(&out, "append", SummaryFor(summary, BenchOp::kAppend));
    AppendOpJson(&out, "delete", SummaryFor(summary, BenchOp::kDelete));
    out.seekp(-2, std::ios_base::end);
    out << "\n}\n";
    return out.str();
}

std::string WriteCsvHeader() {
    return "git_commit,timestamp,hostname,cpu_count,build_type,read_mode,seed,threads,duration_seconds,warmup_seconds,"
           "key_count,value_size,max_append_entries_per_rpc,max_inflight_append_entries_per_peer,"
           "read_percent,put_percent,append_percent,delete_percent,total_operations,"
           "successful_operations,failed_operations,retry_count,throughput_ops_per_second,latency_us_min,"
           "latency_us_avg,latency_us_p50,latency_us_p95,latency_us_p99,latency_us_max,get_success,"
           "get_failed,get_ops_per_second,get_latency_us_p50,get_latency_us_p95,get_latency_us_p99,"
           "put_success,put_failed,put_ops_per_second,put_latency_us_p50,put_latency_us_p95,"
           "put_latency_us_p99,append_success,append_failed,append_ops_per_second,append_latency_us_p50,"
           "append_latency_us_p95,append_latency_us_p99,delete_success,delete_failed,delete_ops_per_second,"
           "delete_latency_us_p50,delete_latency_us_p95,delete_latency_us_p99\n";
}

std::string WriteCsvSummary(const BenchSummary& summary) {
    std::ostringstream out;
    const auto& config = summary.config;
    const auto& get = SummaryFor(summary, BenchOp::kGet);
    const auto& put = SummaryFor(summary, BenchOp::kPut);
    const auto& append = SummaryFor(summary, BenchOp::kAppend);
    const auto& del = SummaryFor(summary, BenchOp::kDelete);
    AppendCsvValue(&out, config.git_commit);
    out << ',';
    AppendCsvValue(&out, config.timestamp);
    out << ',';
    AppendCsvValue(&out, config.hostname);
    out << ',' << config.cpu_count << ',';
    AppendCsvValue(&out, config.build_type);
    out << ',';
    AppendCsvValue(&out, config.read_mode);
    out << ',' << config.seed << ',' << config.threads << ',' << config.duration_seconds << ','
        << config.warmup_seconds << ',' << config.key_count << ',' << config.value_size << ','
        << config.max_append_entries_per_rpc << ',' << config.max_inflight_append_entries_per_peer << ','
        << config.mix.read_percent << ',' << config.mix.put_percent << ',' << config.mix.append_percent << ','
        << config.mix.delete_percent << ',' << summary.total_operations << ',' << summary.successful_operations << ','
        << summary.failed_operations << ',' << summary.retry_count << ',' << std::fixed << std::setprecision(3)
        << summary.throughput_ops_per_second << ',' << summary.latency.min << ',' << summary.latency.avg << ','
        << summary.latency.p50 << ',' << summary.latency.p95 << ',' << summary.latency.p99 << ','
        << summary.latency.max << ',' << get.success << ',' << get.failed << ',' << get.ops_per_second << ','
        << get.latency.p50 << ',' << get.latency.p95 << ',' << get.latency.p99 << ',' << put.success << ','
        << put.failed << ',' << put.ops_per_second << ',' << put.latency.p50 << ',' << put.latency.p95 << ','
        << put.latency.p99 << ',' << append.success << ',' << append.failed << ',' << append.ops_per_second << ','
        << append.latency.p50 << ',' << append.latency.p95 << ',' << append.latency.p99 << ',' << del.success << ','
        << del.failed << ',' << del.ops_per_second << ',' << del.latency.p50 << ',' << del.latency.p95 << ','
        << del.latency.p99 << '\n';
    return out.str();
}

}  // namespace craftkv::bench
