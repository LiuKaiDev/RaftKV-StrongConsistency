#include "storage/file_util.h"

#include <cerrno>
#include <cstring>
#include <fstream>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <sys/stat.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

namespace craftkv::storage {

bool EnsureDirectory(const std::filesystem::path& dir, std::string* error_msg) {
    std::error_code ec;
    if (dir.empty()) {
        return true;
    }
    if (std::filesystem::exists(dir, ec)) {
        return std::filesystem::is_directory(dir, ec);
    }
    if (!std::filesystem::create_directories(dir, ec) && ec) {
        if (error_msg != nullptr) {
            *error_msg = ec.message();
        }
        return false;
    }
    return true;
}

bool EnsureParentDirectory(const std::filesystem::path& file_path, std::string* error_msg) {
    return EnsureDirectory(file_path.parent_path(), error_msg);
}

bool ReadFileToString(const std::filesystem::path& file_path, std::string* data, std::string* error_msg) {
    data->clear();
    std::ifstream input(file_path, std::ios::binary);
    if (!input) {
        if (std::filesystem::exists(file_path)) {
            if (error_msg != nullptr) {
                *error_msg = "failed to open file: " + file_path.string();
            }
            return false;
        }
        return true;
    }
    data->assign(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
    return true;
}

bool WriteStringToFile(const std::filesystem::path& file_path, const std::string& data, std::string* error_msg) {
    if (!EnsureParentDirectory(file_path, error_msg)) {
        return false;
    }
    std::ofstream output(file_path, std::ios::binary | std::ios::trunc);
    if (!output) {
        if (error_msg != nullptr) {
            *error_msg = "failed to open file for write: " + file_path.string();
        }
        return false;
    }
    output.write(data.data(), static_cast<std::streamsize>(data.size()));
    if (!output.good()) {
        if (error_msg != nullptr) {
            *error_msg = "failed to write file: " + file_path.string();
        }
        return false;
    }
    output.flush();
    return output.good();
}

bool AtomicWriteStringToFile(const std::filesystem::path& file_path, const std::string& data, std::string* error_msg) {
    if (!EnsureParentDirectory(file_path, error_msg)) {
        return false;
    }
    std::filesystem::path tmp_path = file_path;
    tmp_path += ".tmp";
    if (!WriteStringToFile(tmp_path, data, error_msg)) {
        return false;
    }
    if (!FsyncFile(tmp_path, error_msg)) {
        return false;
    }
    std::error_code ec;
    std::filesystem::rename(tmp_path, file_path, ec);
    if (!ec) {
        return true;
    }
    std::filesystem::remove(file_path, ec);
    ec.clear();
    std::filesystem::rename(tmp_path, file_path, ec);
    if (ec) {
        if (error_msg != nullptr) {
            *error_msg = ec.message();
        }
        return false;
    }
    return FsyncFile(file_path, error_msg);
}

bool AppendAndSync(const std::filesystem::path& file_path, const std::string& data, std::string* error_msg) {
    if (!EnsureParentDirectory(file_path, error_msg)) {
        return false;
    }
    std::ofstream output(file_path, std::ios::binary | std::ios::app);
    if (!output) {
        if (error_msg != nullptr) {
            *error_msg = "failed to open file for append: " + file_path.string();
        }
        return false;
    }
    output.write(data.data(), static_cast<std::streamsize>(data.size()));
    output.flush();
    if (!output.good()) {
        if (error_msg != nullptr) {
            *error_msg = "failed to append file: " + file_path.string();
        }
        return false;
    }
    output.close();
    return FsyncFile(file_path, error_msg);
}

bool FsyncFile(const std::filesystem::path& file_path, std::string* error_msg) {
#ifdef _WIN32
    int fd = _open(file_path.string().c_str(), _O_RDWR | _O_CREAT | _O_BINARY, _S_IREAD | _S_IWRITE);
    if (fd < 0) {
        if (error_msg != nullptr) {
            *error_msg = "failed to open file for sync: " + file_path.string();
        }
        return false;
    }
    int rc = _commit(fd);
    _close(fd);
    if (rc != 0) {
        if (error_msg != nullptr) {
            *error_msg = "failed to sync file: " + file_path.string();
        }
        return false;
    }
    return true;
#else
    int fd = open(file_path.string().c_str(), O_RDWR | O_CREAT, 0644);
    if (fd < 0) {
        if (error_msg != nullptr) {
            *error_msg = "failed to open file for sync: " + file_path.string() + ": " + std::strerror(errno);
        }
        return false;
    }
#ifdef __linux__
    int rc = fdatasync(fd);
#else
    int rc = fsync(fd);
#endif
    int close_rc = close(fd);
    if (rc != 0 || close_rc != 0) {
        if (error_msg != nullptr) {
            *error_msg = "failed to sync file: " + file_path.string() + ": " + std::strerror(errno);
        }
        return false;
    }
    return true;
#endif
}

uint32_t Checksum32(const std::string& data) {
    uint32_t hash = 2166136261u;
    for (unsigned char ch : data) {
        hash ^= ch;
        hash *= 16777619u;
    }
    return hash;
}

void AppendFixed32(std::string* out, uint32_t value) {
    for (int i = 0; i < 4; ++i) {
        out->push_back(static_cast<char>((value >> (i * 8)) & 0xff));
    }
}

void AppendFixed64(std::string* out, uint64_t value) {
    for (int i = 0; i < 8; ++i) {
        out->push_back(static_cast<char>((value >> (i * 8)) & 0xff));
    }
}

bool ReadFixed32(const std::string& data, std::size_t* offset, uint32_t* value) {
    if (*offset + 4 > data.size()) {
        return false;
    }
    uint32_t result = 0;
    for (int i = 0; i < 4; ++i) {
        result |= static_cast<uint32_t>(static_cast<unsigned char>(data[*offset + i])) << (i * 8);
    }
    *offset += 4;
    *value = result;
    return true;
}

bool ReadFixed64(const std::string& data, std::size_t* offset, uint64_t* value) {
    if (*offset + 8 > data.size()) {
        return false;
    }
    uint64_t result = 0;
    for (int i = 0; i < 8; ++i) {
        result |= static_cast<uint64_t>(static_cast<unsigned char>(data[*offset + i])) << (i * 8);
    }
    *offset += 8;
    *value = result;
    return true;
}

}  // namespace craftkv::storage
