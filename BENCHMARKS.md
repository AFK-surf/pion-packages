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

所有数据如实摘录自各包 `packages/<name>/README.md`，均在 `tokyo-mac-studio-0`（Apple M5 Max，`Darwin arm64`）上以 `--warmup 1 --rounds 5` 严格交替采样并通过 stdout SHA-256 逐字节一致校验。`Speedup > 1.00x` 表示 Pion 快于参考实现，`< 1.00x` 表示落后。

| Package | Workload | Input | Pion Median | Reference Median | Speedup (vs Ref) | Pion Peak RSS | Ref Peak RSS | SHA-256 |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `markdown` | CommonMark 0.31.2 `spec.txt` × 12 → HTML | 2,460,323 B | 36.899 ms | 16.917 ms (`rust_pulldown_cmark`) | 0.46x | 32.11 MiB | 13.06 MiB | `110321ab…6da64d4` |
| `markdown` | Mixed GFM corpus → HTML | 2,503,227 B | 51.712 ms | 22.699 ms (`rust_pulldown_cmark`) | 0.44x | 55.31 MiB | 25.81 MiB | `eb0ade91…af7eba3` |
| `texmath` | 500 formulas × 20 → MathML | 10,000 ops | 101.844 ms | 227.652 ms (`node-katex`) | **2.24x** | 3.27 MiB | 68.84 MiB | `7c3c8390…db2e9fa` |
| `mermaid` | 稳态：Parse + canonical JSON（`--iters 50`） | 1,120,750 B × 50 | 45.997 ms | 13,376.880 ms (`node-mermaid`) | **290.82x** | 2.72 MiB | 252.36 MiB | `2f819d7bc0dd394d…` |
| `mermaid` | 稳态：Layered graph layout（`--iters 20`） | 442,380 B × 20 | 27.840 ms | 8,041.165 ms (`node-dagre`) | **288.84x** | 2.88 MiB | 318.91 MiB | `477f544c81534122…` |
| `mermaid` | 冷启动：Parse + canonical JSON（`--iters 1`） | 1,120,750 B | 8.518 ms | 381.285 ms (`node-mermaid`) | **44.76x** | 2.64 MiB | 108.47 MiB | `12ff4e02e48548c4…` |
| `mermaid` | 冷启动：Layered graph layout（`--iters 1`） | 442,380 B | 9.809 ms | 572.356 ms (`node-dagre`) | **58.35x** | 2.88 MiB | 234.11 MiB | `a61c633038f51153…` |
| `time` | RFC 3339 parse + offset shift + format | 200,000 timestamps | 70.775 ms | 45.161 ms (`rust_jiff`) | 0.64x | 22.81 MiB | 7.83 MiB | `1172c154…0585685f` |
| `time` | Civil calendar & epoch computation | 2,000,000 ops | 114.697 ms | 45.971 ms (`rust_jiff`) | 0.40x | 1.69 MiB | 1.73 MiB | `65a54274…72fc5024` |

## 各包明细

### markdown

