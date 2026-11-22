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
| `mermaid` | 稳态：Parse + canonical JSON（`--iters 50`） | 22,415 B × 50 (1.12 MB) | 45.997 ms | 13,376.880 ms (`node-mermaid`) | **290.82x** | 2.72 MiB | 252.36 MiB | `2f819d7bc0dd394d…` |
| `mermaid` | 稳态：Layered graph layout（`--iters 20`） | 22,119 B × 20 (442 KB) | 27.840 ms | 8,041.165 ms (`node-dagre`) | **288.84x** | 2.88 MiB | 318.91 MiB | `477f544c81534122…` |
| `mermaid` | 冷启动：Parse + canonical JSON（`--iters 1`） | 22,415 B | 8.518 ms | 381.285 ms (`node-mermaid`) | **44.76x** | 2.64 MiB | 108.47 MiB | `12ff4e02e48548c4…` |
| `mermaid` | 冷启动：Layered graph layout（`--iters 1`） | 22,119 B | 9.809 ms | 572.356 ms (`node-dagre`) | **58.35x** | 2.88 MiB | 234.11 MiB | `a61c633038f51153…` |
| `time` | RFC 3339 parse + offset shift + format | 200,000 timestamps | 70.775 ms | 45.161 ms (`rust_jiff`) | 0.64x | 22.81 MiB | 7.83 MiB | `1172c154…0585685f` |
| `time` | Civil calendar & epoch computation | 2,000,000 ops | 114.697 ms | 45.971 ms (`rust_jiff`) | 0.40x | 1.69 MiB | 1.73 MiB | `65a54274…72fc5024` |
| `toml` | TOML v1.0.0 workspace/service config parse（`× 50`） | 150.5 KB × 50 (7,526,500 B) | 119.644 ms | 178.392 ms (`rust_toml`) | **1.49x** | 4.56 MiB | 7.45 MiB | `96cf0bf395d107be…` |
| `yaml` | K8s / GitHub Actions / OpenAPI 多文档 parse + canonical JSON | 3,002,682 B (2,037 docs) | 133.488 ms | 119.183 ms (`rust_yaml_rust2`) | 0.89x | 33.95 MiB | 39.34 MiB | `d57e15ae…f449b633` |
| `diff` | Histogram + indent slider + unified diff（10,029 行 × 50） | 32.4 MB | 115.493 ms | 30.316 ms (`rust-imara-diff`) | 0.26x | 4.44 MiB | 3.39 MiB | `fe0936ea…45a7b906` |
| `diff` | Myers + indent slider + unified diff（10,029 行 × 30） | 19.4 MB | 174.831 ms | 96.955 ms (`rust-imara-diff`) | 0.55x | 5.00 MiB | 4.03 MiB | `a61a0400…c1a2f038` |
| `diff` | `helix_syntax.rs` Histogram + unified diff（2,200 行 × 200） | 32.2 MB | 83.214 ms | 26.269 ms (`rust-imara-diff`) | 0.32x | 2.73 MiB | 2.39 MiB | `586c482f…c70e33f8` |
| `cbor` | Deterministic batch encode（WebAuthn/COSE + Telemetry） | 50,000 ops | 138.962 ms | 120.254 ms (`go_fxamacker`) | 0.87x | 1.78 MiB | 12.33 MiB | `b14fb8d5…a7b61e0b` |
| `cbor` | Batch decode + tree walk（WebAuthn/COSE + Telemetry） | 23,508,920 B (80,000 ops) | 149.661 ms | 169.493 ms (`go_fxamacker`) | **1.13x** | 9.19 MiB | 24.97 MiB | `3e192925…05a48ece` |
| `crdt` | 顺序 + 随机文本编辑 + Yjs v1 编解码（20,000 ops × 10） | 200,000 ops | 1,926.438 ms | 6,750.219 ms (`node_yjs`) | **3.50x** | 15.48 MiB | 246.91 MiB | `0ed09d22…e4e0423f` |
| `crdt` | 双端并发 Text+Array+Map 混合编辑 + 增量 v1 同步（2 × 5,000 ops × 10） | 100,000 ops | 255.262 ms | 1,254.732 ms (`node_yjs`) | **4.92x** | 8.05 MiB | 226.08 MiB | `32c9ec44…1889b8b1` |
| `highlight` | 9 语言源码高亮 + 无损重建（37,800 B × 220） | 8,316,000 B | 112.973 ms | 1,354.656 ms (`node-prismjs`) | **11.99x** | 2.31 MiB | 87.48 MiB | `1fec95f5…5eceeb80` |
| `glob` | 50,000 monorepo 路径 × 80 条 `GlobSet` 规则 × 20（`matches_into`） | 1,000,000 calls | 123.861 ms | 307.405 ms (`rust_globset`) | **2.48x** | 8.23 MiB | 5.86 MiB | `2d9a2ef2…496fe91f` |
| `websocket` | 50,000 掩码客户端帧批量编码 + 流式解码（解掩码、分片重组、严格 UTF-8） | ~50.88 MB | 131.212 ms | 76.104 ms (`rust_tungstenite`) | 0.58x | 1.98 MiB | 2.23 MiB | `7830282b…7e349c92` |
| `websocket` | 同上（对照 Go） | ~50.88 MB | 131.212 ms | 136.798 ms (`go_coder_ws`) | **1.04x** | 1.98 MiB | 16.95 MiB | `7830282b…7e349c92` |

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

