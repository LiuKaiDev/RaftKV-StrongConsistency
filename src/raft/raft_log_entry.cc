#include "raft/raft_log_entry.h"

namespace craft {
namespace {

constexpr char kInternalNoopCommand[] = "\0RAFTKV_INTERNAL\037NOOP\0v1";

}  // namespace

std::string MakeInternalNoopCommand() {
    return std::string(kInternalNoopCommand, sizeof(kInternalNoopCommand) - 1);
}

bool IsInternalNoopCommand(const std::string& command) {
    return command == MakeInternalNoopCommand();
}

}  // namespace craft
