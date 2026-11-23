# Pion Packages Cross-Language Benchmarks

本文件汇总 `AFK-surf/pion-packages` 中各包与上游参考实现（Rust `--release` / Go / C / Node.js 等）在**同机、同真实输入、严格交替执行且 stdout SHA-256 逐字节一致**前提下的客观头对头基准数据。

所有结果均如实记录领先与落后项，不做选择性展示。

## 测试环境与工具链基线

| 项目 | 版本 / 规格 |
| --- | --- |
| 测试节点 | `tokyo-mac-studio-0` |
| CPU / 内存 | Apple M5 Max (18 cores), 64 GB RAM |
| 操作系统 | macOS 27.0.1 (Build 26A434, `arm64_apple`) |
| Pion (`pionc`) | `0.1.0`（v0.2.0 基线 `AFK-surf/pion@b1e4effbfafd94e4f71da4d31c87a83bde34888c`；`markdown` v0.2.1 为 `AFK-surf/pion@a62689d5`；`texmath` Wasm32 复测与 Wave 4 四个包为 `AFK-surf/pion@69a0189d`；Wave 5 与 Wave 6 八个包的数据取自各包 README，未记录 pion commit；Wave 6 发布验证（`verify.sh` 与 24 × 4 `wasm_smoke`）使用 `AFK-surf/pion@bee7628`） |
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

## 基准总榜（v0.2.0 + Wave 4 + Wave 5 + Wave 6）

`v0.2.0` 为最初 12 个包经红队对抗审计（`packages/<name>/audit/`）并修复后的版本；Wave 4 新增 `tar` / `semver` / `uuid` / `url` `v0.1.0`（首发即红队修复后版本），并发布 `markdown` `v0.2.1`（P49 性能优化）；Wave 5 新增 `http1` / `jwt` / `xml` / `csv` `v0.1.0`（首发即红队修复后版本）；Wave 6 新增 `regex` / `flate` / `decimal` / `template` `v0.1.0`（首发即红队修复后版本）。本榜数据如实摘录自各包 `packages/<name>/README.md`，均在 `tokyo-mac-studio-0`（Apple M5 Max，`Darwin arm64`）上经 `scripts/bench_compare.py` 严格交替采样并通过 stdout SHA-256 逐字节一致校验；对抗基准由各包 `sh packages/<name>/audit/run_audit.sh` 产出。`Speedup > 1.00x` 表示 Pion 快于参考实现，`< 1.00x` 表示落后。`—` 表示来源未记录该项。

| Package | Workload | Input | Pion Median | Reference Median | Speedup (vs Ref) | Pion Peak RSS | Ref Peak RSS |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| `markdown` | CommonMark 0.31.2 `spec.txt` × 12 → HTML（v0.2.1 P49） | 2,458,295 B | 20.201 ms | 16.869 ms (`rust_pulldown_cmark`) | 0.84x | 12.30 MiB | 13.03 MiB |
| `markdown` | Mixed GFM corpus → HTML（v0.2.1 P49） | 2,503,227 B | 23.326 ms | 19.904 ms (`rust_pulldown_cmark`) | 0.85x | 18.44 MiB | 24.36 MiB |
| `markdown` | 对抗：`nested_strong_emph`（v0.1.0 6,019 ms） | 224 KB | 8.4 ms | — | **1.01x**（56 KB 交替基准） | — | — |
| `texmath` | `bench/corpus.txt` × 20 → MathML（Native） | 10,000 ops | 122.69 ms | 282.46 ms (`node-katex`) | **2.30x** | 3.44 MiB | 68.86 MiB |
| `texmath` | 同上（Wasm32，`AFK-surf/pion@69a0189d` 复测） | 10,000 ops | 343.3 ms | — (`node-katex`) | 0.78x | 274.8 MiB | — |
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
| `tar` | 混合 USTAR/PAX/GNU 全量读 + 全负载 FNV-1a（40,000 entries） | 122.9 MB | 123.035 ms | 153.760 ms (`go_tar`) | **1.25x** | 13.47 MiB | 24.47 MiB |
| `tar` | 混合 USTAR/PAX/GNU 写（40,000 entries） | 122.9 MB | 81.573 ms | 73.339 ms (`go_tar`) | 0.90x | 30.94 MiB | 41.94 MiB |
| `tar` | 对抗：写 64 MiB 单文件 ×10 | — | 163.9 ms | 71.5 ms (`go_tar`) | 0.44x | 194.0 MiB | 327.1 MiB |
| `semver` | `Version::parse` + 全排序 + `to_string` | 400,000 ops | 177.238 ms | 67.990 ms (`rust_semver`) | 0.38x | 4.55 MiB | 4.59 MiB |
| `semver` | `VersionReq::matches` 矩阵 | 5,000,000 matches | 102.161 ms | 27.603 ms (`rust_semver`) | 0.27x | 3.91 MiB | 3.31 MiB |
| `semver` | 32-comparator `VersionReq` parse + matches + `to_string` | 60,000 ops | 129.408 ms | 137.344 ms (`rust_semver`) | **1.06x** | 15.97 MiB | 16.53 MiB |
| `semver` | 脏输入拒收 | 1,000,000 ops | 79.490 ms | 107.903 ms (`rust_semver`) | **1.36x** | 8.92 MiB | 8.50 MiB |
| `uuid` | UUID 批量 parse + 128-bit 排序 + format（raw / typed `encode_hyphenated`） | 18.58 MB | 58.609 / 81.613 ms | 42.648 ms (`rust_uuid`) | 0.73x / 0.52x | 37.17 MiB | 27.20 MiB |
| `uuid` | UUID v5 + v7 生成 + format（raw / typed `encode_hyphenated`） | 200,000 pairs | 51.575 / 54.142 ms | 34.020 ms (`rust_uuid`) | 0.66x / 0.63x | 1.72 MiB | 1.81 MiB |
| `uuid` | ULID 批量 parse + 排序 + format（raw / typed `encode_bytes`） | 13.50 MB | 51.307 / 68.050 ms | 35.727 ms (`rust_ulid`) | 0.70x / 0.53x | 29.33 / 27.48 MiB | 22.38 MiB |
| `url` | 混合 URL 批量 parse + join + serialize | 14,278,136 B | 114.091 ms | 120.056 ms (`rust_url`) | **1.05x** | 21.25 MiB | 10.59 MiB |
| `url` | `URLSearchParams` parse + mutate + sort + serialize | 16,996,736 B | 244.434 ms | 237.788 ms (`rust_url`) | 0.97x | 23.33 MiB | 11.75 MiB |
| `url` | 对抗：`adv_join`（净库时间） | 200,000 cases | 103.7 ms | 55.5 ms (`rust_url`) | 0.54x | — | — |
| `http1` | HTTP/1.1 请求解析（200,000 条混合请求） | 67.92 MB | 232.180 ms | 342.642 ms (`go_net_http`) / 86.743 ms (`rust_httparse`) | **1.48x**（vs Go）/ 0.37x（vs Rust） | 34.20 MiB | 47.80 / 18.05 MiB |
| `http1` | 响应 + chunked 流式解码（100,000 条 chunked 响应） | 40.77 MB | 174.160 ms | 219.393 ms (`go_net_http`) / 92.271 ms (`rust_httparse`) | **1.26x**（vs Go）/ 0.53x（vs Rust） | 21.27 MiB | 40.91 / 11.58 MiB |
| `http1` | WHATWG SSE 流式解码（400,000 个 LLM token 事件，4 KiB 分块） | 44.21 MB | 250.726 ms | 161.732 ms (`rust_sse`) / 175.662 ms (`go_sse`) | 0.65x（vs Rust）/ 0.70x（vs Go） | 44.52 MiB | 22.95 / 57.92 MiB |
| `jwt` | 签发 50,000 个 JWT（25,000 HS256 + 25,000 HS512；Pion 纯软件标量 SHA-2 vs 参考实现 ARMv8 硬件 SHA-2 指令） | 50,000 ops | 150.028 ms | 58.353 ms (`rust_jsonwebtoken`) / 101.761 ms (`go_golang_jwt`) | 0.39x（vs Rust） | **1.95 MiB** | 2.28 / 18.19 MiB |
| `jwt` | 验签 50,000 个 JWT（含 `exp` / `nbf` / `iss` / `aud` 校验，同上纯软件 SHA-2） | 50,000 ops | 182.783 ms | 62.162 ms (`rust_jsonwebtoken`) / 107.808 ms (`go_golang_jwt`) | 0.34x（vs Rust） | 28.16 MiB | 15.42 / 42.44 MiB |
| `xml` | DOM 解析 + 全树遍历（indexed 访问器） | 6.45 MB | 36.190 ms | 29.203 ms (`rust_roxmltree`) | 0.81x | 7.02 MiB | 4.98 MiB |
| `xml` | DOM 解析 + 全树遍历（公开 `Node` API） | 6.45 MB | 45.700 ms | 26.553 ms (`rust_roxmltree`) | 0.58x | 7.44 MiB | 5.02 MiB |
| `xml` | 流式拉取解析（含 Namespaces 1.0） | 6.45 MB | 39.901 ms | 26.698 ms (`rust_quick_xml`) | 0.67x | 3.16 MiB | 2.56 MiB |
| `xml` | 结构化序列化 | 3.59 MB | 39.435 ms | 34.481 ms (`rust_quick_xml`) | 0.87x | 3.12 MiB | 2.75 MiB |
| `xml` | 对抗：2,000 层作用域、叶子使用最外层前缀（DOM；对抗 11 项中 Pion 领先 5 项） | — | 12.99 ms | 1,679.98 ms (Rust) | **129.32x** | 3.64 MiB | 8.56 MiB |
| `xml` | 对抗：16 MiB 密集实体 / 字符引用（Reader，对抗 11 项中最慢项） | 16 MiB | 73.97 ms | 45.82 ms (Rust) | 0.62x | 35.88 MiB | 18.56 MiB |
| `csv` | 读：200k 行混合 CSV × 2（`from_string`） | 30,910,952 B | 92.004 ms | 87.099 ms (`go_csv`) / 68.669 ms (`rust_csv` `StringRecord`) | 0.95x（vs Go） | 31.27 MiB | 37.59 / 16.66 MiB |
| `csv` | 写：200k 结构化记录 × 2 | 29,001,498 B | 73.909 ms | 93.478 ms (`go_csv`) / 74.053 ms (`rust_csv`) | **1.26x**（vs Go；Rust 同为 1.26x，持平） | 30.00 MiB | 40.31 / 16.38 MiB |
| `csv` | `mixed_1m.csv`，`from_string` vs Rust `ByteRecord`（同口径：均不逐记录校验 UTF-8） | 77 MB | 236.8 ms | 139.2 ms (`rust_byte`) | 1.70x slower | 149.2 MiB | 75.6 MiB |
| `csv` | `mixed_1m.csv`，`from_bytes` vs Rust `StringRecord`（同口径：均严格校验 UTF-8） | 77 MB | 303.5 ms | 160.8 ms (`rust_str`) | 1.89x slower | 149.2 MiB | — |
| `csv` | `trim_comment.csv`（`Trim::All` + `#`） | 64 MB | 168.0 ms | 202.7 ms (`rust_byte`) / 298.7 ms (`rust_str`) | **1.21x faster**（vs `ByteRecord`）/ **1.78x faster**（vs `StringRecord`） | 124.0 MiB | 63.1 MiB |
| `regex` | `find_iter` 混合日志多模式搜索（20,000 行 × 10） | 26.89 MB | 43.756 ms | 18.969 ms (`rust_regex`) / 709.004 ms (`go_regexp`) | 0.43x（vs Rust）/ **16.2x**（vs Go） | 7.42 MiB | 5.61 / 16.52 MiB |
| `regex` | `captures_iter` 结构化日志捕获（20,000 行 × 6 组 × 5） | 13.45 MB | 113.792 ms | 56.727 ms (`rust_regex`) / 383.411 ms (`go_regexp`) | 0.50x（vs Rust）/ **3.4x**（vs Go） | 7.42 MiB | 6.38 / 17.66 MiB |
| `regex` | `RegexSet` 16 规则并行匹配 | 100,000 ops | 55.119 ms | 35.282 ms (`rust_regex`) / 111.581 ms (`go_regexp`) | 0.64x（vs Rust）/ **2.0x**（vs Go） | 9.31 MiB | 6.55 / 11.30 MiB |
| `regex` | ReDoS 线性时间（`a?^40 a^40` + 4,000 字节病态输入） | 250 ops | 11.109 ms | 9.788 ms (`rust_regex`) / 26.023 ms (`go_regexp`) | 0.88x（vs Rust）/ **2.3x**（vs Go） | 2.73 MiB | 3.28 / 5.50 MiB |
| `regex` | 对抗：带 Unicode `\b` 的捕获 `\b(\w+)@?(\d*)\b`（2.8 MB） | 2.8 MB | 916.5 ms | 102.0 ms (Rust) | 8.99x slower | 7.0 MiB | 6.0 MiB |
| `regex` | 对抗：尾锚定 `(?s).*1[01]{12}$`（DFA 抖动） | — | 114.6 ms | 6.7 ms (Rust) | 17.10x slower | 12.0 MiB | 4.1 MiB |
| `flate` | gzip 解压 `big16`（16 MiB 混合语料；吞吐 MB/s） | 16 MiB | 290.7 MB/s | 412.3 MB/s (`miniz_oxide`) / 283.5 MB/s (Go) | 0.71x（vs `miniz`）/ **1.03x**（vs Go） | — | — |
| `flate` | gzip 解压 `entropy`（4 MiB 随机） | 4 MiB | 639.6 MB/s | 1959.9 MB/s (`miniz_oxide`) / 1765.1 MB/s (Go) | 0.33x / 0.36x | — | — |
| `flate` | 压缩 L6 `big16` | 16 MiB | 37.5 MB/s | 36.0 MB/s (`miniz_oxide`) / 110.3 MB/s (Go) | **1.04x** / 0.34x | — | — |
| `flate` | 压缩 L9 `entropy` | 4 MiB | 410.4 MB/s | 64.8 MB/s (`miniz_oxide`) / 183.1 MB/s (Go) | **6.33x** / **2.24x** | — | — |
| `flate` | CRC-32 + Adler-32（6 种语料） | — | 843–1007 MB/s | 1721–2450 MB/s (`miniz_oxide`) / 1175–1510 MB/s (Go) | 0.40–0.49x / 0.63–0.72x | — | — |
| `flate` | 对抗：`bomb_1GiB.gz`（limit = 256 MiB） | — | 0.16 s | 0.04 s (`miniz_oxide`) / 0.12 s (Go) | — | 394.1 MiB | 293.1 / 580.2 MiB |
| `decimal` | 混合十进制解析 + 格式化 | 6.56 MB（500,000 ops） | 54.734 ms | 44.605 ms (`rust_decimal`) | 0.81x | 5.36 MiB | 3.38 MiB |
| `decimal` | 账单算术流（`checked_mul` / `add` / `sub` / `div` / `round_dp(2)`） | 2,000,000 ops | 67.804 ms | 40.552 ms (`rust_decimal`) | 0.60x | **1.72 MiB** | 1.81 MiB |
| `decimal` | 排序 + 聚合 + 银行家舍入 | 500,000 ops | 126.927 ms | 45.269 ms (`rust_decimal`) | 0.36x | 7.91 MiB | 4.12 MiB |
| `decimal` | 对抗：A1 McIlroy 快排杀手（红队修复前 2,872.7 ms） | 50,000 | 15.732 ms | 11.951 ms (`rust_decimal`) | 0.76x | 6.70 MiB | 3.14 MiB |
| `decimal` | 对抗：A4 `checked_div`（32 / 64 / 96-bit 除数） | 2,000,000 | 213.339 ms | 97.042 ms (`rust_decimal`) | 0.45x | **1.75 MiB** | 1.84 MiB |
| `template` | HTML 页面 SSR（10,000 次渲染） | 23.77 MB 输出 | 156.054 ms | 119.374 ms (`rust_minijinja`) | 0.77x | **2.50 MiB** | 3.08 MiB |
| `template` | AI Agent Prompt 渲染（20,000 次） | 9.14 MB 输出 | 69.348 ms | 96.668 ms (`rust_minijinja`) | **1.39x** | **2.41 MiB** | 2.88 MiB |
| `template` | 编译 + 渲染端到端（2,000 次） | 938 KB 输出 | 25.865 ms | 39.368 ms (`rust_minijinja`) | **1.52x** | **2.30 MiB** | 3.12 MiB |
| `template` | 对抗：`bench_attr_lookup_100k` | — | 56.65 ms | 30.91 ms (`rust_minijinja`) | 0.55x | — | — |
| `template` | 对抗：`bench_set_concat_20k` | — | 18.87 ms | 54.55 ms (`rust_minijinja`) | **2.89x** | — | — |

