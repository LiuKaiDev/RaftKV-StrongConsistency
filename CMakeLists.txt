cmake_minimum_required(VERSION 3.16)

project(cRaftKV C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(CRAFTKV_BUILD_RAFT "Build Raft server targets that require gRPC/Protobuf/libgo" ON)
find_package(Threads REQUIRED)

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${PROJECT_SOURCE_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${PROJECT_SOURCE_DIR}/lib)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${PROJECT_SOURCE_DIR}/lib)

include_directories(${PROJECT_SOURCE_DIR}/include)
include_directories(${PROJECT_SOURCE_DIR}/src)
include_directories(${PROJECT_SOURCE_DIR}/src/rpc)

set(COMMON_SRC
  src/common/config.cc
)

set(STORAGE_SRC
  src/storage/file_util.cc
  src/storage/wal.cc
  src/storage/snapshot.cc
)

set(KV_CORE_SRC
  src/kv/kv_command.cc
  src/kv/kv_state_machine.cc
)

add_library(craft_core STATIC
  ${COMMON_SRC}
  ${STORAGE_SRC}
  ${KV_CORE_SRC}
)
target_link_libraries(craft_core PUBLIC Threads::Threads)

add_executable(kv_client client/kv_client.cc)
target_link_libraries(kv_client PRIVATE craft_core)

if(CRAFTKV_BUILD_RAFT)
  include(common.cmake)

  file(GLOB PROTO_INPUT "${PROJECT_SOURCE_DIR}/src/protos/*.proto")
  set(PROTO_OUT_DIR "${PROJECT_SOURCE_DIR}/src/rpc")

  foreach(hw_proto ${PROTO_INPUT})
    get_filename_component(hw_proto_path "${hw_proto}" PATH)
    get_filename_component(base_name_we "${hw_proto}" NAME_WE)
    set(hw_proto_srcs "${PROTO_OUT_DIR}/${base_name_we}.pb.cc")
    set(hw_proto_hdrs "${PROTO_OUT_DIR}/${base_name_we}.pb.h")
    set(hw_grpc_srcs "${PROTO_OUT_DIR}/${base_name_we}.grpc.pb.cc")
    set(hw_grpc_hdrs "${PROTO_OUT_DIR}/${base_name_we}.grpc.pb.h")
    add_custom_command(
      OUTPUT "${hw_proto_srcs}" "${hw_proto_hdrs}" "${hw_grpc_srcs}" "${hw_grpc_hdrs}"
      COMMAND ${_PROTOBUF_PROTOC}
      ARGS --grpc_out "${PROTO_OUT_DIR}"
           --cpp_out "${PROTO_OUT_DIR}"
           -I "${hw_proto_path}"
           --plugin=protoc-gen-grpc="${_GRPC_CPP_PLUGIN_EXECUTABLE}"
           "${hw_proto}"
      DEPENDS "${hw_proto}")
    list(APPEND PROTO_SRCS "${hw_proto_srcs}" "${hw_grpc_srcs}")
    list(APPEND PROTO_HDRS "${hw_proto_hdrs}" "${hw_grpc_hdrs}")
  endforeach()

  file(GLOB RAFT_SRC "${PROJECT_SOURCE_DIR}/src/raft/*.cc")

  add_library(craft STATIC
    ${PROTO_SRCS}
    ${PROTO_HDRS}
    ${RAFT_SRC}
    src/kv/kv_server.cc
  )

  target_link_libraries(craft PUBLIC
    craft_core
    absl::flags
    absl::flags_parse
    ${_REFLECTION}
    ${_GRPC_GRPCPP}
    ${_PROTOBUF_LIBPROTOBUF}
    libgo
    Threads::Threads
  )

  if(UNIX)
    target_link_libraries(craft PUBLIC dl)
  endif()

  add_executable(kv_server server.cc)
  target_link_libraries(kv_server PRIVATE craft)
endif()

enable_testing()

foreach(test_name
    test_kv_state_machine
    test_wal
    test_snapshot
    test_raft_log
    test_restart_replay)
  add_executable(${test_name} tests/${test_name}.cc)
  target_link_libraries(${test_name} PRIVATE craft_core)
  add_test(NAME ${test_name} COMMAND ${test_name})
endforeach()
