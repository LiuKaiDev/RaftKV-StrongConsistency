#include <chrono>
#include <iostream>
#include <string>
#include <thread>

#include "common/config.h"
#include "kv/kv_server.h"

namespace {

std::string ParseConfigPath(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        const std::string prefix = "--config=";
        if (arg.rfind(prefix, 0) == 0) {
            return arg.substr(prefix.size());
        }
        if (arg == "--config" && i + 1 < argc) {
            return argv[i + 1];
        }
    }
    return "config/node1.yaml";
}

}  // namespace

int main(int argc, char** argv) {
    std::string config_path = ParseConfigPath(argc, argv);

    craftkv::common::NodeConfig config;
    std::string error;
    if (!craftkv::common::LoadNodeConfig(config_path, &config, &error)) {
        std::cerr << "load config failed: " << error << std::endl;
        return 1;
    }

    std::thread([] { co_sched.Start(0, 0); }).detach();
    spdlog::set_level(spdlog::level::info);

    craftkv::KVServer server(config, config_path);
    if (!server.Start()) {
        std::cerr << "start kv server failed" << std::endl;
        return 1;
    }

    while (true) {
        std::this_thread::sleep_for(std::chrono::hours(24));
    }
}