## 各包明细

### markdown

参考实现：Rust [`pulldown-cmark`](https://github.com/pulldown-cmark/pulldown-cmark)（`cargo build --release`，`opt-level = 3`，`lto = "thin"`，基准用 `0.13.6`）。`v0.2.1`（P49 性能优化）由 `AFK-surf/pion@a62689d5` 构建，`warmup=1`、`rounds=5`。详见 [`packages/markdown/README.md`](packages/markdown/README.md)。

**1. CommonMark 0.31.2 `spec.txt` × 12（`2,458,295 B` 输入 → `2,690,436 B` HTML）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_pulldown_cmark` | 16.869 | 15.778 | 18.345 | 145.73 | 13.03 MiB | 1.00x (baseline) |
| `pion_markdown`（`to_html_pulldown`） | 20.201 | 18.211 | 21.171 | 121.69 | 12.30 MiB | 0.84x |
| `pion_events`（`parse` + `render_html_pulldown`） | 23.980 | 22.771 | 25.473 | 102.52 | 19.31 MiB | 0.70x |

SHA-256：`a72cc1c4e54ce0990a10f277818f85a5e87db112e86b0bc84844b3c0ec54620a`

**2. Mixed GFM corpus（`2,503,227 B` 输入 → `4,976,832 B` HTML）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_pulldown_cmark` | 19.904 | 19.675 | 20.742 | 125.76 | 24.36 MiB | 1.00x (baseline) |
| `pion_markdown`（`to_html_pulldown`） | 23.326 | 22.677 | 23.943 | 107.31 | 18.44 MiB | 0.85x |
| `pion_events`（`parse` + `render_html_pulldown`） | 29.139 | 28.466 | 29.598 | 85.91 | 35.86 MiB | 0.68x |

SHA-256：`eb0ade9169dfd54fc25a08adb046413fa61bfb44182c6fd0a7310bb8aaf7eba3`

v0.2.0 对照：CommonMark 23.001 ms（0.79x，15.73 MiB）、Mixed GFM 29.847 ms（0.78x，20.05 MiB）。

**3. 三类 O(N²) DoS 消除（`audit/run_audit.sh`）**

| 病态输入 | v0.1.0 | v0.2.0 | v0.2.1（P49） | 与 `pulldown-cmark` 交替基准（P49） |
| --- | ---: | ---: | ---: | --- |
| `nested_strong_emph`（224 KB） | 6,019 ms | 11.3 ms | 8.4 ms | **1.01x**（56 KB） |
| `smart_quotes_nested`（64 KB） | 1,039 ms | 6.8 ms | 5.7 ms | 1.1x |
| `unclosed_comments`（64 KB） | 280 ms | 3.9 ms | 3.5 ms | **1.04x**（128 KB） |

50k 层 `>` 与 32k 层列表 0 SIGSEGV；85,152 例三路差分 `direct != events` 分歧为 0。

落后项：端到端吞吐为 Rust 的 84%–85%（in-process 计算 CommonMark 9.16 ms vs 5.82 ms，Mixed GFM 12.11 ms vs 9.01 ms），峰值 RSS 低于 Rust 6%–24%。包 README 将剩余约 3.1–3.3 ms 计算差距归因于 QBE 标量字节扫描（无 NEON SIMD `memchr`）与 LUT 边界检查消除不跨函数参数传播。

### texmath

参考实现：[`KaTeX`](https://github.com/KaTeX/KaTeX) `v0.19.1`（Node.js `v24.22.2`，`katex.renderToString(..., { output: "mathml" })`）。详见 [`packages/texmath/README.md`](packages/texmath/README.md)。

**v0.2.0：`bench/corpus.txt` × 20 → MathML（SHA-256 一致）**

| Target | `pion-texmath` Median | Peak RSS | `node-katex` Median | `node-katex` Peak RSS | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| Native (`--release`) | 122.69 ms | 3.44 MiB | 282.46 ms | 68.86 MiB | **2.30x** |
| Wasm32（`AFK-surf/pion@69a0189d` 复测） | 343.3 ms | 274.8 MiB | — | — | 0.78x |

落后项：Wasm32 仍为 KaTeX 的 0.78x。在 `AFK-surf/pion@69a0189d` 上复测中位数 343.3 ms、峰值 RSS 274.8 MiB，较此前 `pionc 0.1.0` Wasm 运行时的 654.94 ms / 837.92 MiB / 0.43x 峰值 RSS 降 67%；管道 stdout 完整 314,336 B 零截断，SHA-256 一致。

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

### tar

参考实现：Go 1.27.3 标准库 [`archive/tar`](https://pkg.go.dev/archive/tar)（基线）与 Rust [`tar`](https://crates.io/crates/tar) `0.4.46`（`--release`，LTO）。`AFK-surf/pion@69a0189d`，`--warmup 1 --rounds 5`，三种读基准都对**全部负载字节**计算 FNV-1a。详见 [`packages/tar/README.md`](packages/tar/README.md)。

**1. 混合 USTAR/PAX/GNU 全量读（20 × 2,000 = 40,000 entries，122.9 MB）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_tar`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 123.035 | 119.883 | 129.687 | 998.99 | 3075.87 | 13.47 MiB | **1.25x** |
| `go_tar` | 153.760 | 151.349 | 162.253 | 799.37 | 3844.00 | 24.47 MiB | 1.00x (baseline) |
| `rust_tar` | 117.378 | 116.372 | 117.699 | 1047.14 | 2934.44 | 7.75 MiB | 1.31x |

SHA-256：`5939564e36969c01c2515f273647be551478b5e83f0c0a5cb833e96990af56d6`

**2. 混合 USTAR/PAX/GNU 写（40,000 entries，122.9 MB）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_tar`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 81.573 | 74.858 | 87.505 | 1506.76 | 2039.32 | 30.94 MiB | 0.90x |
| `go_tar` | 73.339 | 70.686 | 80.267 | 1675.92 | 1833.48 | 41.94 MiB | 1.00x (baseline) |
| `rust_tar` | 53.750 | 52.196 | 54.971 | 2286.71 | 1343.75 | 18.84 MiB | 1.36x |

SHA-256：`bc3a15c6b5370100c6a5c1e1b2cafd3c8a8808e3576da5d9c404939546a63888`

**3. 对抗压力负载（`audit/run_audit.sh --quick`，中位数 / 峰值 RSS）**

| Workload | `pion` | `go_tar` | `rust_tar` | `pion` vs `go_tar` |
| --- | ---: | ---: | ---: | ---: |
| Header scan，64 MiB 单文件 ×100 | 21.1 ms / 129.8 MiB | 17.6 ms / 69.8 MiB | 113.6 ms / 65.9 MiB | 0.83x |
| Header scan，每头 4,000 条 PAX 记录 ×1 | 99.9 ms / 46.7 MiB | 107.8 ms / 54.7 MiB | 129.2 ms / 24.5 MiB | **1.08x** |
| 写 64 MiB 单文件 ×10 | 163.9 ms / 194.0 MiB | 71.5 ms / 327.1 MiB | 97.3 ms / 131.0 MiB | 0.44x |
| 写每头 4,000 条 PAX 记录 ×1 | 375.4 ms / 232.3 MiB | 300.3 ms / 242.9 MiB | — | 0.80x |

红队：35/35 单测（含 34 个 Go `archive/tar/testdata` 归档与红队向量）；差分 154/154 归档（44 Go testdata + 110 对抗语料）读结果与 Go 一致，303/303 写入规格与 Go 逐字节一致。审计发现的 P0（4 GiB 写堆溢出、sparse 放大炸弹）、P1（PAX O(n²)、整包 `String` 拷贝等）已修复，修复后默认 `Limits`、`Int64` 溢出安全运算、2 GiB 写入上限与流式 `read_chunk` 见包 README。落后项：写基准为 Go 的 0.90x、Rust 的 0.66x；64 MiB 单文件写仅 Go 的 0.44x（`finish()` 仍有两次 `Bytes::concat`），64 MiB header scan 峰值 RSS 约为 Go 的 1.9 倍。

### semver

参考实现：Rust [`dtolnay/semver`](https://github.com/dtolnay/semver) `=1.0.28`（`--release`，`opt-level = 3`，`lto = "thin"`，版本锁定）。`AFK-surf/pion@69a0189`，`--warmup 1 --rounds 5`。详见 [`packages/semver/README.md`](packages/semver/README.md)。

| Workload | `pion` Median | `rust_semver` Median | ns/op（Pion / Rust） | Peak RSS（Pion / Rust） | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1. `Version::parse` + 全排序 + `to_string`（400,000 ops） | 177.238 ms | 67.990 ms | 443.10 / 169.98 | 4.55 / 4.59 MiB | 0.38x |
| 2. `VersionReq::parse` + `matches` 矩阵（5,000,000 matches） | 102.161 ms | 27.603 ms | 20.43 / 5.52 | 3.91 / 3.31 MiB | 0.27x |
| 3. 32-comparator `VersionReq` parse + matches + `to_string`（60,000 ops） | 129.408 ms | 137.344 ms | 2156.80 / 2289.06 | 15.97 / 16.53 MiB | **1.06x** |
| 4. 脏输入拒收（1,000,000 ops） | 79.490 ms | 107.903 ms | 79.49 / 107.90 | 8.92 / 8.50 MiB | **1.36x** |

SHA-256：Bench 1 `02415012c4d54846f0f03929fdd05e9c9dd375c43dd34f59cd469811933bb31a`；Bench 2 `b1a5400ab4ce74ab82882bf3f8c09dbdcff5513c351a819ea026a841f78e5605`；Bench 3 `c8a02307acbf6a5d9df9148e2ee3c78a6af80feabbe8b5596a837f4d8f3391f3`；Bench 4 `dc0303b9ce5fa81eefe28b9669a72398c8824bb936bc5c93269b4ce3081f4764`。Bench 1 中 Rust 用稳定 driftsort、Pion 用三数取中快排 + 插入排序，输出逐字节一致但计时包含排序算法差异。

红队：35/35 单测；审计 23/23 通过；166,458/166,458 差分用例与上游逐字节一致（0 mismatch）；`small` + `max` + `u64::MAX` 穷举 `matches` 矩阵（2.96 亿次以上）逐字节一致。审计发现的 P0（`u64` 高半值域被拒）、P1（`VersionReq` / `Version` 缓存失效、上游断言被弱化）已修复。落后项：Bench 1 为 0.38x、Bench 2 为 0.27x，包 README 归因于 `pionc 0.1.0`（QBE）对 RC 管理的 `val struct` 字段读取的代码生成上限。

### uuid

参考实现：Rust [`uuid`](https://crates.io/crates/uuid) `1.29.3` 与 [`ulid`](https://crates.io/crates/ulid) `1.2.1`（`--release`）。`AFK-surf/pion@69a0189d`，`--warmup 1 --rounds 5`。同时报告地道 typed API 与 raw 批量 API。详见 [`packages/uuid/README.md`](packages/uuid/README.md)。

| Workload | Implementation | Median (ms) | ns/op | Peak RSS | Speedup |
| --- | --- | ---: | ---: | ---: | ---: |
| 1. UUID 批量 parse + 128-bit 排序 + format（500,000，18.58 MB） | `pion_raw` | 58.609 | 117.22 | 37.17 MiB | 0.73x |
| | `pion_typed_buf` | 81.613 | 163.23 | 37.17 MiB | 0.52x |
| | `pion_typed_str` | 95.766 | 191.53 | 37.17 MiB | 0.45x |
| | `rust_uuid` | 42.648 | 85.30 | 27.20 MiB | 1.00x (baseline) |
| 2. UUID v5（SHA-1）+ v7 生成 + format（200,000 pairs） | `pion_raw` | 51.575 | 257.88 | 1.72 MiB | 0.66x |
| | `pion_typed_buf` | 54.142 | 270.71 | 1.72 MiB | 0.63x |
| | `pion_typed_str` | 66.239 | 331.19 | 1.73 MiB | 0.51x |
| | `rust_uuid` | 34.020 | 170.10 | 1.81 MiB | 1.00x (baseline) |
| 3. ULID 批量 parse + 排序 + format（500,000，13.50 MB） | `pion_raw` | 51.307 | 102.61 | 29.33 MiB | 0.70x |
| | `pion_typed_buf` | 68.050 | 136.10 | 27.48 MiB | 0.53x |
| | `pion_typed_str` | 76.993 | 153.99 | 27.48 MiB | 0.46x |
| | `rust_ulid` | 35.727 | 71.45 | 22.38 MiB | 1.00x (baseline) |

SHA-256：Bench 1 `bd498b7cbd566a04855c18a2e04f7023b0eecd792506b74294c63ef0cfb86ba6`；Bench 2 `8fdf059e12772e0821eb03434f84da85c291fe48b992f8b125d99411f4e65eaf`；Bench 3 `2e742fca70b81a55e4a9533ada0a80b682b55aafbeee7f62b0b61e3c6b8a4c3a`。

**对抗排序分布（1,000,000 个 128-bit 键，修复后）**：`random` `Uuid::sort` 91.2 ms（0.52x）/ `sort_u128_pairs_raw` 51.3 ms（0.92x）；`dup33` 74.5 ms（0.63x）/ 60.0 ms（0.78x）；`deep33` 105.2 ms（0.51x）/ 87.1 ms（0.62x）；`lastbyte` 52.9 ms（0.77x）/ 41.2 ms（0.99x）；`signed` 83.3 ms（0.56x）/ 65.2 ms（0.72x）；`equal` 44.0 ms（0.69x）/ 34.0 ms（0.89x）。重复与公共前缀分布较修复前提速 1.8–2.6 倍。

**Wasm32（Node `v24.22.2`，基线为 Native Rust）**：UUID 批量 500k `wasm_pion_raw` 132.768 ms（0.32x）；UUID v5+v7 200k 100.029 ms（0.33x）；ULID 批量 500k 110.696 ms（0.36x）。

红队：20/20 单测；审计 8,594 例差分无 P0；P1（批量解析空行缺陷、基准公平性、重复数据排序 4–4.5 倍慢）与 P2（`version()` 变体无关、v1/v6 时间戳、42-bit `V7Context42`、严格 ULID 解析等）已修复或补齐。落后项：全部主基准落后 Rust（raw 0.66–0.73x，typed 0.45–0.63x），Wasm32 为 Native Rust 的 0.27–0.36x。

### url

参考实现：Rust [`servo/rust-url`](https://github.com/servo/rust-url) `url =2.5.9`（`--release`）。`--warmup 1 --rounds 5`。详见 [`packages/url/README.md`](packages/url/README.md)。

| Workload | Implementation | Median (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1. 混合 URL 批量 parse + join + serialize（200,000 ops，14,278,136 B） | `pion` | 114.091 | 125.15 | 570.45 | 21.25 MiB | **1.05x** |
| | `rust_url` | 120.056 | 118.93 | 600.28 | 10.59 MiB | 1.00x (baseline) |
| 2. `URLSearchParams` parse + mutate + sort + serialize（200,000 ops，16,996,736 B） | `pion` | 244.434 | 69.54 | 1222.17 | 23.33 MiB | 0.97x |
| | `rust_url` | 237.788 | 71.48 | 1188.94 | 11.75 MiB | 1.00x (baseline) |

SHA-256：Workload 1 `fca6fb3c1d9083d88088188f61cf4c5826e7590a91413844c11058010c4ae9fa`；Workload 2 `6d553a71ae368c6396941bb3e9f9675f928965d8ecc500d7ea840461612832d0`。

**对抗 / 非模板语料（`audit/run_audit.sh` §6，净库时间，SHA-256 一致）**

| Workload | Cases | Net Pion (ms) | Net Rust (ms) | Speedup |
| --- | ---: | ---: | ---: | ---: |
| `adv_ipv4` | 200,000 | 59.3 | 79.9 | **1.35x** |
| `adv_setters`（每 URL 7 个 setter） | 40,000 | 107.6 | 104.5 | 0.97x |
| `adv_ipv6` | 200,000 | 88.3 | 78.2 | 0.89x |
| `adv_big_url`（325 KB URL） | 200 | 78.3 | 65.6 | 0.84x |
| `adv_idn`（Unicode 16.0 UTS #46） | 100,000 | 89.0 | 66.4 | 0.75x |
| `adv_query_sort` | 7,500 | 133.3 | 82.9 | 0.62x |
| `adv_pct` | 100,000 | 218.8 | 125.6 | 0.57x |
| `adv_join` | 200,000 | 103.7 | 55.5 | 0.54x |

**DoS 线性扩展（§5，`4n` 输入中位数）**：`n×@` 授权泛洪 78 KB 7.8 ms（Rust 4.8 ms）；`u:` + `n×@` 7.7 ms（4.5 ms）；Punycode 编码上限 117 KB 8.6 ms（5.7 ms）；Punycode 解码上限 58 KB 7.1 ms（5.1 ms）；`1000 × set_hash` 104 KB 27.8 ms（5.5 ms，5.1x）；`1000 × set_query` 110 KB 25.2 ms（7.9 ms，3.2x）。全部线性扩展。

红队：43/43 单测；WPT `urltestdata.json` 869/869、`setters_tests.json` 274/274；`IdnaTestV2.txt` 6,346/6,348（99.97%，`rust-url 2.5.9` / `idna 1.1.0` 为 6,339/6,348 = 99.86%）；审计套件 31/31，15,876 个 URL 0 非幂等往返。审计发现的 P0（`.%2e` 点段、非特殊 scheme `join`、IDNA 映射子集、UTS #46 校验缺失）与 P1（`@` / Punycode 二次复杂度、setter 全量重解析）已修复。落后项：`URLSearchParams` 0.97x，对抗语料中 `adv_join` / `adv_pct` / `adv_query_sort` 为 0.54–0.62x，峰值 RSS 约为 Rust 的 2 倍；`set_hash` / `set_query` 在超长 URL 上仍比 Rust 慢 3–5 倍。

### http1

参考实现：Rust [`httparse`](https://github.com/seanmonstar/httparse) `1.10.1`（`--release`，基线）与 Go `net/http`（`go1.27.3`）。`--warmup 1 --rounds 5`，`sh packages/http1/bench/run_bench.sh`。详见 [`packages/http1/README.md`](packages/http1/README.md)。

**1. HTTP/1.1 请求解析（200,000 条混合请求，67.92 MB）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_httparse`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **232.180** | 229.165 | 239.914 | **292.54** | 1160.90 | 34.20 MiB | 0.37x |
| `rust_httparse` | 86.743 | 84.775 | 96.716 | 783.02 | 433.72 | 18.05 MiB | 1.00x (baseline) |
| `go_net_http` | 342.642 | 325.165 | 353.424 | 198.23 | 1713.21 | 47.80 MiB | 0.25x |

SHA-256：`ee568111200158fe227d7ab72523087716ac740d973a453d0bf9816024e0dd1f`

**2. HTTP/1.1 响应 + chunked 流式解码（100,000 条 chunked 响应，40.77 MB）**

Pion 走完整的流式 `ChunkedDecoder` 状态机（与 Go `net/http` 的 `ReadResponse` + `Body.Read` 可比），`rust_httparse` 则对连续切片调用无状态的 `parse_chunk_size`。

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_httparse`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **174.160** | 165.298 | 178.951 | **234.08** | 1741.60 | 21.27 MiB | 0.53x |
| `rust_httparse` | 92.271 | 90.461 | 92.712 | 441.82 | 922.71 | 11.58 MiB | 1.00x (baseline) |
| `go_net_http` | 219.393 | 217.825 | 228.853 | 185.82 | 2193.93 | 40.91 MiB | 0.42x |

SHA-256：`013527f1383bbe4530655961b0a38850948e52cc635f27671c7c4d65c00da36c`

**3. WHATWG SSE 流式解码（400,000 个 LLM token 事件，44.21 MB，4 KiB 分块）**

公平性说明：`rust_sse` / `go_sse` 是 `bench/` 中手写移植的同一行扫描算法（不含 `retry:` 解析与 WHATWG `U+FFFD` UTF-8 替换），不是第三方 SSE 库；本表对比的是 Pion 完整 WHATWG 合规 `SseDecoder` 与最小化 Rust / Go 实现。

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_sse`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **250.726** | 245.615 | 485.978 | **176.34** | 626.82 | 44.52 MiB | 0.65x |
| `rust_sse` | 161.732 | 159.276 | 169.487 | 273.36 | 404.33 | 22.95 MiB | 1.00x (baseline) |
| `go_sse` | 175.662 | 174.674 | 223.049 | 251.69 | 439.16 | 57.92 MiB | 0.92x |

SHA-256：`cfa251a98ea173c40138cf1f424b54fd6b0df67cddf2b41dc9eff50cde928cb0`

红队：49/49 单测；审计 33/33 + 200,000 例变异 fuzz（0 分歧）。领先项：请求解析与响应 + chunked 流式解码分别为 Go `net/http` 的 **1.48×** 与 **1.26×**，峰值 RSS 更低（34.20 vs 47.80 MiB、21.27 vs 40.91 MiB；Go `ReadRequest` 另会构建 `url.URL` 并把头部规范化进 `map[string][]string`）。落后项：对 Rust `httparse` 为 0.37x / 0.53x（`httparse` 使用 SIMD/SWAR（`aarch64` NEON），向调用方栈数组写借用的零拷贝 `&[u8]` 区间，不分配 `String`，也不做分帧 / `Host` / 走私校验；Pion 返回 `Send` 安全的 owned `String` 字段并内联执行完整 RFC 9112 分帧与 `Host` 校验）；SSE 为最小化 Rust 解码器的 0.65×、Go 解码器的 0.70×（176.34 MB/s）。

### jwt

参考实现：Rust [`jsonwebtoken`](https://github.com/Keats/jsonwebtoken) `12.0.0`（`--release`，基线）与 Go [`golang-jwt/jwt/v5`](https://github.com/golang-jwt/jwt) `v5.3.1`。`--warmup 1 --rounds 5`，`sh packages/jwt/bench/run_bench.sh`。详见 [`packages/jwt/README.md`](packages/jwt/README.md)。

**1. 签发 / 编码 50,000 个 JWT（25,000 HS256 + 25,000 HS512）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (ops/s) | ns/op | Peak RSS | Speedup (vs `rust_jsonwebtoken`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 150.028 | 147.757 | 152.324 | 333,271 | 3000.56 | 1.95 MiB | **0.39x** |
| `rust_jsonwebtoken` (`12.0.0`, `--release`) | 58.353 | 56.970 | 59.274 | 856,854 | 1167.06 | 2.28 MiB | 1.00x (baseline) |
| `go_golang_jwt` (`v5.3.1`) | 101.761 | 100.608 | 106.362 | 491,347 | 2035.22 | 18.19 MiB | 0.57x |

SHA-256（3 种实现生成的 50,000 个 token 逐位一致）：`9636875f1e3f086e5919fe68afc497b2546c33c7e537888aaa1b3168a01fbf6d`

**2. 验签 / 解码 50,000 个 JWT（25,000 HS256 + 25,000 HS512 + `exp` / `nbf` / `iss` / `aud` 校验）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (ops/s) | ns/op | Peak RSS | Speedup (vs `rust_jsonwebtoken`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 182.783 | 180.810 | 194.363 | 273,548 | 3655.67 | 28.16 MiB | **0.34x** |
| `rust_jsonwebtoken` (`12.0.0`, `--release`) | 62.162 | 60.077 | 70.407 | 804,350 | 1243.25 | 15.42 MiB | 1.00x (baseline) |
| `go_golang_jwt` (`v5.3.1`) | 107.808 | 107.122 | 115.416 | 463,787 | 2156.16 | 42.44 MiB | 0.58x |

SHA-256：`8e46e6e648d8b3f24d2ad00ff40c08f537f02000766e0b6df96929f62d23d5c5`

**硬件差异说明**：在 `Darwin arm64` 上，Rust `sha2`（`jsonwebtoken 12.0.0`）与 Go 标准库 `crypto/sha256` / `sha512` 都通过 ARMv8 Cryptography Extensions（`SHA256H` / `SHA512H` 硬件指令）加速 SHA-2，而 `packages/jwt` 是 100% 纯 Pion 标量软件 SHA-2（零 C FFI，可移植到 `wasm32`）。在此前提下 Pion 达到 **333k 次签发/s** 与 **274k 次验签/s**，签发峰值 RSS **1.95 MiB** 为三者最低。

红队：19/19 单测；270,128 个 SHA-2 / HMAC / Base64URL 差分向量与 RustCrypto 0 差异，三方 JWT 差分与互操作套件、wasm32 逐字节一致、递归深度崩溃探针（0 SIGSEGV / 0 `RangeError`）。落后项：签发 0.39x、验签 0.34x（vs Rust），验签峰值 RSS 28.16 MiB 高于 Rust 的 15.42 MiB。

### xml

参考实现：Rust [`roxmltree`](https://github.com/RazrFalcon/roxmltree) `0.21.2` 与 [`quick-xml`](https://github.com/tafia/quick-xml) `0.42.0`（`--release`，thin LTO，`codegen-units = 1`）。`--warmup 1 --rounds 5`。语料为确定性生成的 645 KB 真实混合 XML（含命名空间的 SVG、Maven / Plist 元数据、带实体 / CDATA / 注释 / PI 的 Atom / RSS），Bench 1 / 2 为 10 轮稳态共 **6.45 MB** 输入，Bench 3 为 5 轮 × 3,000 条结构化记录共 **3.59 MB** 输出。详见 [`packages/xml/README.md`](packages/xml/README.md)。

**1. DOM 解析 + 全树遍历（6.45 MB）**

同时报告两种遍历口径：零分配 indexed 访问器（`Document::node_kind_at`、`attrs_range_at`、`attr_value_len_raw`、`text_len_at`，由 `packages/xml/bench/run_bench.sh` 测量，`sha256:70c1e12cbd0a7d36...`）与公开 `Node` API（`descendants()`、`attributes()`、`text()`，会分配 owned `Array` 与 `String`，由 `packages/xml/audit/perf/run_bench.sh` 测量，`sha256:a32405fd1eeb4911...`）。

| Mode & Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_roxmltree 0.21.2`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (indexed accessors) | 36.190 | 32.133 | 39.675 | 178.23 | 7.02 MiB | 0.81x |
| `rust_roxmltree` (Bench 1) | 29.203 | 26.365 | 32.190 | 220.87 | 4.98 MiB | 1.00x (baseline) |
| `pion` (**public `Node` API**) | 45.700 | 44.895 | 46.569 | 141.14 | 7.44 MiB | **0.58x** |
| `rust_roxmltree` (audit) | 26.553 | 24.651 | 27.078 | 242.91 | 5.02 MiB | 1.00x (baseline) |

**2. 流式拉取解析（6.45 MB，stdout `155 B`，`sha256:520e5cb9a1c90edb...`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_quick_xml 0.42.0`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (with Namespaces 1.0) | 39.901 | 36.755 | 42.520 | 161.65 | 3.16 MiB | 0.67x |
| `rust_quick_xml` (`check_end_names`) | 26.698 | 23.925 | 27.632 | 241.59 | 2.56 MiB | 1.00x (baseline) |

**3. 结构化 XML 序列化（3.59 MB，stdout `211 B`，`sha256:e5290d6c8b4ff356...`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_quick_xml 0.42.0`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (strict atomic + NS checks) | 39.435 | 35.746 | 53.078 | 90.98 | 3.12 MiB | 0.87x |
| `rust_quick_xml` | 34.481 | 31.013 | 41.056 | 104.05 | 2.75 MiB | 1.00x (baseline) |

**4. 对抗与病态负载（`packages/xml/audit/run_audit.sh`，与 Rust `roxmltree 0.21.2` / `quick-xml 0.42.0` SHA-256 一致）**

| Workload | `pion` Median | `pion` RSS | Rust Median | Rust RSS | `pion` vs Rust |
| --- | ---: | ---: | ---: | ---: | ---: |
| Alternating Text/CDATA × 20,000 (DOM) | 10.65 ms | 2.77 MiB | 10.28 ms | 3.42 MiB | **0.96x** |
| 1,000 prefixes, 200k elements cycling prefixes (DOM) | 31.66 ms | 37.08 MiB | 162.31 ms | 17.47 MiB | **5.13x (pion wins)** |
| 2,000-deep scopes, leaf uses outermost prefix (DOM) | 12.99 ms | 3.64 MiB | 1,679.98 ms | 8.56 MiB | **129.32x (pion wins)** |
| 200 elements × 1,000 attributes (DOM) | 23.58 ms | 21.45 MiB | 161.26 ms | 17.86 MiB | **6.84x (pion wins)** |
| 200 elements × 1,000 attributes (Reader) | 24.83 ms | 5.86 MiB | 20.78 ms | 4.23 MiB | **0.84x** |
| 20,000 internal entities + 20,000 refs (DOM, `allow_dtd`) | 15.41 ms | 7.72 MiB | 407.33 ms | 4.19 MiB | **26.43x (pion wins)** |
| 16 MiB single text node (DOM) | 20.08 ms | 33.77 MiB | 28.46 ms | 17.95 MiB | **1.42x (pion wins)** |
| 16 MiB dense entity/char refs (DOM) | 74.63 ms | 36.00 MiB | 56.91 ms | 38.02 MiB | 0.76x |
| 16 MiB dense entity/char refs (Reader) | 73.97 ms | 35.88 MiB | 45.82 ms | 18.56 MiB | 0.62x |
| 100k sibling elements (DOM) | 16.17 ms | 19.12 MiB | 11.29 ms | 9.16 MiB | 0.70x |
| 50,000-deep nesting (DOM, limits raised) | 15.46 ms | 13.70 MiB | 11.15 ms | 6.75 MiB | 0.72x |

对抗 11 项中 Pion 领先 5 项（1.42x–129.32x），落后 6 项（0.62x–0.96x）。

红队：38/38 单测；审计 44/44；W3C XML Conformance Test Suite（`xmlts20130923`）1,458 / 1,662（87.7%，`roxmltree 0.21.2` 为 81.5%，且不存在 `roxmltree` 通过而 `xml` 失败的用例）；2,748 份差分语料在 4 种解析模式下 Native / wasm32 逐字节一致。落后项：Bench 1 indexed 0.81x、公开 `Node` API 0.58x（`NodeData` 使用 64 位 `Int` 索引而 Rust 为 32 位 `NonZeroU32`，以及整体 `val struct` 更新；公开 API 遍历时还会分配 owned `Array` / `String`）；Bench 2 0.67x（`quick-xml` 返回零拷贝借用 `&[u8]` 并用 `memchr` SIMD 扫描，其基础 `Reader` 不做 Namespaces 1.0 校验）；Bench 3 0.87x（含完整写前校验）。

### csv

参考实现：Rust [`BurntSushi/rust-csv`](https://github.com/BurntSushi/rust-csv) `csv =1.4.0`（`--release`）与 Go `encoding/csv`。`--warmup 1 --rounds 5`。详见 [`packages/csv/README.md`](packages/csv/README.md)。

**同口径对比方法**：`Reader::from_string` 信任 `String` 输入为 UTF-8（不逐记录校验），同口径 Rust 对照为 **`ByteRecord`**（`rust_byte`）；`Reader::from_bytes` 按 RFC 3629 严格校验 UTF-8，同口径 Rust 对照为 **`StringRecord`**（`rust_str`）。

**1. 对抗与大文件矩阵（`SECTIONS="bench" sh packages/csv/audit/run_audit.sh`，各实现各轮 stdout SHA-256 逐字节一致）**

| Corpus (Size) / Mode | Pion (ms / RSS) | Rust `StringRecord` | Rust `ByteRecord` | Go `encoding/csv` | Pion vs Like-for-Like Rust | Stdout SHA-256 (prefix) |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `mixed_200k.csv` (15 MB, default `from_string`) | 54.2 / 31.3 MiB | 39.1 | 35.0 / 16.6 MiB | 47.1 | 1.55x slower (vs `ByteRecord`) | `238820ffb412645a` |
| `mixed_1m.csv` (77 MB, default `from_string`) | 236.8 / 149.2 MiB | 162.9 | 139.2 / 75.6 MiB | 203.8 | 1.70x slower (vs `ByteRecord`) | `97221bca6d1004af` |
| `mixed_1m.csv` (77 MB, `from_bytes` validated) | 303.5 / 149.2 MiB | 160.8 | 137.0 / 75.6 MiB | 200.3 | 1.89x slower (vs `StringRecord`) | `97221bca6d1004af` |
| `mixed_1m.csv` (77 MB, `Record::fields()` alloc) | **314.2** / 149.2 MiB | 344.5 | 138.9 / 75.6 MiB | 201.2 | **0.91x (Pion 1.10x faster vs `StringRecord`)** | `97221bca6d1004af` |
| `heavy_quote.csv` (52 MB, dense `""` escapes) | 181.2 / 100.8 MiB | 100.8 | 100.4 / 51.4 MiB | 173.6 | 1.81x slower (vs `ByteRecord`) | `3c55bcf725b2b4d0` |
| `wide_1000.csv` (58 MB, 1,000 cols × 20k rows) | 255.6 / 112.4 MiB | 120.1 | 119.2 / 57.3 MiB | 268.7 | 2.15x slower (vs `ByteRecord`; 1.05x faster vs Go) | `073eb90b9624881a` |
| `semicolon.csv` (55 MB, `;` delimiter) | 193.5 / 107.0 MiB | 124.4 | 105.8 / 54.5 MiB | 163.5 | 1.83x slower (vs `ByteRecord`) | `40345eda2400b10b` |
| `trim_comment.csv` (64 MB, `Trim::All` + `#`) | **168.0** / 124.0 MiB | 298.7 | 202.7 / 63.1 MiB | 119.3 | **0.83x vs `ByteRecord` (1.21x faster), 0.56x vs `StringRecord` (1.78x faster)** | `66276dcc4331b3f9` |
| `escape.csv` (22 MB, `\` escape, `double_quote=false`) | 147.1 / 44.1 MiB | 54.4 | 47.1 / 23.0 MiB | n/a | 3.12x slower (vs `ByteRecord`) | `9ae0aabfea6d2ca3` |
| `narrow.csv` (40 MB, `read_all` 2M × 10 fields) | 429.9 / 668.5 MiB | 289.9 | 280.1 / 517.7 MiB | 403.9 / 521.0 MiB | 1.53x slower, 1.29x memory (vs `ByteRecord`) | `0f6b0ef0092b8c05` |

`mixed_1m.csv`（77 MB）上 `CsvConfig::default()`（`242.2 ms`）与 `max_record_bytes = 0`（`240.1 ms`）一致（`1.01x`），不存在 16 MiB 快路径悬崖。

**2. 读：200k 行混合 CSV × 2 稳态轮（400,000 条记录，`30,910,952 B`，`sh packages/csv/bench/run_bench.sh`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_csv`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`from_string`) | 92.004 | 86.764 | 92.932 | 335.97 | 230.01 | 31.27 MiB | 0.95x |
| `rust_csv` (`StringRecord`, `=1.4.0 --release`) | **68.669** | 67.640 | 69.604 | **450.14** | **171.67** | 16.66 MiB | **1.27x** |
| `go_csv` (`encoding/csv`) | 87.099 | 85.064 | 89.837 | 354.90 | 217.75 | 37.59 MiB | 1.00x (baseline) |

SHA-256：`1ead353719fe54e5aea4d0c4818d61134d51f364cef4f4f8bd4beff1b5310c24`

**3. 写：200k 条结构化记录 × 2 稳态轮（400,000 条记录，`29,001,498 B`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_csv`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **73.909** | 73.064 | 83.390 | **392.39** | **184.77** | 30.00 MiB | **1.26x** |
| `rust_csv` (`=1.4.0 --release`) | 74.053 | 72.719 | 89.356 | 391.63 | 185.13 | 16.38 MiB | 1.26x |
| `go_csv` (`encoding/csv`) | 93.478 | 91.407 | 94.448 | 310.25 | 233.69 | 40.31 MiB | 1.00x (baseline) |

SHA-256：`ddc27c6360c7b492919a2ebe9e6421cf6adf7aec87566c2a2794c81592e69db5`

红队：27/27 单测（`reader_test` 12/12、`writer_test` 6/6、`redteam_test` 9/9）；审计 18/18 对 Rust `csv =1.4.0`（`csv-core 0.1.13`）差分，另有 40,000 读 + 10,000 写差分 fuzz、6,400 次无损往返（0 有损）与 133,816 次 wasm32 / native 逐字节一致运行。领先项：写为 Go 的 **1.26x**、与 Rust 持平（73.909 vs 74.053 ms）；`trim_comment.csv` 快于 Rust `ByteRecord` 1.21x、`StringRecord` 1.78x；`Record::fields()` 分配模式快于 `StringRecord` 1.10x。落后项：读 Bench 1 为 Go 的 0.95x；同口径下 `from_string` 慢于 `ByteRecord` 1.53–2.15x（`escape.csv` 3.12x），`from_bytes` 慢于 `StringRecord` 1.89x；峰值 RSS 多数场景约为 Rust 的 1.8–2.0 倍（`narrow.csv` `read_all` 为 1.29 倍）。

### regex

参考实现：Rust [`regex`](https://github.com/rust-lang/regex) `1.11.1`（`--release`，基线）与 Go `go1.27.3` stdlib `regexp`（RE2）。`--warmup 1 --rounds 5`，`sh packages/regex/bench/run_bench.sh`。详见 [`packages/regex/README.md`](packages/regex/README.md)。

**1. 混合日志多模式搜索（`find_iter`，20,000 行日志 × 10 iters，26.89 MB）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_regex`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 43.756 | 41.373 | 92.132 | 614.61 | 7.42 MiB | 0.43x (**16.2× vs Go**) |
| `rust_regex` | 18.969 | 17.993 | 20.177 | 1417.70 | 5.61 MiB | 1.00x (baseline) |
| `go_regexp` | 709.004 | 688.301 | 760.101 | 37.93 | 16.52 MiB | 0.03x |

_SHA-256 verified identical across all implementations and rounds: `16f877f2f550dcee8b3b644bec3df2cd1c489cdcf2617060714905b6ffcb24ab`._

**2. 结构化日志捕获提取（`captures_iter`，20,000 行 × 6 组 × 5 iters，13.45 MB）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_regex`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 113.792 | 109.889 | 115.274 | 118.17 | 7.42 MiB | 0.50x (**3.4× vs Go**) |
| `rust_regex` | 56.727 | 55.498 | 57.115 | 237.04 | 6.38 MiB | 1.00x (baseline) |
| `go_regexp` | 383.411 | 379.410 | 391.140 | 35.07 | 17.66 MiB | 0.15x |

_SHA-256 verified identical across all implementations and rounds: `8c769e6c2061bea100886a29e886c793b6abcc3a50e8190cad21a812c03403da`._

**3. `RegexSet` 多规则并行匹配（20,000 行 × 16 规则 × 5 iters = 100,000 ops，13.45 MB）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_regex`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 55.119 | 54.412 | 58.088 | 243.95 | 551.19 | 9.31 MiB | 0.64x (**2.0× vs Go**) |
| `rust_regex` | 35.282 | 34.192 | 36.363 | 381.11 | 352.82 | 6.55 MiB | 1.00x (baseline) |
| `go_regexp` | 111.581 | 110.640 | 116.796 | 120.51 | 1115.81 | 11.30 MiB | 0.32x |

_SHA-256 verified identical across all implementations and rounds: `a7e10eb653fdc30d7425bdfbe7d3d939ce4c6640f75fda1b09bc3b8a3446d48d`._

**4. ReDoS 线性时间验证（`a?^40 a^40` + 4,000 字节病态输入 × 50 iters = 250 ops）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_regex`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 11.109 | 9.629 | 11.322 | 44436.00 | 2.73 MiB | 0.88x (**2.3× vs Go**) |
| `rust_regex` | 9.788 | 8.958 | 15.514 | 39153.33 | 3.28 MiB | 1.00x (baseline) |
| `go_regexp` | 26.023 | 24.664 | 27.858 | 104090.00 | 5.50 MiB | 0.38x |

_SHA-256 verified identical across all implementations and rounds: `9f98f5bc3836fb96f47a290a7ceca716b26d89b668b1d60d532d91301c7a0e8d`._

**5. 对抗与压力负载（`audit/stress/run_stress.py`，Pion `--release` vs Rust `regex =1.11.1`，stdout 逐字节一致；最后一列为耗时比 Pion / Rust，`> 1` 表示 Pion 更慢）**

| Scenario | Pion (ms) | Pion RSS | Rust (ms) | Rust RSS | Pion / Rust |
| --- | ---: | ---: | ---: | ---: | ---: |
| Compile `[a × 40,000]` (duplicate class items) | 9.5 | 5.5 MiB | 8.8 | 16.2 MiB | 1.09× |
| Compile `[` × 200,000 (rejected by `nest_limit`) | 5.9 | 3.2 MiB | 44.1 | 102.6 MiB | **0.13×** |
| `\bword\b` on 2.8 MB mixed Unicode/ASCII × 3 | 21.1 | 7.0 MiB | 21.3 | 5.4 MiB | **0.99×** |
| `\b\w+\b` on 2.8 MB mixed Unicode/ASCII | 260.7 | 18.5 MiB | 65.9 | 6.2 MiB | 3.96× |
| Non-one-pass captures `(\w+?)(o\|ox)( ?)` on 2.8 MB | 162.6 | 7.0 MiB | 24.4 | 6.0 MiB | 6.67× |
| Captures with `\b`: `\b(\w+)@?(\d*)\b` on 2.8 MB | 916.5 | 7.0 MiB | 102.0 | 6.0 MiB | 8.99× |
| `RegexSet` 16 rules (incl. `\b`) × 40k lines | 387.3 | 9.8 MiB | 107.2 | 7.3 MiB | 3.61× |
| `RegexSet` 200 rules (incl. `\b`) × 40k lines | 3703.4 | 28.5 MiB | 2009.8 | 13.8 MiB | 1.84× |
| `RegexSet` 500 rules (incl. `\b`) × 40k lines | 16987.0 | 47.9 MiB | 6809.3 | 23.4 MiB | 2.49× |
| `(?s).*1[01]{12}$` (tail-anchored DFA thrash) | 114.6 | 12.0 MiB | 6.7 | 4.1 MiB | 17.10× |

红队：23/23 单测；对 Rust `regex =1.11.1` 差分 51,805 例 0 崩溃 / 0 挂起（`sets` 3,022 / 3,022、`curated` 8,742 / 8,783、`fuzz` 19,986 / 20,000、`capfuzz` 19,892 / 20,000 完全一致），Native 与 Wasm32 debug / `--release` 100% 逐字节一致。领先项：4 项标准负载均快于 Go `regexp` **2.0×–16.2×** 且峰值 RSS 更低；`\bword\b` 与 Rust 持平（0.99×），`[` × 200,000 嵌套炸弹拒收耗时为 Rust 的 0.13×（RSS 3.2 vs 102.6 MiB）。落后项：对 Rust `find_iter` 0.43x、`captures_iter` 0.50x、`RegexSet` 0.64x（无 SIMD `memchr` / Teddy 预过滤，Pion 为标量扫描）；非 one-pass 捕获慢 6.67×、带 Unicode `\b` 的捕获慢 8.99×（无 bounded backtracker，走 PikeVM）；尾锚定 `(?s).*1[01]{12}$` 慢 17.10×（无 reverse-suffix 优化）；`RegexSet` 200 / 500 规则慢 1.84× / 2.49×。已知差异：`(a){0}` 报告 2 个捕获组（同 RE2，Rust 为 1）；约 0.24% 随机 fuzz / capfuzz 模式在深层可空捕获循环上子匹配取舍与 Rust 不同；解析器为递归下降，Wasm32 上把 `nest_limit` 调到约 400 以上可能溢出调用栈（默认 250 安全）。

### flate

参考实现：Rust [`flate2`](https://github.com/rust-lang/flate2-rs) `1.1.11`（`rust_backend` / `miniz_oxide`，`--release`）与 Go `go1.27.3` `compress/gzip` + `hash/{crc32,adler32}`。`sh packages/flate/audit/run_audit.sh bench`（`scripts/bench_compare.py`，`--warmup 1 --rounds 5`，严格交替；压缩模式会重新解压并输出长度 + CRC-32 参与 SHA-256 校验）。详见 [`packages/flate/README.md`](packages/flate/README.md)。

**1. 6 种真实 / 病态语料吞吐（MB/s；`Pion Before` 为红队修复前）**

| Corpus | Operation | Pion Before | **Pion After** | `miniz_oxide` | Go | Pion vs `miniz` | Pion vs Go |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `entropy` (4 MiB rand) | gzip decompress | 530.6 | **639.6** | 1959.9 | 1765.1 | 0.33× | 0.36× |
| `entropy` | compress L1 | 37.0 | **538.5** | 277.2 | 1592.4 | **1.94×** | 0.34× |
| `entropy` | compress L6 | 33.7 | **542.3** | 68.1 | 1470.6 | **7.96×** | 0.37× |
| `entropy` | compress L9 | 34.1 | **410.4** | 64.8 | 183.1 | **6.33×** | **2.24×** |
| `html` (4 MiB Go spec) | gzip decompress | 260.5 | **305.5** | 392.7 | 291.4 | 0.78× | **1.05×** |
| `html` | compress L1 / L6 / L9 | 83.4 / 30.2 / 17.7 | **100.8 / 44.4 / 21.3** | 216.1 / 51.4 / 37.8 | 216.0 / 139.1 / 29.0 | 0.47 / 0.86 / 0.56× | 0.47 / 0.32 / 0.74× |
| `json` (4 MiB records) | gzip decompress | 268.3 | **291.9** | 401.2 | 269.3 | 0.73× | **1.08×** |
| `json` | compress L1 / L6 / L9 | 88.9 / 35.2 / 10.3 | **98.1 / 52.8 / 17.1** | 255.2 / 45.8 / 23.6 | 240.9 / 138.8 / 24.7 | 0.38 / **1.15** / 0.72× | 0.41 / 0.38 / 0.69× |
| `source` (4 MiB Go src) | gzip decompress | 268.4 | **321.2** | 409.6 | 293.9 | 0.78× | **1.09×** |
| `source` | compress L1 / L6 / L9 | 84.5 / 26.7 / 19.0 | **103.7 / 49.8 / 25.9** | 236.0 / 55.8 / 43.4 | 222.0 / 143.6 / 40.9 | 0.44 / 0.89 / 0.60× | 0.47 / 0.35 / 0.63× |
| `text` (2.4 MiB words) | gzip decompress | 191.5 | **247.5** | 337.9 | 229.3 | 0.73× | **1.08×** |
| `text` | compress L1 / L6 / L9 | 70.5 / 20.9 / 6.4 | **93.3 / 26.7 / 9.9** | 207.6 / 29.2 / 15.5 | 180.3 / 101.6 / 17.0 | 0.45 / 0.91 / 0.64× | 0.52 / 0.26 / 0.58× |
| `big16` (16 MiB mix) | gzip decompress | 232.5 | **290.7** | 412.3 | 283.5 | 0.71× | **1.03×** |
| `big16` | compress L1 / L6 / L9 | 64.0 / 23.1 / 11.4 | **87.2 / 37.5 / 15.4** | 182.2 / 36.0 / 24.8 | 167.9 / 110.3 / 23.5 | 0.48 / **1.04** / 0.62× | 0.52 / 0.34 / 0.65× |
| All 6 corpora | CRC-32 + Adler-32 | 702–826 | **843–1007** | 1721–2450 | 1175–1510 | 0.40–0.49× | 0.63–0.72× |

**2. 压缩后体积（Bytes）**

| Corpus | Level 1 (Pion / `miniz` / Go) | Level 6 (Pion / `miniz` / Go) | Level 9 (Pion / `miniz` / Go) |
| --- | ---: | ---: | ---: |
| `entropy` (4,194,304 B) | 4,194,629 / 4,198,186 / 4,194,631 | 4,194,629 / 4,194,969 / 4,194,631 | 4,194,629 / 4,194,969 / 4,194,946 |
| `html` (4,194,304 B) | 1,377,159 / 1,624,878 / 1,386,629 | 1,137,769 / 1,118,477 / 1,164,462 | 1,115,022 / 1,115,149 / 1,110,233 |
| `json` (4,194,304 B) | 1,493,524 / 1,479,550 / 1,344,991 | 1,286,711 / 1,230,323 / 1,210,476 | 1,238,121 / 1,217,228 / 1,144,530 |
| `source` (4,194,304 B) | 1,289,950 / 1,515,528 / 1,301,005 | 1,076,127 / 1,061,930 / 1,096,465 | 1,059,646 / 1,059,129 / 1,055,047 |
| `text` (2,493,885 B) | 822,484 / 958,958 / 896,916 | 759,198 / 756,053 / 795,315 | 759,909 / 755,944 / 742,391 |
| `big16` (16,777,216 B) | 6,272,725 / 6,873,194 / 6,187,274 | 5,512,700 / 5,383,712 / 5,489,706 | 5,418,442 / 5,368,321 / 5,270,229 |

**3. DoS 与对抗病态输入（`run_audit.sh dos`）**

| Workload | Pion Before | **Pion After** | `miniz_oxide` | Go |
| --- | ---: | ---: | ---: | ---: |
| `empty_members_100k.gz` (100k empty members) | 0.49 s | **0.00 s (5.8 MiB RSS)** | 0.16 s (4.0 MiB) | 0.02 s (6.4 MiB) |
| `bomb_1GiB.gz` (limit = 1 MiB) | 0.00 s (5 MiB) | **0.00 s (6.0 MiB RSS)** | 0.00 s (5.1 MiB) | 0.00 s (8.4 MiB) |
| `bomb_1GiB.gz` (limit = 256 MiB) | 0.13 s (391 MiB) | **0.16 s (394.1 MiB RSS)** | 0.04 s (293.1 MiB) | 0.12 s (580.2 MiB) |
| `adv_ab_4M` compress L6 / L9 | — / 4.40 s | **0.22 s / 2.06 s** | 0.27 s / 1.08 s | 0.02 s / 37.35 s |
| `adv_prefix3_4M` compress L6 / L9 | — / 1.61 s | **0.20 s / 0.46 s** | 0.23 s / 0.74 s | 0.02 s / 0.18 s |

红队：20/20 单测 + 审计 11/11；81/81 RFC 边界差分向量（Pion Native / Wasm32、Go、Rust `miniz_oxide`、CPython `zlib`），100/100 压缩互操作流，24,000 例变异 fuzz 0 崩溃 / 挂起、0 Native vs Wasm32 差异、对 Go / Rust / Python 一致结果 0 分歧。领先项：gzip 解压在 5 个可压缩 / 混合语料上为 Go 的 **1.03–1.09×**；L6 压缩在 `big16` / `json` / `entropy` 上为 `miniz_oxide` 的 **1.04× / 1.15× / 7.96×**；随机数据 L9 为 Go 的 **2.24×**；100,000 个空 gzip member 0.00 s。落后项：gzip 解压为 `miniz_oxide` 的 0.71–0.78×（`entropy` 为 0.33×）；CRC-32 + Adler-32 为 `miniz_oxide` 的 0.40–0.49×、Go 的 0.63–0.72×（Rust `crc32fast` 与 Go 使用 ARMv8 硬件 `CRC32X` 指令，Pion 为标量 Slice-by-16）；可压缩数据 L1 压缩为 `miniz_oxide` 的 0.38–0.48×，L6 为 Go 的 0.26–0.38×。已知限制：所有入口均为一次性 `Bytes -> Bytes`，尚无流式 `Inflater` / `Deflater`，峰值 RSS 随 `O(input + output)` 增长（默认 256 MiB 上限下 1 GiB 炸弹 394.1 MiB RSS）；解码不可信数据时应显式设置较小的 `max_output_bytes`。

### decimal

参考实现：Rust [`rust_decimal`](https://github.com/paupino/rust-decimal) `=1.37.2`（`--release`，`rustc 1.100.0`）。`--warmup 1 --rounds 5`，标准负载 `sh packages/decimal/bench/run_bench.sh`，对抗负载 `sh packages/decimal/audit/run_audit.sh`。详见 [`packages/decimal/README.md`](packages/decimal/README.md)。

**1. 混合十进制解析 + 格式化（500,000 ops，6.56 MB）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_decimal`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 54.734 | 52.278 | 57.783 | 119.78 | 109.47 | 5.36 MiB | **0.81x** |
| `rust_decimal` (`1.37.2`) | 44.605 | 42.538 | 46.936 | 146.98 | 89.21 | 3.38 MiB | 1.00x (baseline) |

- Verified common stdout SHA-256: `6a0482dc3aee4ddc3a4c80783d683008c2445a1dccd3fd2ec58e8cbffef1ae48`

**2. 账单算术流（400,000 笔交易 × 5 种运算 = 2,000,000 ops）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_decimal`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 67.804 | 65.193 | 70.656 | 33.90 | **1.72 MiB** | **0.60x** |
| `rust_decimal` (`1.37.2`) | 40.552 | 40.441 | 41.076 | 20.28 | 1.81 MiB | 1.00x (baseline) |

- Verified common stdout SHA-256: `3d0da5b89dfe19db270abada6e5ea031da0006e447090b5e4e684c4f1ba92f50`

**3. 排序 + 聚合 + 银行家舍入（500,000 ops）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_decimal`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 126.927 | 120.636 | 129.210 | 253.85 | 7.91 MiB | **0.36x** |
| `rust_decimal` (`1.37.2`) | 45.269 | 43.706 | 46.540 | 90.54 | 4.12 MiB | 1.00x (baseline) |

- Verified common stdout SHA-256: `d83ad65315d2b3ccb76bcd83b313962ed82c2f7511163a437f3549806d38f7dd`

**4. 对抗负载（各项 stdout SHA-256 与 `rust_decimal =1.37.2` 逐字节一致）**

| Workload | Ops | Pion Median (ms) | Rust Median (ms) | Pion ns/op | Peak RSS (Pion / Rust) | Speedup (vs `rust_decimal`) | Verified SHA-256 |
| --- | ---: | ---: | ---: | ---: | --- | ---: | --- |
| **A1** `Decimal::sort`: McIlroy killer (50k) | 50,000 | **15.732** | 11.951 | 314.65 | 6.70 / 3.14 MiB | **0.76x** | `c8ee2657…5ae0ec8cc` |
| **A2** `Decimal::sort`: same values, random (50k) | 50,000 | 19.647 | 12.322 | 392.95 | 6.70 / 3.14 MiB | **0.63x** | `c8ee2657…5ae0ec8cc` |
| **A3** Full-width 96×96 `checked_mul` | 2,000,000 | 151.264 | 82.603 | 75.63 | **1.75** / 1.84 MiB | **0.55x** | `7f2dffc2…08d3a8e7` |
| **A4** `checked_div` (32/64/96-bit divisors) | 2,000,000 | 213.339 | 97.042 | 106.67 | **1.75** / 1.84 MiB | **0.45x** | `8967bce6…63c0a381a` |
| **A5** `from_scientific` (50k × 10) | 500,000 | 48.237 | 28.138 | 96.47 | 5.69 / 3.47 MiB | **0.58x** | `2032d34f…23b77ce16` |
| **A6** `sqrt` (100k random 96-bit) | 100,000 | 576.608 | 344.611 | 5,766.08 | **1.77** / 1.86 MiB | **0.60x** | `52e54afd…8478868df` |

红队：15/15 单测；对 `rust_decimal =1.37.2` 167,139 次运算差分，33 类运算中 27 类 100% 逐位一致（0 不一致），`judge_exact.py` 0 精度回退，审计 16/16，Native / Wasm32 × debug / `--release` stdout SHA-256 一致；Introsort 把 50k McIlroy 快排杀手从 2,872.7 ms（0.004x）降到 15.732 ms（0.76x）。领先项：Bench 2、A3、A4、A6 峰值 RSS 低于 Rust（如 Bench 2 为 1.72 vs 1.81 MiB）。落后项：全部吞吐项均慢于 Rust——解析格式化 0.81x、账单算术 0.60x、排序聚合 0.36x（`Array[Decimal]` 元素装箱，RSS 7.91 vs 4.12 MiB）、96×96 乘法 0.55x、除法 0.45x、`from_scientific` 0.58x、`sqrt` 0.60x（`Result[Decimal, DecimalError]` 装箱开销，且尚无原生 `UInt128` / `umulh`，宽乘用 32-bit 分段乘法）。另：`round` / `round_dp` / `rescale` 经内部整数标签 `round_dp_code` 实现，以绕开 `pionc 69a0189d` `--release` 跨包内联无字段枚举变体的编译器 bug。

### template

参考实现：Rust [`minijinja`](https://github.com/mitsuhiko/minijinja) `=3.1.0`（`--release`，`opt-level = 3`，`lto = "thin"`，`codegen-units = 1`，features `["builtins", "json", "preserve_order"]`，未开启 `speedups` SIMD `v_htmlescape`）。`--warmup 1 --rounds 5`，`sh packages/template/bench/run_bench.sh`。详见 [`packages/template/README.md`](packages/template/README.md)。

**1. HTML 页面 SSR（`extends` + `block` + `super()` + 20 行 `for` + HTML 自动转义 + 过滤器，10,000 次渲染，输出 23.77 MB）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_minijinja`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 156.054 | 151.756 | 163.427 | 152.32 | 15605.36 | 2.50 MiB | **0.77x** |
| `rust_minijinja` | 119.374 | 118.096 | 128.775 | 199.12 | 11937.37 | 3.08 MiB | 1.00x (baseline) |

_SHA-256 verified identical: `e4fc33828ccace7ee949020a4217baa4ddde3f1f54a4c1d0e4085d3695ee1b39`._

**2. AI Agent Prompt 渲染（条件 + 工具列表 + HTML 安全 `tojson(indent=2)` + `join` + `default`，20,000 次渲染，输出 9.14 MB）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_minijinja`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 69.348 | 67.615 | 75.506 | 131.80 | 3467.40 | 2.41 MiB | **1.39x** |
| `rust_minijinja` | 96.668 | 93.433 | 98.112 | 94.55 | 4833.41 | 2.88 MiB | 1.00x (baseline) |

_SHA-256 verified identical: `ed6753c873c8a3aeace7d3ceb6df3ce580c9d238f3e45261441a2f6907135a0a`._

**3. 编译 + 渲染端到端（3 个模板含 `extends` + `include` + `for` + HTML 转义，2,000 次迭代，输出 938 KB）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_minijinja`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 25.865 | 23.871 | 26.727 | 36.27 | 12932.44 | 2.30 MiB | **1.52x** |
| `rust_minijinja` | 39.368 | 37.992 | 40.312 | 23.83 | 19683.79 | 3.12 MiB | 1.00x (baseline) |

_SHA-256 verified identical: `1561f2114958a0d8e74a73a6d50ccf3a69514b983377865297dfef8698fa5b63`._

**4. 对抗负载（`sh packages/template/audit/run_audit.sh bench`，SHA-256 一致）**

| Workload | `pion` median | `rust_minijinja` median | Speedup (vs `rust_minijinja`) |
| --- | ---: | ---: | ---: |
| `bench_set_concat_20k` (`ns.s ~ 'x'`) | 18.87 ms | 54.55 ms | **2.89x** |
| `bench_unique_20k` (`range(20000)\|unique`) | 10.95 ms | 15.96 ms | **1.46x** (was 738.4 ms / 0.026x) |
| `bench_macro_50k` | 29.98 ms | 30.71 ms | **1.02x** |
| `bench_html_escape_50k` | 31.19 ms | 25.39 ms | **0.81x** |
| `bench_filters_50k` | 54.00 ms | 43.52 ms | **0.81x** |
| `bench_loop_200k` | 36.79 ms | 24.73 ms | **0.67x** |
| `bench_sort_20k` (reversed `\|sort`) | 13.50 ms | 9.10 ms | **0.67x** (was 1757.8 ms / 0.005x) |
| `bench_attr_lookup_100k` | 56.65 ms | 30.91 ms | **0.55x** |

红队：45/45 单测；审计 29/29；对 `minijinja =3.1.0` 差分 251 / 283 逐字节一致，283 / 283 Native vs Wasm32 逐字节一致（0 Wasm32 trap）；62 / 62 DoS 矩阵 0 SIGSEGV / SIGABRT / OOM / 超时。领先项：Prompt 渲染 **1.39x**、编译 + 渲染 **1.52x**、`bench_set_concat_20k` **2.89x**、`bench_unique_20k` **1.46x**，标准负载峰值 RSS 均更低（2.30–2.50 vs 2.88–3.12 MiB）。落后项：HTML SSR 0.77x，渲染密集循环与属性查找 0.55x–0.81x（树遍历 AST 解释器 vs MiniJinja 字节码 VM 与哈希索引查找；且 Rust 基线未开 `speedups`）。已知差异（32 / 283 例，均为 P2）：未实现 `{% for ... recursive %}` / `loop(...)`、`loop.changed(...)`、`{% break %}` / `{% continue %}`、`self.<block>()`、`{%+` / `+%}`、`|format`、`|pprint`、`debug` 全局与宏 `.name` / `.arguments`；元组渲染为列表、极大 / 极小浮点用科学计数法、`-0.0` 部分路径输出 `0.0`；`-2 ** 2`、`2 ** 3 ** 2` 按 Python / Jinja2 优先级（`-4` / `512`）。
