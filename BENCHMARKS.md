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

## 基准总榜（v0.2.0）

`v0.2.0` 为全部 12 个包经红队对抗审计（`packages/<name>/audit/`）并修复后的版本。本榜数据如实摘录自各包 `packages/<name>/README.md`，均在 `tokyo-mac-studio-0`（Apple M5 Max，`Darwin arm64`）上经 `scripts/bench_compare.py` 严格交替采样并通过 stdout SHA-256 逐字节一致校验；对抗基准由各包 `sh packages/<name>/audit/run_audit.sh` 产出。`Speedup > 1.00x` 表示 Pion 快于参考实现，`< 1.00x` 表示落后。`—` 表示来源未记录该项。

| Package | Workload | Input | Pion Median | Reference Median | Speedup (vs Ref) | Pion Peak RSS | Ref Peak RSS |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| `markdown` | CommonMark 0.31.2 `spec.txt` × 12 → HTML | 2,458,295 B | 23.001 ms | 18.065 ms (`rust_pulldown_cmark`) | 0.79x | 15.73 MiB | 13.03 MiB |
| `markdown` | Mixed GFM corpus → HTML | 2,503,227 B | 29.847 ms（v0.2.0 复测 31.9–36.3 ms） | 23.271 ms (`rust_pulldown_cmark`) | 0.78x（复测 0.72–0.77x） | 20.05 MiB | 24.36 MiB |
| `markdown` | 对抗：`nested_strong_emph`（v0.1.0 6,019 ms） | 224 KB | 11.3 ms | — | 0.98x（56 KB 交替基准） | — | — |
| `texmath` | `bench/corpus.txt` × 20 → MathML（Native） | 10,000 ops | 122.69 ms | 282.46 ms (`node-katex`) | **2.30x** | 3.44 MiB | 68.86 MiB |
| `texmath` | 同上（Wasm32） | 10,000 ops | 654.94 ms | 282.34 ms (`node-katex`) | 0.43x | 837.92 MiB | — |
| `mermaid` | 对抗布局 `subgraphs 300` / `dense 40` / `wide 2000` / `scc 200` | — | — | `mermaid` 12.3.0 + `dagre` | **217.2x / 110.1x / 87.3x / 82.3x** | — | — |
| `mermaid` | 稳态 Parse + canonical JSON（`--iters 50`，v0.1.0 记录） | 1.12 MB | 45.997 ms | 13,376.880 ms (`node-mermaid`) | **290.82x** | 2.72 MiB | 252.36 MiB |
| `time` | W1 RFC 3339 parse + 偏移 + format（typed `parse_rfc3339_slice`） | 200,000 timestamps | 53.546 ms | 43.817 ms (`rust_jiff`) | 0.82x | 13.70 MiB | 7.83 MiB |
| `time` | W1 同上（raw `parse_rfc3339_slice_raw`） | 200,000 timestamps | 42.316 ms | 43.817 ms (`rust_jiff`) | **1.04x** | 13.70 MiB | 7.83 MiB |
| `time` | W2 Civil 日历（typed `Date`） | 2,000,000 ops | 90.471 ms | 45.257 ms (`rust_jiff`) | 0.50x | 1.69 MiB | 1.75 MiB |
| `time` | W2 同上（packed） | 2,000,000 ops | 65.160 ms | 45.257 ms (`rust_jiff`) | 0.69x | 1.69 MiB | 1.75 MiB |
| `toml` | 150.5 KB 配置稳态解析 × 50 | 7,526,500 B | 100.995 ms | 93.422 ms (`rust_toml` 1.2.2) | 0.93x | 3.50 MiB | 6.92 MiB |
| `yaml` | K8s / CI / OpenAPI 多文档 parse + canonical JSON | 3,002,682 B | 58.561 ms | 74.506 ms (`rust_yaml_rust2`) | **1.27x** | 33.91 MiB | 39.33 MiB |
| `yaml` | 对抗：`wide_map`（101k 键） | — | 73.8 ms | 107.3 ms (`rust_yaml_rust2`) | **1.45x** | — | — |
| `diff` | Histogram + indent slider + unified diff（10,029 行 × 50） | 32.4 MB | 40.770 ms | 27.525 ms (`rust-imara-diff`) | 0.68x | — | — |
| `diff` | Myers + indent slider + unified diff（10,029 行 × 30） | 19.4 MB | 95.474 ms | 83.445 ms (`rust-imara-diff`) | 0.87x | — | — |
| `diff` | `helix_syntax.rs` Histogram + unified diff（2,200 行 × 200） | 32.2 MB | 26.469 ms | 23.935 ms (`rust-imara-diff`) | 0.90x | 2.31 MiB | 2.39 MiB |
| `diff` | 对抗：`hashflood`（v0.1.0 2,458.9 ms，提速 226×） | 1.44 MB | 10.870 ms | 10.629 ms (`rust-imara-diff`) | 0.98x | — | — |
| `diff` | 对抗：`edge_fallback`（v0.1.0 71.9 ms） | 200k 行 | 37.615 ms | 45.222 ms (`rust-imara-diff`) | **1.20x** | 19.11 MiB | 21.16 MiB |
| `cbor` | 确定性批量编码（WebAuthn/COSE + Telemetry） | 50,000 ops | 72.339 ms | 121.174 ms (`go_fxamacker`) | **1.68x** | 1.80 MiB | 12.20 MiB |
| `cbor` | 批量解码 + 树遍历 | 23,508,920 B | 80.204 ms | 148.137 ms (`go_fxamacker`) | **1.85x** | 9.55 MiB | 17.56 MiB |
| `crdt` | `text_w1`（`text 20000×3`） | — | 192.7 ms | 1965.6 ms (`rust_yrs`) | **10.20x** | 7.1 MiB | 5.5 MiB |
| `crdt` | `append_200k`（v0.1.0 O(n²) 1944.3 ms，提速 24.1×） | 200,000 ops | 80.8 ms | 68.8 ms (`rust_yrs`) | 0.85x | 3.64 MiB | 2.8 MiB |
| `crdt` | `trace_automerge` | 259,778 edits | 1312.8 ms | 6010.3 ms (`rust_yrs`) | **4.58x** | 43.6 MiB | 17.3 MiB |
| `crdt` | `remote_apply`（×20） | — | 155.5 ms | 81.6 ms (`rust_yrs`) | 0.52x | 9.2 MiB | 6.4 MiB |
| `highlight` | HTML 端到端：corpus × 20 | 756 KB | 23.08 ms | — (`prismjs`) | **6.67x** | 2.52 MiB | — |
| `highlight` | HTML 端到端：1 MiB minified JS | 1 MiB | 48.33 ms | — (`prismjs`) | **15.55x** | 33.42 MiB | — |
| `glob` | 50,000 路径 × 80 条 `GlobSet` 规则 × 20（`matches_into`） | 1,000,000 calls | 116.529 ms | 243.484 ms (`rust_globset`) | **2.09x** | 7.27 MiB | 5.89 MiB |
| `glob` | 对抗：`complex_rules_5000` 编译（v0.1.0 21.9 s） | 5,000 rules | 24.8 ms | 55.0 ms (`rust_globset`) | **2.22x** | 52.5 MiB | 58.9 MiB |
| `websocket` | 大帧 `big_1m` 1 MiB × 1,024 | 1.07 GB | 1,633.69 MB/s | 5,956.56 MB/s (`tungstenite`) | 0.27x | — | — |
| `websocket` | 大帧 `big_16m` 16 MiB × 64 | 1.07 GB | 1,554.29 MB/s | 601.66 MB/s (`tungstenite`) | **2.58x** | — | — |
| `websocket` | 小帧 `tiny_1m` 5M × 16 B | 110 MB | 382.60 MB/s | 45.46 MB/s (`go_coder_ws`) | **8.42x** | — | — |

