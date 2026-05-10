#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
BUILD_DIR="${ROOT_DIR}/build"
BUILD_RAFT="${BUILD_RAFT:-ON}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

mkdir -p "${BUILD_DIR}"
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release -DCRAFTKV_BUILD_RAFT="${BUILD_RAFT}"
cmake --build "${BUILD_DIR}" -j"${JOBS}"
ctest --test-dir "${BUILD_DIR}" --output-on-failure
