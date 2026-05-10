#pragma once

#include <cstdint>
#include <filesystem>
#include <string>

namespace craftkv::storage {

bool EnsureDirectory(const std::filesystem::path& dir, std::string* error_msg = nullptr);
bool EnsureParentDirectory(const std::filesystem::path& file_path, std::string* error_msg = nullptr);

bool ReadFileToString(const std::filesystem::path& file_path, std::string* data, std::string* error_msg = nullptr);
bool WriteStringToFile(const std::filesystem::path& file_path, const std::string& data, std::string* error_msg = nullptr);
bool AtomicWriteStringToFile(const std::filesystem::path& file_path, const std::string& data,
                             std::string* error_msg = nullptr);
bool AppendAndSync(const std::filesystem::path& file_path, const std::string& data, std::string* error_msg = nullptr);
bool FsyncFile(const std::filesystem::path& file_path, std::string* error_msg = nullptr);

uint32_t Checksum32(const std::string& data);

void AppendFixed32(std::string* out, uint32_t value);
void AppendFixed64(std::string* out, uint64_t value);
bool ReadFixed32(const std::string& data, std::size_t* offset, uint32_t* value);
bool ReadFixed64(const std::string& data, std::size_t* offset, uint64_t* value);

}  // namespace craftkv::storage