## 各包明细

### markdown

参考实现：Rust [`pulldown-cmark`](https://github.com/pulldown-cmark/pulldown-cmark)（`cargo build --release`，`opt-level = 3`，`lto = "thin"`，基准用 `0.13.6`）。`warmup=2`、`rounds=9`。详见 [`packages/markdown/README.md`](packages/markdown/README.md)。

**1. CommonMark 0.31.2 `spec.txt` × 12（`2,458,295 B` 输入 → `2,690,436 B` HTML）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_pulldown_cmark` | 18.065 | 17.162 | 19.137 | 136.08 | 13.03 MiB | 1.00x (baseline) |
| `pion_markdown` | 23.001 | 21.080 | 23.616 | 106.88 | 15.73 MiB | 0.79x |

SHA-256：`a72cc1c4e54ce0990a10f277818f85a5e87db112e86b0bc84844b3c0ec54620a`

**2. Mixed GFM corpus（`2,503,227 B` 输入 → `4,976,832 B` HTML）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_pulldown_cmark` | 23.271 | 21.993 | 24.975 | 107.57 | 24.36 MiB | 1.00x (baseline) |
| `pion_markdown` | 29.847 | 27.075 | 32.484 | 83.87 | 20.05 MiB | 0.78x |

SHA-256：`eb0ade9169dfd54fc25a08adb046413fa61bfb44182c6fd0a7310bb8aaf7eba3`

红队修复后复测：Mixed GFM 中位数 31.9–36.3 ms（0.72–0.77x），峰值 RSS 20.05 MiB 仍低于 Rust 的 24.36 MiB；CommonMark 约 0.78–0.79x。

**3. 三类 O(N²) DoS 消除（`audit/run_audit.sh`）**

| 病态输入 | v0.1.0 | v0.2.0 | 与 `pulldown-cmark` 交替基准 |
| --- | ---: | ---: | --- |
| `nested_strong_emph`（224 KB） | 6,019 ms | 11.3 ms | 0.98x（56 KB） |
| `smart_quotes_nested`（64 KB） | 1,039 ms | 6.8 ms | 1.1x |
| `unclosed_comments`（64 KB） | 280 ms | 3.9 ms | 1.06x（128 KB） |

50k 层 `>` 与 32k 层列表 0 SIGSEGV。

落后项：主基准吞吐为 Rust 的 72%–79%。包 README 归因于缺少 `StringBuilder::write_substring` / `with_capacity` 原语与 QBE 后端无 SIMD `memchr`。

### texmath

参考实现：[`KaTeX`](https://github.com/KaTeX/KaTeX) `v0.19.1`（Node.js `v24.22.2`，`katex.renderToString(..., { output: "mathml" })`）。详见 [`packages/texmath/README.md`](packages/texmath/README.md)。

**v0.2.0：`bench/corpus.txt` × 20 → MathML（SHA-256 一致）**

| Target | `pion-texmath` Median | Peak RSS | `node-katex` Median | `node-katex` Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| Native (`--release`) | 122.69 ms | 3.44 MiB | 282.46 ms | 68.86 MiB | **2.30x** |
| Wasm32 | 654.94 ms | 837.92 MiB | 282.34 ms | — | 0.43x |

落后项：Wasm32 为 KaTeX 的 0.43x，峰值 RSS 837.92 MiB；该数据基于 `pionc 0.1.0` 修复前的 Wasm 运行时，待升级 `AFK-surf/pion@a62689d`（Wasm 空闲池修复）后复测。

红队：185/185 单测、168/168 红队、60/60 布局 0 误差、KaTeX 截图语料 108/127（0 合法拒收）、31 项 DoS 0 SIGSEGV / 0 OOM。v0.1.0 历史数据（500 条公式 × 20，101.844 ms vs 227.652 ms，2.24x）见包 README。

### mermaid

参考实现：官方 Node.js [`mermaid`](https://github.com/mermaid-js/mermaid) 12.3.0（配 `linkedom`）与 [`@dagrejs/dagre`](https://github.com/dagrejs/dagre)。详见 [`packages/mermaid/README.md`](packages/mermaid/README.md)。

**v0.2.0 对抗头对头（`audit/run_audit.sh`，完整 cluster / 标签 / 平行边布局，SHA-256 一致）**

| Workload | Pion 倍率 |
| --- | ---: |
| `subgraphs 300` | **217.2x** |
| `dense 40` | **110.1x** |
| `wide 2000` | **87.3x** |
| `scc 200` | **82.3x** |

几何质量：与 `dagre` 3.1.3 同框对比 **0/17** 张图存在几何缺陷（v0.1.0 为 14/17 劣于 dagre）；12 组 DoS 0 SIGSEGV；红队 56/63（5 大已实现图类全绿）。

**原 `bench/` 负载（v0.1.0 记录）**

> 稳态（`--iters 50/20`）在单进程内重复计算以摊薄进程启动；冷启动（`--iters 1`）含一次进程启动。包 README 只记录 SHA-256 前 16 位十六进制。

| Workload | Implementation | Median (ms) | Peak RSS | Speedup |
| --- | --- | ---: | ---: | ---: |
| 稳态 Parse + canonical JSON（`--iters 50`，1,120,750 B） | `node-mermaid` | 13,376.880 | 252.36 MiB | 1.00x (baseline) |
| | `pion-mermaid` | 45.997 | 2.72 MiB | **290.82x** |
| 稳态 Layered graph layout（`--iters 20`，442,380 B） | `node-dagre` | 8,041.165 | 318.91 MiB | 1.00x (baseline) |
| | `pion-sugiyama` | 27.840 | 2.88 MiB | **288.84x** |
| 冷启动 Parse + canonical JSON（`--iters 1`） | `node-mermaid` | 381.285 | 108.47 MiB | 1.00x (baseline) |
| | `pion-mermaid` | 8.518 | 2.64 MiB | **44.76x** |
| 冷启动 Layered graph layout（`--iters 1`） | `node-dagre` | 572.356 | 234.11 MiB | 1.00x (baseline) |
| | `pion-sugiyama` | 9.809 | 2.88 MiB | **58.35x** |

SHA-256：稳态 parse `2f819d7bc0dd394d…`，layout `477f544c81534122…`；冷启动 parse `12ff4e02e48548c4…`，layout `a61c633038f51153…`

说明：`node --cpu-prof` 显示该 parse 基准中 `node-mermaid` 约 78–84% 的时间花在 `assignWithDepth`（mermaid 对每个顶点 / 类 / 状态的配置深拷贝），jison 解析本身仅约 2–3%；290x 反映的是「Pion vs 官方 `mermaid` 发行版」端到端，而非纯解析器对比。`dagre` 默认 `ranker: "network-simplex"`（约占其 55% 耗时），Pion 用 longest-path + source tightening。

### time

参考实现：Rust [`jiff`](https://github.com/BurntSushi/jiff) `0.2.46`（`--release` + LTO）与 Go 标准库 `time`（`go1.27.3`）。由 `sh packages/time/audit/run_audit.sh` 测得，typed 与 raw/packed API 并列。详见 [`packages/time/README.md`](packages/time/README.md)。

**W1：RFC 3339 批量解析 + 偏移换算（+09:00）+ 格式化（200,000 timestamps）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_raw`（`parse_rfc3339_slice_raw` + `format_rfc3339_raw_bytes`） | 42.316 | 38.830 | 43.380 | 148.29 | 211.58 | 13.70 MiB | **1.04x** |
| `pion_typed_slice`（`Timestamp::parse_rfc3339_slice` + `write_rfc3339_with_offset`） | 53.546 | 50.739 | 55.898 | 117.19 | 267.73 | 13.70 MiB | 0.82x |
| `pion_typed_split`（`split("\n")` + `Timestamp::parse_rfc3339`） | 53.789 | 53.093 | 69.044 | 116.66 | 268.94 | 22.88 MiB | 0.81x |
| `rust_jiff` | 43.817 | 41.957 | 53.435 | 143.21 | 219.09 | 7.83 MiB | 1.00x (baseline) |
| `go_time` | 52.451 | 50.471 | 53.906 | 119.64 | 262.25 | 24.72 MiB | 0.84x |

SHA-256：`1172c1540ed9d0bc5f41ddce8a7b6253977063fa640aedc9e5eb82000585685f`

**W2：Civil 日历与 epoch 密集计算（2,000,000 ops）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_packed`（`epoch_days_to_packed_date` / `packed_date_*`） | 65.160 | 64.206 | 69.283 | 32.58 | 1.69 MiB | 0.69x |
| `pion_typed`（`Date::from_epoch_days` / `iso_week_date` / `add_days`） | 90.471 | 87.129 | 92.142 | 45.24 | 1.69 MiB | 0.50x |
| `rust_jiff`（calendar `Span`） | 45.257 | 41.739 | 46.963 | 22.63 | 1.75 MiB | 1.00x (baseline) |
| `rust_jiff_sd`（`SignedDuration` days） | 42.219 | 39.172 | 44.832 | 21.11 | 1.75 MiB | 1.07x |
| `go_time` | 77.737 | 72.275 | 79.909 | 38.87 | 4.34 MiB | 0.58x |

SHA-256：`65a54274c38cb0392b001c91e26123de1ddcff28bddec4044e2e9beb72fc5024`

**W3–W5：其余惯用负载**

| Workload | `pion` Median (ms) | `rust_jiff` Median (ms) | `go_time` Median (ms) | `pion` vs `rust_jiff` |
| --- | ---: | ---: | ---: | ---: |
| W3：ISO 8601 `SignedDuration`（200k） | 56.097 | 37.605 | N/A | 0.67x |
| W4：HTTP-date IMF-fixdate（200k） | 63.576 | 43.511 | 71.347 | 0.68x |
| W5：`SignedDuration` + `Timestamp` checked ops（5M） | 577.868 | 74.558 | 70.838 | 0.13x |

落后项：只有 raw API 在 W1 略快于 `jiff`（1.04x）；typed API 为 0.81–0.82x（W1）与 0.50x（W2），W3–W5 为 0.13–0.68x，其中 W5 checked 运算落后最多。W1 峰值 RSS 约为 `jiff` 的 1.7–2.9×。

### toml

参考实现：Rust [`toml`](https://crates.io/crates/toml) `1.2.2`（`--release`，LTO）与 Go [`BurntSushi/toml`](https://github.com/BurntSushi/toml)。合规性来自官方 [`toml-lang/toml-test`](https://github.com/toml-lang/toml-test)（TOML 1.0.0：205/205 valid、474/474 invalid、205/205 encoder）。详见 [`packages/toml/README.md`](packages/toml/README.md)。

**稳态解析：150.5 KB 真实 TOML v1.0.0 workspace / service 配置语料 × 50（`7,526,500 B` 输入，stdout `203 B`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_toml`（1.2.2） | 93.422 | 91.795 | 98.200 | 80.56 | 1868440.00 | 6.92 MiB | 1.00x (baseline) |
| `go_burntsushi` | 262.027 | 257.532 | 369.302 | 28.72 | 5240550.00 | 15.62 MiB | 0.36x |
| `pion` | 100.995 | 86.022 | 113.517 | 74.52 | 2019898.34 | 3.50 MiB | 0.93x |

SHA-256：包 README 只记录了前 16 位十六进制 `96cf0bf395d107be…`，此处如实照录。

落后项：基线换成 `toml 1.2.2` 后，Pion 为其 0.93x（v0.1.0 对 `toml 0.8` 为 1.49x，两者不可直接比较）；峰值 RSS 最低（3.50 MiB）。红队修复：HashDoS（6 万碰撞键 2.6–6.3 s → 33.8 ms）、宽表 `toml::get`（3 万键 1,982 ms → 21–25 ms）、Ryu 浮点格式化 0/60,000 错误。

### yaml

参考实现：Rust [`yaml-rust2`](https://github.com/Ethiraric/yaml-rust2) `0.10.4`（`--release`）与 Go [`gopkg.in/yaml.v3`](https://github.com/go-yaml/yaml) `v3.0.1`。合规性来自官方 [`yaml/yaml-test-suite`](https://github.com/yaml/yaml-test-suite)。详见 [`packages/yaml/README.md`](packages/yaml/README.md)。

**多文档 parse + 规范化有序键 JSON：3.00 MB 真实语料（`3,002,682 B`，2,037 篇 K8s Deployment / GitHub Actions / OpenAPI 3.1，stdout `2,234,058 B`；开启 O(1) 重复键检查与严格 UTF-8 校验）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_yaml_rust2` | 74.506 | 72.146 | 77.285 | 40.30 | 39.33 MiB | 1.00x (baseline) |
| `go_yaml_v3` | 117.757 | 115.343 | 118.489 | 25.50 | 20.67 MiB | 0.63x |
| `pion_yaml` | 58.561 | 57.310 | 61.059 | 51.27 | 33.91 MiB | **1.27x** |

SHA-256：`d57e15ae46b8deb701bd42730f7d034287f48e4e7736d1e71249e80df449b633`（Pion 为 `yaml.v3` 的 2.01x）

**v0.2.0 对抗基准（`audit/run_audit.sh`，SHA-256 一致）**

| Workload | `pion_yaml` | `rust_yaml_rust2` | Speedup |
| --- | ---: | ---: | ---: |
| `wide_map`（单 map，101k 键） | 73.8 ms | 107.3 ms | **1.45x** |
| emit 往返：`block_scalars` | 34.4 ms | 37.2 ms | **1.08x** |
| `dq_escapes` | 76.4 ms | 53.2 ms | 0.70x |

落后项：`dq_escapes` 为 `yaml-rust2` 的 0.70x（同输入为 Go 的 44 倍快）；主基准峰值 RSS 高于 Go（33.91 vs 20.67 MiB）。DoS：合并键放大探针 17.8 s → 0.11 s。

### diff

参考实现：Rust [`imara-diff`](https://github.com/pascalkuthe/imara-diff) `v0.2.0`（`--release`）。详见 [`packages/diff/README.md`](packages/diff/README.md)。

**v0.2.0 标准负载（`bench/run_bench.sh`，SHA-256 一致）**

| Workload | `pion` Median | `rust-imara-diff` Median | Pion Throughput | Speedup |
| --- | ---: | ---: | ---: | ---: |
| Histogram + indent slider + unified diff（10,029 行 × 50，32.4 MB） | 40.770 ms | 27.525 ms | 794 MB/s | 0.68x |
| Myers + indent slider + unified diff（10,029 行 × 30，19.4 MB） | 95.474 ms | 83.445 ms | 204 MB/s | 0.87x |
| `helix_syntax.rs` Histogram + unified diff（2,200 行 × 200，32.2 MB） | 26.469 ms | 23.935 ms | 1215 MB/s | 0.90x |

`helix_syntax.rs` 峰值 RSS：2.31 MiB vs 2.39 MiB。

**v0.2.0 对抗负载（`audit/run_audit.sh`，SHA-256 一致）**

| Workload | v0.1.0 Pion | v0.2.0 Pion | `rust-imara-diff` | Speedup |
| --- | ---: | ---: | ---: | ---: |
| `hashflood`（8 万碰撞行，1.44 MB） | 2,458.9 ms | 10.870 ms（提速 226×） | 10.629 ms | 0.98x |
| `edge_fallback`（20 万行，首行改动 + `}` 段加 1 行） | 71.9 ms | 37.615 ms（19.11 MiB） | 45.222 ms（21.16 MiB） | **1.20x** |
| `million`（100 万行改 1 行） | — | 44.373 ms | 237.054 ms | **5.34x** |
| `multi`（复用 `BeforeInterner`） | — | 50.924 ms | 42.594 ms | 0.84x |

落后项：三项标准负载均落后（0.68x / 0.87x / 0.90x），复用 interner 的 `multi` 为 0.84x。包 README 归因于 QBE 标量带边界检查的访问，对比 Rust 的 NEON SIMD `memchr` / `memcmp`、64 位 `foldhash` 与无检查指针。

### cbor

参考实现：Go [`fxamacker/cbor/v2`](https://github.com/fxamacker/cbor) `v2.9.0`（基线）与 Rust [`ciborium`](https://github.com/enarx/ciborium) `0.2`（`--release`）。详见 [`packages/cbor/README.md`](packages/cbor/README.md)。

**1. 确定性批量编码（50,000 条 WebAuthn/COSE + Telemetry，stdout `58 B`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `go_fxamacker` | 121.174 | 119.342 | 125.585 | 2423.48 | 12.20 MiB | 1.00x (baseline) |
| `rust_ciborium` | 76.984 | 76.011 | 79.241 | 1539.68 | 2.06 MiB | 1.57x |
| `pion` | 72.339 | 70.518 | 73.202 | 1446.78 | 1.80 MiB | **1.68x** |

SHA-256：`b14fb8d50078493f9c8c4349e6dd969f3289721f95fe1cc96f1cda48a7b61e0b`

**2. 批量解码 + 树遍历（80,000 条，`23,508,920 B` 输入，stdout `67 B`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `go_fxamacker` | 148.137 | 145.610 | 153.352 | 158.70 | 1851.72 | 17.56 MiB | 1.00x (baseline) |
| `rust_ciborium` | 123.136 | 122.112 | 131.406 | 190.92 | 1539.20 | 6.72 MiB | 1.20x |
| `pion` | 80.204 | 77.939 | 89.195 | 293.11 | 1002.55 | 9.55 MiB | **1.85x** |

SHA-256：`3e1929251b4f124f4f35012b86df7c3b1ad83579b233cee32aacc5fb05a48ece`

**公平性说明：Go 惯用 typed struct**

上表比较的是动态值树（`CborValue` vs Go `map[string]any` / `map[any]any` vs Rust `ciborium::Value`）。Go 改用预缓存字段排序的惯用 typed struct（`audit/go/cmd/bench_{encode,decode}_struct`，同负载 SHA-256 一致）后：

| Workload | Pion（`CborValue`） | Go（typed struct） | Go（`map`） |
| --- | ---: | ---: | ---: |
| 确定性编码（50k，ns/op） | 1436 ns/op（1.80 MiB，**0.64x** vs Go struct） | 926 ns/op（11.94 MiB，1.00x） | 2372 ns/op（12.70 MiB，0.39x） |
| 解码 + 遍历（80k，MB/s） | 254.6 MB/s（9.58 MiB，**0.93x** vs Go struct） | 274.0 MB/s（11.66 MiB，1.00x） | 155.1 MB/s（18.38 MiB，0.57x） |

落后项：对照 Go 惯用 typed struct 时，Pion 编码为 0.64x、解码为 0.93x；解码峰值 RSS 高于 `ciborium`（9.55 vs 6.72 MiB）。

### crdt

参考实现：Node.js 官方 [`yjs`](https://github.com/yjs/yjs) `13.6.33` 与 Rust [`yrs`](https://github.com/y-crdt/y-crdt) `0.28.2`（`--release`，`lto=thin`，`OffsetKind::Utf16`）。详见 [`packages/crdt/README.md`](packages/crdt/README.md)。

**v0.2.0 三语言基准（`audit/run_audit.sh`，warmup 1，rounds 5，三方 SHA-256 一致，基线 `rust_yrs`）**

| Workload | `pion` | `node_yjs` | `rust_yrs` | Pion vs `yrs` | Pion vs `yjs` |
| --- | ---: | ---: | ---: | ---: | ---: |
| `text_w1`（`text 20000×3`） | 192.7 ms（7.1 MiB） | 1017.7 ms（103.7 MiB） | 1965.6 ms（5.5 MiB） | **10.20x** | **5.28x** |
| `append_50k` | 26.1 ms（2.4 MiB） | 163.6 ms | 26.0 ms（2.6 MiB） | 1.00x | **6.27x** |
| `append_200k` | 80.8 ms（3.64 MiB） | 417.0 ms（100.1 MiB） | 68.8 ms（2.8 MiB） | 0.85x | **5.16x** |
| `trace_automerge`（259,778 次编辑） | 1312.8 ms（43.6 MiB） | 7023.4 ms | 6010.3 ms（17.3 MiB） | **4.58x** | **5.35x** |
| `remote_apply`（×20） | 155.5 ms（9.2 MiB） | 464.0 ms | 81.6 ms（6.4 MiB） | 0.52x | **2.98x** |

- `append_200k` 在 v0.1.0 为 O(n²)（1944.3 ms / 66.8 MiB），v0.2.0 为 80.8 ms / 3.64 MiB，提速 24.1×。
- `automerge-paper` 的 `encodeStateAsUpdate` 体积：Pion 223,411 B，`yjs` 223,414 B，`yrs` 223,411 B（v0.1.0 为 990,662 B）。
- 正确性：132/132 单测、16/16 红队、660 组三方 fuzz 0 失配。

落后项：`append_200k` 为 `yrs` 的 0.85x，`remote_apply` 为 0.52x；`trace_automerge` 峰值 RSS 为 `yrs` 的 2.5 倍（43.6 vs 17.3 MiB）。`yrs` 按每次编辑一个 `transact_mut()` 驱动，未测其单事务批量回放。v0.1.0 仅对照 `yjs` 的历史数据（3.50x / 4.92x）见包 README。

### highlight

参考实现：Node.js [`prismjs`](https://github.com/PrismJS/prism)（Node.js `v24.22.2`），分类准确率另对照 `shiki`。详见 [`packages/highlight/README.md`](packages/highlight/README.md)。

**v0.2.0 HTML 端到端（`audit/run_audit.sh` §5a / §5b，`highlight_html` vs `prismjs` HTML，SHA-256 一致）**

| Workload | `pion-highlight` Median | Throughput | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: |
| §5a corpus × 20（756 KB） | 23.08 ms | 32.76 MB/s | 2.52 MiB | **6.67x** |
| §5b 1 MiB minified JS | 48.33 ms | 21.69 MB/s | 33.42 MiB | **15.55x** |

- 19 项 1 MiB 病态扫描全部线性，9–75 ms（`prismjs` 有 4 项超时）。
- tricky cases 逐字节分类准确率 98.9–100%（对照 `shiki` / `prismjs`）。
- 24 门语言；216/216 单测、35/35 红队。

v0.1.0 历史数据（9 语言 token 流 + 无损重建，8,316,000 B：112.973 ms vs 1,354.656 ms，11.99x）见包 README。本组仅对照 JavaScript 参考实现。

### glob

参考实现：Rust [`globset`](https://github.com/BurntSushi/ripgrep/tree/master/crates/globset) `0.4`（`--release`）。详见 [`packages/glob/README.md`](packages/glob/README.md)。

**v0.2.0：50,000 条 monorepo 路径 × 80 条 `GlobSet` 规则 × 20 iters（1,000,000 次 `matches_into`，SHA-256 一致）**

| Implementation | Median (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| `rust_globset` | 243.484 | 117.42 | 243.48 | 5.89 MiB | 1.00x (baseline) |
| `pion` | 116.529 | 245.35 | 116.53 | 7.27 MiB | **2.09x** |

**v0.2.0 对抗基准（`audit/run_audit.sh`，SHA-256 一致）**

| Workload | v0.1.0 Pion | v0.2.0 Pion | `rust_globset` | Speedup |
| --- | ---: | ---: | ---: | ---: |
| `complex_rules_5000` 编译 | 21.9 s / 1285 MiB | 24.8 ms / 52.5 MiB | 55.0 ms / 58.9 MiB | **2.22x** |
| `complex_rules_5000` 匹配 | — | 3,510.9 ms / 113.3 MiB | 6.5 GiB OOM | — |
| `dfa_cap_blowup_x200` 匹配 | 4,504.1 ms | 8.6 ms / 4.8 MiB | 9.3 ms / 6.2 MiB | **1.08x** |
| `all_rules_hit_3000x` | 1,901.7 ms | 44.9 ms | 72.3 ms | **1.61x** |
| `long_prefix_20000` 匹配 | — | 75.5 ms / 100.0 MiB | 159.2 ms / 144.7 MiB | **2.11x** |

正确性：188/188 单测、29/29 红队、124/124 上游向量。落后项：主基准峰值 RSS 高于 `globset`（7.27 vs 5.89 MiB）。

### websocket

参考实现：Rust [`tungstenite`](https://github.com/snapview/tungstenite-rs) `0.26.2`（`--release`，LTO）与 Go [`coder/websocket`](https://github.com/coder/websocket) `v1.8.14`（含 `mask_arm64.s` NEON 汇编，`text_1m` 加 `utf8.Valid`）。详见 [`packages/websocket/README.md`](packages/websocket/README.md)。

**v0.2.0 流式对抗基准（`audit/run_audit.sh bench`，`--warmup 1 --rounds 5`，SHA-256 一致）**

| Workload（处理字节） | Pion (MB/s) | Rust `tungstenite` (MB/s) | Go `coder/websocket` (MB/s) | Pion vs Rust | Pion vs Go |
| --- | ---: | ---: | ---: | ---: | ---: |
| `big_64k` 64 KiB × 16,384（1.07 GB） | 1,631.20 | 10,718.96 | 4,285.67 | 0.15x | 0.38x |
| `big_1m` 1 MiB × 1,024（1.07 GB） | 1,633.69 | 5,956.56 | 7,427.15 | 0.27x | 0.22x |
| `big_16m` 16 MiB × 64（1.07 GB） | 1,554.29 | 601.66 | 7,642.51 | **2.58x** | 0.20x |
| `text_1m` UTF-8 1 MiB × 1,024（1.07 GB） | 868.21 | 1,971.18 | 1,753.87 | 0.44x | 0.50x |
| `big_1m_c4k` 1 MiB，4 KiB 读（537 MB） | 1,553.56 | 576.97 | 5,556.40 | **2.69x** | 0.28x |
| `frag_storm` 1,000 × 10,000 × 10 B（160 MB） | 321.70 | 825.31 | 54.14 | 0.39x | **5.94x** |
| `tiny_1m` 5M × 16 B 帧（110 MB） | 382.60（57.5 ns/op） | 914.78（24.1 ns/op） | 45.46（484.0 ns/op） | 0.42x | **8.42x** |
| `drip_20k` 1 字节读，10 万帧（2.2 MB） | 16.87 | 2.70 | 25.62 | **6.25x** | 0.66x |

- 去掉 `coalesce()` 双拷贝、改为跨 chunk 直接解掩码 + 16 字节展开后，大帧吞吐提升 2.9–5.1 倍（`big_64k` 317 → 1,631 MB/s，5.15×；`big_1m` 513 → 1,634 MB/s；`big_16m` 530 → 1,554 MB/s；`text_1m` 279 → 868 MB/s）。
- 落后项：64 KiB–16 MiB 大帧上 Pion 约 1.6 GB/s，明显落后 Go 的 NEON 汇编与 Rust 的字宽 XOR（`big_64k` 仅为 Rust 的 0.15x）；包 README 归因于 `pionc 0.1.0` 逐字节带边界检查的 `Bytes` 索引、无 64 位字或 NEON 向量化。小帧与分片风暴上 Pion 落后 Rust（0.39–0.42x），但快于 Go 6–8 倍。
- 正确性：186/186 单测；红队 22/23，唯一未过项是已知未实现的 RFC 7692 `permessage-deflate`。
- v0.1.0 的 50,000 帧混合小帧基准（`bench/run_bench.sh`：131.212 ms，Rust 的 0.58x、Go 的 1.04x）为修复前数据，v0.2.0 未复测。
