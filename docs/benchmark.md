# Benchmark

运行方式：

```bash
scripts/benchmark.sh put 1000
scripts/benchmark.sh get 1000
scripts/benchmark.sh mixed 1000
```

指标：

- QPS
- 平均延迟
- P99 延迟
- 成功请求数
- 失败请求数
- leader 切换期间不可用时间

当前脚本会输出前五项。leader 切换期间不可用时间还没有自动采集，后续可以在客户端 SDK 中记录从首次 `NOT_LEADER` 或连接失败到下一次成功写入之间的窗口。

注意：当前 `Get` 也走 Raft 日志，因此读性能不是优化目标。后续引入 ReadIndex / Lease Read 后，读 QPS 会明显提升。