参考实现：Rust [`pulldown-cmark`](https://github.com/pulldown-cmark/pulldown-cmark) `0.13.1`（`cargo build --release`，`opt-level = 3`，`lto = "thin"`）。详见 [`packages/markdown/README.md`](packages/markdown/README.md)。

**1. CommonMark 0.31.2 `spec.txt` × 12（`2,460,323 B` 输入 → `2,692,692 B` HTML）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_pulldown_cmark` | 16.917 | 15.885 | 17.440 | 145.43 | 13.06 MiB | 1.00x (baseline) |
| `pion_markdown` | 36.899 | 36.655 | 40.525 | 66.68 | 32.11 MiB | 0.46x |

SHA-256：`110321ab0d170585d613698c00eecaf17192fdbedff9f9585e887800d6da64d4`

**2. Mixed GFM corpus（`2,503,227 B` 输入 → `4,976,832 B` HTML）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_pulldown_cmark` | 22.699 | 20.658 | 23.618 | 110.28 | 25.81 MiB | 1.00x (baseline) |
| `pion_markdown` | 51.712 | 49.845 | 56.385 | 48.41 | 55.31 MiB | 0.44x |

SHA-256：`eb0ade9169dfd54fc25a08adb046413fa61bfb44182c6fd0a7310bb8aaf7eba3`

落后项：吞吐约为 Rust 的 44%–46%，峰值 RSS 约 2.1–2.5×。主因是 `Array[Event]` 全量物化与 owned `String` 切片（对比 Rust 零拷贝流式 `CowStr`）、QBE 后端无 SIMD（对比 LLVM `-O3` + `memchr` NEON）、以及块阶段逐行拷贝（详见包 README）。

### texmath

参考实现：[`KaTeX`](https://github.com/KaTeX/KaTeX) `v0.19.1`（Node.js `v24.22.2`，`katex.renderToString(..., { output: "mathml" })`）。详见 [`packages/texmath/README.md`](packages/texmath/README.md)。

**500 条多样公式 × 20 = 10,000 ops → MathML（输出 314,336 B）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `node-katex` | 227.652 | 209.684 | 385.077 | 22765.18 | 68.84 MiB | 1.00x (baseline) |
| `pion-texmath` | 101.844 | 87.906 | 103.650 | 10184.45 | 3.27 MiB | **2.24x** |

SHA-256：`7c3c83901ff427fecac643e702c47cb71e546e8ef1641c429a7b11a57db2e9fa`

### mermaid

参考实现：官方 Node.js [`mermaid`](https://github.com/mermaid-js/mermaid)（配 `linkedom`）与 [`@dagrejs/dagre`](https://github.com/dagrejs/dagre)。详见 [`packages/mermaid/README.md`](packages/mermaid/README.md)。

> 稳态与冷启动两组数据含义不同，请勿混用：**稳态**（`--iters 50/20`）在单进程内重复计算以摊薄进程启动开销，反映纯计算性能；**冷启动**（`--iters 1`）包含一次进程启动（Node.js 运行时加载占大头），仅作 CLI 场景参考。包 README 只记录了 SHA-256 前 16 位十六进制，此处如实照录。

**稳态纯计算**

| Workload | Implementation | Median (ms) | Per pass | Peak RSS | Speedup |
| --- | --- | ---: | ---: | ---: | ---: |
| Parse + canonical JSON（`--iters 50`，6 张图含 320 节点流程图，1,120,750 B） | `node-mermaid` | 13,376.880 | ~267.5 ms | 252.36 MiB | 1.00x (baseline) |
| | `pion-mermaid` | 45.997 | ~0.92 ms | 2.72 MiB | **290.82x** |
| Layered graph layout（`--iters 20`，50 / 200 / 500 节点，1,088 条边含环与长边，442,380 B） | `node-dagre` | 8,041.165 | ~402.1 ms | 318.91 MiB | 1.00x (baseline) |
| | `pion-sugiyama` | 27.840 | ~1.39 ms | 2.88 MiB | **288.84x** |

SHA-256：parse `2f819d7bc0dd394d…`，layout `477f544c81534122…`

**冷启动 CLI（1 次进程启动 + 执行）**

| Workload | Implementation | Median (ms) | Peak RSS | Speedup |
| --- | --- | ---: | ---: | ---: |
| Parse + canonical JSON（`--iters 1`） | `node-mermaid` | 381.285 | 108.47 MiB | 1.00x (baseline) |
| | `pion-mermaid` | 8.518 | 2.64 MiB | **44.76x** |
| Layered graph layout（`--iters 1`） | `node-dagre` | 572.356 | 234.11 MiB | 1.00x (baseline) |
| | `pion-sugiyama` | 9.809 | 2.88 MiB | **58.35x** |

SHA-256：parse `12ff4e02e48548c4…`，layout `a61c633038f51153…`

### time

参考实现：Rust [`jiff`](https://github.com/BurntSushi/jiff) `0.2`（`--release`）与 Go 标准库 `time`（`go1.27.3`）。详见 [`packages/time/README.md`](packages/time/README.md)。

**1. RFC 3339 批量解析 + 偏移换算（+09:00）+ 格式化（200,000 timestamps）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_jiff` | 45.161 | 42.689 | 45.385 | 138.95 | 225.80 | 7.83 MiB | 1.00x (baseline) |
| `go_time` | 54.308 | 51.015 | 59.045 | 115.54 | 271.54 | 24.83 MiB | 0.83x |
| `pion` | 70.775 | 66.448 | 73.976 | 88.66 | 353.87 | 22.81 MiB | 0.64x |

SHA-256：`1172c1540ed9d0bc5f41ddce8a7b6253977063fa640aedc9e5eb82000585685f`

**2. Civil 日历与 epoch 密集计算（2,000,000 ops）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_jiff` | 45.971 | 43.239 | 49.788 | 22.99 | 1.73 MiB | 1.00x (baseline) |
| `go_time` | 80.517 | 76.596 | 84.090 | 40.26 | 4.38 MiB | 0.57x |
| `pion` | 114.697 | 105.852 | 122.772 | 57.35 | 1.69 MiB | 0.40x |

SHA-256：`65a54274c38cb0392b001c91e26123de1ddcff28bddec4044e2e9beb72fc5024`

落后项：Pion 在两项负载上分别为 Rust `jiff` 的 0.64x 与 0.40x，也慢于 Go `time`（Go 相对 `jiff` 为 0.83x / 0.57x）；Civil 负载峰值 RSS 与 `jiff` 持平（1.69 vs 1.73 MiB），RFC 3339 负载约为其 2.9×。
