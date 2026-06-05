#pragma once

#include <string>

namespace craft {

std::string MakeInternalNoopCommand();
bool IsInternalNoopCommand(const std::string& command);

}  // namespace craft
