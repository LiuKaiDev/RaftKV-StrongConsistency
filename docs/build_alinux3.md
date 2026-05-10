# Alibaba Cloud Linux 3 构建说明

目标环境：

- Alibaba Cloud Linux 3.2104 U11 OpenAnolis Edition
- GCC / G++ 10.2.1
- CMake 已安装
- Python 3.6.8

Alibaba Cloud Linux 3 属于 RHEL / CentOS / Fedora 系，本文使用 `yum` 或 `dnf` 作为包管理方案。

## 依赖清单

需要确认以下依赖可用：

- `gcc`
- `g++`
- `cmake`
- `make`
- `protobuf`
- `protoc`
- `grpc_cpp_plugin`
- `gRPC C++`
- `libgo`
- `spdlog`
- `absl`

如果系统仓库版本不可用，建议使用源码安装 gRPC / Protobuf / libgo，并保证 CMake 能找到对应 package。


## 推荐安装方式

先安装基础编译工具：

```bash
sudo dnf install -y gcc gcc-c++ cmake make git pkgconf-pkg-config openssl-devel zlib-devel
```

如果仓库里提供 Protobuf/gRPC 开发包，可以优先使用系统包；如果版本过旧或缺少 `gRPCConfig.cmake`，建议从源码安装 Protobuf/gRPC，并通过 `CMAKE_PREFIX_PATH` 指向安装目录。示例：

```bash
export CMAKE_PREFIX_PATH=/usr/local:$CMAKE_PREFIX_PATH
```

`libgo` 通常需要按其项目说明源码编译安装。安装完成后请确认头文件和库能被编译器/链接器找到。

注意：本文以 Alibaba Cloud Linux / RHEL 系为目标，不使用 `apt` 或 `apt-get`。

## Core Tests 构建

core tests 不依赖 gRPC / libgo，适合先验证 KV、WAL、Snapshot、重启 replay：

```bash
BUILD_RAFT=OFF bash scripts/build.sh
```

## 完整构建

依赖齐全后构建 server、client 和 tests：

```bash
bash scripts/build.sh
```

如果 CMake 找不到 gRPC / Protobuf，优先检查：

```bash
which protoc
which grpc_cpp_plugin
cmake --version
g++ --version
```

## 启动三节点

```bash
scripts/start_cluster.sh
```

默认端口：

- Raft RPC：`8001`、`8002`、`8003`
- KV Client：`9001`、`9002`、`9003`

## 客户端验证

```bash
./bin/kv_client put name chaos
./bin/kv_client get name
./bin/kv_client append name _raft
./bin/kv_client get name
./bin/kv_client delete name
```

## 常见问题

### CMake 找不到 gRPC

确认 gRPC 安装后是否提供 CMake config，并设置 `CMAKE_PREFIX_PATH` 指向安装目录。

### 找不到 libgo

确认 libgo 已编译安装，且库文件可被链接器找到。也可以在 CMake 中显式配置库路径。

### Python 版本较旧

Python 3.6.8 足够运行基础脚本。本项目脚本主要使用 Bash，不依赖 Python 新特性。
