# Pion Packages Cross-Language Benchmarks

本文件汇总 `AFK-surf/pion-packages` 中各包与上游参考实现（Rust `--release` / Go / C / Node.js 等）在**同机、同真实输入、严格交替执行且 stdout SHA-256 逐字节一致**前提下的客观头对头基准数据。

所有结果均如实记录领先与落后项，不做选择性展示。

## 测试环境与工具链基线

| 项目 | 版本 / 规格 |
| --- | --- |
| 测试节点 | `tokyo-mac-studio-0` |
| CPU / 内存 | Apple M5 Max (18 cores), 64 GB RAM |
| 操作系统 | macOS 27.0.1 (Build 26A434, `arm64_apple`) |
| Pion (`pionc`) | `0.1.0` (`AFK-surf/pion@b1e4effbfafd94e4f71da4d31c87a83bde34888c`) |
| Rust (`rustc`) | `1.100.0 (0ef1bc386 2026-11-09)` |
| Go (`go`) | `go1.27.3 darwin/arm64` |
| Node.js (`node`) | `v24.22.2` |
| C/C++ (`clang`) | `Apple clang version 21.0.0 (clang-2100.3.34.2)` |
| Python (`python3`) | `Python 3.9.6` |

## 对比方法学

所有基准统一通过 [`scripts/bench_compare.py`](scripts/bench_compare.py) 执行：

1. **严格交替采样**：默认 `--warmup 1 --rounds 5`，每轮按循环移位顺序（如 `[A, B, C]` → `[B, C, A]` → `[C, A, B]`）执行，抵消系统负载与温控漂移。
2. **强制 SHA-256 逐字节一致门禁**：每轮捕获各实现的原始 `stdout` 并计算 SHA-256；若同一实现多次结果不一致、不同实现结果不一致或与 `--expect-sha256` 不符，框架立即非零退出并拒绝产出榜单。
3. **统一指标**：
   - 耗时：以 `time.perf_counter()` 记录墙钟时间，统计 `median`、`min`、`p95`（单位 ms）。
   - 吞吐：按 `--bytes` 计算 `MB/s`（10^6 bytes/s），按 `--ops` 计算 `ns/op`。
   - 峰值 RSS：macOS 通过 `/usr/bin/time -l` 解析 `maximum resident set size`（bytes），Linux 通过 `/usr/bin/time -v` 解析 `Maximum resident set size`（KiB）。
   - 相对倍率：以基线实现中位数为 `1.00x`，`speedup = baseline_median_ms / impl_median_ms`（`> 1.00x` 表示快于基线，`< 1.00x` 表示慢于基线）。

## 基准总榜

| Package | Workload | Input | Implementations | Pion Median | Reference Median | Speedup (vs Ref) | Pion Peak RSS | SHA-256 | Details |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |

*(暂无基准记录，将随 Wave 1+ 各包验收合入。)*
