# Proto Directory

The active Raft proto used by CMake is `src/protos/raft.proto`.

This project currently exposes the KV client API through a lightweight TCP client protocol in `client/kv_client.cc` and `src/kv/kv_server.cc`, so there is no generated KV gRPC proto in the build.

The root `proto/` directory is kept only for future public API drafts to avoid confusing it with the active generated-code flow.