### toml

参考实现：Rust [`toml`](https://crates.io/crates/toml) `0.8`（`--release`）与 Go [`BurntSushi/toml`](https://github.com/BurntSushi/toml) `v1.4.0`。合规性来自官方 [`toml-lang/toml-test`](https://github.com/toml-lang/toml-test) `v1.0.0`。详见 [`packages/toml/README.md`](packages/toml/README.md)。

**稳态解析：150.5 KB 真实 TOML v1.0.0 workspace / service 配置语料 × 50（`7,526,500 B` 输入，stdout `203 B`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_toml` | 178.392 | 158.839 | 184.359 | 42.19 | 3567831.66 | 7.45 MiB | 1.00x (baseline) |
| `go_burntsushi` | 288.358 | 273.687 | 299.497 | 26.10 | 5767160.84 | 13.50 MiB | 0.62x |
| `pion` | 119.644 | 102.283 | 130.105 | 62.91 | 2392885.00 | 4.56 MiB | **1.49x** |

SHA-256：包 README 只记录了前 16 位十六进制 `96cf0bf395d107be…`，此处如实照录。

### yaml

参考实现：Rust [`yaml-rust2`](https://github.com/Ethiraric/yaml-rust2) `0.10.4`（`--release`）与 Go [`gopkg.in/yaml.v3`](https://github.com/go-yaml/yaml) `v3.0.1`。合规性来自官方 [`yaml/yaml-test-suite`](https://github.com/yaml/yaml-test-suite)。详见 [`packages/yaml/README.md`](packages/yaml/README.md)。

**多文档 parse + 规范化有序键 JSON：3.00 MB 真实语料（`3,002,682 B`，2,037 篇 K8s Deployment / GitHub Actions / OpenAPI 3.1，stdout `2,234,058 B`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_yaml_rust2` | 119.183 | 82.868 | 196.088 | 25.19 | 39.34 MiB | 1.00x (baseline) |
| `go_yaml_v3` | 126.812 | 118.331 | 148.825 | 23.68 | 20.94 MiB | 0.94x |
| `pion_yaml` | 133.488 | 126.385 | 208.556 | 22.49 | 33.95 MiB | 0.89x |

SHA-256：`d57e15ae46b8deb701bd42730f7d034287f48e4e7736d1e71249e80df449b633`

落后项：Pion 为 `yaml-rust2` 的 0.89x，也略慢于 Go `yaml.v3`（0.94x）；峰值 RSS 低于 Rust（33.95 vs 39.34 MiB），但高于 Go（20.94 MiB）。

### diff

参考实现：Rust [`imara-diff`](https://github.com/pascalkuthe/imara-diff) `v0.2.0`（`--release`）。详见 [`packages/diff/README.md`](packages/diff/README.md)。

**1. Histogram diff + indent slider + unified diff（10,029 行重构 × 50，32.4 MB 输入，stdout `67,406 B`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust-imara-diff` | 30.316 | 30.020 | 32.131 | 1068.23 | 3.39 MiB | 1.00x (baseline) |
| `pion` | 115.493 | 113.648 | 121.808 | 280.40 | 4.44 MiB | 0.26x |

SHA-256：`fe0936eaa06404b6d49c707348a6790ff1234d4d3e27f14cc86d325d45a7b906`

**2. Myers diff + indent slider + unified diff（10,029 行重构 × 30，19.4 MB 输入，stdout `238,918 B`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust-imara-diff` | 96.955 | 82.300 | 108.232 | 200.41 | 4.03 MiB | 1.00x (baseline) |
| `pion` | 174.831 | 164.568 | 203.590 | 111.14 | 5.00 MiB | 0.55x |

SHA-256：`a61a0400fdf2028988aac61e9e10d5ee97136d733d2dcb02bbd6a572c1a2f038`

**3. 真实文件 `helix_syntax.rs` Histogram + unified diff（2,200 行 × 200，32.2 MB 输入，stdout `7,131 B`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust-imara-diff` | 26.269 | 24.617 | 27.731 | 1224.62 | 2.39 MiB | 1.00x (baseline) |
| `pion` | 83.214 | 83.037 | 87.081 | 386.59 | 2.73 MiB | 0.32x |

SHA-256：`586c482f0fd9d4a787fbc561f69095e8395a2990128debd8d13230fcc70e33f8`

落后项：三项负载 Pion 均落后，为 `imara-diff` 的 0.26x / 0.55x / 0.32x，峰值 RSS 高约 14%–31%。包 README 归因于 Rust 侧 SIMD `memchr`、`foldhash` 与 LLVM `-O3` + LTO；unified diff 输出逐字节一致。

### cbor

参考实现：Go [`fxamacker/cbor/v2`](https://github.com/fxamacker/cbor) `v2.9.0`（基线）与 Rust [`ciborium`](https://github.com/enarx/ciborium) `0.2`（`--release`）。详见 [`packages/cbor/README.md`](packages/cbor/README.md)。

**1. 确定性批量编码（50,000 条 WebAuthn/COSE + Telemetry，stdout `58 B`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `go_fxamacker` | 120.254 | 115.331 | 141.477 | 2405.08 | 12.33 MiB | 1.00x (baseline) |
| `rust_ciborium` | 85.764 | 84.385 | 87.391 | 1715.29 | 2.06 MiB | 1.40x |
| `pion` | 138.962 | 137.165 | 153.740 | 2779.23 | 1.78 MiB | 0.87x |

SHA-256：`b14fb8d50078493f9c8c4349e6dd969f3289721f95fe1cc96f1cda48a7b61e0b`

**2. 批量解码 + 树遍历（80,000 条，`23,508,920 B` 输入，stdout `67 B`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `go_fxamacker` | 169.493 | 142.346 | 221.261 | 138.70 | 2118.67 | 24.97 MiB | 1.00x (baseline) |
| `rust_ciborium` | 139.573 | 127.944 | 159.863 | 168.43 | 1744.67 | 6.72 MiB | 1.21x |
| `pion` | 149.661 | 139.664 | 159.145 | 157.08 | 1870.76 | 9.19 MiB | **1.13x** |

SHA-256：`3e1929251b4f124f4f35012b86df7c3b1ad83579b233cee32aacc5fb05a48ece`

落后项：编码 Pion 为 Go 的 0.87x，落后 Rust `ciborium`（1.40x）约 38%；解码 Pion 快于 Go（1.13x）但仍慢于 `ciborium`（1.21x，约 7%）。峰值 RSS 编码最低（1.78 MiB），解码高于 `ciborium`（9.19 vs 6.72 MiB）。

### crdt

参考实现：Node.js 官方 [`yjs`](https://github.com/yjs/yjs)（Node.js `v24.22.2`，`npm install yjs` 未锁版本）。正确性另有官方 Node.js `yjs` 生成的黄金线协议向量测试。详见 [`packages/crdt/README.md`](packages/crdt/README.md)。

**1. 顺序 + 随机文本编辑（20,000 ops × 10 iters）+ Yjs Update v1 编解码**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `node_yjs` | 6750.219 | 6070.897 | 7636.549 | 33751.10 | 246.91 MiB | 1.00x (baseline) |
| `pion` | 1926.438 | 1466.458 | 2320.333 | 9632.19 | 15.48 MiB | **3.50x** |

SHA-256：`0ed09d229ad8d2ccc4309209b62dce774bbb95cb8322f2e63b42601de4e0423f`

**2. 双客户端并发 Text + Array + Map 混合编辑（2 × 5,000 ops × 10 iters）+ 增量 v1 同步**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `node_yjs` | 1254.732 | 1205.617 | 1594.238 | 12547.32 | 226.08 MiB | 1.00x (baseline) |
| `pion` | 255.262 | 236.044 | 289.484 | 2552.61 | 8.05 MiB | **4.92x** |

SHA-256：`32c9ec4460bf7bb803c77429623574041f23f879e9f4c2ce3d3729801889b8b1`

说明：Pion 两项负载 P95/Min 波动较大（文本编辑 1466–2320 ms）；本组仅对照 JavaScript 参考实现，未与 Rust `yrs` 对比。

### highlight

参考实现：Node.js [`prismjs`](https://github.com/PrismJS/prism)（Node.js `v24.22.2`）。详见 [`packages/highlight/README.md`](packages/highlight/README.md)。

**9 种语言（Rust、TypeScript、Go、Python、JSON、YAML、C、CSS、HTML）37,800 B × 220 = `8,316,000 B`，校验无损重建源码字节（stdout `428 B`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `node-prismjs` | 1354.656 | 1230.325 | 1715.957 | 6.14 | 87.48 MiB | 1.00x (baseline) |
| `pion-highlight` | 112.973 | 110.089 | 125.756 | 73.61 | 2.31 MiB | **11.99x** |

SHA-256：`1fec95f5f26869f0e95b351d3f462b36a883947e103e513529b074855eceeb80`

说明：SHA-256 校验的是由 token 重建的源码字节（无损性），不是两边的 token 切分；单次迭代 Pion 产出 10,832 个 span（5,876 非 Plain），Prism 产出 10,008 个叶子（6,424 个带类型），粒度并不完全相同，逐语言对照见包 README。本组仅对照 JavaScript 参考实现。

### glob

参考实现：Rust [`globset`](https://github.com/BurntSushi/ripgrep/tree/master/crates/globset) `0.4`（`--release`）。详见 [`packages/glob/README.md`](packages/glob/README.md)。

**50,000 条 monorepo 路径 × 80 条 `GlobSet` 规则 × 20 iters（1,000,000 次 `matches_into`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_globset` | 307.405 | 290.437 | 438.753 | 93.01 | 307.40 | 5.86 MiB | 1.00x (baseline) |
| `pion` | 123.861 | 119.863 | 136.977 | 230.83 | 123.86 | 8.23 MiB | **2.48x** |

SHA-256：`2d9a2ef2bb80d5efd6926bf1bd5024be7f929dd793d5d4ce76a90316496fe91f`

落后项：峰值 RSS 高于 `globset`（8.23 vs 5.86 MiB，约 1.4×）。

### websocket

参考实现：Rust [`tungstenite`](https://github.com/snapview/tungstenite-rs) `0.26.2`（`--release`，基线）与 Go [`coder/websocket`](https://github.com/coder/websocket) `v1.8.14`（含 `mask_arm64.s` NEON 汇编）。详见 [`packages/websocket/README.md`](packages/websocket/README.md)。

**50,000 个掩码客户端帧（~50.88 MB，Text + Binary + 跨分片 UTF-8 Text + 穿插 Ping）批量编码 + 流式解码（解掩码、分片重组、严格 UTF-8 校验）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_tungstenite` | 76.104 | 72.802 | 77.086 | 668.56 | 1522.08 | 2.23 MiB | 1.00x (baseline) |
| `go_coder_ws` | 136.798 | 134.678 | 144.166 | 371.93 | 2735.96 | 16.95 MiB | 0.56x |
| `pion` | 131.212 | 127.738 | 140.728 | 387.77 | 2624.24 | 1.98 MiB | 0.58x |

SHA-256：`7830282bc43598507bfee624e7f55c3bbd01505b2f8e8e4674117ca67e349c92`

落后项：Pion 为 Rust `tungstenite` 的 0.58x（吞吐 387.8 vs 668.6 MB/s）；略快于 Go `coder/websocket`（按两者中位数折算 1.04x），峰值 RSS 三者最低。包 README 归因于 `pionc 0.1.0` 在逐字节解掩码循环中每字节约 13 条标量指令（逐字节边界检查、无 64 位字 / NEON 向量化）。总榜「对照 Go」一行的 1.04x 由包 README 两侧中位数折算（136.798 / 131.212），非框架直接输出。
