# Pion Packages Cross-Language Benchmarks

本文件汇总 `AFK-surf/pion-packages` 中各包与上游参考实现（Rust `--release` / Go / C / Node.js 等）在**同机、同真实输入、严格交替执行且 stdout SHA-256 逐字节一致**前提下的客观头对头基准数据。

所有结果均如实记录领先与落后项，不做选择性展示。

## 测试环境与工具链基线

| 项目 | 版本 / 规格 |
| --- | --- |
| 测试节点 | Apple M5 Max (Darwin arm64) |
| CPU / 内存 | Apple M5 Max (18 cores), 64 GB RAM |
| 操作系统 | macOS 27.0.1 (Build 26A434, `arm64_apple`) |
| Pion (`pionc`) | `0.1.0`（v0.2.0 基线 `AFK-surf/pion@b1e4effbfafd94e4f71da4d31c87a83bde34888c`；`markdown` v0.2.1 为 `AFK-surf/pion@a62689d5`；`texmath` Wasm32 复测与 Wave 4 四个包为 `AFK-surf/pion@69a0189d`；Wave 5 与 Wave 6 八个包的数据取自各包 README，未记录 pion commit；Wave 6 发布验证（`verify.sh` 与 24 × 4 `wasm_smoke`）使用 `AFK-surf/pion@bee7628`；Wave 7 四个包的数据取自各包 README，发布验证（`verify.sh` 与 28 × 4 `wasm_smoke`）使用 `AFK-surf/pion@81b8fb0`；Wave 8 四个包的数据取自各包 README（基准与红队审计均在 `AFK-surf/pion@81b8fb0` 上产出），发布验证（`verify.sh` 与 32 × 4 `wasm_smoke`）使用 `AFK-surf/pion@81b8fb0`；`base64` 与 `effect` 的数据取自各包 README，编译器为 `AFK-surf/pion@8d110a3`，`effect` 发布验证（`verify.sh` 34 包与 `wasm_smoke` 4 模式）亦使用 `AFK-surf/pion@8d110a3`；`crypto` `v0.2.0` 的数据取自包 README（未记录 pion commit），发布验证（`verify.sh` 44 包、`ct_ssa_check.py` 与 `wasm_smoke` 4 模式）使用 `AFK-surf/pion@c375cee`（`v0.1.0` 为 `AFK-surf/pion@8d110a3`）；`fts` 的数据取自包 README，编译器为 `AFK-surf/pion@8d110a3`，发布验证（`verify.sh` 40 包与 `wasm_smoke` 4 模式）亦使用 `AFK-surf/pion@8d110a3`；Wave 9 四个包（`zip` / `dns` / `protobuf` / `graphql`）的数据取自各包 README，基准与红队审计在 `AFK-surf/pion@8d110a3` 上产出，发布验证（`verify.sh` 44 包、4 个 `audit` 套件与 44 × 4 `wasm_smoke`）使用 `AFK-surf/pion@c375cee`；Wave 10 四个包（`http2` / `jsonschema` / `mime` / `asn1`）的数据取自各包 README（未记录 pion commit），发布验证（`verify.sh` 51 包 4,706 / 4,706、4 个 `audit` 套件与 51 × 4 `wasm_smoke`，后者在逐包隔离的 `PION_CACHE_DIR` 下运行，以规避上游 `pionc` Wasm32 CAS 跨包污染缺陷）使用 `AFK-surf/pion@c375cee`；Wave 13 四个包（`bson` / `resp` / `hcl` / `email`）的数据取自各包红队修复后刷新的 README，发布验证（`verify.sh` 69 包 5,029 / 5,029、4 个 `audit` 套件与 69 × 4 `wasm_smoke` 冷共享 CAS `xargs -P 6` 并发）使用 `AFK-surf/pion@66d2b4b`；Wave 14 四个包（`jsonpath` / `svg` / `promql` / `lua`）的数据取自各包红队修复后刷新的 README，发布验证（`verify.sh` 73 包 5,110 / 5,110、4 个 `audit` 套件与 73 × 4 `wasm_smoke` 冷共享 CAS `xargs -P 6` 并发）同样使用 `AFK-surf/pion@66d2b4b`；Wave 15 四个包（`openapi` / `avro` / `kdl` / `xpath`）的数据取自各包红队修复后刷新的 README（红队审计在 `AFK-surf/pion@66d2b4b` 上产出），发布验证（`verify.sh` 77 包 5,218 / 5,218、4 个 `audit` 套件与 77 × 4 `wasm_smoke` 冷共享 CAS `xargs -P 6` 并发）同样使用 `AFK-surf/pion@66d2b4b`；Wave 17 四个包（`json` / `sse` `v0.1.0` 与 `crypto` / `markdown` `v0.3.0`）的数据取自各包红队修复后刷新的 README（红队审计在 `AFK-surf/pion@66d2b4b` 上产出），发布验证（`verify.sh` 79 包 5,290 / 5,290、4 个审计套件与 79 × 4 `wasm_smoke` 冷共享 CAS `xargs -P 6` 并发）同样使用 `AFK-surf/pion@66d2b4b`；Wave 18 两个包（`proxy` `v0.1.0` 与 `crypto` `v0.4.0`）的数据取自各包红队修复后刷新的 README（红队审计在 `AFK-surf/pion@66d2b4b` 上产出），发布验证（冷 CAS `verify.sh` 80 包 5,313 / 5,313、`crypto` 3 个与 `proxy` 1 个审计套件、80 × 4 `wasm_smoke` 冷共享 CAS `xargs -P 6` 并发）同样使用 `AFK-surf/pion@66d2b4b`；Wave 19 两个包（`gif` / `webvtt` `v0.1.0`）的数据取自各包红队修复后的基准与审计报告，发布验证（热 CAS `verify.sh` 82 包 5,381 / 5,381、2 个审计套件含基准复测、2 × 4 `wasm_smoke`）使用 2026-11-24 安装的 `pionc 0.1.0`（self-hosted，未记录 pion commit）；Wave 20 `webp` `v0.1.0` 的数据为发布时同机复测，发布验证（热 CAS `verify.sh` 83 包 5,392 / 5,392、`audit/run_audit.sh` 含基准段、1 × 4 `wasm_smoke`）使用同一 `pionc 0.1.0`；Wave 21 新增 `wgsl` `v0.1.0`（以 Rust `naga =24.0.0 --release` 为基线）的数据为发布时同机复测，发布验证（热 CAS `verify.sh` 84 包 5,412 / 5,412、`audit/run_audit.sh` 含基准段与阶段分拆、1 × 4 `wasm_smoke`）使用同一 `pionc 0.1.0`；Wave 22 新增 `exif` `v0.1.0`（以 Rust `kamadak-exif =0.6.2 --release` 为基线）的数据为发布时同机复测，发布验证（热 CAS `verify.sh` 85 包 5,422 / 5,422、`STRICT=1 audit/run_audit.sh` 含基准段与 `gen_bench_real.py` 相机尺寸对照、1 × 4 `wasm_smoke`）使用同一 `pionc 0.1.0`；Wave 23 新增 `icc` `v0.1.0`（以预缓存 Rust `qcms =0.3.0` 与 `moxcms =0.9.2 --release` 为基线）的数据为发布时同机复测，发布验证（热 CAS `verify.sh` 86 包 5,432 / 5,432、`STRICT=1 audit/run_audit.sh` 10 个核心门禁段、`bench/run_bench.sh` 完整复测、1 × 4 `wasm_smoke`）使用同一 `pionc 0.1.0`；Wave 24 新增 `encoding` `v0.1.0`（以 Rust `encoding_rs =0.8.44 --release` 为基线）的数据为发布时同机复测，发布验证（热 CAS `verify.sh` 87 包 5,468 / 5,468、`STRICT=1 audit/run_audit.sh` 9 个可单独运行的核心门禁段（含 `bench` 段即 `bench/run_bench.sh` 7 组完整复测）、1 × 4 `wasm_smoke`）使用同一 `pionc 0.1.0`；Wave 25 新增 `css_color` `v0.1.0`（以 Rust Linebender `color =0.3.3 --release` 为基线）的数据为发布时同机复测，发布验证（热 CAS `verify.sh` 88 包 5,508 / 5,508、`STRICT=1 audit/run_audit.sh` 全部 13 段（含 `bench` 段）、`bench/run_bench.sh` 完整复测、1 × 4 `wasm_smoke`）使用同一 `pionc 0.1.0`；Wave 26 新增 `cookie` `v0.1.0`（以 Rust `cookie =0.18.3` 与 `psl =2.1.261 --release` 为基线）的数据为发布时同机复测，发布验证（热 CAS `verify.sh` 89 包 5,523 / 5,523、`STRICT=1 audit/run_audit.sh` 全部 13 段（含 `bench` 段）、`bench/run_bench.sh` 完整复测、1 × 4 `wasm_smoke`）使用 `pionc 0.1.0`（`AFK-surf/pion@1e609a5`，Wave H-1）；Wave 27 新增 `opentype` `v0.1.0`（以 Rust `ttf-parser 0.25.1 --release` 为基线）的数据为发布时同机复测，发布验证（热 CAS `verify.sh` 90 包 5,556 / 5,556、`STRICT=1 audit/run_audit.sh` 全部段（含 `bench` 段）、`bench/run_bench.sh` 完整复测、1 × 4 `wasm_smoke`）使用同一 `pionc 0.1.0`；Wave 28 新增 `hls` `v0.1.0`（以 Rust `m3u8-rs 6.0.1 --release` 为基线）的数据为发布时同机复测，发布验证（热 CAS `verify.sh` 91 包 5,569 / 5,569、`STRICT=1 audit/run_audit.sh` 全部段（含 `bench` 段与 `altbench` 第二语料）、`bench/run_bench.sh` 完整复测、1 × 4 `wasm_smoke`）使用同一 `pionc 0.1.0`；Wave 29 新增 `dash` `v0.1.0`（以 Rust `dash-mpd-core =0.1.0 --release` 为基线）的数据为发布时同机复测，发布验证（热 CAS `verify.sh` 95 包 5,643 / 5,643、`STRICT=1 audit/run_audit.sh` 全部段（含 `bench` 段与 `altbench` 第二语料）、`bench/run_bench.sh` 完整复测、1 × 4 `wasm_smoke`）使用同一 `pionc 0.1.0`；Wave 30 新增 `idna` `v0.1.0`（以 Rust `idna =1.1.0 --release` LTO 为基线）的数据为发布时同机复测，发布验证（热 CAS `verify.sh` 96 包 5,674 / 5,674、`STRICT=1 audit/run_audit.sh` 全部段（含 `bench` 段与 `altbench` 第二语料）、`bench/run_bench.sh` 完整复测、1 × 4 `wasm_smoke`）使用 `AFK-surf/pion@1e609a5` 的 `pionc 0.1.0`） |
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

## 基准总榜（v0.2.0 + Wave 4–15 + Wave 17–30 + `base64` + `effect` + `crypto` + 浏览器与多媒体沉淀波 1–10 + `fts`）

`v0.2.0` 为最初 12 个包经红队对抗审计（`packages/<name>/audit/`）并修复后的版本；Wave 4 新增 `tar` / `semver` / `uuid` / `url` `v0.1.0`（首发即红队修复后版本），并发布 `markdown` `v0.2.1`（P49 性能优化）；Wave 5 新增 `http1` / `jwt` / `xml` / `csv` `v0.1.0`（首发即红队修复后版本）；Wave 6 新增 `regex` / `flate` / `decimal` / `template` `v0.1.0`（首发即红队修复后版本）；Wave 7 新增 `cron` / `msgpack` / `json5` / `html` `v0.1.0`（首发即红队修复后版本）；Wave 8 新增 `cli` / `sql` / `graph` / `css` `v0.1.0`（首发即红队修复后版本；`css` 由各包 `audit/scripts/perf.py` 交替采样，非 `bench_compare.py`，见明细）；随后单独发布 `base64` `v0.1.0` 与 `effect` `v0.1.0`（`effect` 以 Go 为基线，另列 Node.js），以及 `crypto` `v0.1.0`（以 Go 标准库为基线；Go 在 `darwin/arm64` 上使用 ARMv8 加密指令与汇编，本包为纯标量 Pion，见明细；后升至 `v0.2.0`，新增 X25519 / HKDF / ChaCha20-Poly1305 / P-256 / RSA，基准扩至 8 项）；随后发布 浏览器与多媒体沉淀波 1（`brotli` / `unicode_bidi` / `hyphenation` / `pdf`）与 `fts` `v0.1.0`（以 C SQLite FTS5 为基线，另列 Python `sqlite3`）。Wave 9 新增 `zip`（以 Go `archive/zip` 为基线，另列 Rust `zip`）、`dns`（以 Rust `hickory-proto` 为基线，另列 Go `miekg/dns`）、`protobuf`（以 Rust `prost` 为基线，另列 Go `protowire`；`DynamicMessage` 另与 Go `dynamicpb` 对比）与 `graphql`（以 Rust `apollo-parser` 为基线，另列 Node `graphql-js`）`v0.1.0`，首发即红队修复后版本。Wave 10 新增 `http2`（以 Rust `h2 0.4.20` 为基线，另列 Go `golang.org/x/net v0.62.0`）、`jsonschema`（以 Rust `jsonschema 0.29.1` 为基线，另列 Node `ajv 8.17.1`；另列去除固定启动开销后的稳态 `ns/op`）、`mime`（以 Go 1.27 标准库为基线，`Content-Type` 解析另以 Rust `mime 0.3.18`、魔数嗅探以 Rust `infer 0.16.0` 为基线）与 `asn1`（以 Go `crypto/x509` / `encoding/asn1` 为基线，另列 Rust `x509-parser 0.16.0` / `der 0.7.10`）`v0.1.0`，首发即红队修复后版本。Wave 11 新增 `cel`（以 Go `cel-go v0.24.1` 为基线）、`wasm`（以 Rust `wasmparser` / `wasm-encoder` / `wasmprinter 0.221.3` 为基线）、`ical`（以 Rust `rrule 0.14.0` / `icalendar 0.16.17` 为基线）与 `ssh`（以 Go `golang.org/x/crypto/ssh v0.38.0` 为基线；Go 缺失的 `|1|` 哈希主机、RFC 4253 分包与 `SSHSIG` 由等价 Go 实现补齐）`v0.1.0`，首发即红队修复后版本。Wave 12 新增 `git`（以 Rust `gix`（`gix-object 0.46` / `gix-pack 0.56` / `gix-index 0.37` / `gix-packetline 0.18`）为基线）、`jq`（以 Go `gojq v0.12.17` 为基线）、`qrcode`（以 Rust `qrcode 0.14.1` 为基线，另列 `qrcodegen 1.8.0` / `fast_qr 0.14.0`）与 `mqtt`（以 Rust `rumqttc 0.25.1` 为基线，另列 Go `paho.golang/packets v0.23.0`；`TopicTrie` 为同算法跨语言对照）`v0.1.0`，首发即红队修复后版本。Wave 13 新增 `bson`（以 Rust `bson 2.15.0` 为基线；解码另列零拷贝 `RawDocument` 遍历）、`resp`（以 Rust `redis-protocol 6.0.0` 零拷贝 `decode_bytes_mut` 为基线）、`hcl`（以 Go `hashicorp/hcl/v2 v2.23.0` 为基线）与 `email`（MIME 解析以 Rust `mail-parser 0.9.4`、地址 / 日期解析以 Go `net/mail`、DKIM 以 Go `go-msgauth v0.7.0` 为基线）`v0.1.0`，首发即红队修复后版本，数据取自各包红队修复后刷新的 README；Wave 14 新增 `jsonpath`（以 Rust `serde_json_path 0.7.2` + `json-patch 4.2.0` 为基线）、`svg`（以 Rust `svgtypes 0.15.3` / `roxmltree 0.20.0` 同算法实现为基线，另列地道 `kurbo 0.11.3` 与非等价参考 Node `svgo@3.3.2`）、`promql`（以 Go `prometheus/prometheus v0.302.1` 的 `promql/parser` 与 `promql.Engine` 为基线）与 `lua`（以 Go `gopher-lua v1.1.1` 为基线，W3 采用只开同等库子集的公平配置）`v0.1.0`，首发即红队修复后版本，数据取自各包红队修复后刷新的 README；Wave 15 新增 `openapi`（以 Go `kin-openapi v0.131.0` 为基线）、`avro`（以 Go `hamba/avro/v2 v2.28.0` 动态 `map[string]any` 为基线，另列 typed `struct`）、`kdl`（以 Rust `kdl 6.7.1` 无损 CST 解析器为基线，非同构对照）与 `xpath`（以 Rust `sxd-xpath 0.4.2` 为基线，另列 C `libxml2 -O2`）`v0.1.0`，首发即红队修复后版本，数据取自各包红队修复后刷新的 README；Wave 17 新增 `json`（以 Rust `serde_json =1.0.145` 为基线，另列 Go `encoding/json`）与 `sse`（以 Rust `eventsource-stream =0.2.3` 为基线）`v0.1.0`，并发布 `crypto` `v0.3.0`（新增 AES-256-GCM、P-256 ECDH 与 P-256 公钥校验 4 行，迭代数按红队 P2-1 加大到 Go 侧 ≥ 45 ms 实际工作量的稳态口径，原 8 行同步刷新）与 `markdown` `v0.3.0`（新增树状 AST 与纯文本提取吞吐，无上游同构实现，仅列 Pion 自身数据），数据取自各包红队修复后刷新的 README；Wave 18 新增 `proxy` `v0.1.0`（W1 / W2 以同输出的手写 Go 参考实现 `go_ref` 为基线，W3 以 Go `net/http` `ReadRequest` / `ReadResponse` 为基线，见明细）并发布 `crypto` `v0.4.0`（新增 PBKDF2-HMAC-SHA256 与 scrypt 2 行，以 Go `golang.org/x/crypto` `v0.58.0` 为基线，迭代数按 Go 侧 ≥ 50 ms 的稳态口径），数据取自各包红队修复后刷新的 README；Wave 19 新增 `gif`（以 Go `image/gif` 标准库为基线）与 `webvtt`（以同规则手写 Go 镜像 `go_ref` 为基线，按红队 F20 另列零拷贝 `go_tuned`）`v0.1.0`，首发即红队修复后版本；Wave 20 新增 `webp` `v0.1.0`（以 Go `golang.org/x/image/webp` `v0.48.0` 为基线），首发即红队修复后版本，数据为发布时同机复测；Wave 21 新增 `wgsl` `v0.1.0`（以 Rust `naga =24.0.0 --release` 为基线）、Wave 22 新增 `exif` `v0.1.0`（以 Rust `kamadak-exif =0.6.2 --release` 为基线）与 Wave 23 新增 `icc` `v0.1.0`（以预缓存 Rust `qcms =0.3.0`（`precache_output_transform()`）与 `moxcms =0.9.2 --release` 为基线）与 Wave 24 新增 `encoding` `v0.1.0`（以 Mozilla Rust `encoding_rs =0.8.44 --release` 为基线）与 Wave 25 新增 `css_color` `v0.1.0`（以 Rust Linebender `color =0.3.3 --release` 为基线）与 Wave 26 新增 `cookie` `v0.1.0`（以 Rust `cookie =0.18.3` 与 `psl =2.1.261 --release` 为基线）、Wave 27 新增 `opentype` `v0.1.0`（以 Rust `ttf-parser 0.25.1 --release` 为基线）、Wave 28 新增 `hls` `v0.1.0`（以 Rust `m3u8-rs 6.0.1 --release` 为基线）与 Wave 29 新增 `dash` `v0.1.0`（以 Rust `dash-mpd-core =0.1.0 --release` 为基线）、Wave 30 新增 `idna` `v0.1.0`（以 Rust `idna =1.1.0 --release` LTO 为基线），均首发即红队修复后版本，数据为发布时同机复测。本榜数据如实摘录自各包 `packages/<name>/README.md`，均在 Apple M5 Max (Darwin arm64)（Apple M5 Max，`Darwin arm64`）上经 `scripts/bench_compare.py` 严格交替采样并通过 stdout SHA-256 逐字节一致校验；对抗基准由各包 `sh packages/<name>/audit/run_audit.sh` 产出。`Speedup > 1.00x` 表示 Pion 快于参考实现，`< 1.00x` 表示落后。`—` 表示来源未记录该项。

| Package | Workload | Input | Pion Median | Reference Median | Speedup (vs Ref) | Pion Peak RSS | Ref Peak RSS |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| `markdown` | CommonMark 0.31.2 `spec.txt` × 12 → HTML（v0.2.1 P49） | 2,458,295 B | 20.201 ms | 16.869 ms (`rust_pulldown_cmark`) | 0.84x | 12.30 MiB | 13.03 MiB |
| `markdown` | Mixed GFM corpus → HTML（v0.2.1 P49） | 2,503,227 B | 23.326 ms | 19.904 ms (`rust_pulldown_cmark`) | 0.85x | 18.44 MiB | 24.36 MiB |
| `markdown` | Mixed GFM corpus → HTML（v0.3.0 回归复测） | 2,503,227 B | 23.704 ms | 21.543 ms (`rust_pulldown_cmark`) | 0.91x | 18.44 MiB | — |
| `markdown` | v0.3.0 `parse_document` 树状 AST（Mixed GFM） | 2,503,227 B | 35.851 ms (69.82 MB/s) | — | — | 33.84 MiB | — |
| `markdown` | v0.3.0 `to_plain_text` 全文（`collapse_whitespace`） | 2,503,227 B | 41.174 ms (60.80 MB/s) | — | — | 34.88 MiB | — |
| `markdown` | v0.3.0 `to_plain_text` 预览（`max_chars: 120` + 占位符） | 2,503,227 B | 34.076 ms (73.46 MB/s) | — | — | 33.86 MiB | — |
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
| `cron` | W1 解析 100 条生产 cron 表达式 × 1,000 | 100,000 ops | 23.914 ms | 152.088 ms (`rust_croner`) / 50.801 ms (`go_robfig`) | **6.36x**（vs Rust）/ **2.12x**（vs Go） | 1.75 MiB | 5.66 / 12.28 MiB |
| `cron` | W2 `next_after` 步进（100 表达式 × 20 × 50） | 100,000 ops | 15.311 ms | 78.508 ms (`rust_croner`) / 141.102 ms (`go_robfig`) | **5.13x** / **9.22x** | 1.77 MiB | 5.67 / 4.55 MiB |
| `cron` | W3 稀疏 / 罕见日期步进 | 10,000 ops | 8.095 ms | 28.057 ms (`rust_croner`) / 34.111 ms (`go_robfig`) | **3.47x** / **4.21x** | 1.75 MiB | 5.48 / 4.41 MiB |
| `cron` | W4 13 号星期五（`dom_and_dow = true`） | 10,000 ops | 8.962 ms | 62.558 ms (`rust_croner`) | **6.98x** | 1.75 MiB | 5.45 MiB |
| `cron` | 对抗：A4 不可能日期 + 157 项年份列表 | 2,000 searches | 9,624.88 ns/op | 346,684.19 ns/op (Java Quartz 2.3.2) | **36.02x** | — | — |
| `cron` | 对抗：A6 长显式列表（至 2 KB） | 60,000 parses | 5,350.61 ns/op | 21,389.53 ns/op (`croner`) / 15,941.90 ns/op (`robfig`) | **2.98x**（vs 最佳上游） | — | — |
| `msgpack` | W1 嵌套 RPC / 遥测解码（80,000 条） | 13,655,320 B | 71.684 ms | 108.612 ms (`rust_rmpv`) / 118.004 ms (`go_vmihailenco`) | **1.52x**（vs Rust）/ **1.65x**（vs Go） | 7.66 MiB | 6.62 / 15.77 MiB |
| `msgpack` | W2 嵌套 RPC / 遥测编码（50,000 条） | 50,000 ops | 36.296 ms | 37.416 ms (`rust_rmpv`) / 47.108 ms (`go_vmihailenco`) | **1.03x** / **1.30x** | **1.78 MiB** | 1.98 / 11.25 MiB |
| `msgpack` | W3 大 `bin` + `str` + `array` 解码（~64 MiB） | 64,811,276 B | 29.840 ms | 25.849 ms (`rust_rmpv`) / 24.195 ms (`go_vmihailenco`) | 0.87x / 0.81x | **37.64 MiB** | 40.06 / 67.84 MiB |
| `msgpack` | 对抗：W1 解码 vs Go 类型化 struct | 80,000 | 69.9 ms | 61.9 ms (Go struct) | 0.89x（Go 1.13×） | — | — |
| `msgpack` | 对抗：W2 编码 vs Go 类型化 struct | 50,000 | 39.4 ms | 27.8 ms (Go struct) | 0.71x（Go 1.42×） | — | — |
| `msgpack` | 对抗：HashDoS 262,144 构造 uint64 键（`reject_duplicate_keys`） | — | 30 ms | 57 ms (Rust HashSet) / 55 ms (Go map) | **1.90x** / **1.83x** | — | — |
| `json5` | W1 大型带注释 JSON5 配置解析（60 × 95.6 KB） | 5,738,040 B | 46.070 ms | 45.344 ms (`rust_json5`) / 335.266 ms (`node_json5`) | 0.98x（vs Rust）/ **7.28x**（vs Node） | 2.58 MiB | 2.84 / 71.67 MiB |
| `json5` | W2 JSON5 → 标准 JSON 序列化往返（40 × 95.6 KB） | 3,825,360 B | 47.108 ms | 39.354 ms (`rust_json5`) / 239.411 ms (`node_json5`) | 0.84x / **5.08x** | 2.84 MiB | 3.06 / 70.34 MiB |
| `json5` | W3 RFC 6902 Patch + RFC 6901 Pointer | 100,000 ops | 106.641 ms | 140.022 ms (`rust_json_patch`) / 266.937 ms (`node_fast_json_patch`) | **1.31x** / **2.50x** | 2.00 MiB | 2.14 / 52.78 MiB |
| `json5` | 对抗：A4 `diff()` 50k 键对象（红队修复前 16,594 ms） | — | 48.6 ms | 24.0 ms (Rust) / 89.8 ms (Node) | 0.49x | — | — |
| `json5` | 对抗：A6 50k 键 `Array` 对象上 50k 次 `pointer_get`（O(k) 线性扫描） | — | 6,114 ms | 23.4 ms (Rust) / 84.3 ms (Node) | 0.004x（重复查找应改用 `ObjectIndex`） | — | — |
| `html` | Bench 1 HTML5 文档解析 + 文本 / 链接抽取（20 轮） | 1,377,460 B | 31.347 ms | 35.603 ms (`rust_scraper`) / 24.969 ms (`go_net_html`) | **1.14x**（vs Rust）/ 0.80x（vs Go） | **2.91 MiB** | 3.58 / 11.48 MiB |
| `html` | Bench 2 大 DOM CSS 选择器查询（250 次） | 250 queries | 18.284 ms | 16.559 ms (`rust_scraper`) | 0.91x | **3.09 MiB** | 3.56 MiB |
| `html` | Bench 3 HTML XSS 清洗（20 轮） | 2,451,400 B | 51.752 ms | 70.666 ms (`rust_ammonia`) | **1.37x** | **3.44 MiB** | 4.78 MiB |
| `html` | 对抗：全部 2,125 个 WHATWG `;` 实体 × 40 | — | 22.9 ms | 103.7 ms (`html5ever`) | **4.53x** | — | — |
| `html` | 对抗：`div.a div.b em`（30k 节点） | — | 17.1 ms | 13.9 ms (`scraper`) | 0.81x | — | — |
| `cli` | W1 复杂 CLI（30 选项 + 5 级子命令）× 50,000 次解析 | 50,000 ops | 182.972 ms | 1318.488 ms (`rust_clap`) / 360.676 ms (`go_pflag`) | **7.21x**（vs Rust）/ **1.97x**（vs Go） | **1.95 MiB** | 2.81 / 17.84 MiB |
| `cli` | W2 100k 参数批量（短标志聚合 + 重复 Append + `--`） | 100,000 args | 14.085 ms | 41.769 ms (`rust_clap`) / 13.829 ms (`go_pflag`) | **2.97x** / 0.98x | **4.78 MiB** | 45.55 / 10.33 MiB |
| `cli` | W3 拼写建议 + 帮助渲染 | 20,000 ops | 62.663 ms | 397.137 ms (`rust_clap`) | **6.34x** | **2.03 MiB** | 2.95 MiB |
| `cli` | 对抗：W1 冷启动（构建 + 解析 × 50k，红队修复前 949 ms） | — | 763.516 ms | 3872.762 ms (`rust_clap`) | **5.07x** | — | — |
| `cli` | 对抗：16k 链式 `.arg()`（红队修复前 628 ms） | — | 10.792 ms | 13.743 ms (`rust_clap`) | **1.27x** | — | — |
| `cli` | 对抗：4 KB 名称拼写建议（红队修复前 472 ms） | — | 15.166 ms | 178.246 ms (`rust_clap`) | **11.75x** | — | — |
| `sql` | W1 复杂生产 PostgreSQL 解析（10 条 × 2,000） | 4,828,000 B（20,000 ops） | 136.493 ms | 1190.852 ms (`rust_sqlparser`) | **8.72x** | **2.56 MiB** | 3.33 MiB |
| `sql` | W2 大 SQL 脚本分词（10 × 969.6 KB） | 9,696,000 B | 100.063 ms | 794.741 ms (`rust_sqlparser`) | **7.94x** | **23.47 MiB** | 38.66 MiB |
| `sql` | W3 解析 → `to_sql()` → 重解析 + 结构化 `stmt_eq` 往返 | 2,414,000 B（10,000 ops） | 161.034 ms | 1172.362 ms (`rust_sqlparser`) | **7.28x** | **2.81 MiB** | 3.61 MiB |
| `sql` | 对照：W1 / W3 对 `mimalloc` 链接的同版本 `sqlparser`（`audit/rust --features mimalloc`） | — | — | — | 约 2.6x | — | — |
| `graph` | W1 Dijkstra（50,000 节点 / 250,000 边 × 3） | 750k 次松弛 | 47.174 ms (`pion_csr`) / 69.541 ms (`pion_digraph`) | 63.012 ms (`rust_petgraph`) | **1.34x** / 0.91x | 19.03 / 14.78 MiB | 10.36 MiB |
| `graph` | W2 Tarjan SCC + 拓扑排序（100,000 节点 / 400,000 边 × 2） | 800k 边 | 79.203 ms (`pion_digraph`) / 80.140 ms (`pion_csr`) | 47.419 ms (`rust_petgraph`) | 0.60x / 0.59x | 50.98 / 57.16 MiB | 34.41 MiB |
| `graph` | W3 Kruskal MST（50,000 节点 / 200,000 无向边） | 200k 边 | 20.565 ms | 26.138 ms (`rust_petgraph`) | **1.27x** | 20.88 MiB | 12.52 MiB |
| `graph` | W4 CFG 支配树（20,000 节点 / 60,000 边 × 5） | 300k 次边检查 | 21.727 ms (`pion_csr`) / 24.869 ms (`pion_digraph`) | 41.751 ms (`rust_petgraph`) | **1.92x** / **1.68x** | **7.28 / 5.55 MiB** | 8.61 MiB |
| `graph` | 对抗：A2 Dinic 最大流（200 层 × 10） | — | 14.2 ms | 25.9 ms (`petgraph`) | **1.83x** | 6 MiB | 5 MiB |
| `graph` | 对抗：A9 Floyd-Warshall（300 节点稠密图） | — | 24.3 ms | 31.9 ms (`petgraph`) | **1.31x** | **6 MiB** | 7 MiB |
| `graph` | 对抗：A10 传递规约（20k 链） | — | 13.7 ms | 1255.9 ms (`petgraph`) | **91.46x** | **7 MiB** | 912 MiB |
| `graph` | 对抗：A10b 传递规约（100k 出星，红队修复前 1,217 MiB） | — | 58.3 ms | 21.0 ms (`petgraph`) | 0.36x | 28 MiB | 22 MiB |
| `graph` | 对抗：A11 随机图支配树（50k / 200k） | — | 52.6 ms | 63.0 ms (`petgraph`) | **1.20x** | **27 MiB** | 29 MiB |
| `css` | 零分配 `count_tokens()` vs `cssparser` token walk（5 语料） | 1.34–2.09 MB × 3 | 21.4–26.1 ms | 31.5–42.5 ms (`cssparser`) | **1.28x–1.63x** | — | — |
| `css` | 全量物化 `tokenize()` vs `cssparser` token walk（5 语料） | 1.34–2.09 MB × 3 | 61.8–89.8 ms | 31.5–42.5 ms (`cssparser`) | 0.47x–0.52x | — | — |
| `css` | 单遍流式 `parse_stylesheet()` vs `cssparser` 自有 AST（5 语料） | 1.34–2.09 MB × 3 | 37.8–91.2 ms | 29.7–107.2 ms (`cssparser`) | 0.79x–1.18x | 8.2–41.2 MB | 9.1–34.0 MB |
| `css` | 单遍流式 `parse_stylesheet()` vs `lightningcss` 解析（5 语料） | 1.34–2.09 MB × 3 | 37.8–91.2 ms | 105.4–449.6 ms (`lightningcss`) | **1.62x–4.93x** | **8.2–41.2 MB** | 34.6–202.6 MB |
| `css` | 单遍流式 `minify()` vs `lightningcss` 压缩器（5 语料；后者另做类型化属性优化） | 1.34–2.09 MB × 3 | 67.8–125.2 ms | 125.3–569.7 ms (`lightningcss`) | **1.26x–4.55x** | **5.7–7.6 MB** | 35.1–203.4 MB |
| `css` | 单遍流式 `parse_stylesheet()` vs Node `css-tree` 解析（5 语料） | 1.34–2.09 MB × 3 | 37.8–91.2 ms | 442.8–1220.2 ms (`css-tree`) | **5.19x–19.86x** | **8.2–41.2 MB** | 164.1–448.6 MB |
| `base64` | `b64_encode` Base64 编码 4 MiB × 64 | 268,435,456 B | 239.2 ms | 100.7 ms (Rust) / 122.6 ms (Go) | 0.42x (vs Rust) · 0.51x (vs Go) | 16.4 MiB | 11.1 / 31.7 MiB (Rust / Go) |
| `base64` | `b64_decode` Base64 严格解码 4 MiB × 64 | 268,435,456 B | 228.9 ms | 99.0 ms (Rust) / 110.5 ms (Go) | 0.43x (vs Rust) · 0.48x (vs Go) | 20.5 MiB | 15.1 / 32.5 MiB (Rust / Go) |
| `base64` | `url_encode` Base64URL 编码 4 MiB × 64 | 268,435,456 B | 228.6 ms | 99.3 ms (Rust) / 122.4 ms (Go) | 0.43x (vs Rust) · 0.54x (vs Go) | 16.5 MiB | 11.1 / 26.8 MiB (Rust / Go) |
| `base64` | `url_decode` Base64URL 严格解码 4 MiB × 64 | 268,435,456 B | 226.5 ms | 94.6 ms (Rust) / 106.7 ms (Go) | 0.42x (vs Rust) · 0.47x (vs Go) | 20.5 MiB | 15.1 / 30.4 MiB (Rust / Go) |
| `base64` | `b32_encode` Base32 编码 4 MiB × 64 | 268,435,456 B | 253.3 ms | 113.2 ms (Rust) / 118.6 ms (Go) | 0.45x (vs Rust) · 0.47x (vs Go) | 18.6 MiB | 12.2 / 29.9 MiB (Rust / Go) |
| `base64` | `b32_decode` Base32 严格解码 4 MiB × 64 | 268,435,456 B | 253.1 ms | 110.9 ms (Rust) / 642.3 ms (Go) | 0.44x (vs Rust) · **2.54x** (vs Go) | 22.6 MiB | 16.2 / 49.1 MiB (Rust / Go) |
| `base64` | `hex_encode` Hex 编码 4 MiB × 64 | 268,435,456 B | 300.7 ms | 511.6 ms (Rust) / 209.7 ms (Go) | **1.70x** (vs Rust) · 0.70x (vs Go) | 21.8 MiB | 13.8 / 66.3 MiB (Rust / Go) |
| `base64` | `hex_decode` Hex 解码 4 MiB × 64 | 268,435,456 B | 315.7 ms | 1449.4 ms (Rust) / 185.1 ms (Go) | **4.59x** (vs Rust) · 0.59x (vs Go) | 25.8 MiB | 20.0 / 31.4 MiB (Rust / Go) |
| `effect` | W1 有界队列乒乓（cap = 16） | 50,000 msgs | 18.318 ms | 17.479 ms (Go) / 57.203 ms (Node) | 0.95x (vs Go) · **3.12x** (vs Node) | **1.83 MiB** | 4.59 / 48.62 MiB (Go / Node) |
| `effect` | W2 虚拟时钟定时器调度（Pion 为完整结构化纤程，基线为裸最小堆，见明细） | 20,000 timers | 47.402 ms | 18.574 ms (Go) / 58.455 ms (Node) | 0.39x (vs Go) · **1.23x** (vs Node) | 28.23 MiB | 5.95 / 49.86 MiB (Go / Node) |
| `effect` | W3 结构化扇出汇合（2,500 × 4） | 10,000 fibers | 19.481 ms | 18.090 ms (Go) / 51.110 ms (Node) | 0.93x (vs Go) · **2.62x** (vs Node) | **1.84 MiB** | 5.42 / 45.16 MiB (Go / Node) |
| `crypto` | SHA-256 流式哈希 | 16 MiB | 94.222 ms | 17.716 ms (Go) | 0.19x | **1.84 MiB** | 5.02 MiB |
| `crypto` | SHA-512 流式哈希 | 16 MiB | 63.312 ms | 21.785 ms (Go) | 0.34x | **1.84 MiB** | 5.05 MiB |
| `crypto` | HMAC-SHA256 | 50,000 × 256 B | 140.606 ms | 32.078 ms (Go) | 0.23x | **1.80 MiB** | 11.41 MiB |
| `crypto` | Ed25519 签名 + 验签 | 200 + 200 ops | 60.823 ms | 24.094 ms (Go) | 0.40x | **1.89 MiB** | 5.03 MiB |
| `crypto` | X25519 密钥交换 | 200 次 | 30.242 ms | 28.051 ms (Go) | 0.93x | **1.83 MiB** | 4.95 MiB |
| `crypto` | HKDF-SHA256 | 20,000 × 64 B | 102.889 ms | 31.297 ms (Go) | 0.30x | **1.83 MiB** | 12.28 MiB |
| `crypto` | ChaCha20-Poly1305 加密 + 解密 | 4 MiB | 73.418 ms | 20.921 ms (Go) | 0.28x | **2.05 MiB** | 10.80 MiB |
| `crypto` | AES-256-GCM 加密 + 解密（v0.3.0） | 1,000 × 64 KiB | 2,033.434 ms (64.46 MB/s) | 55.673 ms (Go) | 0.03x | **2.05 MiB** | 14.75 MiB |
| `crypto` | AES-256-GCM 小包加密 + 解密（v0.3.0） | 150,000 × 256 B | 2,315.511 ms (7.72 µs/op) | 46.906 ms (Go) | 0.02x | **1.88 MiB** | 11.84 MiB |
| `crypto` | NIST P-256 ES256 签名 + 验签 | 50 + 50 ops | 121.651 ms | 14.271 ms (Go) | 0.12x | **1.97 MiB** | 5.81 MiB |
| `crypto` | NIST P-256 ECDH（v0.3.0） | 2,000 次 | 1,402.492 ms (701.25 µs/op) | 69.888 ms (Go) | 0.05x | **1.89 MiB** | 7.09 MiB |
| `crypto` | NIST P-256 公钥校验（v0.3.0，非压缩 + 压缩） | 20,000 + 20,000 | 828.830 ms (20.72 µs/op) | 81.086 ms (Go) | 0.10x | **1.81 MiB** | 11.11 MiB |
| `crypto` | PBKDF2-HMAC-SHA256（v0.4.0，500,000 次迭代，32 B） | 500,000 iters | 251.241 ms (502.48 ns/op) | 51.484 ms (Go `x/crypto`) | 0.20x | **1.78 MiB** | 4.95 MiB |
| `crypto` | scrypt `N=16384, r=8, p=1`（v0.4.0，32 B × 4） | 4 次 | 130.075 ms (32.52 ms/op) | 80.441 ms (Go `x/crypto`) | 0.62x | **33.78 MiB** | 39.81 MiB |
| `brotli` | Web HTML/CSS/JS/JSON 解压（2 MiB q6 × 10） | 20 MiB | 34.820 ms | 25.524 ms (`rust_brotli`) / 24.281 ms (`c_brotlidec`) | 0.73x (vs Rust) · 0.70x (vs C) | — | — |
| `brotli` | WOFF2 字体载荷解压（1 MiB q11 × 10） | 10 MiB | 33.678 ms | 24.419 ms (`rust_brotli`) / 25.004 ms (`c_brotlidec`) | 0.73x (vs Rust) · 0.74x (vs C) | — | — |
| `brotli` | 小包批量解压（512 pkts q5 × 10） | 5,120 pkts | 43.355 ms | 69.620 ms (`rust_brotli`) / 35.054 ms (`c_brotlidec`) | **1.61x** (vs Rust) · 0.81x (vs C) | — | — |
| `unicode_bidi` | Pure LTR 快路径（40k ops） | 3.98 MB | 63.711 ms | 68.927 ms (`rust_unicode_bidi`) | **1.08x** | — | — |
| `unicode_bidi` | Mixed 阿/希/英双向混排（10k ops） | 900 KB | 46.083 ms | 38.388 ms (`rust_unicode_bidi`) | 0.83x | — | — |
| `unicode_bidi` | Deep 嵌套隔离与配对括号（5k ops） | 383 KB | 30.637 ms | 27.972 ms (`rust_unicode_bidi`) | 0.91x | — | — |
| `unicode_bidi` | 逐行 `visual_runs` + `reorder_line`（10k ops） | 900 KB | 69.079 ms | 48.495 ms (`rust_unicode_bidi`) | 0.70x | — | — |
| `hyphenation` | `bench100k` 批量断词（100k × 10，`opportunities_into`） | 10.28 MB（1M ops） | 144.435 ms | 487.704 ms (`rust_hyphenation`) | **3.38x** | 10.02 MiB | 9.06 MiB |
| `hyphenation` | 全量去重词典（235,915 词 × 10，`opportunities_into`） | 22.57 MB（2.36M ops） | 457.358 ms | 1,154.906 ms (`rust_hyphenation`) | **2.53x** | 18.58 MiB | 15.56 MiB |
| `hyphenation` | 词典文本建树（4,938 模式 + 1,441 例外 × 20） | 20 loads | 33.691 ms | 34.398 ms (`rust_from_text`) / 10.458 ms (`rust_bincode`) | **1.02x** (vs 文本建树) · 0.31x (vs 预编译 bincode) | 4.72 MiB | 4.48 / 2.23 MiB |
| `pdf` | 100 页矢量 + 文本报表（`/FlateDecode`） | 100 pages | 22.71 ms | 14.57 ms (`rust_pdf_writer`) | 0.64x | **4.11 MiB** | 6.36 MiB |
| `pdf` | 10 页 800×600 RGBA 导出（`/FlateDecode`，14.4 MB RGB） | 14.4 MB | 75.77 ms | 74.52 ms (`rust_pdf_writer`) | 0.98x | **24.62 MiB** | 27.61 MiB |
| `pdf` | 10 页 800×600 RGBA 导出（`/RunLengthDecode`，14.4 MB RGB） | 14.4 MB | 64.56 ms | 37.54 ms (`rust_pdf_writer`) | 0.58x | 55.41 MiB | 38.20 MiB |
| `fts` | 10,000 文档建索引 + 30 查询（多语言 + 代码语料） | 620,254 B | 45.518 ms | 32.386 ms (`sqlite_fts5_c`) / 61.211 ms (`sqlite_fts5_py`) | 0.71x (vs C) · **1.34x** (vs Python) | 25.41 MiB | 6.53 / 16.44 MiB |
| `fts` | 10,000 文档建索引 + 600 查询（30 × 20） | 600 queries | 226.551 ms | 196.257 ms (`sqlite_fts5_c`) / 223.737 ms (`sqlite_fts5_py`) | 0.87x (vs C) · 0.99x (vs Python) | 25.41 MiB | 6.58 / 16.58 MiB |
| `zip` | 全量解压 + CRC-32（200 个 JSON / 日志 / 源码文件） | 23,566,337 B | 51.997 ms | 43.306 ms (`go_zip`) / 29.660 ms (`rust_zip`) | 0.83x (vs Go) · 0.57x (vs Rust) | 6.23 MiB | 15.42 / 4.75 MiB |
| `zip` | Deflate L6 打包写出（同 200 个文件） | 23,566,337 B | 160.149 ms | 78.654 ms (`go_zip`) / 121.926 ms (`rust_zip`) | 0.49x (vs Go) · 0.76x (vs Rust) | 55.72 MiB | 65.97 / 28.53 MiB |
| `zip` | 20,000 条目 CD 扫描 + 60,000 次随机按名查找 | 3 × 20,000 ops | **43.756 ms** | 101.993 ms (`go_zip`) / 159.757 ms (`rust_zip`) | **2.33x** (vs Go) · **3.65x** (vs Rust) | **15.06 MiB** | 28.86 / 18.20 MiB |
| `dns` | 混合响应批量解码（A / AAAA / CNAME / MX / TXT / SRV / SOA / OPT） | 200,000 packets（32,627,200 B） | 268.973 ms | 245.879 ms (`rust_hickory`) / 264.416 ms (`go_miekg_dns`) | 0.91x (vs Rust) · 0.98x (vs Go) | **2.22 MiB** | 2.44 / 16.58 MiB |
| `dns` | 带压缩的批量响应编码 | 200,000 packets | 100.887 ms | 152.929 ms (`rust_hickory`) / 97.707 ms (`go_miekg_dns`) | **1.52x** (vs Rust) · 0.97x (vs Go) | **4.50 MiB** | 4.52 / 16.86 MiB |
| `dns` | 查询构造 + 编码 + 解码往返 | 500,000 ops | 109.090 ms | 162.928 ms (`rust_hickory`) / 78.874 ms (`go_miekg_dns`) | **1.49x** (vs Rust) · 0.72x (vs Go) | **1.86 MiB** | 2.23 / 16.23 MiB |
| `dns` | A1 小响应压缩编码（对抗基准） | 1M msgs | **161.74 ns/op** | 253.22 ns/op (`rust_hickory`) / 172.06 ns/op (`go_miekg_dns`) | **1.57x** (vs Rust) · **1.06x** (vs Go) | — | — |
| `dns` | A7 2,000 owner 大响应解码（对抗基准） | 2,000 owners | **177.39 µs/msg** | 189.91 µs/msg (`rust_hickory`) / 214.09 µs/msg (`go_miekg_dns`) | **1.07x** (vs Rust) · **1.21x** (vs Go) | — | — |
| `protobuf` | OTel / RPC Span 批量解码（嵌套） | 100,000 spans（24,398,500 B） | 115.646 ms | 54.200 ms (`rust_prost`) / 43.227 ms (`go_protobuf`) | 0.47x (vs Rust) · 0.37x (vs Go) | 2.84 MiB | 2.50 / 11.08 MiB |
| `protobuf` | OTel / RPC Span 批量编码（嵌套） | 100,000 spans | 39.001 ms | 18.271 ms (`rust_prost`) / 16.866 ms (`go_protobuf`) | 0.47x (vs Rust) · 0.43x (vs Go) | **3.12 MiB** | 3.19 / 5.28 MiB |
| `protobuf` | packed `sint64` + `double` 往返（8 × 400k 值） | 19,110,272 B | 24.728 ms | 22.519 ms (`rust_prost`) / 21.188 ms (`go_protobuf`) | 0.91x (vs Rust) · 0.86x (vs Go) | 13.02 MiB | 10.97 / 24.34 MiB |
| `protobuf` | `DynamicMessage` 解码（OTel spans 2,000 × 20） | 2,000 × 20 | **127.275 ms** | 205.256 ms (Go `dynamicpb`) | **1.61x** (vs Go) | **3.80 MiB** | 16.97 MiB |
| `protobuf` | `bigschema_2000`（2,000 消息 schema，20k `Leaf`） | 20k `Leaf` | **16.762 ms** | 34.043 ms (Go `dynamicpb`) | **2.03x** (vs Go) | **12.97 MiB** | 28.28 MiB |
| `graphql` | 大型 Schema SDL 解析 | 3 × 2,040,452 B | **82.777 ms** | 110.948 ms (`rust_apollo`) / 159.354 ms (`node_graphqljs`) | **1.34x** (vs Rust) · **1.93x** (vs Node) | 31.19 MiB | 23.17 / 301.61 MiB |
| `graphql` | 复杂可执行查询解析 + 静态校验 | 20,000 queries | 211.478 ms | 391.700 ms (`rust_apollo`) / 168.720 ms (`node_graphqljs`) | **1.85x** (vs Rust) · 0.80x (vs Node) | 2.73 MiB | 2.70 / 72.91 MiB |
| `graphql` | 查询压缩 + 重解析 + 打印往返 | 10,000 queries（7.25 MB） | **226.587 ms** | 278.217 ms (`rust_apollo`) / 1,050.477 ms (`node_graphqljs`) | **1.23x** (vs Rust) · **4.64x** (vs Node) | **2.75 MiB** | 2.97 / 81.27 MiB |
| `woff2` | WOFF2 解码 `Arial.woff2`（含 `glyf`/`loca` 全表逐字节一致） | 755 KB SFNT × 10 | 66.423 ms | 36.295 ms (`rust_wuff`) | 0.55x | **7.84 MiB** | 9.80 MiB |
| `woff2` | WOFF2 解码 `Monaco.woff2`（含 `glyf`/`loca` 全表逐字节一致） | 517 KB SFNT × 10 | 33.235 ms | 19.566 ms (`rust_wuff`) | 0.59x | 5.20 MiB | 4.75 MiB |
| `woff2` | WOFF1 解码 `Arial.woff`（全表逐字节一致） | 755 KB SFNT × 10 | 43.867 ms | 29.495 ms (`rust_wuff`) | 0.67x | 6.59 MiB | 5.66 MiB |
| `mp4` | 标准 MP4 解复用（H.264 720p B 帧 + AAC-LC，309 samples × 1,000） | 1,000 iters | **18.043 ms** (`18.04 µs/iter`) | 894.839 ms (`894.84 µs/iter`, `rust_symphonia`) | **49.60x** | **8.86 MiB** | 9.80 MiB |
| `mp4` | YouTube MSE fMP4 视频（`sidx`+`moof`+`mdat`，60 samples，init+seg × 1,000） | 1,000 iters | **13.992 ms** (`13.99 µs/iter`) | 373.335 ms (`373.33 µs/iter`, `rust_symphonia`) | **26.68x** | **5.30 MiB** | 7.69 MiB |
| `mp4` | 多 `trun` fMP4 视频（2 `trun`/1 `traf`，60 samples，init+seg × 1,000） | 1,000 iters | **11.052 ms** (`11.05 µs/iter`) | 392.389 ms (`392.39 µs/iter`, `rust_symphonia`) | **35.50x** | **5.30 MiB** | 7.67 MiB |
| `mp4` | YouTube MSE fMP4 音频（AAC-LC 48kHz，92 samples，init+seg × 2,000） | 2,000 iters | **14.700 ms** (`7.35 µs/iter`) | 43.697 ms (`21.85 µs/iter`, `rust_symphonia`) | **2.97x** | **2.05 MiB** | 2.66 MiB |
| `glsl` | Three.js PBR ES 1.00 Frag（parse + reflect + 410 转译，4.77 KB × 500） | 2.39 MB | **63.358 ms** (37.61 MB/s) | 1,505.716 ms (`rust_glsl 7.0.0`) | **23.77x** | **2.25 MiB** | 2.75 MiB |
| `glsl` | WebGL2 Shadertoy ES 3.00 Frag（parse + reflect + 410 转译，2.88 KB × 500） | 1.44 MB | **38.506 ms** (37.33 MB/s) | 1,502.805 ms (`rust_glsl 7.0.0`) | **39.03x** | **2.12 MiB** | 2.67 MiB |
| `glsl` | 2D Post-Process ES 1.00 Frag（parse + reflect + 410 转译，1.44 KB × 500） | 0.72 MB | **35.911 ms** (20.08 MB/s) | 910.515 ms (`rust_glsl 7.0.0`) | **25.35x** | **2.05 MiB** | 2.56 MiB |
| `http2` | HPACK 头块流解码（100,000 块，Huffman + 动态表） | 3,445,400 B | 145.847 ms (23.62 MB/s) | 116.742 ms (`rust_h2_0.4.20`) | 0.80x | **2.16 MiB** | 2.17 MiB |
| `http2` | HPACK 批量编码（100,000 块，Huffman ON + 动态表） | 28,562,500 B | 55.688 ms (512.90 MB/s) | 40.547 ms (`rust_h2_0.4.20`) | 0.73x | **3.56 MiB** | 5.28 MiB |
| `http2` | 混合 HTTP/2 帧引擎（200,000 帧：解帧 + CONTINUATION + HPACK） | 5,689,500 B | 82.564 ms (68.91 MB/s) | 72.177 ms (`rust_h2_0.4.20`) | 0.87x | **2.17 MiB** | 2.28 MiB |
| `jsonschema` | W1 MCP 工具调用批量校验（含启动 + 解析 + 编译） | 50,000 ops | 30.346 ms | 21.039 ms (`rust_jsonschema_0.29.1`) | 0.69x | **4.12 MiB** | 34.73 MiB |
| `jsonschema` | W2 清单 / 工作流批量校验（含启动 + 解析 + 编译） | 20,000 ops | 28.730 ms | 21.832 ms (`rust_jsonschema_0.29.1`) | 0.76x | **4.03 MiB** | 40.70 MiB |
| `jsonschema` | W3 编译 + 校验 E2E | 2,000 schemas | **29.104 ms** | 30.392 ms (`rust_jsonschema_0.29.1`) | **1.04x** | **4.50 MiB** | 30.92 MiB |
| `jsonschema` | W1 稳态校验斜率（去除固定开销，2,000 次） | — | 396 ns/op | 116 ns/op (`rust_jsonschema_0.29.1`) | 0.29x | — | — |
| `jsonschema` | W2 稳态校验斜率（去除固定开销，2,000 次） | — | 977 ns/op | 268 ns/op (`rust_jsonschema_0.29.1`) | 0.27x | — | — |
| `mime` | 50 MB `multipart/form-data` 解析（10 × 5 MiB 附件 + 200 字段） | 52,453,980 B | 39.383 ms (1331.88 MB/s) | 34.855 ms (`go_stdlib`) | 0.89x | **101.88 MiB** | 120.06 MiB |
| `mime` | 20 万混合 `Content-Type` / `Content-Disposition` / RFC 2047 头部解析 | 11,900,000 B | 124.604 ms (95.50 MB/s) | 74.173 ms (`go_stdlib`) | 0.60x | **2.33 MiB** | 12.14 MiB |
| `mime` | 20 万 `Content-Type` 媒体类型解析 | 6,060,000 B | 79.984 ms (75.76 MB/s) | 31.236 ms (`rust_mime`) | 0.39x | 2.06 MiB | 1.97 MiB |
| `mime` | 16 MB Quoted-Printable 解码 | 16,777,217 B | **40.049 ms** (418.91 MB/s) | 69.042 ms (`go_stdlib`) | **1.72x** | **48.25 MiB** | 55.42 MiB |
| `mime` | 10 万次魔数 MIME 嗅探 | 4,770,000 B | 20.325 ms (234.68 MB/s) | 16.937 ms (`rust_infer`) | 0.83x | 1.86 MiB | 1.80 MiB |
| `asn1` | 真实 PEM 证书链完整解析（10,000 张多算法 X.509 v3） | 11,010,800 B | 68.050 ms (161.80 MB/s) | 60.654 ms (`go_x509`) | 0.89x | **3.08 MiB** | 16.55 MiB |
| `asn1` | 纯 DER X.509 v3 解析 + 3× SAN 主机名校验（50,000 张） | 38,604,000 B | 215.075 ms (179.49 MB/s) | 182.652 ms (`go_x509`) | 0.85x | **2.56 MiB** | 18.91 MiB |
| `asn1` | 通用 ASN.1 DER TLV 编码 + 解码往返（100,000 结构） | 7,635,000 B | **120.671 ms** (63.27 MB/s) | 178.035 ms (`go_asn1`) | **1.48x** | **1.94 MiB** | 16.34 MiB |
| `sdp` | Google Meet Offer 解析（11,142 B × 2,000） | 22.28 MB | **54.080 ms** (412.06 MB/s) | 105.431 ms (`rust_sdp 0.9.0`) | **1.95x** | **2.08 MiB** | 2.53 MiB |
| `sdp` | Google Meet Offer 解析 + CRLF 往返（11,142 B × 2,000） | 22.28 MB | **87.608 ms** (254.36 MB/s) | 127.865 ms (`rust_sdp 0.9.0`) | **1.46x** | **2.30 MiB** | 2.67 MiB |
| `sdp` | Google Meet SFU Answer 解析 + CRLF 往返（9,370 B × 2,000） | 18.74 MB | **85.317 ms** (219.65 MB/s) | 141.306 ms (`rust_sdp 0.9.0`) | **1.66x** | **2.31 MiB** | 2.55 MiB |
| `stun` | STUN 编码 + 签名（`MI` + `FP`，100k WebRTC ICE 混合包） | 100,000 pkts | 331.526 ms (`3315.26 ns/op`) | 198.978 ms (`rust_webrtc_stun 0.8.0`) | 0.60x | **1.86 MiB** | 2.08 MiB |
| `stun` | STUN 解码 + 校验 `FP` + 校验 `MI`（100k WebRTC ICE 混合包） | 100,000 pkts | 368.555 ms (`3685.55 ns/op`) | 142.332 ms (`rust_webrtc_stun 0.8.0`) | 0.39x | **1.89 MiB** | 2.11 MiB |
| `rtp` | RTP 解析 + 封装（1,200 B + 3 RFC 5285 扩展 × 50,000） | 50,000 pkts | 82.330 ms (`1646.61 ns/op`) | 32.447 ms (`rust_webrtc_rtp 0.12.0`) | 0.39x | **1.80 MiB** | 2.08 MiB |
| `rtp` | RTCP 复合包解析 + 封装（SR + PLI + NACK × 50,000） | 50,000 pkts | 72.339 ms (`1446.79 ns/op`) | 62.501 ms (`rust_webrtc_rtcp 0.12.0`) | 0.86x | **1.84 MiB** | 2.20 MiB |
| `rtp` | SRTP `AES128_CM_HMAC_SHA1_80` 加密 + 解密（5,000 × 1,200 B） | 12 MB | 271.028 ms (44.28 MB/s) | 131.295 ms (`rust_webrtc_srtp 0.14.0`) | 0.48x | **1.88 MiB** | 2.08 MiB |
| `rtp` | SRTP `AEAD_AES_128_GCM` 加密 + 解密（5,000 × 1,200 B） | 12 MB | 247.303 ms (48.52 MB/s) | 120.209 ms (`rust_webrtc_srtp 0.14.0`) | 0.49x | **1.86 MiB** | 2.11 MiB |
| `webm` | VP9 + Opus 12s WebM 解复用（563 KB × 200） | 112.6 MB | **12.852 ms** (8,761.93 MB/s) | 21.545 ms (`rust_matroska 0.6.1`) | **1.68x** | 3.39 MiB | 2.86 MiB |
| `webm` | Pure Opus 60s 音频 WebM 解复用（959 KB × 200） | 191.8 MB | **17.994 ms** (10,653.33 MB/s) | 31.679 ms (`rust_matroska 0.6.1`) | **1.76x** | 4.25 MiB | 3.31 MiB |
| `webm` | AV1 + Opus 10s WebM 解复用（360 KB × 200） | 72.0 MB | **13.200 ms** (5,454.25 MB/s) | 19.635 ms (`rust_matroska 0.6.1`) | **1.49x** | 2.97 MiB | 2.59 MiB |
| `webm` | YouTube MSE Init + Clusters（562 KB × 200） | 112.4 MB | **13.249 ms** (8,490.17 MB/s) | 20.020 ms (`rust_matroska 0.6.1`) | **1.51x** | 3.39 MiB | 3.30 MiB |
| `csp` | 真实 CSP3 解析 + 评估（10k 策略 + 100k 检查，`rounds=11`） | 100,000 ops | 96.534 ms (`965.34 ns/op`) | 65.204 ms (`rust_csp`, `url 2.5.9`) | 0.68x | 2.80 MiB | 2.31 MiB |
| `csp` | WHATWG Fetch CORS 预检 + 响应 + Origin（200k ops，`rounds=11`） | 200,000 ops | 67.541 ms (`337.71 ns/op`) | 42.427 ms (`rust_csp`, `url 2.5.9`) | 0.63x | 2.73 MiB | 2.16 MiB |
| `cel` | 已编译 IAM / K8s 准入规则稳态求值（250k 上下文 × 4 规则） | 1,000,000 ops | 366.844 ms (`366.84 ns/op`) | **144.705 ms** (`go_cel v0.24.1`) | 0.39x | **2.95 MiB** | 17.66 MiB |
| `cel` | 宏 + 正则 `matches` + 时间戳批量求值 | 20,000 ops | **32.911 ms** (`1645.58 ns/op`) | 145.960 ms (`go_cel v0.24.1`) | **4.43x** | **3.36 MiB** | 19.20 MiB |
| `cel` | 端到端解析 + 类型检查 + 编译 + 求值（10 策略 × 200） | 2,000 ops | **22.450 ms** (`11224.79 ns/op`) | 152.088 ms (`go_cel v0.24.1`) | **6.77x** | **3.34 MiB** | 17.69 MiB |
| `wasm` | 二进制全解码 + 指令遍历（20 × 395,839 B） | 7,916,780 B | 127.484 ms (62.10 MB/s) | **31.710 ms** (`rust_wasmparser 0.221.3`) | 0.25x | 10.36 MiB | **2.66 MiB** |
| `wasm` | WebAssembly 规范全量校验（20 × 395,839 B） | 7,916,780 B | 105.034 ms (75.37 MB/s) | **29.676 ms** (`rust_wasmparser 0.221.3`) | 0.28x | **3.06 MiB** | 3.77 MiB |
| `wasm` | 解码 → 重编码 + WAT 反汇编（5 × 395,839 B） | 1,979,195 B | **86.426 ms** (22.90 MB/s) | 107.445 ms (`rust_wasmtools 0.221.3`) | **1.24x** | 41.30 MiB | **20.50 MiB** |
| `ical` | 4,000 `VEVENT` `.ics` 解析 + 序列化往返 | 1.93 MB | **47.27 ms** (40.76 MB/s) | 74.34 ms (`rust_icalendar 0.16.17`) | **1.57x** | **15.73 MiB** | 51.06 MiB |
| `ical` | 复杂 `RRULE` 展开（80 规则，58,000 次） | 58,000 occs | **14.72 ms** (`253.85 ns/op`) | 24.70 ms (`rust_rrule 0.14.0`) | **1.68x** | **2.27 MiB** | 7.78 MiB |
| `ical` | `RRuleSet` 窗口查询批量（200 集，72,200 次） | 72,200 occs | 26.04 ms (`130.21 µs/set`) | **24.18 ms** (`rust_rrule 0.14.0`) | 0.93x | **2.42 MiB** | 7.81 MiB |
| `ssh` | 20,000 × `authorized_keys` 解析 + SHA-256 指纹 | 20,000 keys | 88.459 ms (`4422.96 ns/op`) | **41.307 ms** (`go_x_crypto_ssh v0.38.0`) | 0.47x | **2.16 MiB** | 16.22 MiB |
| `ssh` | 5,000 × `known_hosts` `\|1\|` + 1,000 × 证书 Ed25519 CA 校验 | 6,000 ops | 214.219 ms (`35703.14 ns/op`) | **72.530 ms** (`go_x_crypto_ssh`，含等价 Go `\|1\|`) | 0.34x | **2.27 MiB** | 17.11 MiB |
| `ssh` | 1,000 × `SSHSIG` Ed25519 校验 + 50,000 × RFC 4253 分包往返 | 51,000 ops | 148.606 ms (`2913.84 ns/op`) | **54.266 ms** (`go_x_crypto_ssh`，等价 Go SSHSIG + 分包) | 0.37x | **2.09 MiB** | 14.66 MiB |
| `ssh` | `SSHSIG` RSA-2048 `rsa-sha2-256`（200 次） | 200 sigs | 93.666 ms | **22.696 ms** (`go_x_crypto_ssh`，等价 Go SSHSIG) | 0.24x | **2.33 MiB** | 10.33 MiB |
| `ssh` | `SSHSIG` ECDSA P-256 `sha512`（500 次） | 500 sigs | 977.063 ms | **40.443 ms** (`go_x_crypto_ssh`，等价 Go SSHSIG) | 0.04x | **2.38 MiB** | 11.61 MiB |
| `ssh` | `SSHSIG` Ed25519 `sha512`（500 次） | 500 sigs | 77.757 ms | **36.629 ms** (`go_x_crypto_ssh`，等价 Go SSHSIG) | 0.47x | **2.25 MiB** | 10.33 MiB |
| `http_cache` | RFC 9111 缓存策略 + Vary + 条件重验证 + 304 合并（12 场景 × 5,000） | 60,000 ops | **65.263 ms** (`1087.72 ns/op`) | 74.413 ms (`rust_http_cache_semantics 3.0.0` prebuilt) | **1.14x** | **2.05 MiB** | 2.50 MiB |
| `git` | Packfile v2 全量解包 + `OFS_DELTA` 解析 + SHA-1（合成，159.9 KB × 5） | 799.5 KB | 39.470 ms (4.05 MB/s) | **17.805 ms** (`rust_gix`) | 0.45x | 4.36 MiB | **4.20 MiB** |
| `git` | Packfile v2 全量解包（真实 `pion-packages` `.git` 包，6.1 MB × 1） | 6.1 MB | 221.075 ms (27.81 MB/s) | **110.195 ms** (`rust_gix`) | 0.50x | 48.50 MiB | **23.70 MiB** |
| `git` | 大 Tree（200 × 150 条目）+ 2,000 Commit 解析与重编码（× 3） | 5.35 MB | 37.943 ms (141.13 MB/s) | **20.510 ms** (`rust_gix`) | 0.54x | 5.66 MiB | **4.00 MiB** |
| `git` | `.git/index` v2 + v4（各 2,000 文件）+ 10,000 `pkt-line` 解码（× 5） | 4.71 MB | 17.577 ms (268.08 MB/s) | **7.895 ms** (`rust_gix`) | 0.45x | 5.25 MiB | **3.36 MiB** |
| `jq` | 10k K8s / API 事件聚合（`select` + `group_by` + `map` + `sort_by`，× 5） | 10k events | 89.242 ms | **50.694 ms** (`go_gojq v0.12.17`) | 0.57x | **23.75 MiB** | 24.02 MiB |
| `jq` | 深层嵌套树提取 + `\|=` 路径改写（× 10） | — | **18.116 ms** | 29.080 ms (`go_gojq v0.12.17`) | **1.61x** | **5.41 MiB** | 13.22 MiB |
| `jq` | 端到端编译 + 求值（1,000 查询：`reduce` / `def` / 插值 / `@csv` / `test`） | 1,000 queries | **34.467 ms** | 42.824 ms (`go_gojq v0.12.17`) | **1.24x** | **4.47 MiB** | 14.03 MiB |
| `qrcode` | 批量 URL / 2FA OTP URI 编码（10,000 次，v2–v6 M/Q，自动最优掩码） | 10,000 ops | **1115.197 ms** | 5382.242 ms (`rust_qrcode 0.14.1`；`qrcodegen` 1171.980 ms，`fast_qr` **511.794 ms**) | **4.83x** | **1.89 MiB** | 2.48 MiB |
| `qrcode` | 大版本二进制编码（300 次，v10–v40 + RS 交织） | 300 ops | 772.248 ms | 2987.593 ms (`rust_qrcode 0.14.1`；`qrcodegen` 712.249 ms，`fast_qr` **216.022 ms**) | **3.87x** | **2.16 MiB** | 3.14 MiB |
| `qrcode` | 真实混合负载（OTP / Wi-Fi / vCard / URL / 数字，10,000 次，DP 分段优化） | 10,000 ops | **1098.078 ms** | 8118.516 ms (`rust_qrcode 0.14.1`) | **7.39x** | **1.92 MiB** | 2.64 MiB |
| `mqtt` | 200,000 × MQTT 5.0 `PUBLISH`（属性 + User Property + QoS 1）编码 + 流式解码 | 200,000 pkts | 334.738 ms (`1673.69 ns/op`) | **99.373 ms** (`rust_rumqttc 0.25.1`；Go `paho` 731.590 ms) | 0.30x | **2.09 MiB** | 5.67 MiB |
| `mqtt` | 500,000 × MQTT 3.1.1 + 5.0 混合控制报文流式解码（137 B 分片） | 500,000 pkts | 101.253 ms (`202.51 ns/op`) | **44.190 ms** (`rust_rumqttc 0.25.1`) | 0.44x | **2.16 MiB** | 5.72 MiB |
| `mqtt` | 500,000 × MQTT 5.0 全 15 种控制报文（含 `AUTH`）流式解码 | 500,000 pkts | **140.293 ms** (`280.59 ns/op`) | 402.232 ms (`go_paho v0.23.0`) | **2.87x** | **2.14 MiB** | 18.28 MiB |
| `mqtt` | `TopicTrie` 路由（10,000 通配订阅 × 100,000 发布，同算法对照） | 100,000 pubs | 238.851 ms (`2388.52 ns/op`) | **151.683 ms** (`rust_trie_foldhash`；SipHash 294.326 ms，Go 355.923 ms) | 0.64x | **3.83 MiB** | 6.39 MiB |
| `bson` | BSON 解码（50,000 复合文档，owned `BsonDocument` + 遍历） | 12.01 MB | 59.839 ms (200.75 MB/s) | 99.650 ms (`rust_ref` `Document::from_reader`；零拷贝 `rust_raw` **31.190 ms**) | **1.67x** | 2.83 MiB | 2.84 MiB |
| `bson` | BSON 编码（50,000 复合文档） | 12.01 MB | **44.761 ms** (268.37 MB/s) | 47.095 ms (`rust_bson 2.15.0`) | **1.05x** | **4.45 MiB** | 5.72 MiB |
| `bson` | BSON ↔ Extended JSON v2 Canonical + Relaxed 往返（20,000 文档） | 4.81 MB | **175.664 ms** (27.35 MB/s) | 245.903 ms (`rust_bson 2.15.0`，经 `serde_json::Value`) | **1.40x** | **4.73 MiB** | 5.98 MiB |
| `resp` | 200,000 混合 RESP3 响应流式解码（137 B 分片） | 5.73 MB | 53.333 ms (107.46 MB/s) | **50.346 ms** (`rust_redis_protocol 6.0.0` 零拷贝) | 0.94x | 12.67 MiB | **7.55 MiB** |
| `resp` | 500,000 管道命令编码 + 解码往返（`SET` / `GET` / `HSET` / `MGET`） | 500,000 ops | 278.751 ms (`557.50 ns/op`) | **207.744 ms** (`rust_redis_protocol 6.0.0`) | 0.75x | 2.80 MiB | **2.31 MiB** |
| `resp` | 2,000,000 Cluster `key_slot` + 500,000 `MOVED` / `ASK` 解析 | 2,000,000 ops | 48.325 ms (`24.16 ns/op`) | **32.137 ms** (`rust_redis_protocol 6.0.0`) | 0.67x | **1.73 MiB** | 1.94 MiB |
| `hcl` | 大 Terraform 配置（2,111 块）解析 + AST 遍历（× 15） | 2,111 blocks | 590.412 ms | **420.075 ms** (`go_hcl v2.23.0`) | 0.71x | **24.05 MiB** | 59.62 MiB |
| `hcl` | 批量解析 + `EvalContext` 表达式 / `for` / 模板 / 内建函数（× 1,000） | 1,000 ops | **42.036 ms** | 129.594 ms (`go_hcl v2.23.0`) | **3.08x** | **3.00 MiB** | 15.12 MiB |
| `hcl` | `format_hcl` vs `hclwrite.Format` 批量规范格式化（× 3,000，逐字节一致） | 3,000 ops | **123.722 ms** | 169.535 ms (`go_hcl v2.23.0`) | **1.37x** | **2.56 MiB** | 18.41 MiB |
| `email` | 5,000 封多部分 MIME 邮件解析 + 正文 / 附件哈希 | 6.35 MB | 48.458 ms (130.95 MB/s) | **25.434 ms** (`rust_mail_parser 0.9.4`) | 0.52x | 3.23 MiB | **2.69 MiB** |
| `email` | 100,000 次复杂 RFC 5322 地址列表 + 日期解析 | 12.49 MB | **120.999 ms** (103.24 MB/s) | 208.833 ms (`go_net_mail`) | **1.73x** | **2.36 MiB** | 17.27 MiB |
| `email` | 2,000 封邮件构建 + DKIM `relaxed/relaxed` Ed25519 签名 / 验签往返 | 2,000 ops | 575.242 ms | **121.817 ms** (`go_msgauth v0.7.0`) | 0.21x | **2.38 MiB** | 16.98 MiB |
| `jsonpath` | W1 复杂 K8s / OpenAPI JSONPath 编译 + 查询 + 规范化路径 | 120 ops | **47.282 ms** (`394,018 ns/op`) | 185.938 ms (`rust_serde_json_path 0.7.2`) | **3.93x** | **4.67 MiB** | 5.95 MiB |
| `jsonpath` | W2 预编译 JSONPath 热路径吞吐 | 50,000 ops | 67.176 ms (`1,344 ns/op`) | **37.848 ms** (`rust_serde_json_path 0.7.2`) | 0.56x | 2.62 MiB | **2.59 MiB** |
| `jsonpath` | W3 RFC 6902 `diff_patch` + `apply_patch` + RFC 7396 `merge_patch` 往返 | 5,000 ops | 32.687 ms (`6,537 ns/op`) | **24.468 ms** (`rust_json_patch 4.2.0`) | 0.75x | 3.03 MiB | **2.92 MiB** |
| `svg` | W1a 50,000 复杂路径解析 + 三次归一 + 精确解析包围盒（同算法） | 3,836,510 B | 65.902 ms (58.22 MB/s) | **31.062 ms** (`rust_svgtypes_same_algo`；`svgtypes + kurbo` 43.426 ms) | 0.47x（vs `kurbo` 0.66x） | 9.08 MiB | **5.59 MiB** |
| `svg` | W2 2,000 嵌套图标 DOM + 变换 + 形状转路径 + 精确包围盒 | 1,742,279 B | 34.072 ms (51.14 MB/s) | **18.748 ms** (`rust_roxmltree_svgtypes`) | 0.55x | 5.92 MiB | **3.95 MiB** |
| `svg` | W3a 2,000 图标优化（同 pass，输出逐字节一致） | 1,742,279 B | 30.566 ms (57.00 MB/s) | **19.720 ms** (`rust_roxmltree_svgtypes`；非等价参考 `svgo@3.3.2` 671.579 ms) | 0.65x | 5.95 MiB | **3.89 MiB** |
| `promql` | W1 生产 PromQL 解析 + 规范 `String()` | 20,000 ops | 210.604 ms (`10530.20 ns/op`) | **151.355 ms** (`go_promql v0.302.1`) | 0.72x | **2.98 MiB** | 30.53 MiB |
| `promql` | W2 指标选择器解析 + 标签抽取 | 50,000 ops | 357.538 ms (`7150.76 ns/op`) | **143.705 ms** (`go_promql v0.302.1`) | 0.40x | **2.91 MiB** | 29.69 MiB |
| `promql` | W3 内存时序求值（`eval_instant` + `eval_range`，5,600 点） | 200 iters | **17.750 ms** (`3169.73 ns/op`) | 46.888 ms (`go_promql` `promql.Engine` + `teststorage`) | **2.64x** | **2.80 MiB** | 35.97 MiB |
| `lua` | W1 Sieve(4000) × 20 + Fib(24) + 表排序 / 聚合 | 1 script | 124.518 ms | **28.668 ms** (`gopher_lua v1.1.1`) | 0.23x | **4.47 MiB** | 11.27 MiB |
| `lua` | W2 闭包 + 元表 OOP + 模式 `gsub` / `gmatch` / `format`（1,500 轮） | 1,500 iters | 50.590 ms | **33.985 ms** (`gopher_lua v1.1.1`) | 0.67x | **6.56 MiB** | 12.41 MiB |
| `lua` | W3 编译 + 新建沙箱 VM 执行（2,000 脚本，公平配置：Go `SkipOpenLibs` + `base/table/string/math`） | 2,000 scripts | **43.806 ms** | 103.180 ms (`gopher_lua v1.1.1`；全库 `NewState` 165.528 ms → **3.53x**) | **2.36x** | **2.78 MiB** | 19.97 MiB |
| `openapi` | W1 大型 OpenAPI 3.0.3 规范（150 路径 / 250 操作 / 密集 `$ref`）解析 + `$ref` + 静态校验 | 10 iters | **21.078 ms** | 124.374 ms (`go_kin v0.131.0` `LoadFromData` + `Validate`) | **6.05x**（含 `Validator::from_doc` 同工作量 32.626 ms → **3.81x**） | **4.48 MiB** | 20.84 MiB |
| `openapi` | W2 RFC 6570 高频路由 + 路径参数抽取 | 50,000 ops | **19.483 ms** (`389.66 ns/op`) | 222.918 ms (`go_kin` `gorillamux`) | **11.44x** | **4.50 MiB** | 23.38 MiB |
| `openapi` | W3 请求体 + 参数校验（路由 + 校验端到端） | 10,000 reqs | **20.895 ms** (`2089.48 ns/op`) | 66.362 ms (`go_kin` `openapi3filter`) | **3.18x**（纯校验约持平） | **6.95 MiB** | 21.47 MiB |
| `avro` | W1 二进制编码 + 解码往返（50,000 嵌套记录） | 2,607,112 B | 109.163 ms | **79.457 ms** (`go_hamba_any v2.28.0`；typed `struct` 33.958 ms) | 0.73x | **72.03 MiB** | 98.31 MiB |
| `avro` | W2 Schema 演进批量解码 Writer v1 → Reader v2（50,000 记录） | 2,607,112 B | 47.841 ms (54.50 MB/s) | **34.008 ms** (`go_hamba_any`；typed `struct` 15.572 ms) | 0.71x | 51.42 MiB | **41.69 MiB** |
| `avro` | W3 `.avro` OCF deflate 50 块写 + 读（50,000 记录） | 2,607,112 B | 146.121 ms | **99.143 ms** (`go_hamba_any`；typed `struct` 54.536 ms) | 0.68x | **69.03 MiB** | 104.55 MiB |
| `kdl` | W1 大型真实 KDL v2 配置解析 | 8,056,290 B | **204.810 ms** (39.34 MB/s) | 3,999.952 ms (`rust_kdl 6.7.1` 无损 CST) | **19.53x** | **25.97 MiB** | 104.06 MiB |
| `kdl` | W2 解析 + 格式化 + 重解析往返 | 1,469,340 B | **109.090 ms** (13.47 MB/s) | 1,503.416 ms (`rust_kdl`) | **13.78x** | **2.97 MiB** | 8.17 MiB |
| `kdl` | W3 小配置高频解析 + 抽取（8,000 次） | 3,744,000 B | **137.341 ms** (`pion_accessor`；`pion_query` 125.344 ms → 12.46x) | 1,562.345 ms (`rust_kdl`) | **11.38x** | **2.05 MiB** | 2.52 MiB |
| `kdl` | W4 10 万属性宽节点解析 | 3,833,370 B | **154.170 ms** (24.86 MB/s) | 1,569.316 ms (`rust_kdl`) | **10.18x** | **29.86 MiB** | 84.44 MiB |
| `xpath` | W1 866 KB 大文档 10 条预编译复合查询（5 轮） | 866,214 B | 101.466 ms | 320.295 ms (`rust_sxd 0.4.2`) / **85.358 ms** (`c_libxml2`) | **3.16x**（vs Rust）/ 0.84x（vs C） | 13.88 MiB | **13.55 MiB** |
| `xpath` | W2 高频 XPath 编译 + 求值 | 20,000 iters | 420.083 ms (`21004.15 ns/op`) | 535.888 ms (`rust_sxd`) / **299.880 ms** (`c_libxml2`) | **1.28x**（vs Rust）/ 0.71x（vs C） | 2.73 MiB | **2.08 MiB** |
| `xpath` | W3 深层递归轴 + 聚合 | 156,950 B | 49.204 ms | 69.649 ms (`rust_sxd`) / **42.092 ms** (`c_libxml2`) | **1.42x**（vs Rust）/ 0.86x（vs C） | 5.20 MiB | **4.55 MiB** |
| `xpath` | W4 大节点集比较（8,000 × 8,000） | 182,939 B | **36.693 ms** | 276.451 ms (`rust_sxd`) / 585.176 ms (`c_libxml2`) | **7.53x**（vs Rust）/ **15.95x**（vs C） | 10.00 MiB | **7.45 MiB** |
| `xpath` | W5 > 1 MB 文档（50,000 元素，默认 `XPathLimits`） | 1,188,939 B | **168.141 ms** | 404.483 ms (`rust_sxd`) / 195.615 ms (`c_libxml2`) | **2.41x**（vs Rust）/ **1.16x**（vs C） | **27.69 MiB** | 29.89 MiB (C) |
| `proxy` | W1 代理 URL 解析 + 强制脱敏 + `NO_PROXY` 匹配 | 200,000 ops | **59.627 ms** (`298.14 ns/op`) | 71.454 ms (`go_ref`，`net/url` + `net/netip` 手写) | **1.20x** | **1.84 MiB** | 16.00 MiB |
| `proxy` | W2 SOCKS5 完整双向握手（`UserPass` + `ATYP=0x03`） | 500,000 rounds | 213.555 ms (`427.11 ns/op`) | **39.357 ms** (`go_ref`，内联字节切片) | 0.18x | **1.83 MiB** | 9.20 MiB |
| `proxy` | W3 HTTP `CONNECT` + 明文正向代理头清洗（Pion 含完整 CL/TE 走私校验） | 100,000 requests | **245.813 ms** (`2458.13 ns/op`) | 382.039 ms (`go_net_http`) | **1.55x** | **1.95 MiB** | 19.59 MiB |
| `gif` | 静态 512×512 纹理 GIF → RGBA8888（`decode_first_frame` × 60） | 60 MiB RGBA | **84.769 ms**（发布复测） | 90.543 ms (`go_image_gif`) | **1.07x**（包基准 1.10x） | **4.23 MiB** | 11.92 MiB |
| `gif` | 256×256 × 24 帧动画（4 种 Disposal + 透明）全帧合成 × 30 | 180 MiB RGBA | **66.250 ms**（发布复测） | 78.357 ms (`go_image_gif`) | **1.18x**（包基准 1.15x） | **17.53 MiB** | 21.38 MiB |
| `webvtt` | 解析 + `plain_text` + 2,000 次时间轴查询（20 × 8,000 cues） | 27,534,460 B | 107.692 ms（发布复测） | 110.258 ms (`go_ref`) / **96.302 ms** (`go_tuned`) | **1.02x**（vs `go_ref`；包基准 1.04x）/ 0.89x（vs `go_tuned`；包基准 0.90x） | **6.70 MiB** | 16.28 / 17.12 MiB |
| `webp` | VP8L 无损 512×512 → RGBA8888 × 30 | 30 MiB RGBA | **130.652 ms** | 154.463 ms (`go_x_image_webp`) | **1.18x** | **4.47 MiB** | 11.95 MiB |
| `webp` | VP8 有损 512×512 → RGBA8888 × 30 | 30 MiB RGBA | 147.946 ms | **143.284 ms** (`go_x_image_webp`) | 0.97x | **4.39 MiB** | 12.89 MiB |
| `webp` | VP8X + ALPH（VP8L alpha + VP8 有损）512×512 → RGBA8888 × 30 | 30 MiB RGBA | **179.968 ms** | 192.009 ms (`go_x_image_webp`) | **1.07x** | **4.80 MiB** | 11.97 MiB |
| `webp` | v0.2.0 VP8L 无损编码 512×512 RGBA（`exact`，进程内，× 10，Linux x86_64） | 10 MiB RGBA | **583.544 ms** | 1267.907 ms (`libwebp_z4` C `-O2 -lwebp`) | **2.17x** | **8.79 MiB** | 27.07 MiB |
| `wgsl` | WGSL 解析 + 校验 + MSL 2.x / GLSL 生成（PBR + Compute Reduce + Particles，200 × 3 份，1,400 次编译；两端管线工作量不同，见 [`wgsl`](#wgsl)） | 1,014,000 B | **121.677 ms** (`86911.79 ns/op`) | 165.073 ms (`rust_naga`，`naga =24.0.0`) | **1.36x**（审计复测 1.34x） | **3.19 MiB** | 4.47 MiB |
| `exif` | EXIF 解析 + `format_canonical`（JPEG + BE TIFF + WebP + PNG 4 容器相机尺寸语料，72 tags / 文件，含 30 KB MakerNote 与 11 KB 缩略图，× 25,000 = 100,000 次解析） | 10,923,100,000 B | **465.537 ms** (`4655.37 ns/op`) | 618.723 ms (`rust_kamadak_exif`，`kamadak-exif =0.6.2`) | **1.33x**（审计复测 1.40x） | **3.45 MiB** | 4.09 MiB |
| `icc` | 解析 + `Transform::to_srgb` + 饱和探针 `(200, 70, 40)`，Display-P3 v4 `para3`（× 20,000） | 8,880,000 B | **30.258 ms** (`1512.88 ns/op`) | 50.890 ms (`rust_qcms_pre`，`qcms =0.3.0` 预缓存) / 856.125 ms (`rust_moxcms`) | **1.68x**（vs `moxcms` **28.29x**） | **2.06 MiB** | 2.41 / 2.80 MiB |
| `icc` | 同上，sRGB v2 `curv[1024]`（× 20,000） | 49,520,000 B | 60.565 ms (`3028.24 ns/op`) | **54.914 ms** (`rust_qcms_pre`) / 842.186 ms (`rust_moxcms`) | 0.91x（vs `moxcms` **13.91x**） | **2.08 MiB** | 2.34 / 2.81 MiB |
| `icc` | 同上，AdobeRGB v2 `curv` gamma（× 20,000） | 8,640,000 B | **70.213 ms** (`3510.64 ns/op`) | 82.256 ms (`rust_qcms_pre`) / 895.762 ms (`rust_moxcms`) | **1.17x**（vs `moxcms` **12.76x**） | **2.06 MiB** | 2.36 / 2.69 MiB |
| `icc` | 同上，Rec.2020 v4 `para3`（709 TRC，× 20,000） | 8,800,000 B | 71.605 ms (`3580.26 ns/op`) | **50.809 ms** (`rust_qcms_pre`) / 860.987 ms (`rust_moxcms`) | 0.71x（vs `moxcms` **12.02x**） | **2.06 MiB** | 2.41 / 2.89 MiB |
| `icc` | 1920×1080 RGBA8 Display-P3 → sRGB × 20 帧（41,472,000 px） | 165,888,000 B | 107.813 ms (`2.60 ns/px`) | 100.764 ms (`rust_qcms_pre`) / **52.097 ms** (`rust_moxcms`，NEON) | 0.93x（vs `moxcms` 0.48x） | 17.98 MiB | **10.16** / 18.33 MiB |
| `encoding` | 解码 UTF-8 ~1 MiB 真实 HTML（× 100） | 104,809,800 B | 47.195 ms (2220.79 MB/s) | **14.345 ms** (`rust_encoding_rs`) | 0.30x | **5.19 MiB** | 9.16 MiB |
| `encoding` | 解码 GB18030 ~1 MiB HTML（× 100） | 104,815,200 B | 243.813 ms (429.90 MB/s) | **64.240 ms** (`rust_encoding_rs`) | 0.26x | 14.20 MiB | **9.20 MiB** |
| `encoding` | 解码 Shift_JIS ~1 MiB HTML（× 100） | 104,830,200 B | 226.179 ms (463.48 MB/s) | **86.963 ms** (`rust_encoding_rs`) | 0.38x | **8.42 MiB** | 9.17 MiB |
| `encoding` | `encode_html` Big5，~1 MiB UTF-8 HTML（NCR 回退，× 20） | 20,963,640 B | **357.426 ms** (58.65 MB/s) | 397.445 ms (`rust_encoding_rs`) | **1.11x** | 6.84 MiB | **5.17 MiB** |
| `encoding` | `encode_html` gb18030，~1 MiB UTF-8 HTML（× 20） | 20,971,000 B | **363.519 ms** (57.69 MB/s) | 367.104 ms (`rust_encoding_rs`) | **1.01x** | **6.77 MiB** | 9.20 MiB |
| `encoding` | `encode_html` Shift_JIS，~1 MiB UTF-8 HTML（× 20） | 20,962,800 B | 195.433 ms (107.26 MB/s) | **109.661 ms** (`rust_encoding_rs`) | 0.56x | 6.77 MiB | **5.17 MiB** |
| `encoding` | `encode_html` EUC-KR，~1 MiB UTF-8 HTML（× 20） | 20,965,480 B | 308.335 ms (68.00 MB/s) | **60.401 ms** (`rust_encoding_rs`) | 0.20x | 6.80 MiB | **5.16 MiB** |
| `css_color` | CSS Color 4 解析 + sRGB 转换（2,042 条 × 100，204,200 次） | 6,250,700 B | 66.646 ms (93.79 MB/s) | **29.791 ms** (`rust_color`) | 0.45x | 2.36 MiB | **2.23 MiB** |
| `css_color` | 4 段管线 sRGB → Oklch → Display-P3 → Lab → sRGB（2,042 色 × 200，408,400 次） | — | 296.204 ms (725.28 ns/op) | **74.826 ms** (`rust_color`) | 0.25x | 2.56 MiB | **2.30 MiB** |
| `cookie` | RFC 6265bis `Set-Cookie` 解析（200 条 × 2,000，400,000 次） | 26,000,000 B | 121.602 ms (213.81 MB/s) | **60.322 ms** (`rust_cookie`) | 0.50x | **2.03 MiB** | 2.30 MiB |
| `cookie` | Mozilla PSL 可注册域 + 公共后缀查找（106 域 × 2,000，212,000 次） | 2,786,000 B | 88.841 ms (419.06 ns/op) | **17.468 ms** (`rust_psl`) | 0.20x | **2.19 MiB** | 2.58 MiB |
| `opentype` | 惰性 `Face::parse` + 256 次 `cmap` / `hmtx` + 64 个 `glyf` 轮廓，Arial.ttf（× 200） | 154,647,200 B | 17.542 ms (87.71 µs/op) | **9.860 ms** (`rust_ttf_parser`) | 0.56x | 3.44 MiB | **2.72 MiB** |
| `opentype` | 同上，合成 512 字形可变字体 `synthetic_512.ttf`（× 200） | 4,559,200 B | 12.215 ms (61.08 µs/op) | **9.698 ms** (`rust_ttf_parser`) | 0.79x | 2.00 MiB | 2.00 MiB |
| `hls` | 主语料：70 个 Master / Media / LL-HLS 播放列表解析（× 50，3,500 次） | 21,627,600 B | **97.242 ms** (222.41 MB/s) | 134.893 ms (`rust_m3u8_rs`) | **1.39x** | 4.03 MiB | **3.52 MiB** |
| `hls` | `altbench` 现实语料：60 个长 URL / 逐分片 PDT / 密钥轮换 / 显式字节范围播放列表（× 5，300 次） | 42,287,085 B | 126.932 ms (333.15 MB/s) | **115.993 ms** (`rust_m3u8_rs`) | 0.91x | 27.44 MiB | **13.77 MiB** |
| `dash` | 主语料：60 个 MPD 清单解析（静态 `SegmentBase` / 动态 `SegmentTemplate` + `SegmentTimeline` / 多 `Period` DRM / `SegmentList`，× 200，12,000 次） | 23,996,400 B | **212.539 ms** (112.90 MB/s) | 277.300 ms (`rust_dash_mpd`) | **1.30x** | **2.94 MiB** | 8.61 MiB |
| `dash` | `altbench` 现实语料：12 个多 `Period` 插播 / Widevine + PlayReady `pssh` / 2 h `SegmentTimeline` / 带令牌 URL 清单 | 1,078,211 B | **334.877 ms** (64.39 MB/s) | 395.973 ms (`rust_dash_mpd`) | **1.18x** | **9.80 MiB** | 15.39 MiB |
| `lepton` | Baseline 512×512 RGB JPEG (`SOF0`, 50,288 B) 往返 ×10（Linux x86_64） | 502,880 B | 446.070 ms (1.13 MB/s) | **212.924 ms** (`rust_lepton_jpeg`) | 0.48x | **4.89 MiB** | 8.71 MiB |
| `lepton` | Progressive 512×512 Luma JPEG (`SOF2`, 44,142 B) 往返 ×10（Linux x86_64） | 441,420 B | 385.331 ms (1.15 MB/s) | **262.010 ms** (`rust_lepton_jpeg`) | 0.68x | **4.58 MiB** | 8.26 MiB |
| `lepton` | Baseline 512×512 RGB JPEG (`SOF0`, 50,288 B) 解码 ×10（Linux x86_64） | 502,880 B | 216.703 ms (2.32 MB/s) | **155.921 ms** (`rust_lepton_jpeg`) | 0.72x | **4.30 MiB** | 8.13 MiB |
| `bzip2` | L6 压缩：结构化 JSON 日志语料（768 KiB × 3，Linux x86_64） | 2,359,296 B | 656.495 ms (3.59 MB/s) | **269.012 ms** (`rust_bzip2` `0.6.1`) | 0.41x | 15.34 MiB | **7.77 MiB** |
| `bzip2` | L6 解压：结构化 JSON 日志语料（768 KiB × 10，Linux x86_64） | 7,864,320 B | 267.268 ms (29.42 MB/s) | **182.432 ms** (`rust_bzip2` `0.6.1`) | 0.68x | 8.79 MiB | **6.46 MiB** |
| `preflate` | RFC 1951 `analyze` + `reencode` 往返（zlib L1，Linux x86_64，× 3） | 2,892,498 B 明文（186,902 B DEFLATE） | 90.985 ms (31.79 MB/s) | **46.661 ms** (`rust_preflate_rs`) | 0.51x | **7.04 MiB** | 7.56 MiB |
| `preflate` | RFC 1951 `analyze` + `reencode` 往返（zlib L6，Linux x86_64，× 3） | 2,892,498 B 明文（151,737 B DEFLATE） | 164.980 ms (17.53 MB/s) | **82.277 ms** (`rust_preflate_rs`) | 0.50x | **6.96 MiB** | 7.59 MiB |
| `preflate` | RFC 1951 `analyze` + `reencode` 往返（zlib L9，Linux x86_64，× 3） | 2,892,498 B 明文（136,769 B DEFLATE） | 468.736 ms (6.17 MB/s) | **112.447 ms** (`rust_preflate_rs`) | 0.24x | **6.87 MiB** | 7.38 MiB |
| `idna` | 多语种 IDN 语料：200 个 100% IDN / Punycode / NFD / 全角域名 × 200 次 `to_ascii` + `to_unicode`（80,000 次） | 649,000 B | 77.321 ms (8.39 MB/s) | **26.143 ms** (`rust_idna`) | 0.34x | 2.48 MiB | **2.17 MiB** |
| `idna` | 真实浏览器流量语料：70% ASCII / 30% IDN 与 Punycode × 200 次 `to_ascii` + `to_unicode`（80,000 次） | 722,000 B | 24.835 ms (29.07 MB/s) | **19.740 ms** (`rust_idna`) | 0.79x | 2.48 MiB | **2.11 MiB** |

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

**4. `v0.3.0` 树状 AST 与纯文本提取（Mixed GFM corpus `2,503,227 B`，`warmup=1`、`rounds=5`）**

| Operation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| `to_html_pulldown`（回归复测，同轮 Rust 21.543 ms → 0.91x） | 23.704 | 21.792 | 24.299 | 105.60 | 18.44 MiB |
| `parse_document`（完整树状 `Document` AST） | 35.851 | 34.484 | 36.133 | 69.82 | 33.84 MiB |
| `to_plain_text`（全文，`collapse_whitespace: true`） | 41.174 | 39.394 | 43.375 | 60.80 | 34.88 MiB |
| `to_plain_text`（`max_chars: 120` 预览 + 占位符） | 34.076 | 30.610 | 36.293 | 73.46 | 33.86 MiB |

`pulldown-cmark` 只有事件流、没有树状 AST 与纯文本预览，这一组无同构上游实现，只列 Pion 自身数据。725 / 725 单测；`audit_v030`（0 P0 + 3 P1 + 6 P2 + 1 既有缺陷全部修复）`QUICK=1` **exit 0**；`wasm_smoke` 4 模式 stdout 均为 `639 B`、SHA-256 `dbb0840afd40e42a7fe5c059665a57695ae70099f6f96955722ced80b7a4ec02`。

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

### cron

参考实现：Rust [`croner`](https://github.com/Hexagon/croner-rust) `=2.1.0` + `chrono` `=0.4.39`（`cargo build --release`）、Go [`robfig/cron/v3`](https://github.com/robfig/cron) `v3.0.1`；对抗负载另对照 Java Quartz 2.3.2。`--warmup 1 --rounds 5`，标准负载 `sh packages/cron/bench/run_bench.sh`，对抗负载 `sh packages/cron/audit/run_audit.sh` §7。详见 [`packages/cron/README.md`](packages/cron/README.md)。

**W1: Parse 100 Production Cron Expressions × 1,000 Rounds (100,000 parse ops)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_croner`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 23.914 | 22.227 | 27.972 | 239.14 | 1.75 MiB | 6.36x |
| `rust_croner` | 152.088 | 146.412 | 171.631 | 1520.88 | 5.66 MiB | 1.00x (baseline) |
| `go_robfig` | 50.801 | 45.282 | 52.404 | 508.01 | 12.28 MiB | 2.99x |

_SHA-256 verified identical across all implementations and rounds: `1be910972faf8b39adb7459b4b9cb4354c69f49b106a23b21b0bf58306a6d321`._

**W2: Next-After Stepping (100 Expressions × 20 Rounds × 50 Steps = 100,000 `next_after` ops)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_croner`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 15.311 | 14.351 | 16.666 | 153.11 | 1.77 MiB | 5.13x |
| `rust_croner` | 78.508 | 73.963 | 83.178 | 785.08 | 5.67 MiB | 1.00x (baseline) |
| `go_robfig` | 141.102 | 132.285 | 142.351 | 1411.02 | 4.55 MiB | 0.56x |

_SHA-256 verified identical across all implementations and rounds: `58ad2a568af15f5aabd5ea178ade64496cd0f4f14c0cf778e71aa15a09db851f`._

**W3: Sparse / Rare Dates Stepping (`0 0 29 2 *`, `0 0 31 12 *`, `0 0 30 4 *`, `0 0 1 1 *`, `0 0 31 1,3,5,7,8,10,12 *`, 10,000 ops)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_croner`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 8.095 | 7.655 | 13.684 | 809.45 | 1.75 MiB | 3.47x |
| `rust_croner` | 28.057 | 27.752 | 41.915 | 2805.67 | 5.48 MiB | 1.00x (baseline) |
| `go_robfig` | 34.111 | 33.779 | 41.001 | 3411.12 | 4.41 MiB | 0.82x |

_SHA-256 verified identical across all implementations and rounds: `54226233917f64c1af181715a2cdb1e62a4d03c24a0000cfaa2ff82f14367747`._

**W4: Friday the 13th (`0 0 13 * 5` with `dom_and_dow = true`, 10,000 ops, Pion vs Rust `croner`)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_croner`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 8.962 | 7.829 | 9.591 | 896.16 | 1.75 MiB | 6.98x |
| `rust_croner` | 62.558 | 60.504 | 64.561 | 6255.83 | 5.45 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `329bd33da0317b71d7d614d94a091b1498227820e127a83d6750ab7a343fb3ee`._

**Adversarial Workloads A1–A6 (`sh packages/cron/audit/run_audit.sh` §7, `Darwin arm64`, `--warmup 1 --rounds 5`, SHA-256 verified identical)**

| Workload | Pion | Rust `croner` 2.1.0 | Go `robfig` v3.0.1 | Java `Quartz` 2.3.2 | Pion vs best upstream |
| --- | ---: | ---: | ---: | ---: | ---: |
| A1 Quartz `L`/`W`/`#`/`nL` stepping (320k ops) | 123.43 ns/op | 1,040.21 ns/op | — | 2,085.80 ns/op | **8.43x faster** |
| A2 Quartz `LW` / `L-n` stepping (200k ops) | 137.21 ns/op | — | — | 2,704.71 ns/op | **19.71x faster** |
| A3 7-field year ranges/steps/lists (66.8k ops) | 237.63 ns/op | — | — | 3,558.31 ns/op | **14.97x faster** |
| A4 Impossible date + 157-item year list (2k searches) | 9,624.88 ns/op | — | — | 346,684.19 ns/op | **36.02x faster** |
| A5 Reject 21 malformed expressions (420k ops) | 95.53 ns/op | 919.47 ns/op | 310.42 ns/op | — | **3.25x faster** |
| A6 Long explicit lists up to 2 KB (60k parses) | 5,350.61 ns/op | 21,389.53 ns/op | 15,941.90 ns/op | — | **2.98x faster** |

_9,999-item year list DoS probe (`0 0 0 31 2,4,6,9,11 ? 1,2,...,9999`, single `next_after`): **0.008 s** wall-clock (including process start), down from 10.042 s prior to year-bitmap precompilation._

红队：15/15 单测；对抗负载 A1–A6 与上游 SHA-256 一致，对最佳上游 2.98x–36.02x；9,999 项年份列表 DoS 探针（单次 `next_after`）由年份位图预编译前的 10.042 s 降至 0.008 s（含进程启动）。领先项：W1–W4 全部快于 `croner`（3.47x–6.98x），峰值 RSS 最低（1.75–1.77 MiB）。落后 / 口径说明：W2–W3 中 Go `robfig` 慢于 `croner`（0.56x / 0.82x）；W3 / W4 墙钟约 9.5–10.8 ms，进程启动占明显比例；`robfig` 不接受 `7` 表示周日、无 `dom_and_dow` AND 选项（故不参与 W4）、单次前瞻上限 `t.Year() + 5`（W3 闰日步进限定在 `2024..2088`）；`packages/cron` 只处理 UTC 民用时间 / Unix 秒，不做 IANA 时区与 DST 调整。

### msgpack

参考实现：Rust [`rmpv`](https://github.com/3Hren/msgpack-rust) `1.3.1`（`--release`，`read_value` 动态树）、Go [`vmihailenco/msgpack/v5`](https://github.com/vmihailenco/msgpack) `v5.4.1`（`any` / `map[string]any`，`SetSortMapKeys(true)`）。`--warmup 1 --rounds 5`，标准负载 `sh packages/msgpack/bench/run_bench.sh`，对抗与惯用口径对比来自 `audit/run_audit.sh`。详见 [`packages/msgpack/README.md`](packages/msgpack/README.md)。

**Workload 1: Nested RPC/Telemetry Decode (40 × 2,000 = 80,000 records)**

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `67 B` (`sha256:988b268324c5f308...`) | Input: `13655320 B` | Ops: `80000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs go_vmihailenco) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **71.684** | 70.188 | 75.939 | **190.49** | **896.06** | 7.66 MiB | **1.65x** |
| `rust_rmpv` | 108.612 | 95.365 | 113.814 | 125.73 | 1357.65 | 6.62 MiB | 1.09x |
| `go_vmihailenco` | 118.004 | 114.465 | 122.632 | 115.72 | 1475.05 | 15.77 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `988b268324c5f308408ec8f8c6f2b855114df4704c463f0240a64a64e491c1df`._

**Workload 2: Nested RPC/Telemetry Encode (50,000 records)**

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `48 B` (`sha256:76af0c6f9e92027a...`) | Ops: `50000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs go_vmihailenco) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **36.296** | 35.673 | 38.111 | **725.92** | **1.78 MiB** | **1.30x** |
| `rust_rmpv` | 37.416 | 35.998 | 38.195 | 748.32 | 1.98 MiB | 1.26x |
| `go_vmihailenco` | 47.108 | 46.527 | 48.053 | 942.17 | 11.25 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `76af0c6f9e92027a3c488da154c32a0c13b5bba73a8aec34daa7ed9e2d7377f2`._

**Workload 3: Large `bin` + `str` + `array` Decode (4 × ~16 MiB = ~64 MiB)**

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `57 B` (`sha256:556ed267b0263a59...`) | Input: `64811276 B`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs go_vmihailenco) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 29.840 | 28.826 | 31.210 | 2171.92 | **37.64 MiB** | 0.81x |
| `rust_rmpv` | 25.849 | 24.355 | 28.997 | 2507.25 | 40.06 MiB | 0.94x |
| `go_vmihailenco` | **24.195** | 23.763 | 26.274 | **2678.71** | 67.84 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `556ed267b0263a59107e7938427c471ffe6938cdf76b06c916625136a90d7ed1`._

**Idiomatic & Adversarial Comparison (from `audit/run_audit.sh`, SHA-256 verified)**

| Workload | Pion | Go (idiomatic struct / `any`) | Rust `rmpv::read_value` | Rust `rmpv::read_value_ref` |
| --- | ---: | ---: | ---: | ---: |
| W1 decode-rpc 80k (vs Go typed struct) | 69.9 ms | **61.9 ms** (struct, Go 1.13×) / 119.9 ms (`any`) | 96.6 ms | — |
| W1 RPC generic tree walk (80k) | 62.5 ms | 116.1 ms (`any`) | 94.6 ms | **54.5 ms** (Rust ref 1.15×) |
| W2 encode-rpc 50k (vs Go typed struct) | 39.4 ms | **27.8 ms** (struct, Go 1.42×) / 48.0 ms (`any`) | 37.6 ms | — |
| 1M `int` array ×5 | 82.9 ms | 120.9 ms (`any`) | 60.9 ms | **53.2 ms** |
| 1M `float32` array ×5 | 69.9 ms | 112.6 ms (`any`) | 59.6 ms | **48.6 ms** |
| 1M `float64` array ×5 | 81.5 ms | 117.8 ms (`any`) | 63.3 ms | **54.7 ms** |
| Depth 100 × 10k ×5 (`decode_iter` path) | 396.1 ms | **241.5 ms** (`any`) | 530.7 ms | 397.3 ms |
| 10k-key `str` map ×50 (dup reject) | **43.8 ms** | 62.2 ms (Go map) | 121.1 ms | — |
| Streaming 256 KiB / 65,536 frames (`decode_prefix_at`) | 14.9 ms (2.3 MiB RSS) | 22.5 ms | **12.8 ms** | — |
| Streaming 2 MiB / 524,288 frames (`decode_prefix_at`) | 52 ms (5.7 MiB RSS) | 103 ms | **36 ms** | — |
| HashDoS 262,144 crafted uint64 keys (`reject_duplicate_keys`) | **30 ms** (random: 34 ms) | 55 ms (Go map) | 57 ms (HashSet) | — |

红队：27/27 单测 + 11 个红队审计测试；15 个官方 `msgpack-test-suite` 套件全量移植。领先项：对动态树基线，W1 RPC 解码 1.65x（vs Go）/ 1.52x（vs Rust）、W2 RPC 编码 1.30x / 1.03x，峰值 RSS 最低；keyed SipHash-1-3 使 262,144 个构造键 HashDoS 用时 30 ms（与随机键 34 ms 相当），优于 Go / Rust；`decode_prefix_at` 去掉整缓冲 `to_string()` 缓存后 2 MiB / 524,288 帧流式解码 52 ms（5.7 MiB RSS）。落后项：W3 64 MiB 大载荷 0.81x（vs Go）/ 0.87x（vs Rust），因 Pion 对 12.5 MiB 多字节 UTF-8 做完整标量 RFC 3629 校验（Go `msgpack` 跳过校验，Rust 用 SIMD `from_utf8`）；Go 类型化 struct 仍更快（解码 1.13×、编码 1.42×），Rust 零拷贝 `read_value_ref` 在借用树（1.15×）与 1M 稠密数值数组（1.44–1.56×）上仍更快。

### json5

参考实现：Rust [`json5`](https://github.com/callum-oakley/json5-rs) `=1.3.8` + `serde_json` `=1.0.140`（`preserve_order`）+ [`json-patch`](https://github.com/idubrov/json-patch) `=4.2.0`（`--release`，LTO）、Node.js `json5@2.2.3` + `fast-json-patch@3.1.1`（Node v24.22.2）。`--warmup 1 --rounds 5`，`sh packages/json5/bench/run_bench.sh`，对抗负载来自 `packages/json5/audit`。详见 [`packages/json5/README.md`](packages/json5/README.md)。

**Workload 1: Large Commented JSON5 Config Parse (60× 95.6 KB = 5.74 MB)**

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `181 B` (`sha256:0a2adae864081868...`) | Input: `5738040 B` | Ops: `60`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_json5) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 46.070 | 43.051 | 47.728 | 124.55 | 767840.28 | 2.58 MiB | 0.98x |
| `rust_json5` | 45.344 | 43.230 | 46.249 | 126.54 | 755736.10 | 2.84 MiB | 1.00x (baseline) |
| `node_json5` | 335.266 | 311.695 | 346.727 | 17.11 | 5587772.92 | 71.67 MiB | 0.14x |

_Note: Against the earlier `pest`-based Rust `json5 =0.4.1` (271.919 ms median / 21.10 MB/s), `pion` is **5.48x faster**. Against the rewritten Rust `json5 =1.3.8`, `pion` matches within 2% (0.98x median, faster min) with lower peak RSS (2.58 MiB vs 2.84 MiB) and is **7.28x faster** than Node `json5@2.2.3`._

**Workload 2: JSON5 → Standard JSON Serialization Roundtrip (40× 95.6 KB = 3.83 MB)**

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `63 B` (`sha256:0c48002fe75458d2...`) | Input: `3825360 B` | Ops: `40`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_json5) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 47.108 | 45.472 | 51.839 | 81.20 | 1177703.12 | 2.84 MiB | 0.84x |
| `rust_json5` | 39.354 | 38.548 | 40.435 | 97.20 | 983857.28 | 3.06 MiB | 1.00x (baseline) |
| `node_json5` | 239.411 | 220.521 | 263.252 | 15.98 | 5985281.25 | 70.34 MiB | 0.16x |

_Honest trade-off: `pion` trails Rust `json5 1.3.8 + serde_json` by ~16% (0.84x) on serialize roundtrip due to its 100% iterative serializer task stack (trading stack-overflow immunity for extra heap task pushes) compared to `serde_json`'s recursive stack serializer, while outperforming Node `json5@2.2.3 + JSON.stringify` by **5.08x** with 25× lower peak RSS._

**Workload 3: RFC 6902 Patch Apply + RFC 6901 Pointer Query (100,000 ops)**

50,000 RFC 6901 `pointer_get` queries (including `~0`/`~1` escaped keys and array indices) + 50,000 atomic RFC 6902 `apply_patch` operations (7-op patches covering `test`, `replace`, `add` `/-`, `remove`, `move`, `copy`):

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `95 B` (`sha256:890c0a8943a1b7c0...`) | Ops: `100000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs rust_json_patch) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 106.641 | 103.842 | 119.429 | 1066.41 | 2.00 MiB | 1.31x |
| `rust_json_patch` | 140.022 | 134.873 | 148.554 | 1400.22 | 2.14 MiB | 1.00x (baseline) |
| `node_fast_json_patch` | 266.937 | 256.552 | 303.542 | 2669.37 | 52.78 MiB | 0.52x |

_`pion` leads Rust `json-patch =4.2.0` by **1.31x** (1,066 ns/op vs 1,400 ns/op) and Node `fast-json-patch@3.1.1` by **2.50x**, at 2.00 MiB peak RSS._

**Adversarial Benchmarks (A1–A8, `packages/json5/audit`)**

Measured on `Darwin arm64` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification) against Rust `json5 =1.3.8` + `serde_json =1.0.140` (`preserve_order`) + `json-patch =4.2.0` and Node `json5@2.2.3` + `fast-json-patch@3.1.1`:

| Workload | Pion (Before) | Pion (After) | Rust | Node | Pion vs Rust |
| --- | ---: | ---: | ---: | ---: | ---: |
| **A1** Parse 5.5 MB JSON5, 240k non-ASCII keys | 0.83x | **78.1 ms** | 72.4 ms | 649.3 ms | **0.93x** (8.3x faster than Node) |
| **A2** Parse 6.9 MB, 300k 17-digit doubles | 0.49x | **59.9 ms** | 36.6 ms | 395.9 ms | **0.61x** (6.6x faster than Node) |
| **A3** RFC 6902 `test`: 50k-key object vs itself | 5,545 ms | **52.1 ms** | 28.9 ms | 116.4 ms | **0.55x** (106x speedup; 2.2x faster than Node) |
| **A4** `diff()`: 50k-key objects, 1 value changed | 16,594 ms | **48.6 ms** | 24.0 ms | 89.8 ms | **0.49x** (341x speedup; 1.85x faster than Node) |
| **A5** `diff()`: 100-level spine, 5k-int pad/level | — | **94.8 ms** | 56.3 ms | 76.4 ms | **0.59x** |
| **A6** 50k `pointer_get` on 50k-key `Array` object | 5,022 ms | 6,114 ms | 23.4 ms | 84.3 ms | O(k) linear scan (use `ObjectIndex` for O(1)) |
| **A7** 200 single-op atomic patches on 2.5 MB doc | 1,193 ms | **36.8 ms** | 28.4 ms | 59.3 ms | **0.77x** (32.4x speedup; 1.61x faster than Node) |
| **A8** 18,000-op add/move nesting 6,000 levels | 4,009 ms | **31.0 ms**\* | 25.6 ms | throws | **0.82x** (129x speedup)\* |

_\*Default `apply_patch` enforces `max_depth: 512` and safely rejects the 6,000-level nesting DoS (0 Wasm32 crash on `patchgrow` 1,890 rounds). The A8 timing above uses `apply_patch_with_options(PatchOptions::{ max_depth: 8192, max_nodes: 1_000_000 })` with SHA-256-verified identical output against Rust._

红队：242/242 单测；114/114 官方 `json5-tests`、108/108 RFC 6902 `json-patch-tests` 向量；独立红队审计 13/15（剩余 2 例为 `>2^53` 整数按 IEEE-754 `Double` 表示的已知边界）；对 Node `json5` 1,112,064 个 Unicode 标识符 0 分歧、37,995 个数值解析 0 分歧，59,999 次浮点往返 0 失败。领先项：W1 解析与 Rust `json5 =1.3.8` 持平（0.98x，min 更快、RSS 更低），W3 Patch + Pointer 1.31x（vs Rust）；A3 / A4 / A7 / A8 修复后提速 106x–341x。落后项：W2 序列化 0.84x（全迭代任务栈 vs `serde_json` 递归序列化），A1–A5 / A7 / A8 为 Rust 的 0.49x–0.93x，A6 宽对象单次 `pointer_get` 线性扫描 6,114 ms（重复查找应用 `ObjectIndex`）；`wasm32` 上递归 RC 析构限制文档深度约 1,400–1,600 层（默认 `max_depth` 128 / 512 兜底）。

### html

参考实现：Rust [`scraper`](https://github.com/rust-scraper/scraper) `=0.22.0`（`html5ever 0.29.1`）+ [`ammonia`](https://github.com/rust-ammonia/ammonia) `=4.0.0`（`cargo build --release`，`opt-level = 3`，`lto = "thin"`）、Go `golang.org/x/net` `v0.35.0`（`go 1.27.3`）。`--warmup 1 --rounds 5`，`sh packages/html/bench/run_bench.sh`，非精选 / 对抗负载来自 `audit/scripts/adv_bench.py`。详见 [`packages/html/README.md`](packages/html/README.md)。

**Bench 1: HTML5 Document Parse + Text/Link Extraction (20 rounds, 1,377,460 B)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_scraper`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **31.347** | 29.814 | 32.733 | **43.94** | **2.91 MiB** | **1.14x** |
| `go_net_html` | **24.969** | 22.554 | 25.792 | **55.17** | 11.48 MiB | 1.43x |
| `rust_scraper` | 35.603 | 33.965 | 38.610 | 38.69 | 3.58 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `d288e1dc3c38f7787b4573bfc647fff56c5308b8c49d25e0f7fd58a35637f211`._

**Bench 2: CSS Selector Query on Large DOM (50 rounds × 5 complex selectors = 250 queries)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_scraper`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 18.284 | 17.862 | 19.226 | 73,135 | **3.09 MiB** | **0.91x** (up from 0.45x) |
| `rust_scraper` | **16.559** | 15.915 | 17.961 | **66,238** | 3.56 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `af4b62ca244afbee8b7a38bfc72531a5c2be6fd03f96d9da816e9124bbd224d8`._

**Bench 3: HTML XSS Sanitization Throughput (20 rounds, 2,451,400 B)**

Note: `rust_ammonia` is configured with `.add_clean_content_tags(["iframe"])` so both sanitizers enforce identical `<iframe>` subtree stripping and produce byte-for-byte identical sanitized HTML (`fnv64` verified).

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_ammonia`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **51.752** | 51.282 | 54.927 | **47.37** | **3.44 MiB** | **1.37x** |
| `rust_ammonia` | 70.666 | 67.387 | 71.797 | 34.69 | 4.78 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `07a42875443631f00e8fa857076d34f1c34e6b9d962b017c7cbc93251871b6ff`._

**Un-Curated / Adversarial Benchmarks (`audit/scripts/adv_bench.py`)**

Bench 1–3 use a curated synthetic corpus; on un-curated real-world / adversarial corpora (`scripts/adv_bench.py`):
- **All 2,125 WHATWG `;`-entities ×40**: Pion **22.9 ms** vs Rust `html5ever` **103.7 ms** (**4.53x**, `same_output=True`).
- **`li:nth-child(2n+1)` on 20k siblings**: Pion **15.2 ms** vs Rust `scraper` **18.3 ms** (**1.20x**, `same_output=True`, down from 770 ms).
- **`li:last-child` / `li:first-of-type` / `[data-k$='7']` on 20k siblings**: Pion **13.2–14.2 ms** vs Rust **16.9–18.9 ms** (**1.19–1.43x**, `same_output=True`).
- **`section > article p > span em` (30k nodes)**: Pion **11.0 ms** vs Rust **12.1 ms** (**1.11x**, `same_output=True`).
- **`div.a div.b em` (30k nodes)**: Pion **17.1 ms** vs Rust **13.9 ms** (**0.81x**, `same_output=True`).
- **Filtered html5lib messy corpus ×40**: parse Pion **277.9 ms** vs Rust **322.2 ms** (**1.16x**) vs Go **230.1 ms**; sanitize Pion **217.8 ms** vs `ammonia` **265.0 ms** (**1.22x**).

红队：29/29 单测；红队审计 36/37（25/25 `p1_*`、8/8 `control_*`、3/4 `p2_*`，唯一差异为默认只允许 `http` / `https` / `mailto` 3 种 URL scheme，比 `ammonia` 的 25 种更严）；WHATWG 命名字符引用 2,231/2,231；html5lib tree-construction（`9329e64`，scripting-on）1,147/1,578（72.69%）；20,137 例 XSS / mXSS 往返 0 不安全输出、0 非幂等输出；CSS 选择器对 `scraper` 差分 139/141 一致（剩余 2 例为 EOF 未闭合 `[lang` 被有意拒绝）。领先项：Bench 1 解析 1.14x、Bench 3 清洗 1.37x（vs Rust），峰值 RSS 均最低；20k 兄弟节点伪类查询 1.19–1.43x，实体解码 4.53x。落后项：Bench 1 慢于 Go `x/net/html`（Go 为 Rust 的 1.43x），Bench 2 CSS 查询 0.91x（由 0.45x 优化而来），`div.a div.b em` 0.81x；`<template>` 内容未单独包 `DocumentFragment`，公开 `Node` API 无独立命名空间访问器。

### cli

参考实现：Rust [`clap`](https://github.com/clap-rs/clap) `=4.5.32`（`features = ["suggestions", "usage", "help", "error-context"]`，`cargo build --release`，`try_get_matches_from_mut(&mut cmd)` 免逐次 `Command::clone()`）、Go [`spf13/pflag`](https://github.com/spf13/pflag) `v1.0.6`（`go build`）。`--warmup 1 --rounds 5`，标准负载 `sh packages/cli/bench/run_bench.sh`，冷启动与对抗负载 `sh packages/cli/audit/run_audit.sh bench`。W1 的 Go 端为 5 级子命令分发 + 两个 `pflag.FlagSet`；W2 的 Rust 端以 `Append` + `num_args(0)` 规避 `Count` 的 `u8` 饱和；W3 因 `pflag` 无拼写建议只对比 `clap`。详见 [`packages/cli/README.md`](packages/cli/README.md)。

**W1: Complex CLI (30 Options + 5-Level Subcommand) × 50,000 Parses**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_clap`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 182.972 | 165.857 | 189.389 | 3659.45 | 1.95 MiB | 7.21x |
| `rust_clap` | 1318.488 | 1289.462 | 1410.804 | 26369.77 | 2.81 MiB | 1.00x (baseline) |
| `go_pflag` | 360.676 | 258.459 | 407.668 | 7213.51 | 17.84 MiB | 3.66x |

_SHA-256 verified identical across all implementations and rounds: `77494c5de5dede8eafd6b0d39b6df2500dea64184b2685fb02b72be7c4ddeb36`._

**W2: 100k-Arg Batch (Short Clustering + Repeated Append + `--` Terminator)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_clap`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 14.085 | 11.652 | 17.057 | 140.85 | 4.78 MiB | 2.97x |
| `rust_clap` | 41.769 | 40.426 | 53.805 | 417.69 | 45.55 MiB | 1.00x (baseline) |
| `go_pflag` | 13.829 | 12.530 | 15.538 | 138.29 | 10.33 MiB | 3.02x |

_SHA-256 verified identical across all implementations and rounds: `b83a9179ea608dbf1a8cfaab9274634be69bc0249e0da4a65b327edb524699c9`._

**W3: Typo Suggestion + Help Rendering (20,000 ops, Pion vs Rust `clap`)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_clap`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 62.663 | 59.457 | 64.428 | 3133.17 | 2.03 MiB | 6.34x |
| `rust_clap` | 397.137 | 381.026 | 401.087 | 19856.85 | 2.95 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `27bb597df1373cec45fce02623cc473dd3417a75b082e219db750b1b25dd96e4`._

**Cold-Start & Adversarial Complexity Benchmarks (`run_audit.sh bench`, `--warmup 1 --rounds 5`, SHA-256 gated)**

| Workload | Pion (Before Fix) | Pion (After Fix) | Rust `clap` (fair) | Speedup (vs `rust_clap`) |
| --- | ---: | ---: | ---: | ---: |
| W1 cold (build + parse × 50k) | 949 ms | 763.516 ms | 3872.762 ms | **5.07x** |
| ADV 16k chained `.arg()` | 628 ms | 10.792 ms | 13.743 ms | **1.27x** |
| ADV 16k chained `.subcommand()` | 691 ms | 10.358 ms | 12.569 ms | **1.21x** |
| ADV 16k `.args(list)` + parse | 17.4 ms | 15.792 ms | 16.410 ms | **1.04x** |
| ADV 3k options × 1k typos | 647 ms | 233.640 ms | 1620.184 ms | **6.93x** |
| ADV 1 MB unknown flag | 11.5 ms | 14.775 ms | 136.869 ms | **9.26x** |
| ADV 4 KB-name typo suggestion | 472 ms | 15.166 ms | 178.246 ms | **11.75x** |

红队：21/21 单测；红队审计 `pionc test -p cli_audit packages/cli/audit` 35/40，原 9 个 P0（Bash / Zsh / Fish 补全脚本命令注入与语法破坏，经 `bash -n` / `zsh -n`、source + TAB 与真实 zle TAB 实测）与 P1 / P2 均已修复；剩余 5 例中 4 例 `div_*` 为 README「Semantic Divergences」表记录的有意差异（负数默认作位置参数、单值选项重复时后者生效、全局 `Count` 跨层累加、子命令深度上限 64），1 例 `p1_get_double_not_correctly_rounded` 为审计测试本身的期望常量错误（`2.5e-8` 断言写成 `4493456761410498376` = `0x3e5bf71dfd732f48` ≈ 2.604e-8，与同行注释 `0x3e5ad7f29abcaf48` 不符；Pion 实际返回 `0x3e5ad7f29abcaf48`，与 Rust `str::parse::<f64>` 一致，其余 3 个断言均通过）。领先项：W1 7.21x、W3 6.34x、冷启动 5.07x（vs `clap`），全部对抗负载 1.04x–11.75x，峰值 RSS 均最低。落后项：W2 与 Go `pflag` 持平略慢（0.98x）。

### sql

参考实现：Rust [`sqlparser`](https://github.com/apache/datafusion-sqlparser-rs) `=0.53.0`（`--release`，`opt-level = 3`，`lto = true`，`codegen-units = 1`，`PostgreSqlDialect`，macOS 系统分配器）。`--warmup 1 --rounds 5`，`sh packages/sql/bench/run_bench.sh`；stdout 含 FNV-1a 语句标签序列哈希与结构化往返等价（`stmt_eq` / `PartialEq`）并经 SHA-256 逐字节校验。详见 [`packages/sql/README.md`](packages/sql/README.md)。

**Workload 1: Complex Production SQL Parse (20,000 ops / 4.83 MB)**

10 production-grade PostgreSQL statements (CTEs, recursive CTEs, multi-table `JOIN`s, window functions with `ROWS BETWEEN`, `EXISTS` subqueries, `CASE`/`CAST`/JSON operators, `FILTER (WHERE ...)`, `INSERT ... ON CONFLICT DO UPDATE ... RETURNING`, `UPDATE ... FROM ... RETURNING`, `DELETE ... RETURNING`, `CREATE TABLE` with FK/CHECK/array types, partial `CREATE UNIQUE INDEX`, `ALTER TABLE`) × 2,000 rounds:

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `85 B` (`sha256:f6751764383fb9cc...`) | Input: `4828000 B` | Ops: `20000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_sqlparser) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 136.493 | 130.175 | 154.151 | 35.37 | 6824.66 | 2.56 MiB | **8.72x** |
| `rust_sqlparser` | 1190.852 | 1116.332 | 1416.671 | 4.05 | 59542.60 | 3.33 MiB | 1.00x (baseline) |

**Workload 2: Large SQL Script Tokenize (10× 969.6 KB = 9.70 MB)**

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `45 B` (`sha256:f2f4b19293f241b0...`) | Input: `9696000 B` | Ops: `10`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_sqlparser) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 100.063 | 95.771 | 129.482 | 96.90 | 10006300.00 | 23.47 MiB | **7.94x** |
| `rust_sqlparser` | 794.741 | 772.797 | 819.762 | 12.20 | 79474091.70 | 38.66 MiB | 1.00x (baseline) |

**Workload 3: SQL Parse → `to_sql()` → Reparse + Structural `stmt_eq` Roundtrip (10,000 ops / 2.41 MB)**

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `105 B` (`sha256:e1463eb660ccacbc...`) | Input: `2414000 B` | Ops: `10000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_sqlparser) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 161.034 | 150.443 | 190.695 | 14.99 | 16103.44 | 2.81 MiB | **7.28x** |
| `rust_sqlparser` | 1172.362 | 756.640 | 1541.544 | 2.06 | 117236.16 | 3.61 MiB | 1.00x (baseline) |

分配器口径：改用 `mimalloc` 链接同版本 `sqlparser =0.53.0`（`packages/sql/audit/rust --features mimalloc`）后，Pion 在 W1 / W3 上仍约 2.6x，11 个对抗负载全部领先（`packages/sql/audit/REPORT.md`）；上表 7–9x 含 macOS 系统分配器差异。

红队：35/35 单测；红队审计 `pionc test -p sql_redteam_audit packages/sql/audit` 36/37，原 `- -x` → `--` 注释注入（`to_sql` 往返变成 `DROP TABLE`）、`extract_tables` 漏报 9 处表读取与 O(n²)、SQLite 走私、`max_depth` 不约束左深链导致 wasm32 崩溃、运算符优先级与 `stmt_eq` 文本相等等发现均已修复；剩余 1 例 `p0_split_statements_has_no_dialect_sqlite_nested_comment` 调用不带方言的 `split_statements`（按 Generic 方言即 PostgreSQL 式嵌套注释切分），SQLite 脚本需用新增的 `split_statements_dialect(src, Dialect::SQLite)`，同一输入实测切出 2 段，与 SQLite 一致。领先项：W1–W3 全部 7.28x–8.72x，峰值 RSS 均更低。范围边界：仅 SQLite / PostgreSQL / Generic 三种方言，未实现存储过程、触发器、`MERGE`、`GRANT` / `REVOKE`、`COPY` 等；wasm32 上建议 `max_depth <= 128`。

### graph

参考实现：Rust [`petgraph`](https://github.com/petgraph/petgraph) `=0.8.3`（`cargo build --release`，`opt-level = 3`，`lto = true`，`codegen-units = 1`）。`--warmup 1 --rounds 5`，标准负载 `sh packages/graph/bench/run_bench.sh`，对抗负载 `sh packages/graph/audit/bench_adversarial.sh`。详见 [`packages/graph/README.md`](packages/graph/README.md)。

**W1: Dijkstra Single-Source Shortest Path (50,000 nodes / 250,000 edges × 3 rounds, 750k edge relaxations)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_petgraph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_digraph` | 69.541 | 61.842 | 93.057 | 92.72 | 14.78 MiB | 0.91x |
| `pion_csr` | 47.174 | 45.962 | 48.540 | 62.90 | 19.03 MiB | **1.34x** |
| `rust_petgraph` | 63.012 | 56.597 | 73.541 | 84.02 | 10.36 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `7d2284ef80a7958750d57f68f5b7c13e778b90566e1aa519f59de9fa21baa83e`._

**W2: Tarjan SCC + Topological Sort (100,000 nodes / 400,000 edges each, 800k edges total)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_petgraph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_digraph` | 79.203 | 69.790 | 80.445 | 99.00 | 50.98 MiB | 0.60x |
| `pion_csr` | 80.140 | 67.131 | 91.331 | 100.18 | 57.16 MiB | 0.59x |
| `rust_petgraph` | 47.419 | 44.977 | 58.554 | 59.27 | 34.41 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `765842299691f19a22f0cdf0c8aa82872f1736b55d15c90b19522f0eedae1b3f`._

**W3: Kruskal Minimum Spanning Tree (50,000 nodes / 200,000 undirected edges)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_petgraph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 20.565 | 18.085 | 24.096 | 102.83 | 20.88 MiB | **1.27x** |
| `rust_petgraph` | 26.138 | 25.721 | 28.549 | 130.69 | 12.52 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `99042b7e421ab0d812b17c519414d5c6b0d1622c526fd32fa3fd30314527198e`._

**W4: CFG Dominators (20,000 nodes / 60,000 edges × 5 rounds, 300k edge inspections)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_petgraph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_digraph` | 24.869 | 22.975 | 26.494 | 82.90 | 5.55 MiB | **1.68x** |
| `pion_csr` | 21.727 | 21.237 | 22.014 | 72.42 | 7.28 MiB | **1.92x** |
| `rust_petgraph` | 41.751 | 40.911 | 42.089 | 139.17 | 8.61 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `8e7d2450047cbab918a4750d47eaac42b7146df5ba268c76f74c387920aabd2f`._

**Additional Adversarial Benchmarks (`packages/graph/audit/bench_adversarial.sh`, SHA-256 verified)**

| Workload | Pion (ms) | Rust `petgraph` (ms) | Speedup | Peak RSS (Pion / Rust) |
| --- | ---: | ---: | ---: | --- |
| `A2_dinic_layers` (200 layers × 10) | 14.2 | 25.9 | **1.83x** | 6 / 5 MiB |
| `A9_floyd_dense` (300 dense) | 24.3 | 31.9 | **1.31x** | 6 / 7 MiB |
| `A10_tred_chain` (20k chain) | 13.7 | 1255.9 | **91.46x** | **7 / 912 MiB** |
| `A10b_tred_star` (100k out-star) | 58.3 | 21.0 | 0.36x | **28 / 22 MiB** (down from 1,217 MiB) |
| `A11_dominators_rand` (50k / 200k) | 52.6 | 63.0 | **1.20x** | 27 / 29 MiB |

红队：29/29 单测；红队审计 `pionc test -p graph_audit packages/graph/audit` 20/21，F1–F10（A* 非一致启发式次优、支配边界丢入口节点、Floyd-Warshall 误报溢出、传递规约 V²/64 内存与 32-bit 溢出 panic、建图开销、尺寸守卫等）均已修复；剩余 1 例 `p2_neighbor_order_matches_petgraph` 为 README 记录的有意设计（邻居按插入顺序迭代，`petgraph` 为新者在前）。10 seeds × 1,000 随机图 × 22 段对 `petgraph` + 精确 `i128` / `u128` / 暴力参考差分 0 正确性不一致，400,000 次随机增删 0 指针完整性违例。领先项：W1 CSR Dijkstra 1.34x、W3 Kruskal 1.27x、W4 支配树 1.68x–1.92x，Dinic 1.83x、Floyd-Warshall 1.31x、链上传递规约 91.46x（7 MiB vs 912 MiB）。落后项：W1 `DiGraph` Dijkstra 0.91x，W2 SCC + 拓扑 0.59x–0.60x（`add_edge` 建图开销，Tarjan 内核本身 2.4x–5.0x），100k 出星传递规约 0.36x，建图主导负载 `B0_build_dense` 0.30x / `B0_build_rand` 0.24x，峰值 RSS 多数高于 Rust。

### css

参考实现：Rust [`cssparser`](https://github.com/servo/rust-cssparser) `=0.35.0`（`tokcount` token walk 与对齐 Pion `Stylesheet` 形状的自有通用 AST）、[`lightningcss`](https://github.com/parcel-bundler/lightningcss) `=1.0.0-alpha.72`（完整类型化 AST 与生产级压缩器）、Node `css-tree@3.1.0`（`node v24.22.2`）。采样由 `packages/css/audit/scripts/perf.py --rounds 5`（每进程 3 次重复、预热后 5 轮严格交替、取中位数与峰值 RSS）完成，`sh packages/css/audit/run_audit.sh` 一键复现。详见 [`packages/css/README.md`](packages/css/README.md)。

**5-Corpus Head-to-Head Matrix (median ms, lower is better)**

| Corpus (size × 3) | Pion `count_tokens` | Pion `tokenize()` | `cssparser` tok walk | Pion `parse` | `cssparser` AST | `lightningcss` parse | Pion `minify` | `lightningcss` minify | `css-tree` parse |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `design_system` (2.09 MB) | **25.9** | 66.7 | 34.7 | **63.1** | 66.2 | 110.5 | **85.2** | 135.1 | 531.4 |
| `color_heavy` (1.81 MB) | **25.7** | 69.3 | 33.0 | 64.9 | **61.0** | 105.4 | **99.7** | 125.3 | 626.1 |
| `selector_heavy` (1.34 MB) | **21.4** | 61.8 | 31.5 | 37.8 | **29.7** | 110.2 | **84.0** | 172.0 | 750.9 |
| `nesting_heavy` (1.74 MB) | **26.1** | 89.8 | 42.5 | **91.2** | 107.2 | 449.6 | **125.2** | 569.7 | 1220.2 |
| `custom_props` (2.04 MB) | **24.6** | 70.1 | 33.6 | 85.3 | **76.4** | 202.8 | **67.8** | 237.1 | 442.8 |

**Peak RSS (MB, lower is better)**

| Corpus | Pion `parse` | `cssparser` AST | `lightningcss` parse | Pion `minify` | `lightningcss` minify | `css-tree` parse |
|---|---:|---:|---:|---:|---:|---:|
| `design_system` | 18.1 | **18.0** | 44.2 | **7.4** | 46.4 | 247.6 |
| `color_heavy` | **16.8** | 17.0 | 34.6 | **7.1** | 35.1 | 326.0 |
| `selector_heavy` | **8.2** | 9.1 | 36.2 | **5.7** | 37.7 | 280.8 |
| `nesting_heavy` | 41.2 | **34.0** | 202.6 | **6.9** | 203.4 | 448.6 |
| `custom_props` | 22.7 | **22.5** | 56.2 | **7.6** | 58.2 | 164.1 |

红队：32/32 单测；红队审计 `pionc test -p css_audit packages/css/audit` 34/34，原 P0（CSS Nesting 声明顺序丢失、`:is()` / `:not()` / `:where()` / `:has()` 内后代组合器被压缩删除）与 P1 / P2 均已修复；`tok_diff.py` 17,904 例 + 2,014 例原始字节输入 99.85% 与 `cssparser` 一致（`tokenize_bytes` 2,014 / 2,014）；`minify_diff.py` 2,114 例 0 语义破坏、0 非幂等；`dos.py` 20 / 20 线性、0 崩溃；`wasm4.py` 12 语料 × 4 模式 SHA-256 逐字节一致。领先项：`count_tokens()` 1.28x–1.63x（vs `cssparser`），`parse_stylesheet()` 1.62x–4.93x（vs `lightningcss`），`minify()` 1.26x–4.55x 且内存低 4.9x–29.5x（vs `lightningcss`，后者另做简写合并、厂商前缀与颜色空间转换等深度优化）。落后项：全量物化 `tokenize()` 0.47x–0.52x，`parse_stylesheet()` 对 `cssparser` 自有 AST 在 `color_heavy` / `selector_heavy` / `custom_props` 上 0.79x–0.94x，`nesting_heavy` 峰值 RSS 41.2 MB 高于 `cssparser` 的 34.0 MB。

### base64

参考实现：Rust [`base64`](https://github.com/marshallpierce/rust-base64) `=0.22.1`（`STANDARD` / `URL_SAFE`）、[`data-encoding`](https://github.com/ia0/data-encoding) `=2.11.1`（Base32）、[`hex`](https://github.com/KokaKiwi/rust-hex) `=0.4.3`（`--release`，LTO）；Go `go1.27.3` 标准库 `encoding/base64`（`.Strict()`）/ `encoding/base32` / `encoding/hex`。`sh packages/base64/bench/run_bench.sh 4194304 64` 构建三方实现并按模式调用 `scripts/bench_compare.py --warmup 1 --rounds 5`：每次运行生成 4 MiB xorshift32 数据并编码（或解码）64 次，吞吐按 256 MiB 原始字节计，耗时含约 20 ms 的输入生成；每个模式三方 stdout（尺寸、逐轮采样和与末次结果 FNV-1a 64）SHA-256 逐字节一致。采样时机器负载约 16–18，小差距需谨慎解读。详见 [`packages/base64/README.md`](packages/base64/README.md)。

**8-Mode Head-to-Head (median ms, MB/s)**

| Mode | Pion | Go stdlib | Rust | Pion vs Rust | Pion vs Go | Peak RSS Pion / Go / Rust (MiB) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `b64_encode` | 239.2 (1122) | 122.6 (2189) | 100.7 (2667) | 0.42x | 0.51x | 16.4 / 31.7 / 11.1 |
| `b64_decode` | 228.9 (1173) | 110.5 (2429) | 99.0 (2711) | 0.43x | 0.48x | 20.5 / 32.5 / 15.1 |
| `url_encode` | 228.6 (1175) | 122.4 (2193) | 99.3 (2703) | 0.43x | 0.54x | 16.5 / 26.8 / 11.1 |
| `url_decode` | 226.5 (1185) | 106.7 (2515) | 94.6 (2838) | 0.42x | 0.47x | 20.5 / 30.4 / 15.1 |
| `b32_encode` | 253.3 (1060) | 118.6 (2263) | 113.2 (2371) | 0.45x | 0.47x | 18.6 / 29.9 / 12.2 |
| `b32_decode` | 253.1 (1060) | 642.3 (418) | 110.9 (2421) | 0.44x | **2.54x** | 22.6 / 49.1 / 16.2 |
| `hex_encode` | 300.7 (893) | 209.7 (1280) | 511.6 (525) | **1.70x** | 0.70x | 21.8 / 66.3 / 13.8 |
| `hex_decode` | 315.7 (850) | 185.1 (1450) | 1449.4 (185) | **4.59x** | 0.59x | 25.8 / 31.4 / 20.0 |

23/23 单测（RFC 4648 §10 五种编码向量、Go 用例与错误偏移、Base64 2 / 3 符号尾部与 Base32 各尾长规范性穷举、0–64 全长度与 64 KiB / 1 MiB 往返）；`wasm_smoke` 4 模式 stdout SHA-256 均为 `b9babfa55084789669b9487724ff5d938cbc2517d10008490c09b9310df19539`。领先项：hex 编码 / 解码为 Rust `hex` 的 1.70x / 4.59x，Base32 解码为 Go 的 2.54x（Go 按组处理填充与换行）。落后项：Base64 / Base64URL 编解码与 Base32 编码为 Rust 与 Go 的 0.42x–0.54x，Base32 解码为 Rust `data-encoding` 的 0.44x，hex 为 Go 的 0.70x / 0.59x（参考实现按机器字批量处理，本包逐字节经边界检查 `Bytes` 索引查表；4,096 项双符号表与展开索引实测无收益）。峰值 RSS 每个模式都介于 Rust 与 Go 之间。

### effect

参考实现：同语义 Go（`go1.27.3`，goroutine / channel / `container/heap`）与 Node.js（`v24.22.2`，Promise / 微任务）基线，源码见 [`packages/effect/bench/`](packages/effect/bench/)。`sh packages/effect/bench/run_bench.sh` 先做 `wasm_smoke` 4 模式 SHA-256 校验，再构建 Pion `--release` 与 Go 二进制并对三个负载调用 `scripts/bench_compare.py --warmup 1 --rounds 5 --baseline go`，三方 stdout SHA-256 逐字节一致。详见 [`packages/effect/README.md`](packages/effect/README.md)。

| Workload | Pion Median / Peak RSS | Go Median / Peak RSS | Node Median / Peak RSS | Pion vs Go | Pion vs Node |
| --- | ---: | ---: | ---: | ---: | ---: |
| W1 有界队列乒乓（50k msgs，cap = 16） | 18.318 ms / 1.83 MiB | 17.479 ms / 4.59 MiB | 57.203 ms / 48.62 MiB | 0.95x | **3.12x** |
| W2 虚拟时钟定时器调度（20k fibers / timers） | 47.402 ms / 28.23 MiB | 18.574 ms / 5.95 MiB | 58.455 ms / 49.86 MiB | 0.39x | **1.23x** |
| W3 结构化扇出汇合（2,500 × 4 = 10k fibers） | 19.481 ms / 1.84 MiB | 18.090 ms / 5.42 MiB | 51.110 ms / 45.16 MiB | 0.93x | **2.62x** |

19 / 19 单测；`wasm_smoke` 4 模式 stdout SHA-256 均为 `3a81d54555c2f572d5dcf8c3cc934a5a8d02606e41cf0a42bc4e2600b671d57a`。领先项：三个负载均快于 Node（1.23x–3.12x），W1 / W3 峰值 RSS 低于 Go 与 Node。落后项：W1 / W3 为 Go 的 0.95x / 0.93x；W2 为 Go 的 0.39x，峰值 RSS 28.23 MiB 高于 Go 的 5.95 MiB——两侧结构不对等：Pion 同时创建 20,000 个完整结构化纤程（`Task` + `Fiber` + `sleep_k` 定时器 + 作用域监视），Go 与 Node 基线只往最小堆压入裸 `{at, seq, idx}` 结构体，该比值反映的是结构化纤程的固定开销而非堆本身。

### crypto

`v0.4.1`。参考实现：Go `go1.27.3` 标准库 `crypto/sha256` / `crypto/sha512` / `crypto/hmac` / `crypto/ed25519` / `crypto/ecdsa` / `crypto/aes` + `cipher.NewGCMWithNonceSize` / `crypto/ecdh` 与 `golang.org/x/crypto` `v0.58.0`（`curve25519` / `chacha20poly1305` / `hkdf` / `pbkdf2` / `scrypt`），源码见 [`packages/crypto/bench/`](packages/crypto/bench/)。数据取自包 v0.3.0 红队修复后刷新的 README（`Darwin arm64`，`AFK-surf/pion@66d2b4b`），发布验证（`verify.sh` 79 包、`audit_v030/run_audit.sh tests` / `diff` / `ct`、`audit/ct_ssa_check.py` 与 `wasm_smoke` 4 模式）同样使用 `AFK-surf/pion@66d2b4b`（`v0.2.0` 为 `AFK-surf/pion@c375cee`）。`sh packages/crypto/bench/run_bench.sh` 先做 `wasm_smoke` 4 模式 SHA-256 校验，再构建 Pion `--release` 与 Go 二进制并对 12 个负载调用 `scripts/bench_compare.py --warmup 1 --rounds 5`（严格交替），双方 stdout SHA-256 在每个负载上逐字节一致。详见 [`packages/crypto/README.md`](packages/crypto/README.md)。

| Workload | Pion Median / Peak RSS | Go Median / Peak RSS | Pion 吞吐 / 单次 | Pion vs Go |
| --- | ---: | ---: | ---: | ---: |
| SHA-256（16 MiB 流式） | 94.222 ms / 1.84 MiB | 17.716 ms / 5.02 MiB | 178.06 MB/s | 0.19x |
| SHA-512（16 MiB 流式） | 63.312 ms / 1.84 MiB | 21.785 ms / 5.05 MiB | 264.99 MB/s | 0.34x |
| HMAC-SHA256（50,000 × 256 B） | 140.606 ms / 1.80 MiB | 32.078 ms / 11.41 MiB | 2,812.11 ns/op | 0.23x |
| Ed25519（200 签名 + 200 验签） | 60.823 ms / 1.89 MiB | 24.094 ms / 5.03 MiB | 152.06 µs/op | 0.40x |
| X25519（200 次密钥交换） | 30.242 ms / 1.83 MiB | 28.051 ms / 4.95 MiB | 151.21 µs/op | 0.93x |
| HKDF-SHA256（20,000 × 64 B） | 102.889 ms / 1.83 MiB | 31.297 ms / 12.28 MiB | 5,144.44 ns/op | 0.30x |
| ChaCha20-Poly1305（4 MiB 加密 + 解密） | 73.418 ms / 2.05 MiB | 20.921 ms / 10.80 MiB | 114.26 MB/s | 0.28x |
| AES-256-GCM（1,000 × 64 KiB 加密 + 解密，v0.3.0） | 2,033.434 ms / 2.05 MiB | 55.673 ms / 14.75 MiB | 64.46 MB/s | 0.03x |
| AES-256-GCM 小包（150,000 × 256 B 加密 + 解密，v0.3.0） | 2,315.511 ms / 1.88 MiB | 46.906 ms / 11.84 MiB | 7.72 µs/op | 0.02x |
| NIST P-256 ES256（50 签名 + 50 验签） | 121.651 ms / 1.97 MiB | 14.271 ms / 5.81 MiB | 1.22 ms/op | 0.12x |
| NIST P-256 ECDH（2,000 次密钥交换，v0.3.0） | 1,402.492 ms / 1.89 MiB | 69.888 ms / 7.09 MiB | 701.25 µs/op | 0.05x |
| NIST P-256 公钥校验（20,000 非压缩 + 20,000 压缩，v0.3.0） | 828.830 ms / 1.81 MiB | 81.086 ms / 11.11 MiB | 20.72 µs/op | 0.10x |
| PBKDF2-HMAC-SHA256（500,000 次迭代，32 B，v0.4.1） | 175.074 ms / 1.81 MiB | 55.964 ms / 4.97 MiB | 350.15 ns/op | 0.32x（Go `-tags purego` 纯标量的 0.95x） |
| scrypt（`N=16384, r=8, p=1`，32 B × 4，v0.4.1） | 101.280 ms / **17.80 MiB** | 83.341 ms / 39.38 MiB | 25.32 ms/op | 0.82x |

v0.4.1（性能补丁，API 与输出不变，`wasm_smoke` SHA-256 同 v0.4.0）：scrypt 改用打包 `FixedArray[UInt64]` 的 `V` / `xy`、Phase 1 直接写 `V`、Phase 2 融合 `BlockMix(X ^ V[j])`，0.62x → **0.82x**、峰值 RSS 33.78 → **17.80 MiB**（余下约 18–19 ms 差距对应 QBE 把每次循环移位生成 `lsl`/`lsr`/`orr` 三条指令而非 ARM64 单条 `ror`）；PBKDF2-HMAC-SHA256 内循环改用全展开的 32 字节单块 SHA-256 压缩，0.20x → **0.32x**，对 Go `-tags purego` 纯标量 SHA-256 为 **0.95x**（320 ns/op），余下差距即 ARMv8 `SHA256H` 约 3.1× 的硬件指令优势。

v0.4.0：83 / 83 单测；`wasm_smoke` 4 模式 stdout 均为 `4605 B`、SHA-256 `3f3456531e2f127a430ddf46647ed4d68a38c93f00c57e0b730476ffc6f97108`（新增 PBKDF2 / scrypt 向量）。新增 2 行数据取自包 v0.4.0 README，迭代数按 Go 侧 ≥ 50 ms 实际工作量设定；发布验证中 `audit_v040/run_audit.sh` 的 `bench` 门禁复测 Go 固定进程开销占 6 % / 4 %，进程内放大复测 PBKDF2 0.185x、scrypt 0.587x，与仓库比值（0.208x / 0.633x）相差在 1.1 倍以内。PBKDF2 落后来自 Go 在 `darwin/arm64` 上用 ARMv8 `SHA256H` 指令（与 SHA-256 行同一差距）；scrypt 主要受 Salsa20/8 与内存带宽限制，达 Go 的 0.62x，峰值 RSS 33.78 MiB 低于 Go 的 39.81 MiB。v0.4.0 红队审计（[`packages/crypto/audit_v040/REPORT.md`](packages/crypto/audit_v040/REPORT.md)）：0 P0 + 1 P1 + 3 P2 全部修复，1,103 个 Go / Node.js 交叉核对向量 4 模逐字节一致，17 / 17 变异体被检出。

v0.3.0：76 / 76 单测；`wasm_smoke` 4 模式 stdout 均为 `4127 B`、SHA-256 `a07d31d36c6e770f35416c4473bc83bacd595fb7578f2edfa9b0eb0df3f31611`（新增 AES-128 / 256-GCM 96 位与非 96 位 nonce 及篡改拒绝、P-256 ECDH / 公钥校验与解压）。v0.3.0 红队审计（[`packages/crypto/audit_v030/REPORT.md`](packages/crypto/audit_v030/REPORT.md)）：对 Go 20,054 个向量 4 模逐字节一致、SSA 常量时间门禁通过、10 / 10 变异体被检出，0 P0 / 0 P1；P2-1 指出新增 4 行原先只跑 64–400 次迭代，Go 侧中位数主要是约 3 ms 进程启动，使比值虚高 3.3–12.4×，修复后迭代数加大到 Go 侧 ≥ 45 ms 实际工作量（启动占比 < 7%），上表 4 行即稳态比值；INFO-1 的 ECDH 标量范围检查改为固定 8 limb 掩码比较。新增 4 行如实为本包最弱项：Go 在 `darwin/arm64` 上用 ARMv8 AES + PMULL 指令（约 2.35 GB/s）与 ARM64 汇编 `crypto/ecdh`（35 µs/op），本包是常量时间位切片软件 AES 与纯标量 P-256。原 8 行同轮刷新，与 v0.2.0 数据差异在 ±0.07x 以内；其中最短的 X25519（Go ≈ 28 ms）仍含约 3 ms 进程启动，比值为近似值。

v0.2.0 对照：SHA-256 0.16x、SHA-512 0.32x、HMAC-SHA256 0.21x、Ed25519 0.47x、X25519 0.96x、HKDF-SHA256 0.34x、ChaCha20-Poly1305 0.34x、P-256 ES256 0.16x。

v0.2.0：69 / 69 单测（含 40 个红队测试）；`wasm_smoke` 4 模式 stdout 均为 `3525 B`、SHA-256 `feceef7d07daa52fb9aaf44c09dec5047d1b5838c71024d3ea1bd8bce296d7ee`。v0.2.0 红队审计无 P0，修复 P1 RT-4（常量时间 RSA CRT）、P2 RT-5（常量时间 P-256 标量运算）与 P2 RT-6（RSA `e < 2^33` 上限），三项修复不改变任何输出：8 个基准的 stdout 修复前后逐字节一致。领先项：峰值 RSS 1.80–2.05 MiB，比 Go 的 4.92–12.11 MiB 低 2.6×–6.6×；X25519 达 Go 的 0.96x。落后项：8 个负载全部慢于 Go（0.16x–0.96x），P-256 ES256 与 SHA-256 最弱（0.16x）。两侧实现手段不对等：Go 在 `darwin/arm64` 上用 ARMv8 加密扩展（`SHA256H` / `SHA512H`）加速 SHA-256 / SHA-512，ChaCha20 / Poly1305 用 NEON / ARM64 汇编，Ed25519 / P-256 用手写 ARM64 汇编与预计算表；本包是零 C FFI、零汇编的纯标量 Pion 代码，Native 与 `wasm32` 共用同一实现，签名路径额外付出无分支常量时间查表与运算的开销。

### brotli

参考实现：Rust [`brotli`](https://github.com/dropbox/rust-brotli) `7.0.0`（`--release`）与 Google C [`libbrotlidec`](https://github.com/google/brotli) `1.2.1`（`-O3`）。通过 `sh packages/brotli/bench/run_bench.sh` 在 `Darwin arm64` 上调用 `scripts/bench_compare.py --warmup 1 --rounds 5` 严格交替采样，三方 stdout SHA-256 逐字节一致。详见 [`packages/brotli/README.md`](packages/brotli/README.md)。

| Workload | `pion` Median (Throughput) | `rust_brotli` Median (Throughput) | `c_brotlidec` Median (Throughput) | `pion` vs `rust_brotli` |
| --- | ---: | ---: | ---: | ---: |
| Web HTML/CSS/JS/JSON (2 MiB q6 × 10 = 20 MiB) | 34.820 ms (602.28 MB/s) | 25.524 ms (821.63 MB/s) | 24.281 ms (863.71 MB/s) | 0.73x |
| WOFF2 Binary Font Payload (1 MiB q11 × 10 = 10 MiB) | 33.678 ms (311.35 MB/s) | 24.419 ms (429.41 MB/s) | 25.004 ms (419.36 MB/s) | 0.73x |
| Small Packet Batch (512 pkts q5 × 10 = 5,120 pkts) | 43.355 ms (62.80 MB/s) | 69.620 ms (39.11 MB/s) | 35.054 ms (77.67 MB/s) | **1.61x** |

红队：10 / 10 单测，`audit` 6 / 6，226,218 例差分与 Google C `libbrotlidec 1.2.1` 0 差异；IMTF 修复后提速 10.5×，`hp_literals` 达 C 的 0.85×；`wasm_smoke` 4 模式 stdout SHA-256 均为 `027a31d9b0e0094c6dc068938bfd187f8561d338945e1b828ecd6cb3cd71e23e`。领先项：小包批量解压反超 Rust `brotli` 至 **1.61x**（无每包大型状态结构分配开销）。落后项：Web 与 WOFF2 大流解压为 Rust 的 0.73x（C 的 0.70x–0.74x），受纯标量热循环与边界检查数组访问限制；小包批量仍为 C 的 0.81x。

### unicode_bidi

参考实现：Rust [`unicode-bidi`](https://github.com/servo/unicode-bidi) `0.3.18`（`--release`）。通过 `sh packages/unicode_bidi/bench/run_bench.sh` 在 `Darwin arm64` 上调用 `scripts/bench_compare.py --warmup 1 --rounds 5` 严格交替采样，所有轮次 stdout SHA-256 逐字节一致。详见 [`packages/unicode_bidi/README.md`](packages/unicode_bidi/README.md)。

| Benchmark | Pion Median (ms) | Rust Median (ms) | Pion Throughput (MB/s) | Rust Throughput (MB/s) | Speedup vs Rust |
| --- | ---: | ---: | ---: | ---: | ---: |
| Pure LTR fast path (`40k ops`, `3.98 MB`) | 63.711 | 68.927 | 62.43 | 57.71 | **1.08x** |
| Mixed Arabic/Hebrew/English (`10k ops`, `900 KB`) | 46.083 | 38.388 | 19.54 | 23.46 | 0.83x |
| Deep nested isolates & brackets (`5k ops`, `383 KB`) | 30.637 | 27.972 | 12.52 | 13.71 | 0.91x |
| Per-line `visual_runs` + `reorder_line` (`10k ops`, `900 KB`) | 69.079 | 48.495 | 13.04 | 18.57 | 0.70x |

红队：11 / 11 单测，`audit` 18 / 18，Unicode 16.0.0 全码点表 0 / 1,112,064 偏差，`BidiCharacterTest` 91,707 / 91,707 + `BidiTest` 770,241 / 770,241 零失败。领先项：Pure LTR 快路径反超 Rust 至 **1.08x**。落后项：Mixed 0.83x、Deep 嵌套隔离与配对括号 0.91x、逐行 `visual_runs` + `reorder_line` 0.70x。

### hyphenation

参考实现：Rust [`hyphenation`](https://github.com/tapeinos/hyphenation) `=0.8.4`（`--release`, `lto = true`），双方执行完全相同的 `hyph-en-us` 4,938 模式 + 1,441 例外表。通过 `packages/hyphenation/audit/scripts/bench_fair.py`（底层调用 `scripts/bench_compare.py --warmup 1 --rounds 5`）严格交替采样，stdout SHA-256 逐字节一致。详见 [`packages/hyphenation/README.md`](packages/hyphenation/README.md)。

**1. Batch Hyphenation — `bench100k`（100,000 draws × 10 = 1,000,000 ops，10.28 MB）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_hyph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_into` | **144.435** | 142.740 | 155.014 | **71.21** | **144.44** | 10.02 MiB | **3.38x** |
| `pion_alloc` | 145.391 | 143.380 | 149.541 | 70.74 | 145.39 | 10.02 MiB | **3.35x** |
| `rust_hyph` | 487.704 | 472.676 | 509.784 | 21.09 | 487.70 | 9.06 MiB | 1.00x (baseline) |
| `rust_opp` | 475.928 | 448.806 | 499.748 | 21.61 | 475.93 | 12.94 MiB | 1.02x |

_SHA-256: `569e94245a2ebfa02b5152c63d86f731704a7cc8b5cadbe4a0cf98f0f34254c5`._

**2. Batch Hyphenation — Full Distinct Dictionary（235,915 distinct words × 10 = 2,359,150 ops，22.57 MB）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_hyph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_into` | **457.358** | 450.269 | 729.512 | **49.36** | **193.87** | 18.58 MiB | **2.53x** |
| `pion_alloc` | 466.959 | 464.261 | 633.838 | 48.34 | 197.94 | 18.58 MiB | **2.47x** |
| `rust_hyph` | 1,154.906 | 1,126.700 | 1,227.287 | 19.55 | 489.54 | 15.56 MiB | 1.00x (baseline) |
| `rust_opp` | 1,156.373 | 1,093.154 | 2,045.208 | 19.52 | 490.17 | 21.98 MiB | 1.00x |

_SHA-256: `9a65ebd3301a0401dfa90968e96d0a34ad36bc8ed6a15952b2a0476fc2f78b26`._

**3. Dictionary Load（4,938 patterns + 1,441 exceptions × 20 loads）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_from_text`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_from_tex` | **33.691** | 32.945 | 34.960 | **1,684,545.80** | 4.72 MiB | **1.02x** |
| `rust_from_text` | 34.398 | 32.425 | 40.342 | 1,719,883.35 | 4.48 MiB | 1.00x (baseline) |
| `rust_bincode` (pre-compiled) | 10.458 | 10.082 | 11.593 | 522,904.20 | 2.23 MiB | 3.29x |

_SHA-256: `bd519a5b90095c9523b1d7ca8d114f327f4b87d62b2eec8f11c1560c84c5ca6b`._

红队：11 / 11 单测，`audit` 21 / 21，80 语种 99.995% 一致。领先项：三项公平对比全部领先 Rust `hyphenation =0.8.4`（`bench100k` **3.38x**、全词典 **2.53x**、文本词典建树 **1.02x**）。落后项：相比 Rust 预编译 `bincode` 反序列化（10.458 ms，2.23 MiB），从文本现场建树为 0.31x；各负载峰值 RSS 略高于 Rust `rust_hyph`（10.02 vs 9.06 MiB、18.58 vs 15.56 MiB、4.72 vs 4.48 MiB）。

### pdf

参考实现：Rust [`pdf-writer`](https://github.com/typst/pdf-writer) `0.12.1` + `flate2 1.1`（`rust_backend`, `--release`）。通过 `sh packages/pdf/bench/run_bench.sh` 在 `Darwin arm64` 上调用 `scripts/bench_compare.py --warmup 1 --rounds 5` 严格交替采样，stdout SHA-256 逐字节一致，且全部产出 PDF 通过 Rust `lopdf 0.35.0` 第三方解析校验。详见 [`packages/pdf/README.md`](packages/pdf/README.md)。

| Workload | Pion Median | Rust `pdf-writer` Median | Pion Throughput / ns/op | Pion Peak RSS | Rust Peak RSS | Speedup vs Rust |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 100-Page Vector + Text Report (`/FlateDecode`) | 22.71 ms | 14.57 ms | 227.1 us/page | **4.11 MiB** | 6.36 MiB | 0.64x |
| 10-Page 800×600 RGBA Image Export (`/FlateDecode`, 14.4 MB RGB) | 75.77 ms | 74.52 ms | 190.06 MB/s | **24.62 MiB** | 27.61 MiB | 0.98x |
| 10-Page 800×600 RGBA Image Export (`/RunLengthDecode`, 14.4 MB RGB) | 64.56 ms | 37.54 ms | 223.05 MB/s | 55.41 MiB | 38.20 MiB | 0.58x |

红队：8 / 8 单测（复用 `flate` 20 / 20），`audit` 30 / 30（2 P0 + 9 P1 + 14 P2 清零，`v_quadratic_40k` 提速 2,380× 至 6 ms）。领先项：`images_flate` 与 Rust `--release` 基本持平（0.98x）且峰值 RSS 更低（24.62 vs 27.61 MiB）；`report100` 峰值 RSS 同样更低（4.11 vs 6.36 MiB），输出体积更小（93 KB vs 97 KB）。落后项：`report100` 为 0.64x（每流 `flate` 状态初始化占 22.7 ms 中约 11 ms）；`images_rle` 为 0.58x 且峰值 RSS 较高（55.41 vs 38.20 MiB，标量 PackBits 扫描与逐字节拷贝对比 LLVM 自动向量化 Rust）。

### fts

参考实现：SQLite [FTS5](https://www.sqlite.org/fts5.html)（C `-O3 -lsqlite3` 与 Python `sqlite3`，均为 `:memory:`，`tokenize="unicode61 tokenchars '_'"`）。`sh packages/fts/bench/run_bench.sh 10000` 在确定性的 10,000 文档多语言 + 代码语料（英文、中文、日文、韩文、`CamelCase`、`snake_case`、`#PR`、十六进制 SHA）上跑 30 个查询（精确、CJK、代码词、短语、前缀、`NOT`），调用 `scripts/bench_compare.py --warmup 1 --rounds 5` 严格交替采样，三方 stdout SHA-256 逐字节一致。Pion 在建索引时现场分词，SQLite FTS5 摄入同源 `fts5_index_text` 产出的 token。编译器 `AFK-surf/pion@8d110a3`。详见 [`packages/fts/README.md`](packages/fts/README.md)。

**1. 10,000 文档建索引 + 30 查询（620,254 B 原文，`sha256:1d044d63afdb2ecb...`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `sqlite_fts5_c`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 45.518 | 43.582 | 46.837 | 13.63 | 25.41 MiB | 0.71x |
| `sqlite_fts5_c` | 32.386 | 31.103 | 33.194 | 19.15 | 6.53 MiB | 1.00x (baseline) |
| `sqlite_fts5_py` | 61.211 | 60.792 | 62.303 | 10.13 | 16.44 MiB | 0.53x |

**2. 10,000 文档建索引 + 600 查询（30 查询 × 20 次，`sha256:742eb42a94d684ec...`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `sqlite_fts5_c`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 226.551 | 217.275 | 265.433 | 377585.42 | 25.41 MiB | 0.87x |
| `sqlite_fts5_c` | 196.257 | 192.415 | 204.213 | 327095.42 | 6.58 MiB | 1.00x (baseline) |
| `sqlite_fts5_py` | 223.737 | 222.254 | 226.689 | 372895.07 | 16.58 MiB | 0.88x |

红队：23 / 23 单测（含 11 个红队测试），`audit/difftest.py` 对 SQLite 3.54.0 FTS5 9 个种子约 34,000 次查询与 21,600 次摘要 0 差异（token、`MATCH` 表达式、结果顺序与 BM25 分值 ±1e-12、摘要 UTF-8 安全）；`wasm_smoke` 4 模式 stdout SHA-256 均为 `1ebc76fd113f109093c0d76af062b1300d6b6a5846920a24552ff45759715562`。领先项：30 查询负载快于 Python `sqlite3`（45.5 vs 61.2 ms）。落后项：两个负载均慢于 C SQLite FTS5（0.71x / 0.87x）；600 查询负载与 Python `sqlite3` 基本持平（226.6 vs 223.7 ms）；峰值 RSS 25.41 MiB，约为 C 的 3.9×、Python `sqlite3` 的 1.5×。

### zip

参考实现：Go `go1.27.3` 标准库 `archive/zip` 与 Rust `1.100.0` [`zip`](https://github.com/zip-rs/zip2) `=2.2.3`（`--release --locked`，`default-features = false, features = ["deflate"]`，经 `packages/zip/bench/rust/Cargo.lock` 锁定 `flate2 1.1.11` / `miniz_oxide 0.9.1` / `crc32fast 1.5.5`）。`sh packages/zip/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`--warmup 1 --rounds 5`，严格交替）运行，三方 stdout SHA-256 逐字节一致。

**1. 全量解压 + CRC-32（200 个混合 JSON / 日志 / 源码文件，23,566,337 B 解压后，`sha256:df6e3ff7b79285ec...`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `go_zip`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 51.997 | 46.998 | 59.155 | 453.22 | 6.23 MiB | 0.83x |
| `go_zip` | 43.306 | 42.174 | 43.810 | 544.18 | 15.42 MiB | 1.00x (baseline) |
| `rust_zip` | 29.660 | 29.248 | 30.896 | 794.55 | 4.75 MiB | 1.46x |

**2. Deflate L6 打包写出（同 200 个文件，`sha256:a8a92fa0e98f2bdc...`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `go_zip`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 160.149 | 153.976 | 181.847 | 147.15 | 55.72 MiB | 0.49x |
| `go_zip` | 78.654 | 72.730 | 81.822 | 299.62 | 65.97 MiB | 1.00x (baseline) |
| `rust_zip` | 121.926 | 103.381 | 130.851 | 193.28 | 28.53 MiB | 0.65x |

**3. 20,000 条目 CD 扫描 + 60,000 次随机按名查找（3 × 20,000 ops，`sha256:5a54f9e6c779591b...`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_zip`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 43.756 | 36.921 | 48.859 | 729.27 | 15.06 MiB | **2.33x** |
| `go_zip` | 101.993 | 86.057 | 113.823 | 1699.88 | 28.86 MiB | 1.00x (baseline) |
| `rust_zip` | 159.757 | 147.226 | 201.739 | 2662.62 | 18.20 MiB | 0.64x |

红队：15 / 15 单测（复用 `flate` 20 / 20），`audit` 18 / 18（3 P0 + 7 P1 + 5 P2 全部修复）；62 个构造向量 + 12,000 例变异 fuzz 0 崩溃，4 模式输出逐字节一致；65,536 个对抗碰撞文件名打开耗时 0.09 s（修复前 13.4 s，对照组 0.10 s）。领先项：W3 大归档 CD 索引 + 随机查找为 Go 的 **2.33x**、Rust `zip` 的 **3.65x**（729.3 ns/op，峰值 RSS 约为 Go 的一半），W1 峰值 RSS 比 Go 低 2.5×，W2 峰值 RSS 比 Go 低 10.25 MiB。落后项与 caveat：W1 为 Go 的 0.83x、Rust 的 0.57x，W2 为 Go 的 0.49x、Rust 的 0.76x，剖析确认 `zip` 自身头部 / 分帧开销 ≤ 10%，差距来自 `packages/flate` 的标量 Slice-by-16 CRC-32（比 Go / Rust 的 ARMv8 `CRC32X` 慢约 4.5×）与标量 LZ77 L6 匹配；W2 的 SHA-256 门禁只覆盖元数据（文件数、解压总量、CRC 异或），不覆盖压缩后体积，L6 下 `flate` 输出 2,317,817 B，比 Go `compress/flate` 的 2,237,829 B 大 **3.6%**；W3 的 Store 条目在 Pion 中是零拷贝 `Bytes::slice`，而 Go（`io.ReadAll` 经 `fs.File`，首次 `Open` 还会建排序目录树）与 Rust（`read_to_end`）都会拷贝负载，领先部分反映 API 语义差异；单个归档 / 条目上限为 2 GiB − 1（内存 `Bytes` + 32 位 `Int`）。

### dns

参考实现：Go 1.27.3 [`miekg/dns`](https://github.com/miekg/dns) `v1.1.63`（`-mod=readonly`，锁定 `go.sum`）与 Rust 1.100.0 [`hickory-proto`](https://github.com/hickory-dns/hickory-dns) `0.24.2`（`--release --locked`）。`sh packages/dns/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`--warmup 1 --rounds 5`，严格交替）运行，stdout 覆盖完整名称 / AAAA / TXT 与完整编码线格式字节，三方 SHA-256 逐字节一致；对抗基准由 `sh packages/dns/audit/bench/run_adv_bench.sh` 产出（A1–A7 SHA-256 均一致）。

**1. 混合响应批量解码（200,000 个 A / AAAA / CNAME / MX / TXT / SRV / SOA / OPT 响应，32,627,200 B，`sha256:3fa1bb3a9936a8b8...`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_hickory) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 268.973 | 267.223 | 270.015 | 121.30 | 1344.86 | 2.22 MiB | 0.91x |
| `go_miekg_dns` | 264.416 | 257.589 | 266.582 | 123.39 | 1322.08 | 16.58 MiB | 0.93x |
| `rust_hickory` | 245.879 | 244.680 | 249.039 | 132.70 | 1229.39 | 2.44 MiB | 1.00x (baseline) |

**2. 带压缩的批量响应编码（200,000 个，`sha256:1fa867834398d9f1...`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_hickory) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 100.887 | 100.177 | 102.464 | 323.40 | 504.43 | 4.50 MiB | 1.52x |
| `go_miekg_dns` | 97.707 | 93.693 | 101.225 | 333.93 | 488.54 | 16.86 MiB | 1.57x |
| `rust_hickory` | 152.929 | 150.142 | 155.991 | 213.35 | 764.65 | 4.52 MiB | 1.00x (baseline) |

**3. 查询构造 + 编码 + 解码往返（500,000 ops，`sha256:86090f4893c5869a...`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs rust_hickory) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 109.090 | 107.476 | 112.043 | 218.18 | 1.86 MiB | 1.49x |
| `go_miekg_dns` | 78.874 | 76.821 | 81.206 | 157.75 | 16.23 MiB | 2.07x |
| `rust_hickory` | 162.928 | 161.232 | 163.773 | 325.86 | 2.23 MiB | 1.00x (baseline) |

**4. 对抗基准（A1–A7）**

| Workload | Pion | Go `miekg/dns` | Rust `hickory-proto` | Pion vs Rust |
| --- | ---: | ---: | ---: | ---: |
| A1 small response encode (1M msgs), ns/op | **161.74** | 172.06 | 253.22 | **1.57x** |
| A2 500-owner encode, µs/msg | 60.80 | **41.48** | 197.39 | **3.25x** |
| A3 2,000-owner encode (>16 KiB), µs/msg | 223.19 | **121.69** | 1202.71 | **5.39x** |
| A4 2,000 **colliding** owners encode, µs/msg | 232.10 | **120.64** | 1758.90 | **7.58x** |
| A5 2,750-owner encode (~62 KiB), µs/msg | 296.30 | **147.65** | 1547.98 | **5.22x** |
| A6 2,750 **colliding** owners encode, µs/msg | 305.60 | **150.93** | 2537.59 | **8.30x** |
| A7 2,000-owner decode, µs/msg | **177.39** | 214.09 | 189.91 | **1.07x** |

红队：23 / 23 单测，`audit` 70 / 70（5 P0 + 15 P1 + 12 P2 全部修复）；10,178 例差分（消息 6,389、名称 1,548、IPv6 635、TCP 806、DoH 800）Native == Wasm32 逐字节一致，0 panic / trap；635 / 635 个 IPv6 与 Go `netip` / Rust `std::net` 完全一致。领先项：A1 小响应压缩编码 161.74 ns/op 同时领先 Go（172.06）与 Rust（253.22）；W2 为 Rust 的 **1.52x**（Go 的 0.97x），W3 为 Rust 的 **1.49x**；A7 2,000 owner 解码同时领先 Go 与 Rust；按消息加种子的哈希使碰撞负载与普通负载基本持平（A4 / A3 = 1.04，A6 / A5 = 1.03）；各负载峰值 RSS 约为 Go 的 1/4–1/9。落后项：W1 混合解码为 Rust 的 0.91x、Go 的 0.98x；W3 为 Go 的 0.72x；500–2,750 owner 大响应编码（A2 / A3 / A5）比 Go 慢约 1.5–2.0×（仍比 Rust 快 3.25–5.39×）。

### protobuf

参考实现：Rust [`prost`](https://github.com/tokio-rs/prost) `0.13.5`（`--release --locked`）与 Go [`google.golang.org/protobuf`](https://github.com/protocolbuffers/protobuf-go) `v1.36.6`（`protowire`；`DynamicMessage` 对比使用 `dynamicpb` / `protojson`），依赖经 `Cargo.lock` 与 `go.sum` 锁定。W1–W3 由 `sh packages/protobuf/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`--warmup 1 --rounds 5`，严格交替）产出，三方 stdout SHA-256 逐字节一致；`DynamicMessage` 对比来自 `sh packages/protobuf/audit/run_audit.sh` 第 6 节（SHA-256 校验一致）。

**1. OTel / RPC Span 批量解码（100,000 个嵌套 span，24,398,500 B，`sha256:34e1a7ae7c6c0e93...`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_prost) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 115.646 | 105.939 | 117.208 | 210.97 | 1156.46 | 2.84 MiB | 0.47x |
| `rust_prost` | 54.200 | 53.464 | 56.525 | 450.15 | 542.00 | 2.50 MiB | 1.00x (baseline) |
| `go_protobuf` | 43.227 | 41.709 | 44.736 | 564.43 | 432.27 | 11.08 MiB | 1.25x |

**2. OTel / RPC Span 批量编码（100,000 个嵌套 span，`sha256:f534611558427306...`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_prost) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 39.001 | 37.328 | 39.826 | 625.60 | 390.00 | 3.12 MiB | 0.47x |
| `rust_prost` | 18.271 | 17.146 | 19.970 | 1335.40 | 182.71 | 3.19 MiB | 1.00x (baseline) |
| `go_protobuf` | 16.866 | 16.352 | 17.339 | 1446.63 | 168.66 | 5.28 MiB | 1.08x |

**3. packed `sint64` + `double` 往返（8 × 400k 值，19,110,272 B，`sha256:092a2171c4c9da7c...`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_prost) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 24.728 | 23.752 | 25.456 | 772.83 | 7.73 | 13.02 MiB | 0.91x |
| `rust_prost` | 22.519 | 21.396 | 22.737 | 848.62 | 7.04 | 10.97 MiB | 1.00x (baseline) |
| `go_protobuf` | 21.188 | 21.007 | 21.988 | 901.95 | 6.62 | 24.34 MiB | 1.06x |

**4. `DynamicMessage` vs Go `dynamicpb`**

| Workload | Pion Median (ms) | Go `dynamicpb` Median (ms) | Pion Speedup (vs Go) | Peak RSS (Pion / Go) |
| --- | ---: | ---: | ---: | ---: |
| OTel spans (2,000 × 20): Dynamic Decode | 127.275 | 205.256 | **1.61x** | 3.80 / 16.97 MiB |
| OTel spans (2,000 × 20): Dynamic Decode + Proto3 JSON | 270.435 | 440.897 | **1.63x** | 3.97 / 18.03 MiB |
| OTel spans (2,000 × 20): Dynamic Decode + Re-encode | 217.606 | 365.582 | **1.68x** | 3.89 / 16.98 MiB |
| `map<string,int64>` 50k distinct entries (×5): Decode + JSON | 113.330 | 194.031 | **1.71x** | 22.16 / 40.88 MiB |
| `map<string,int64>` 50k distinct entries (×5): Roundtrip | 107.533 | 90.999 | 0.85x | 20.02 / 27.48 MiB |
| `merge_unknown_10000` (40 KB adversarial merge) | 11.038 | 11.732 | **1.06x** | 3.91 / 9.66 MiB |
| `bigschema_2000` (2,000-message schema, 20k `Leaf`) | 16.762 | 34.043 | **2.03x** | 12.97 / 28.28 MiB |

红队：29 / 29 单测，`audit` 44 / 44（4 P0 + 7 P1 + 5 P2，F-1–F-16 全部修复）；212 个定向向量 + 6,006 例线格式变异与 2,000 例 `.proto` 变异 fuzz，对 Go `protowire` / `dynamicpb` / `protojson` / `protocompile` 与 Rust `prost` 三方差分。领先项：`DynamicMessage` 解码 / JSON / 重编码与 2,000 消息大 schema 为 Go `dynamicpb` 的 **1.61x–2.03x**，峰值 RSS 低 4–4.5×；对抗合并 `merge_unknown_10000` 为 Go 的 1.06x。落后项：手写嵌套 Span 解码 / 编码为 Rust `prost` 的 0.47x（Go 的 0.37x / 0.43x），根因是 `Span` / `KeyValue` / `SpanEvent` 逐字段堆分配、`Array` push 增长与 `WireWriter` 逐字节拷贝（Rust / Go 下沉为 SIMD `memcpy`）；packed 往返为 Rust 的 0.91x、Go 的 0.86x；`map<string,int64>` 5 万条往返为 Go 的 0.85x。

### graphql

参考实现：Rust [`apollo-parser`](https://github.com/apollographql/apollo-rs) `=0.8.4`（`cargo build --release`，基线 `1.00x`）与 Node.js [`graphql`](https://github.com/graphql/graphql-js) `16.10.0`（`parse({ noLocation: true })`、`stripIgnoredCharacters`、`print`）。`sh packages/graphql/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`--warmup 1 --rounds 5`，严格交替）运行，三方 stdout SHA-256 逐字节一致；Pion 使用默认 `ParseOptions`。

**1. 大型 Schema SDL 解析（3 × 2,040,452 B = 6.12 MB，`sha256:9cf6ac8cb35d6b5a...`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_apollo`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **82.777** | 81.175 | 83.853 | **73.95** | 31.19 MiB | **1.34x** |
| `rust_apollo` (`apollo-parser 0.8.4`) | 110.948 | 109.095 | 120.548 | 55.17 | **23.17 MiB** | 1.00x (baseline) |
| `node_graphqljs` (`graphql 16.10.0`) | 159.354 | 155.201 | 167.396 | 38.41 | 301.61 MiB | 0.70x |

**2. 复杂可执行查询解析 + 静态校验（20,000 个查询，`sha256:ca78a77d644df252...`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_apollo`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 211.478 | 208.869 | 212.338 | 10,573.92 | 2.73 MiB | **1.85x** |
| `rust_apollo` (`apollo-parser 0.8.4`) | 391.700 | 381.426 | 406.097 | 19,585.02 | **2.70 MiB** | 1.00x (baseline) |
| `node_graphqljs` (`graphql 16.10.0`) | **168.720** | 166.912 | 177.995 | **8,436.00** | 72.91 MiB | **2.32x** |

**3. 查询压缩 + 重解析 + 打印往返（10,000 个查询 / 7.25 MB，`sha256:9f372181ffe8ee03...`）**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_apollo`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **226.587** | 221.770 | 240.716 | **31.99** | **22,658.68** | **2.75 MiB** | **1.23x** |
| `rust_apollo` (`apollo-parser 0.8.4`) | 278.217 | 271.302 | 304.855 | 26.05 | 27,821.66 | 2.97 MiB | 1.00x (baseline) |
| `node_graphqljs` (`graphql 16.10.0`) | 1,050.477 | 1,003.847 | 1,124.690 | 6.90 | 105,047.74 | 81.27 MiB | 0.26x |

红队：33 / 33 单测，`audit` 30 / 30（2 P0 + 4 P1 + 9 P2 全部修复）；6,000 例语法生成文档 AST 与 `graphql-js` 100% 一致。领先项：3 项负载全部领先 Rust `apollo-parser`（**1.34x / 1.85x / 1.23x**），大 SDL 解析与压缩往返分别为 Node `graphql-js` 的 **1.93x** / **4.64x**，峰值 RSS 比 Node 低 10–30×。落后项与 caveat：W2 20k 小查询落后 V8 热 JIT（0.80x，但 Pion 同时跑全部 13 条规则，峰值 RSS 2.73 vs 72.91 MiB）；W1 峰值 RSS 高于 Rust（31.19 vs 23.17 MiB，40 万平铺字段时高至 3×）；`apollo-parser` 构造无损 Rowan CST 而非紧凑 AST，其 W3 "打印" 为 CST 原文 `to_string()`；Node 计时含每轮约 40 ms 进程启动与 JIT 预热；**Wasm32 caveat**：`audit/scripts/perf.py` 在 Node 下实测 Pion Wasm32 比 Pion Native 慢 1.9–2.7×，5 个语料中 4 个解析比 `graphql-js` 慢 1.3–1.8×（仅转义密集字符串领先，打印与压缩仍领先 `graphql-js`）；`validate_executable` 只含 13 条 schema-free 规则，schema-aware 类型检查不在 `v0.1.0` 范围内。

### woff2

参考实现：纯 Rust [`wuff`](https://github.com/googlefonts/wuff) `0.2.10`（`--release`）。`sh packages/woff2/bench/run_bench.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替）运行于真实 TrueType 字体（`Arial.ttf` 755 KB / 3,381 glyphs、`Monaco.ttf` 517 KB / 1,678 glyphs）；每个解码出的 SFNT 表载荷——含完整重建的 `glyf` 与 `loca` 表——均经全 SFNT SHA-256 验证 **100% 逐字节一致**，且 Pion 解码出的 SFNT 整字体校验和精确等于 `0xB1B0AFBA`。详见 [`packages/woff2/README.md`](packages/woff2/README.md)。

| Workload | `pion` Median (Throughput) | `rust_wuff` Median (Throughput) | `pion` Peak RSS | `rust_wuff` Peak RSS | `pion` vs `rust_wuff` |
| --- | ---: | ---: | ---: | ---: | ---: |
| WOFF2 Decode: `Arial.woff2` (755 KB SFNT × 10) | 66.423 ms (116.91 MB/s) | 36.295 ms (213.95 MB/s) | **7.84 MiB** | 9.80 MiB | 0.55x |
| WOFF2 Decode: `Monaco.woff2` (517 KB SFNT × 10) | 33.235 ms (159.21 MB/s) | 19.566 ms (270.45 MB/s) | 5.20 MiB | 4.75 MiB | 0.59x |
| WOFF1 Decode: `Arial.woff` (755 KB SFNT × 10) | 43.867 ms (176.27 MB/s) | 29.495 ms (262.15 MB/s) | 6.59 MiB | 5.66 MiB | 0.67x |

红队：35 / 35 单测，`run_audit.sh all` 退出码 0，110 / 110 真实字体（含 `glyf`/`loca`）与 Rust `wuff` 逐字节一致，12k `--release` fuzz 0 crash。领先项：`Arial.woff2` 峰值 RSS 低于 Rust `wuff`（7.84 vs 9.80 MiB）。落后项：3 项吞吐为 `wuff` 的 0.55x / 0.59x / 0.67x（底层分别复用纯 Pion `brotli` 与 `flate`，叠加 SFNT 轮廓重建与边界校验开销）。

### mp4

参考实现：独立纯 Rust [`symphonia-format-isomp4`](https://github.com/pdeljanov/Symphonia) `0.5.5`（`--release`），配合强制 **`ffprobe` 真值校验**（全部 4 组语料在 `pos/size/dts/pts/dur/key` 上与 `ffprobe` 精确一致，含 2-`trun`/1-`traf` 多 `trun` fMP4 分片）。`sh packages/mp4/bench/run_bench.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替）运行，全轮次 stdout SHA-256 逐字节一致。详见 [`packages/mp4/README.md`](packages/mp4/README.md)。

| Workload | `pion` Median (`µs/iter`) | `rust_symphonia` Median (`µs/iter`) | `pion` Peak RSS | `rust_symphonia` Peak RSS | Speedup vs `rust_symphonia` | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Standard MP4 Demux (H.264 720p B-frames + AAC-LC, 309 samples × 1,000) | **18.043 ms (`18.04 µs/iter`)** | 894.839 ms (`894.84 µs/iter`) | **8.86 MiB** | 9.80 MiB | **49.60×** | `4d2ee24b3c8a09ff...` |
| YouTube MSE fMP4 Video (`sidx`+`moof`+`mdat`, 60 samples, init+seg × 1,000) | **13.992 ms (`13.99 µs/iter`)** | 373.335 ms (`373.33 µs/iter`) | **5.30 MiB** | 7.69 MiB | **26.68×** | `e65578c1240d7bf2...` |
| Multi-`trun` fMP4 Video (2 `trun`s/`traf`, 60 samples, init+seg × 1,000) | **11.052 ms (`11.05 µs/iter`)** | 392.389 ms (`392.39 µs/iter`) | **5.30 MiB** | 7.67 MiB | **35.50×** | `e65578c1240d7bf2...` |
| YouTube MSE fMP4 Audio (AAC-LC 48kHz, 92 samples, init+seg × 2,000) | **14.700 ms (`7.35 µs/iter`)** | 43.697 ms (`21.85 µs/iter`) | **2.05 MiB** | 2.66 MiB | **2.97×** | `5564d952aa7922c1...` |

进程内微基准（`mp4_audit prof-fmp4`，300k 轮 `yt_init_0.m4s` + `yt_seg_0_1.m4s`）：`parse_init_segment` = **0.83 µs/iter**（250 ms / 300k），`parse_media_segment` = **0.87 µs/iter**（262 ms / 300k）。

红队与诚实口径说明：8 / 8 单测，`redteam_test` 22 / 22 全绿，`compare` 37 / 37 与 `ffprobe` 逐样本对齐且 31 条 `elst` 偏移归零，12,000 例 Native / Wasm32 fuzz 0 崩溃 / 0 分歧，`trun`/`stco` 放大炸弹在 1.9 MiB RSS 下 0 ms 拒收。**口径说明**：fMP4 基准每轮均同时解析 init 与 media segment，按 `µs/iter` 而非被 `mdat` 体积虚增的 `MB/s` 报告；`symphonia-format-isomp4` 的 `next_packet()` 会把 `mdat` 载荷拷入逐包 `Vec<u8>`，而 `packages/mp4` 是返回 `(offset, size)` 范围的零拷贝解复用器，倍率同时反映了纯 Pion 元数据解析效率与零拷贝索引设计。

### glsl

参考实现：Rust [`glsl`](https://crates.io/crates/glsl) `7.0.0`（`--release`，LTO）。`sh packages/glsl/bench/run_bench.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替）运行于真实 Three.js PBR（ES 1.00）、WebGL2 Shadertoy 光线步进（ES 3.00）与 2D 后处理（ES 1.00）片元着色器，双方输出规范化反射摘要并经 SHA-256 逐字节一致校验。详见 [`packages/glsl/README.md`](packages/glsl/README.md)。

| Workload | `pion` Median (Throughput) | `rust_glsl` Median (Throughput) | `pion` Peak RSS | `rust_glsl` Peak RSS | `pion` vs `rust_glsl` | Reflection SHA-256 (identical) |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Three.js PBR ES 1.00 Frag (`4.77 KB × 500`) | **63.358 ms (37.61 MB/s)** | 1,505.716 ms (1.58 MB/s) | **2.25 MiB** | 2.75 MiB | **23.77x** | `a1a0175c13201ce9...` |
| WebGL2 Shadertoy ES 3.00 Frag (`2.88 KB × 500`) | **38.506 ms (37.33 MB/s)** | 1,502.805 ms (0.96 MB/s) | **2.12 MiB** | 2.67 MiB | **39.03x** | `f848fbeb2be7e14d...` |
| 2D Post-Process ES 1.00 Frag (`1.44 KB × 500`) | **35.911 ms (20.08 MB/s)** | 910.515 ms (0.79 MB/s) | **2.05 MiB** | 2.56 MiB | **25.35x** | `6afda6cb4886d4b6...` |

真值编译与红队验证：真实 macOS OpenGL 4.1 Core（`4.1 Metal - 91.7 | GLSL: 4.10`）`judge` **75 / 75 PASS**（74 / 74 有效 WebGL1/WebGL2 着色器对编译链接全过 + 1 / 1 非法 UTF-8 BOM 拒收），`verify_gl41.c` 基准语料 **5 / 5 PASS**；`audit unit` **26 / 26** 全绿，12,000 例 Native / Wasm32 fuzz 0 崩溃 / 0 差异，50k `#define` 由 2 s 降至 49 ms。**口径说明**：本基准对比 **parse + reflect** 吞吐（Pion 侧同时完成 ES→410 Core 转译，且支持函数体内 `#ifdef`/`#if`）；Rust `glsl 7.0.0` 通过 `nom` 构造完整递归下降表达式 AST 并按原 ES 方言打印，不做 ES→410 转译，倍率同时反映前端架构定位差异。

### http2

参考实现：Rust `h2` `0.4.20`（`--release --locked`，基线）与 Go `golang.org/x/net` `v0.62.0`（`http2.Framer` + `ReadMetaHeaders` + `http2/hpack`）。以下内容如实摘录自 [`packages/http2/README.md`](packages/http2/README.md)；红队审计与公平基准证据见 `packages/http2/audit/`。

Run with `sh packages/http2/bench/run_bench.sh` via `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, locked `go.sum` / `Cargo.lock`, mandatory full-content stdout SHA-256 verification) on **Darwin arm64** against modern production HTTP/2 engines:
- **Go 1.27.3** `golang.org/x/net` **v0.62.0** (`http2.Framer` + `ReadMetaHeaders` + `http2/hpack`, `-mod=readonly`)
- **Rust 1.100.0** **`h2` 0.4.20** (its own `hpack` engine + `h2::Codec`, `--release --locked`, Huffman ON)

#### 1. HPACK Header Stream Decode (100,000 header blocks, Huffman + Dynamic Table)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `66 B` (`sha256:1612b3b496634b49...`) | Input: `3445400 B` | Ops: `100000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_h2_0.4.20) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 145.847 | 144.318 | 148.793 | 23.62 | 1458.47 | 2.16 MiB | 0.80x |
| `go_x_net_v0.62` | 135.819 | 135.606 | 136.535 | 25.37 | 1358.19 | 16.70 MiB | 0.86x |
| `rust_h2_0.4.20` | 116.742 | 113.514 | 117.552 | 29.51 | 1167.42 | 2.17 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `1612b3b496634b49335a3f0368965080d2bd520bc4b686084ac5736acfaf2294`._

#### 2. HPACK Batch Header Encode (100,000 header blocks, Huffman ON + Dynamic Table)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `73 B` (`sha256:d966eddf243ed850...`) | Input: `28562500 B` | Ops: `100000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_h2_0.4.20) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 55.688 | 54.932 | 55.860 | 512.90 | 556.88 | 3.56 MiB | 0.73x |
| `go_x_net_v0.62` | 59.137 | 58.811 | 60.249 | 482.99 | 591.37 | 14.31 MiB | 0.69x |
| `rust_h2_0.4.20` | 40.547 | 40.198 | 40.835 | 704.43 | 405.47 | 5.28 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `d966eddf243ed850ad2685fd406e46937173b02817e5dd9293ddbced9d986693`._

#### 3. Mixed HTTP/2 Frame Engine (200,000 frames: Deframe + CONTINUATION + HPACK)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `59 B` (`sha256:e96a6c442cacb947...`) | Input: `5689500 B` | Ops: `200000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_h2_0.4.20) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 82.564 | 81.492 | 83.443 | 68.91 | 412.82 | 2.17 MiB | 0.87x |
| `go_x_net_v0.62` | 84.889 | 83.337 | 85.383 | 67.02 | 424.44 | 16.41 MiB | 0.85x |
| `rust_h2_0.4.20` | 72.177 | 71.340 | 72.691 | 78.83 | 360.88 | 2.28 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `e96a6c442cacb947bdf20398303b9c673a6c0d0b90c43b0bc60b5bb80bfd910c`._

#### Objective Analysis
- **HPACK Encode (Huffman ON)**: With the $O(1)$ open-addressing dynamic-table hash index and zero-copy string Huffman encoding, Pion (`55.7 ms`, `512.9 MB/s`) is **faster than Go `x/net v0.62.0`** (`59.1 ms`, `483.0 MB/s`) and reaches **0.73×** of Rust `h2 0.4.20` (`40.5 ms`), at `3.56 MiB` peak RSS (vs `5.28 MiB` Rust / `14.31 MiB` Go).
- **Frame Engine (200k frames)**: Pion (`82.6 ms`, `68.9 MB/s`) is **faster than Go `x/net v0.62.0` `Framer + ReadMetaHeaders`** (`84.9 ms`, `67.0 MB/s`) and reaches **0.87×** of Rust `h2::Codec` (`72.2 ms`), at `2.17 MiB` peak RSS (level with Rust `2.28 MiB`).
- **HPACK Decode (100k blocks)**: With reusable Huffman scratch buffers and zero `to_bytes()` length copies, Pion (`145.8 ms`, `23.6 MB/s`) reaches **0.80×** of Rust `h2 0.4.20` (`116.7 ms`) and stays within 7% of Go `x/net v0.62.0` (`135.8 ms`, `0.86×`).

### jsonschema

参考实现：Rust `jsonschema =0.29.1`（基线）与 Node `ajv@8.17.1`。端到端负载含进程启动、JSON 解析与编译；稳态斜率由 `audit/bench/steady_state.py` 去除固定开销后测得。以下内容如实摘录自 [`packages/jsonschema/README.md`](packages/jsonschema/README.md)。

Measured on `Darwin arm64` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory byte-for-byte stdout SHA-256 verification).

- **Pion**: `packages/jsonschema` compiled with `pionc build --release`
- **Rust**: `jsonschema =0.29.1` (`Cargo.lock` locked, `cargo build --locked --release`)
- **Node.js**: `ajv@8.17.1` (`ajv/dist/2020`, single reused `Ajv2020` instance in all workloads)

Reproduce via:
```sh
sh packages/jsonschema/bench/run_bench.sh
sh packages/jsonschema/audit/run_audit.sh bench
```

#### End-to-End Workloads (`run_bench.sh`, includes process start-up + JSON parse + compile)

| Workload | Pion Median (ms) | Rust Median (ms) | Node `ajv` Median (ms) | Pion RSS | Rust RSS | Pion vs Rust | SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| **W1**: MCP tool call batch (50,000 ops) | 30.346 | 21.039 | 77.882 | 4.12 MiB | 34.73 MiB | 0.69x | `719e1b73...` |
| **W2**: Manifest / workflow batch (20,000 ops) | 28.730 | 21.832 | 83.605 | 4.03 MiB | 40.70 MiB | 0.76x | `2b436286...` |
| **W3**: Compile + validate E2E (2,000 schemas) | **29.104** | 30.392 | 201.044 | **4.50 MiB** | 30.92 MiB | **1.04x** | `561dcae3...` |

#### Steady-State Validation Slope (Fixed Start-up Removed, 2,000 Iterations)

Because short batch runs (20–85 ms) include fixed process start-up, file I/O, JSON parsing, and schema compilation, `audit/bench/steady_state.py` measures the pure validation slope (`ns/op`) between `0` and `2,000` iterations:

| Workload | Pion fixed / steady | Rust fixed / steady | Node `ajv` fixed / steady | Pion steady vs Rust |
| --- | ---: | ---: | ---: | ---: |
| **W1** (MCP tool call) | 4.5 ms / **396 ns/op** | 10.1 ms / 116 ns/op | 68.7 ms / 91 ns/op | 0.29x |
| **W2** (Manifest / workflow) | 3.6 ms / **977 ns/op** | 12.5 ms / 268 ns/op | 68.5 ms / 421 ns/op | 0.27x |

#### Adversarial Head-to-Head Benchmarks (`audit/run_audit.sh bench`)

| Workload | Pion Median (ms) | Rust Median (ms) | Node `ajv` Median (ms) | Pion RSS | Rust RSS | Pion vs Rust |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **a1**: Wide objects (1,000 keys, `additionalProperties`) | 34.108 | 17.558 | 127.740 | 10.83 MiB | 18.25 MiB | 0.51x |
| **a2**: `unevaluatedProperties`, 300-key objects | 45.313 | 36.359 | 103.189 | **5.25 MiB** | 22.47 MiB | 0.80x |
| **a3**: `uniqueItems`, 2,000-element arrays of objects | 67.332 | 41.414 | 22,487.369 | 20.19 MiB | 41.62 MiB | 0.62x |
| **a4**: Recursive `$ref` tree depth 40 | 31.425 | 28.071 | 73.028 | **5.53 MiB** | 21.34 MiB | 0.89x |
| **a5**: W1 MCP schema, 5,000 distinct instances | 57.743 | 33.913 | 85.902 | 14.03 MiB | 45.75 MiB | 0.59x |

#### Benchmark Takeaways

- **Compile + Validate (W3)** & **Cold/CLI latency**: Pion leads Rust slightly (`1.04x`) and is `6.9x` faster than reused-instance `ajv` while keeping Peak RSS at **4–5 MiB** (7–10x lower than Rust and 15–19x lower than Node).
- **Steady-state throughput (W1/W2/a1/a5)**: Once start-up is amortized, Rust `jsonschema` (per-keyword compiled trait objects over `serde_json::Map`) and V8-JIT'd `ajv` are ~3–4x faster per call than Pion's interpreter-style node dispatch.
- **Adversarial complexity (`a2`, `a3`, `run_audit.sh dos`)**: All quadratic paths are eliminated (`unevaluatedProperties` 50k keys in 4–6 ms, `uniqueItems` 4k deep-colliding arrays in 4–5 ms, `compile_refs_8000` in 6 ms vs Rust 15 ms, `$ref` DAG 2^22 in 91 ms / 3 MB vs Rust 7.0 s / 15.8 GB).

### mime

参考实现：Go 1.27.3 标准库（`mime` / `mime/multipart` / `mime/quotedprintable`）与 Rust `mime 0.3.18` + `infer 0.16.0`。以下内容如实摘录自 [`packages/mime/README.md`](packages/mime/README.md)。

Run with `sh packages/mime/bench/run_bench.sh` via `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, locked `go.sum` / `Cargo.lock`, mandatory stdout SHA-256 verification) on **Darwin arm64** against:
- **Go 1.27.3** stdlib (`mime`, `mime/multipart`, `mime/quotedprintable`, `-mod=readonly`)
- **Rust 1.100.0** (`mime 0.3.18` + `infer 0.16.0`, `--release --locked`)

#### 1. 50 MB `multipart/form-data` Parse (10 × 5 MiB binary attachments + 200 form fields)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `63 B` (`sha256:792007fefaba0ec5...`) | Input: `52453980 B`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs go_stdlib) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 39.383 | 38.959 | 41.377 | 1331.88 | 101.88 MiB | 0.89x |
| `go_stdlib` | 34.855 | 32.817 | 37.470 | 1504.94 | 120.06 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `792007fefaba0ec5c328a7a9142c02d667d6ddd0dc58658935440ecc48101e39`._

#### 2a. 200k Mixed `Content-Type` / `Content-Disposition` / RFC 2047 Header Parse

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `48 B` (`sha256:549e031f7958ce5e...`) | Input: `11900000 B` | Ops: `200000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs go_stdlib) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 124.604 | 117.952 | 125.890 | 95.50 | 623.02 | 2.33 MiB | 0.60x |
| `go_stdlib` | 74.173 | 68.211 | 77.216 | 160.44 | 370.87 | 12.14 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `549e031f7958ce5eb731bb7517877082c7bc83ba1a3de8b1eea76fe6b0f5e55c`._

#### 2b. 200k `Content-Type` Media-Type Parse (Pion vs Go 1.27 vs Rust `mime 0.3`)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `46 B` (`sha256:b8e823b81e6f5cca...`) | Input: `6060000 B` | Ops: `200000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_mime) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 79.984 | 78.698 | 83.950 | 75.76 | 399.92 | 2.06 MiB | 0.39x |
| `go_stdlib` | 44.954 | 42.894 | 46.320 | 134.80 | 224.77 | 11.98 MiB | 0.69x |
| `rust_mime` | 31.236 | 29.393 | 34.145 | 194.00 | 156.18 | 1.97 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `b8e823b81e6f5cca03be4d98c61a840d24916cdf331841e2cf064cffbc7a7bb6`._

#### 3a. 16 MB Quoted-Printable Decode

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `50 B` (`sha256:7680fc8584f4cf31...`) | Input: `16777217 B`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs go_stdlib) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 40.049 | 37.152 | 41.652 | 418.91 | 48.25 MiB | 1.72x |
| `go_stdlib` | 69.042 | 66.728 | 72.467 | 243.00 | 55.42 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `7680fc8584f4cf31ba330eeed449ffca494efff3c06efee79d148707bd1862bd`._

#### 3b. 100k Magic-Byte MIME Sniffing (Pion vs Rust `infer 0.16`)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `40 B` (`sha256:58428bd96f470754...`) | Input: `4770000 B` | Ops: `100000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_infer) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 20.325 | 16.584 | 23.947 | 234.68 | 203.25 | 1.86 MiB | 0.83x |
| `rust_infer` | 16.937 | 16.623 | 19.214 | 281.64 | 169.37 | 1.80 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `58428bd96f4707549477eb91fc02e793a497fabf19415d34b2c81cabdd3d7526`._

#### 4. Red-Team Adversarial Performance Probes (`sh packages/mime/audit/run_audit.sh perf`)

All probes verified with identical stdout SHA-256 against Go 1.27 (`--warmup 1 --rounds 5`):

| Adversarial Probe | Pion Before | Pion After | Go 1.27 | Pion/Go (After) |
| --- | ---: | ---: | ---: | ---: |
| 8 MiB random body (typical) | 19.7 ms | **13.2 ms** | 19.1 ms | **0.7x** (faster) |
| 8 MiB near-miss (`--boundary1234567890`) | 19.6 ms | **14.5 ms** | 17.1 ms | **0.9x** (faster) |
| **P1-4**: 8 MiB periodic worst case (`a`×70) | 576.7 ms | **16.8 ms** | 20.4 ms | **0.8x** (faster, **34× speedup**) |
| 1000 tiny parts fan-out | — | **10.8 ms** | 14.4 ms | **0.7x** (faster) |
| **P0-1**: 64 × 60 KiB plain-param bomb | 4,646 ms | **75.8 ms** | 50.5 ms | **1.5x** (**61× speedup**) |
| **P0-1**: 64 × 60 KiB RFC 2231 param bomb | 13,171 ms | **136.4 ms** | 184.0 ms | **0.7x** (faster, **96× speedup**) |
| Wasm32 release: `bmh_worst_8.bin` | 2.43 s | **0.09 s** | — | **27× speedup** |
| Wasm32 release: `mp_cont_bomb.bin` | 12.02 s | **0.31 s** | — | **39× speedup** |

#### Honest Performance Analysis

- **Wins**:
  - **Quoted-Printable Decode (16 MB)**: Pion (`418.91 MB/s`) is **1.72x faster** than Go 1.27 `mime/quotedprintable` (`243.00 MB/s`) with lower peak RSS (`48.25 MiB` vs `55.42 MiB`).
  - **Adversarial Multipart & RFC 2231 Bombs**: Pion beats Go 1.27 on 8 MiB periodic worst-case boundary search (`0.8x` time), 8 MiB random/near-miss bodies (`0.7–0.9x`), 1000-part fan-out (`0.7x`), and 64 × 60 KiB RFC 2231 parameter bombs (`0.7x`). Note that Go reads multipart through a streaming `io.Reader` and copies part bodies, whereas Pion slices an in-memory `Bytes` buffer.
  - **50 MB `multipart/form-data` Parse**: Pion (`1,331.88 MB/s`) achieves **0.89x** of Go 1.27 (`1,504.94 MB/s`) while consuming **15% less peak RSS** (`101.88 MiB` vs `120.06 MiB`).
- **Gaps**:
  - **Short Header Parsing (`headers_full` / `headers_mt`) & Plain-Param Bomb**: Pion (`399.92 ns/op` on `Content-Type`, `623.02 ns/op` on mixed headers, `1.5x` time on 64 × 60 KiB plain params) trails Go 1.27 (`224.77 / 370.87 ns/op`) and Rust `mime 0.3` (`156.18 ns/op`), though Pion uses **5–6x less peak RSS** than Go (`2.06–2.33 MiB` vs `11.98–12.14 MiB`) because Pion allocates per-component `String` slices instead of keeping a single backing buffer with index spans.
  - **Magic-Byte Sniffing (100k ops)**: After expanding coverage to 40+ formats (matching `infer 0.16`), Pion (`203.25 ns/op`) is **0.83x** of Rust `infer 0.16` (`169.37 ns/op`) with near-identical ~1.8 MiB peak RSS.

### asn1

参考实现：Go `go1.27.3` 标准库（`crypto/x509` + `encoding/pem` + `encoding/asn1`）与 Rust（`x509-parser 0.16.0`、`der 0.7.10`、`pem 3.0.6`）。以下内容如实摘录自 [`packages/asn1/README.md`](packages/asn1/README.md)。

Measured on `Darwin arm64` via `sh packages/asn1/bench/run_bench.sh` and `sh packages/asn1/audit/run_audit.sh bench` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification) comparing:
- **`pion`**: `packages/asn1` (`pionc 0.1.0 --release`)
- **`go_x509` / `go_asn1`**: Go `go1.27.3` stdlib (`crypto/x509` + `encoding/pem` + `encoding/asn1`)
- **`rust_x509` / `rust_der`**: Rust (`x509-parser 0.16.0`, `der 0.7.10`, `pem 3.0.6`, `--release --locked`)

#### 1. Real PEM Cert Chain Full Parse (100 multi-algo X.509 v3 certs × 100 = 10,000 certs, 11,010,800 B)

_SHA-256 verified identical across all implementations and rounds: `3ab4b31423628fc3545d5a72b7f0da1ba3412305cd485e56ac37a732545cd923`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_x509`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 68.050 | 67.790 | 69.271 | 161.80 | 6804.99 | 3.08 MiB | 0.89x |
| `go_x509` | 60.654 | 59.571 | 62.331 | 181.54 | 6065.36 | 16.55 MiB | 1.00x (baseline) |
| `rust_x509` | 59.519 | 59.284 | 65.117 | 185.00 | 5951.85 | 2.66 MiB | 1.02x |

#### 2. Pure DER X.509 v3 Parse + 3× SAN Hostname Verify (50,000 certs, 38,604,000 B)

_SHA-256 verified identical across all implementations and rounds: `63790b358ff1381909ec8b61dab2061b036ac91dfeb24a6b1d608ede566fa33e`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_x509`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 215.075 | 210.849 | 226.265 | 179.49 | 4301.50 | 2.56 MiB | 0.85x |
| `go_x509` | 182.652 | 177.559 | 199.655 | 211.35 | 3653.04 | 18.91 MiB | 1.00x (baseline) |
| `rust_x509` | 95.695 | 94.139 | 98.284 | 403.41 | 1913.90 | 2.30 MiB | 1.91x |

#### 3. Generic ASN.1 DER TLV Encode + Decode Roundtrip (100,000 structures, 7,635,000 B)

_SHA-256 verified identical across all implementations and rounds: `19093852fc5c5b2e675595878a529fd55915f8af43d6e897ef276720d041cd86`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_asn1`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 120.671 | 119.352 | 122.347 | 63.27 | 1206.71 | 1.94 MiB | **1.48x** |
| `go_asn1` | 178.035 | 176.802 | 181.341 | 42.88 | 1780.35 | 16.34 MiB | 1.00x (baseline) |
| `rust_der` | 41.362 | 40.861 | 47.660 | 184.59 | 413.62 | 1.94 MiB | 4.30x |

#### 4. Adversarial-Shape X.509 Benchmarks (`audit/run_audit.sh bench`)

_All stdout SHA-256 hashes verified identical across Pion, Go 1.27, and Rust in every round._

| Shape | Work | `pion` (ms) | `go_x509` (ms) | `rust_x509` (ms) | `pion` vs Go | `pion` vs Rust | Peak RSS pion / go / rust (MiB) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `real` | 8 OpenSSL certs × 20,000 | 600.539 | 471.353 | 291.890 | 0.78x | 0.49x | 2.39 / 17.41 / 2.27 |
| `big_rsa_cert` | RSA-4096 cert × 100,000 | 410.845 | 306.991 | 192.480 | 0.75x | 0.47x | 2.23 / 16.91 / 2.22 |
| `many_rdn` | 1 cert, 4,000-RDN subject × 300 | 182.252 | 140.372 | 122.758 | 0.77x | 0.67x | 2.64 / 16.81 / 3.95 |
| `many_san` | 1 cert, 4,000 dNSName SANs × 300 | 50.075 | 42.320 | 35.189 | 0.85x | 0.70x | 2.83 / 16.08 / 2.64 |
| `many_ext` | 1 cert, 4,000 extensions × 20 | 25.863 | 26.475 | 13.979 | **1.02x** | 0.54x | 3.14 / 15.36 / 2.83 |

Single-certificate extension cliff (`N = 64,000` distinct extensions, `1.2 MB` DER): **Pion `0.01 s` CPU** vs Go `0.02 s` vs Rust `0.00 s` (down from `4.10 s` prior to O(1) duplicate-OID hashing).

#### Honest Performance Notes

- **Strengths**:
  - **Generic DER TLV Roundtrip (`1.48×` Go `encoding/asn1`)**: Direct `DerWriter` / `DerReader` encoding and cursor-based decoding avoid Go's reflection overhead (`120.7 ms` vs `178.0 ms`) while using **8.4× less peak RSS** (`1.94 MiB` vs `16.34 MiB`).
  - **Adversarial Extensions (`1.02×` Go `crypto/x509`)**: Hybrid O(1) duplicate-OID hashing over raw DER slices and single-buffer OID formatting eliminate the O(N²) cliff (`many_ext` improved `16.6×`, from `0.08×` to `1.02×` Go; 64k-extension cert runs in `0.01 s` vs Go's `0.02 s`).
  - **Low Memory Footprint Across All Workloads**: Peak RSS stays at `1.94–3.14 MiB` across all benign and adversarial workloads — matching Rust (`1.94–3.95 MiB`) and using **5×–8.5× less memory** than Go (`15.36–18.91 MiB`).
  - **PEM + X.509 Pipeline**: Reaching `0.89×` Go `crypto/x509` (`161.8 MB/s`) and `0.87×` Rust `x509-parser` while strictly enforcing DER canonicality, inner/outer algorithm matching, duplicate-extension rejection, and full extension decoding.
- **Remaining Gaps**:
  - **Pure DER X.509 Parse (`0.85×` Go, `0.44×` Rust `x509-parser`)**: `Bytes::slice` copies into owned buffers for returned fields (`tbs_bytes`, `raw`, keys, signatures, DN/SAN strings), and `x509-parser` borrows `&[u8]` slices directly and lazily parses extensions without DER canonicality or duplicate-extension checks.
  - **Generic DER vs Rust `der` (`0.34×` Rust)**: Rust `der` reuses pre-allocated `Vec<u8>` buffers and pre-parsed `ObjectIdentifier` constants across iterations, whereas `DerWriter` in Workload 3 allocates per-record sequence buffers and re-encodes the OID string per iteration.

### sdp

参考实现：纯 Rust [`webrtc-rs/sdp`](https://github.com/webrtc-rs/sdp) `0.9.0`（`--release`）。`sh packages/sdp/bench/run_bench.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替）运行于真实 Chrome / Google Meet Offer（11,142 B：音频 + 双视频 + DataChannel、BUNDLE、VP8/VP9/H.264/AV1/Opus、12 条 `extmap`、Simulcast `rid`/`simulcast`、`ssrc-group:SIM`/`FID`、14 条 ICE candidate）与 Google Meet SFU Answer（9,370 B：`ice-lite`、10 条 bundled m-line），双方在规范结构摘要与完整 CRLF 序列化输出上均经 SHA-256 逐字节一致校验。详见 [`packages/sdp/README.md`](packages/sdp/README.md)。

| Workload | `pion` Median (Throughput) | `rust_sdp` Median (Throughput) | `pion` Peak RSS | `rust_sdp` Peak RSS | `pion` vs `rust_sdp` |
| --- | ---: | ---: | ---: | ---: | ---: |
| SDP Parse: Google Meet Offer (`11,142 B × 2000`) | **54.080 ms (412.06 MB/s)** | 105.431 ms (211.36 MB/s) | **2.08 MiB** | 2.53 MiB | **1.95x** |
| SDP Roundtrip: Google Meet Offer (`11,142 B × 2000`) | **87.608 ms (254.36 MB/s)** | 127.865 ms (174.28 MB/s) | **2.30 MiB** | 2.67 MiB | **1.46x** |
| SDP Roundtrip: Google Meet SFU Answer (`9,370 B × 2000`) | **85.317 ms (219.65 MB/s)** | 141.306 ms (132.62 MB/s) | **2.31 MiB** | 2.55 MiB | **1.66x** |

红队：10 / 10 单测，`audit` 31 / 31 全绿（1 P0 + 4 P1 + 18 P2 全部修复：P0-1 放大炸弹 RSS 从 4.95 GB 降至 3.72 MiB、Wasm32 零 OOM、18k × 2 Native/Wasm32 fuzz 0 崩溃 / 0 分歧）。3 项真实 WebRTC SDP 负载全面领先 Rust `webrtc-rs/sdp 0.9.0`（**1.46×–1.95×**）且峰值 RSS 均更低（2.08–2.31 vs 2.53–2.67 MiB）。

### stun

参考实现：Rust [`webrtc-rs/stun`](https://github.com/webrtc-rs/stun) `v0.8.0`（`--release`，底层由 `ring` 汇编 SHA-1 加速）。`sh packages/stun/bench/run_bench.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替）运行于 100,000 个真实 WebRTC ICE STUN 三路混合包（Binding Request + Binding Success Response IPv4 / IPv6，均带 `MESSAGE-INTEGRITY` 与 `FINGERPRINT`），全部编码线格式与校验和摘要经 SHA-256 逐字节一致校验。详见 [`packages/stun/README.md`](packages/stun/README.md)。

| Workload | `pion` Median (`ns/op`) | `rust_webrtc_stun` Median (`ns/op`) | `pion` Peak RSS | `rust_webrtc_stun` Peak RSS | `pion` vs `rust_webrtc_stun` | Stdout SHA-256 (Identical) |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Encode + Sign (`MI` + `FP`, 100k pkts) | 331.526 ms (`3315.26 ns/op`) | **198.978 ms (`1989.78 ns/op`)** | **1.86 MiB** | 2.08 MiB | 0.60x | `eb1d673bb93fca8f...` |
| Decode + Verify `FP` + Verify `MI` (100k pkts) | 368.555 ms (`3685.55 ns/op`) | **142.332 ms (`1423.31 ns/op`)** | **1.89 MiB** | 2.11 MiB | 0.39x | `2739a0786b801d32...` |

红队：12 / 12 单测（复用 `crypto` 69 / 69），`audit unit` **30 / 30** 全绿（5 P1 + 12 P2 全部修复：DoS 36.1 s → 0.01 s、fuzz 60k × 4 0 崩 0 diff、compare 30,126 条 0 安全差异）。领先项：两项峰值 RSS 均低于 Rust（1.86 / 1.89 vs 2.08 / 2.11 MiB）。落后项：编码签名 0.60×、解码验签 0.39×，根因是本包使用 Native/Wasm32 共用的纯标量 Pion `crypto::Sha1` + 查表 CRC-32，而 `webrtc-rs/stun` 底层调用 `ring` ARM64 汇编 SHA-1。

### rtp

参考实现：Rust [`webrtc-rs`](https://github.com/webrtc-rs/webrtc)（`rtp 0.12.0`、`rtcp 0.12.0`、`webrtc-srtp 0.14.0`，`--release`）。`sh packages/rtp/bench/run_bench.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替）运行，全部 4 项负载经 stdout SHA-256 逐字节一致校验（证明线格式与密文/认证标签精确互通）。详见 [`packages/rtp/README.md`](packages/rtp/README.md)。

| Workload | Pion Median (ms) | Rust `webrtc-rs` Median (ms) | Pion Rate / Throughput | Pion Peak RSS | Rust Peak RSS | Speedup vs Rust | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| RTP Parse + Marshal (1,200 B + 3 RFC 5285 1-byte exts × 50,000) | 82.330 | **32.447** | 1,646.61 ns/op | **1.80 MiB** | 2.08 MiB | 0.39x | `1490e46b1e6d14d1…` (exact) |
| RTCP Compound Parse + Marshal (SR + PLI + NACK × 50,000) | 72.339 | **62.501** | 1,446.79 ns/op | **1.84 MiB** | 2.20 MiB | 0.86x | `5727aeb0e46e2972…` (exact) |
| SRTP `AES128_CM_HMAC_SHA1_80` Protect + Unprotect (5,000 × 1,200 B = 12 MB) | 271.028 | **131.295** | 44.28 MB/s | **1.88 MiB** | 2.08 MiB | 0.48x | `3a80d94aed49bb1f…` (exact) |
| SRTP `AEAD_AES_128_GCM` Protect + Unprotect (5,000 × 1,200 B = 12 MB) | 247.303 | **120.209** | 48.52 MB/s | **1.86 MiB** | 2.11 MiB | 0.49x | `9709ef15a59a9dfc…` (exact) |

红队与诚实说明：10 / 10 单测（复用 `crypto` 69 / 69），`audit/` 零改动且 `run_audit.sh all` 全绿（**22 / 22** unit = 14 / 14 control + 8 / 8 redteam、Rust `webrtc-rs` 双向 **282 / 282 + 492 / 492** 互通、12k fuzz 0 崩 / 0 trap / 0 diff、10 万伪造 SSRC DoS 从 10.0 s / 9.1 MiB 降至 **0.24 s / 1.9 MiB**）。领先项：全部 4 项峰值 RSS 均低于 Rust（1.80–1.88 vs 2.08–2.20 MiB），RTCP 复合包达 Rust 的 0.86×。落后项：RTP 1,200 B 为 0.39×（Rust 用零拷贝引用计数 `bytes::Bytes::slice()`，Pion 拷贝载荷至自有 `Bytes`）；SRTP CM-SHA1（44.28 MB/s，0.48×）与 GCM（48.52 MB/s，0.49×）由 Native/Wasm32 通用纯标量 Pion 代码在开启收发双向重放保护下跑出，对照 Rust 硬件 AES/PMULL/SHA1 指令（且未开重放窗），吞吐仍达 >350 Mbps。

### webm

参考实现：纯 Rust [`matroska-demuxer`](https://crates.io/crates/matroska-demuxer) `0.6.1`（`--release`）。`sh packages/webm/bench/run_bench.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替）运行于 4 组真实 `ffmpeg` 编码 WebM 语料（VP9 + Opus、Pure Opus、AV1 + Opus、YouTube 风格 MSE Init + 独立 Cluster Media Segment），每条轨道元数据与每一帧（`track_number`、`size`、`pts_ns`、`pts_ms`、`is_keyframe` 及逐帧载荷 FNV-1a 64-bit 哈希）均经全 stdout SHA-256 逐字节一致校验。详见 [`packages/webm/README.md`](packages/webm/README.md)。

| Workload | `pion` Median (Throughput) | `rust_matroska` Median (Throughput) | `pion` Peak RSS | `rust_matroska` Peak RSS | `pion` vs `rust_matroska` | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| VP9 + Opus 12s WebM (563 KB × 200) | **12.852 ms (8,761.93 MB/s)** | 21.545 ms (5,226.74 MB/s) | 3.39 MiB | **2.86 MiB** | **1.68x** | `63ce66873b5cadea...` |
| Pure Opus 60s Audio WebM (959 KB × 200) | **17.994 ms (10,653.33 MB/s)** | 31.679 ms (6,051.33 MB/s) | 4.25 MiB | **3.31 MiB** | **1.76x** | `265c035f8bbcce75...` |
| AV1 + Opus 10s WebM (360 KB × 200) | **13.200 ms (5,454.25 MB/s)** | 19.635 ms (3,666.69 MB/s) | 2.97 MiB | **2.59 MiB** | **1.49x** | `5b30808c7978885e...` |
| YouTube MSE Init + Clusters (562 KB × 200) | **13.249 ms (8,490.17 MB/s)** | 20.020 ms (5,618.56 MB/s) | 3.39 MiB | **3.30 MiB** | **1.51x** | `90ce627eec08617d...` |

红队：10 / 10 单测，`audit/` 零改动且 `audit unit` **19 / 19** 全绿（11 / 11 redteam + 8 / 8 control，1 P0 + 2 P1 + 11 P2 全部根治），12,000 例 Native / Wasm32 fuzz 0 崩溃 / 0 `wasm_trap` / 0 差异。领先项：凭借 `0xA3` `SimpleBlock` 快路径与零拷贝帧索引，4 项真实语料全面领先 Rust `matroska-demuxer 0.6.1`（**1.49×–1.76×**）。落后项：4 项峰值 RSS 略高于 Rust（2.97–4.25 vs 2.59–3.31 MiB）。

### csp

参考实现：基于 `servo/rust-url`（`url = 2.5.9`）与 `percent-encoding = 2.3.2` 的独立 Rust W3C CSP3 + WHATWG Fetch CORS 实现（`packages/csp/bench/rust`，`cargo build --release`）。`sh packages/csp/bench/run_bench.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=11`，严格交替）运行，双方全部决策字段（`allowed`、`violated_directive`、`effective_directive`、`matched_source`、`exposed_headers`、`format_origin`、`max_age`）逐字节 FNV-1a 64-bit 哈希并经 SHA-256 逐字节一致校验。详见 [`packages/csp/README.md`](packages/csp/README.md)。

| Workload | `pion` Median (`ns/op`) | `rust_csp` Median (`ns/op`) | `pion` Min / P95 (ms) | `rust_csp` Min / P95 (ms) | `pion` Peak RSS | `rust_csp` Peak RSS | `pion` vs `rust_csp` | Stdout SHA-256 (Identical) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Real-World CSP3 Parse + Eval (10k policies + 100k checks) | 96.534 ms (`965.34 ns/op`) | **65.204 ms (`652.04 ns/op`)** | 95.560 / 104.051 | 64.188 / 69.148 | 2.80 MiB | **2.31 MiB** | 0.68x | `0c6bda1f51bef097...` |
| WHATWG Fetch CORS Preflight + Response + Origin (200k ops) | 67.541 ms (`337.71 ns/op`) | **42.427 ms (`212.13 ns/op`)** | 66.518 / 84.032 | 41.177 / 47.698 | 2.73 MiB | **2.16 MiB** | 0.63x | `f78bb5cbd9976a46...` |

红队：18 / 18 单测（复用 `url` 50 / 50），`audit/` 零改动且 `run_audit.sh all` 全绿（**32 / 32** unit = 12 / 12 control + 20 / 20 redteam，全部 2 P0 + 6 P1 + 10 P2 根治），对 Node WHATWG `URL` + CSP3 §6.7.2 独立参考差分 **88,856 / 88,856 (100.0%)** 零 bypass / 零 over-block / 零 origin mismatch，30k × 4 fuzz 零崩零差异，DoS 探针全线性（20k 指令 4 ms、100k 源 26 ms）。两项吞吐如实落后 Rust `servo/rust-url` 基线（0.68× / 0.63×），峰值 RSS 接近（2.73–2.80 vs 2.16–2.31 MiB）。

### cel

参考实现：Go [`google/cel-go`](https://github.com/google/cel-go) `v0.24.1`。`sh packages/cel/bench/run_bench.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，全部轮次与实现 stdout SHA-256 逐字节一致）运行。详见 [`packages/cel/README.md`](packages/cel/README.md)。

| Workload | `pion` Median (`ns/op`) | `go_cel` Median (`ns/op`) | `pion` Min / P95 (ms) | `go_cel` Min / P95 (ms) | `pion` Peak RSS | `go_cel` Peak RSS | `pion` vs `go_cel` | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| W1 Compiled IAM / K8s Admission Batch Eval (1,000,000 ops) | 366.844 ms (`366.84`) | **144.705 ms (`144.70`)** | 345.430 / 466.154 | 131.740 / 150.039 | **2.95 MiB** | 17.66 MiB | 0.39x | `593c1a054b215439…` |
| W2 Macros + Regex `matches` + Timestamp Batch Eval (20,000 ops) | **32.911 ms (`1645.58`)** | 145.960 ms (`7297.99`) | 29.035 / 34.086 | 117.004 / 148.032 | **3.36 MiB** | 19.20 MiB | **4.43x** | `8e806c8d63c22d1a…` |
| W3 End-to-End Compile + Eval (2,000 ops) | **22.450 ms (`11224.79`)** | 152.088 ms (`76043.96`) | 16.331 / 24.091 | 145.405 / 188.257 | **3.34 MiB** | 17.69 MiB | **6.77x** | `c32a199ce3539235…` |

红队：14 / 14 单测（复用 `time` + `regex`），`audit/` 零改动且 `audit` **30 / 30** 全绿（24 / 24 redteam + 6 / 6 control，3 P0 + 11 P1 + 9 P2 全部根治）。领先项：手写单遍解析器写入扁平 `Array[ExprNode]` arena（无 ANTLR / protobuf `CheckedExpr` / 反射类型检查），宏走专用 `Comprehension` 节点、常量 `matches()` 预编译 RE2 兼容自动机。落后项：W1 稳态 1M 次已编译小规则求值仅 0.39×——Go 规划器把表达式编译为特化闭包树且默认零成本预算跟踪，Pion 为 AST 解释求值并对每次求值强制执行 `EvalLimits`（深度、成本、累计输出字节）。

### wasm

参考实现：Rust `wasmparser` / `wasm-encoder` / `wasmprinter` `0.221.3`（`--release --locked`）。`sh packages/wasm/bench/run_bench.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行于真实 395,839 B 编译器生成 `.wasm` 语料。详见 [`packages/wasm/README.md`](packages/wasm/README.md)。

| Workload | `pion` Median (Throughput) | Rust Median (Throughput) | `pion` Min / P95 (ms) | Rust Min / P95 (ms) | `pion` Peak RSS | Rust Peak RSS | `pion` vs Rust | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| W1 Full Binary Decode + Instruction Traversal (20 × 395,839 B) | 127.484 ms (62.10 MB/s) | **31.710 ms (249.66 MB/s)** (`rust_wasmparser`) | 127.245 / 127.900 | 30.928 / 32.015 | 10.36 MiB | **2.66 MiB** | 0.25x | `6b66e630579352fa…` |
| W2 Full WebAssembly Spec Validation (20 × 395,839 B) | 105.034 ms (75.37 MB/s) | **29.676 ms (266.77 MB/s)** (`rust_wasmparser`) | 104.840 / 106.352 | 29.273 / 29.852 | **3.06 MiB** | 3.77 MiB | 0.28x | `287af374249e4709…` |
| W3 Decode → Re-encode + WAT Disassembly (5 × 395,839 B) | **86.426 ms (22.90 MB/s)** | 107.445 ms (18.42 MB/s) (`rust_wasmtools`) | 85.767 / 88.055 | 106.149 / 107.714 | 41.30 MiB | **20.50 MiB** | **1.24x** | `8963bf896344fc38…` |

红队：14 / 14 单测，`audit/` 零改动且 `audit` **63 / 63** 全绿（27 / 27 redteam + 36 / 36 control，7 P0 + 12 P1 + 8 P2 全部根治）；20,335 模块对 Rust `wasmparser` 与 Node v24 V8 三方差分 0 `ACCEPTS_INVALID` / 0 `REJECTS_VALID`，5,565 / 5,565 WASM2 合法 fuzz 模块 WAT 语义等价。领先项：W3 往返 + WAT 1.24×（`write_indent` 50 层封顶、整数 / 十六进制直写 `StringBuilder`），W2 单遍流式校验峰值 RSS 3.06 MiB 低于 Rust。落后项：W1 解码 0.25×（`decode_module` 物化完整 `Module` / `Array[Instr]` AST，而 `wasmparser` 零拷贝流式 `Operator`），W2 校验 0.28×。

### ical

参考实现：Rust [`rrule`](https://github.com/fmeringdal/rust-rrule) `0.14.0` + [`icalendar`](https://github.com/hoodie/icalendar-rs) `0.16.17`（`--release --locked`）。`sh packages/ical/bench/run_bench.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。详见 [`packages/ical/README.md`](packages/ical/README.md)。

| Workload | `pion` Median (Throughput / Latency) | Rust Median (Throughput / Latency) | `pion` Min / P95 (ms) | Rust Min / P95 (ms) | `pion` Peak RSS | Rust Peak RSS | `pion` vs Rust | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| W1 4,000-VEVENT `.ics` Parse + Serialize Roundtrip (1.93 MB) | **47.27 ms (40.76 MB/s)** | 74.34 ms (25.92 MB/s) (`rust_icalendar`) | 45.59 / 49.21 | 70.98 / 78.51 | **15.73 MiB** | 51.06 MiB | **1.57x** | `e4e48bf0c572404c…` |
| W2 Complex `RRULE` Expansion (80 rules, 58,000 occs) | **14.72 ms (`253.85 ns/op`)** | 24.70 ms (`425.86 ns/op`) (`rust_rrule`) | 13.82 / 15.04 | 24.03 / 29.12 | **2.27 MiB** | 7.78 MiB | **1.68x** | `8a01a8a0a03b5cbc…` |
| W3 `RRuleSet` Window Query Batch (200 sets, 72,200 occs) | 26.04 ms (`130.21 µs/set`) | **24.18 ms (`120.90 µs/set`)** (`rust_rrule`) | 25.70 / 26.29 | 23.08 / 24.75 | **2.42 MiB** | 7.81 MiB | 0.93x | `f79e28a0fac65a54…` |

红队：23 / 23 单测（复用 `time` 262 / 262），`audit/` 零改动且 `audit` **38 / 38** 全绿（24 / 24 redteam + 14 / 14 control，2 P0 + 8 P1 + 9 P2 全部根治）；4,000 条规则三方差分（`python-dateutil` + Rust `rrule`）一致率 75.4% → 87.6%，剩余 54 处差异均为参考实现偏离 RFC，0 真实缺陷；DoS 断崖 `D1a` 4,107 MiB / 1.29 s → 2.8 MiB / 0.01 s、`VTIMEZONE` `SECONDLY` `offset_at` 15.4 s → 0.00 s。领先项：W1 单遍流式反折行 + 扁平 `Array[Property]`，W2 惰性 `(days × timeset)` 流式展开。落后项：W3 `RRuleSet` 窗口查询 0.93×（流式 `ZonedRuleStream` 与逐次时区解析开销），但 RSS 低 3.2×；W2 / W3 语料仅 UTC。

### ssh

参考实现：Go [`golang.org/x/crypto/ssh`](https://pkg.go.dev/golang.org/x/crypto/ssh) `v0.38.0`（`go1.27.3 darwin/arm64`）；Go 未导出的 `|1|` 哈希主机匹配、RFC 4253 分包与 `SSHSIG` 由 `bench/go/main.go` / `audit/diff/go/main.go` 中等价 Go 实现补齐。`sh packages/ssh/bench/run_bench.sh` 与 `sh packages/ssh/audit/run_audit.sh bench` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，6 项全部 stdout SHA-256 逐字节一致）运行。Go 峰值 RSS 含约 10–14 MiB 运行时基线。详见 [`packages/ssh/README.md`](packages/ssh/README.md)。

| Workload | `pion` Median (`ns/op`) | Go Median (`ns/op`) | `pion` Min / P95 (ms) | Go Min / P95 (ms) | `pion` Peak RSS | Go Peak RSS | `pion` vs Go | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| W1 20,000 × `authorized_keys` parse + SHA-256 fingerprint | 88.459 ms (`4422.96`) | **41.307 ms (`2065.36`)** | 72.433 / 89.921 | 39.917 / 43.428 | **2.16 MiB** | 16.22 MiB | 0.47x | `8a48c5cbe0f0ef40…` |
| W2 5,000 × `known_hosts` (`\|1\|` HMAC-SHA1) + 1,000 × Cert Ed25519 CA verify | 214.219 ms (`35703.14`) | **72.530 ms (`12088.38`)** | 203.608 / 223.219 | 69.580 / 96.976 | **2.27 MiB** | 17.11 MiB | 0.34x | `201b5c12cfa6c460…` |
| W3 1,000 × `SSHSIG` Ed25519 verify + 50,000 × RFC 4253 packet roundtrip | 148.606 ms (`2913.84`) | **54.266 ms (`1064.04`)** | 145.698 / 160.819 | 51.365 / 59.989 | **2.09 MiB** | 14.66 MiB | 0.37x | `b09bb6eb1cb7a2df…` |
| `SSHSIG` RSA-2048 (`rsa-sha2-256`, 200×) | 93.666 ms (`468332.50`) | **22.696 ms (`113480.62`)** | 92.260 / 103.798 | 19.759 / 24.033 | **2.33 MiB** | 10.33 MiB | 0.24x | `6d403f5828734861…` |
| `SSHSIG` ECDSA P-256 (`sha512`, 500×) | 977.063 ms (`1954126.83`) | **40.443 ms (`80885.25`)** | 841.482 / 1255.210 | 35.611 / 44.862 | **2.38 MiB** | 11.61 MiB | 0.04x | `b8ac5346e99ad98e…` |
| `SSHSIG` Ed25519 (`sha512`, 500×) | 77.757 ms (`155514.17`) | **36.629 ms (`73258.42`)** | 72.249 / 79.627 | 35.430 / 38.689 | **2.25 MiB** | 10.33 MiB | 0.47x | `b8ac5346e99ad98e…` |

红队：19 / 19 单测（复用 `base64` + `crypto`），`audit/` 零改动且 `audit` **36 / 37**（16 / 16 control 全绿；2 P0 + 8 P1 + 11 P2 中仅保留 `p1_sshsig_verify_has_no_trust_anchor`：按已批准方案 `sshsig_verify` 保持 `ssh-keygen -Y check-novalidate` 语义，信任锚校验由 `sshsig_verify_with_key` / `sshsig_verify_allowed` 提供）。落后项：全部 6 项吞吐落后——Go `crypto/*` 使用 ARMv8 加密扩展与域运算汇编，`packages/crypto` 为纯标量可移植 Pion（ECDSA P-256 仅 0.04×，约慢 20–25×）。领先项：峰值 RSS 2.1–2.4 MiB vs Go 10.3–17.1 MiB；`known_hosts` 通配 `("a*" × n) + "b"` 在 `n = 20,000` 仍 0.03–0.05 s，而 Go `knownhosts`（`n = 11` 58.5 s）与 OpenSSH `ssh-keygen -F`（`n = 11` 17.0 s）指数回溯。

### http_cache

参考实现：纯 Rust [`http-cache-semantics`](https://crates.io/crates/http-cache-semantics) `3.0.0`（`--release`），在计时循环外预构建 `http::Request` / `http::Response` 对象以保持严格对等口径。`sh packages/http_cache/bench/run_bench.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替）运行于 12 组真实 YouTube / Twitter(X) / Cloudflare CDN / GitHub API 场景（`3,912 B × 5,000 = 60,000` 次策略 + `Vary` + 条件重验证 + 304 合并评估），双方完整规范决策摘要经 SHA-256 逐字节一致校验（`381d374237a9503d7bf37d00fce5073ac74741213a17cefb98a1264cc44f229e`）。详见 [`packages/http_cache/README.md`](packages/http_cache/README.md)。

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `http-cache-semantics 3.0.0` prebuilt) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | **65.263** | 63.918 | 70.426 | **299.71** | **1,087.72** | **2.05 MiB** | **1.14x** |
| `rust_http_cache_semantics_prebuilt` (`3.0.0`, `--release`) | 74.413 | 71.017 | 78.214 | 262.86 | 1,240.22 | 2.50 MiB | 1.00x (baseline) |

红队：12 / 12 单测，`audit/` 零改动且 `audit unit` **30 / 30** 全绿（10 / 10 control + 20 / 20 redteam，全部 1 P0 + 6 P1 + 9 P2 根治：P0-1 `private="field"`/`no-cache="field"` 防跨用户 `Set-Cookie` 泄露、P1-2 禁 206 投毒、P1-3/4/5 304 严检、P1-6 Vary 哈希索引消 CPU DoS、P1-7 `max_total_bytes` 全额计入头字节）。领先项：严格对等预构建口径下快于 Rust `http-cache-semantics 3.0.0` **1.14×**，且峰值 RSS 更低（2.05 vs 2.50 MiB）。

### git

参考实现：Rust [`gix`](https://github.com/GitoxideLabs/gitoxide)（`gix-object 0.46` + `gix-pack 0.56` + `gix-index 0.37` + `gix-packetline 0.18`，`--release --locked`）。`sh packages/git/bench/run_bench.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行；W1 的 `gix-pack` 基线为公平单遍解码循环（每条目仅 inflate 一次）。详见 [`packages/git/README.md`](packages/git/README.md)。

| Workload | `pion` Median (Throughput) | `rust_gix` Median (Throughput) | `pion` Peak RSS | `rust_gix` Peak RSS | `pion` vs `rust_gix` | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| W1 Synthetic Packfile v2 Full Unpack + `OFS_DELTA` Resolve + SHA-1 (× 5, 159.9 KB) | 39.470 ms (4.05 MB/s) | **17.805 ms (8.98 MB/s)** | 4.36 MiB | **4.20 MiB** | 0.45x | `6375ce4b19dad182…` |
| W1 (real pack) `pion-packages` own `.git` Packfile v2 (6.1 MB × 1) | 221.075 ms (27.81 MB/s) | **110.195 ms (55.79 MB/s)** | 48.50 MiB | **23.70 MiB** | 0.50x | `fade04aed0186d6f…` |
| W2 Large Tree (200 × 150) + 2,000 Commit Parse & Re-encode (× 3, 5.35 MB) | 37.943 ms (141.13 MB/s) | **20.510 ms (261.09 MB/s)** | 5.66 MiB | **4.00 MiB** | 0.54x | `cf3f4606e657d786…` |
| W3 `.git/index` v2 + v4 (2,000 files each) + 10,000 `pkt-line` Decode (× 5, 4.71 MB) | 17.577 ms (268.08 MB/s) | **7.895 ms (596.83 MB/s)** | 5.25 MiB | **3.36 MiB** | 0.45x | `c3065f79872ee914…` |

红队：26 / 26 单测（复用 `flate` + `crypto` + `diff`），`audit/` 零改动且 `audit` **40 / 40** 全绿（31 / 31 redteam + 9 / 9 control）；`run_audit.sh --quick` 4 模 **2,038 / 2,038** 记录一致，0 diff / 0 crash / 0 trap。落后项：全部 4 项吞吐落后 `gix`（0.45–0.54×）——纯 Pion `zlib_inflate_at` + 标量 `crypto::Sha1` 对 `miniz_oxide` + `sha1_smol` + `memmap2`；W2 / W3 每条目分配独立 `String` / `Bytes`，而 `gix` 借用 `&[u8]` 零拷贝；`PackReader::open` 物化已解析对象，真实 6.1 MB 包峰值 RSS 48.50 vs 23.70 MiB。W2 经零分配 tree 比较器与已排序快路径从 70.4 ms 提速至 37.9 ms（1.86×）。

### jq

参考实现：Go [`github.com/itchyny/gojq`](https://github.com/itchyny/gojq) `v0.12.17`。`sh packages/jq/bench/run_bench.sh` 与 `sh packages/jq/audit/bench/run_blindspots.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。详见 [`packages/jq/README.md`](packages/jq/README.md)。

| Workload | `pion` Median (ms) | `gojq` Median (ms) | `pion` Peak RSS | `gojq` Peak RSS | `pion` vs `gojq` | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| W1 10k K8s / API events aggregation (`select` + `group_by` + `map` + `sort_by`, × 5) | 89.242 | **50.694** | **23.75 MiB** | 24.02 MiB | 0.57x | `a8fb7ca11b5f520f…` |
| W2 Deep nested tree extract + `\|=` path rewrite (× 10) | **18.116** | 29.080 | **5.41 MiB** | 13.22 MiB | **1.61x** | `0e0ecf194f9eb7e3…` |
| W3 End-to-end Compile + Eval (1,000 queries) | **34.467** | 42.824 | **4.47 MiB** | 14.03 MiB | **1.24x** | `0856973c670c20d5…` |
| B0 Startup floor (`.` on `null`) | **9.317** | 9.755 | **3.48 MiB** | 6.52 MiB | **1.05x** | `ba20c457b9f476ed…` |
| B1 Wide array `\|=` (`[range(20000)]`) | **13.549** | 19.845 | **5.91 MiB** | 12.38 MiB | **1.46x** | `67a670ba038aa058…` |
| B2 Wide array `=` (`[range(20000)]`) | **10.711** | 16.166 | **5.08 MiB** | 11.84 MiB | **1.51x** | `0eb4bfffcb8d8eae…` |
| B3 5k-key object `.[] \|= . + 1` | **14.376** | 16.383 | **9.41 MiB** | 11.98 MiB | **1.14x** | `2a558e4d2c486388…` |
| B4 `to_entries \| from_entries` on 20k keys | **23.102** | 26.431 | **18.45 MiB** | 19.45 MiB | **1.14x** | `0eb4bfffcb8d8eae…` |
| B5 `"a" * 50000 \| indices("aa")` | **11.682** | 14.565 | **6.41 MiB** | 14.73 MiB | **1.25x** | `2c10fe1df8ae7a2d…` |
| B6 2k `has` lookups on a 20k-key object | 18.959 | **17.511** | **10.92 MiB** | 12.11 MiB | 0.92x | `a0fd9d82673f5825…` |
| B7 `"ab" * 50000 \| gsub("a"; "x")` | **11.063** | 5171.332 | **10.22 MiB** | 2623.95 MiB | **467.46x** | `2898ea78580f87fc…` |

红队：39 / 39 单测（依赖树合计 377 / 377，复用 `json5` + `regex` + `base64` + `url`），`audit/` 零改动且 `audit` **35 / 35** 全绿（28 / 28 redteam + 7 / 7 control）；9,021 例 4 模差分 0 模式不一致 / 0 崩溃 / 0 trap，三方精确一致 8,551 / 9,021（94.8%）；69 例 DoS / 深嵌套探针在 Native + 4 模 Wasm32 下 0 SIGABRT / 0 OOM / 0 超时。领先项：W2 / W3 与 B0–B5 / B7（单遍结构化 `\|=` / `=`、惰性 `ObjHashIndex`、KMP `indices`、跨调用正则缓存），峰值 RSS 低 1.0–3.1×。落后项：W1 0.57×（5 MB 输入跨 `json5::Json5Value` ↔ `JqVal` 桥接与 `group_by` / `sort_by` 中间物化）、B6 0.92×。

### qrcode

参考实现：Rust [`qrcode`](https://crates.io/crates/qrcode) `0.14.1`（基线），另列 Nayuki [`qrcodegen`](https://github.com/nayuki/QR-Code-generator) `1.8.0` 与 [`fast_qr`](https://crates.io/crates/fast_qr) `0.14.0`（均 `--release --locked`）。`sh packages/qrcode/audit/run_audit.sh bench` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，全部实现与轮次 stdout SHA-256 逐字节一致）运行。详见 [`packages/qrcode/README.md`](packages/qrcode/README.md)。

| Workload | `pion` Median (ms) | `qrcode 0.14.1` | `qrcodegen 1.8.0` | `fast_qr 0.14.0` | `pion` Peak RSS | Ref Peak RSS (`qrcode` / `qrcodegen` / `fast_qr`) | `pion` vs `qrcode 0.14.1` | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| W1 Batch URL / 2FA OTP URI Encode (10,000 ops, v2–v6 M/Q) | 1115.197 | 5382.242 | 1171.980 | **511.794** | **1.89 MiB** | 2.48 / 2.42 / 2.17 MiB | **4.83x** | `a58f60af0df01ae7…`（四实现 `audit/oracle`；双实现 `bench/` W1 `ef441039…`、W3 `ff4e4671…`） |
| W2 Large Multi-Version Binary Encode (300 ops, v10–v40 + RS) | 772.248 | 2987.593 | 712.249 | **216.022** | **2.16 MiB** | 3.14 / 2.94 / 2.30 MiB | **3.87x** | `0de3a5ce50d6c474…` |
| Real-World Mixed-Case Payloads (10,000 ops, DP optimizer) | **1098.078** | 8118.516 | — | — | **1.92 MiB** | 2.64 MiB / — / — | **7.39x** | `bebae88dbe9b0261…` |

红队：17 / 17 单测，`audit/` 零改动且 `audit` **21 / 21** 全绿（13 / 13 redteam + 8 / 8 control）；对 `qrcodegen 1.8.0` 1,280 / 1,280 固定掩码符号逐像素一致、160 / 160 自动掩码精确一致，12,000 串 DP 分段 0 次次优，与 `rqrr 0.11.0` 交叉解码 2,689 / 2,689 + 771 / 771（镜像），4,688 次注错 0 静默误纠。领先项：全部负载快于 `qrcode 0.14.1`（3.87–7.39×），W1 略快于 `qrcodegen`（1.05×），四实现中峰值 RSS 最低；混合负载因精确 O(n) DP 分段选出更小版本（`qrcodegen` / `fast_qr` 无混合模式优化，无法通过 SHA-256 门禁故未列）。落后项：`fast_qr` 在 W1 / W2 分别快 2.18× / 3.57×，`qrcodegen` 在 W2 快约 8%。

### mqtt

参考实现：Rust [`rumqttc`](https://crates.io/crates/rumqttc) `0.25.1`（`--release --locked`，基线）与 Go [`github.com/eclipse/paho.golang/packets`](https://github.com/eclipse/paho.golang) `v0.23.0`（`go.sum` 锁定）。`sh packages/mqtt/bench/run_bench.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。`rumqttc` 不支持 MQTT 5.0 `AUTH`（`InvalidPacketType(15)`），故 W2 只测 14 种共有报文，W2b 全 15 种报文对照 Go；W3 `TopicTrie` 为同一层级索引 Trie 算法的跨语言对照（`rumqttc` 无路由器、`paho` `StandardRouter` 为线性扫描）。详见 [`packages/mqtt/README.md`](packages/mqtt/README.md)。

| Workload | `pion` Median (`ns/op`) | Reference Median (`ns/op`) | `pion` Min / P95 (ms) | `pion` Peak RSS | Ref Peak RSS | `pion` vs Ref | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| W1 200,000 × MQTT 5.0 `PUBLISH` Encode + Stream Decode | 334.738 ms (`1673.69`) | **99.373 ms (`496.86`)** (`rust_rumqttc`)；Go 731.590 ms (`3657.95`) | 329.079 / 346.464 | **2.09 MiB** | 5.67 MiB（Go 18.39 MiB） | 0.30x（vs Go **2.19x**） | `938ea9a3ff656f3c…` |
| W2 500,000 × Mixed 3.1.1 + 5.0 Stream Decode (137 B chunks) | 101.253 ms (`202.51`) | **44.190 ms (`88.38`)** (`rust_rumqttc`) | 96.911 / 125.585 | **2.16 MiB** | 5.72 MiB | 0.44x | `43806b6c796e18ec…` |
| W2b 500,000 × MQTT 5.0 All 15 Packets (incl. `AUTH`) Stream Decode | **140.293 ms (`280.59`)** | 402.232 ms (`804.46`) (`go_paho`) | 133.876 / 150.471 | **2.14 MiB** | 18.28 MiB | **2.87x** | `24dd6070f01db72f…` |
| W3 `TopicTrie` 10,000 Wildcard Subs × 100,000 Publishes | 238.851 ms (`2388.52`) | **151.683 ms (`1516.83`)** (`rust_trie_foldhash`)；SipHash 294.326 ms、FNV 169.125 ms、Go 355.923 ms | 224.283 / 265.019 | **3.83 MiB** | 6.39 MiB（Go 13.12 MiB） | 0.64x（vs SipHash **1.23x**、vs Go **1.49x**） | `b7e0b1e8964642f6…` |

红队：22 / 22 单测，`audit/` 零改动且 `audit` **37 / 37** 全绿（25 / 25 redteam + 12 / 12 control）。领先项：编解码对 Go `paho` 快 2.19×（W1）/ 2.87×（W2b），内存低约 8.5–9×；`TopicTrie` 快于 Go（1.49×）与 Rust `std` SipHash（1.23×）且 RSS 最低。落后项：Rust `rumqttc` 原始编解码快 2.3–3.4×（W1 0.30×、W2 0.44×，零拷贝 `bytes::Bytes` 切片且校验更少，Pion 强制完整 OASIS UTF-8 / 属性 / 原因码合规）；W3 对同为种子化快速哈希的 Rust `foldhash` 慢 1.57×（0.64×）。

### bson

参考实现：Rust [`bson`](https://crates.io/crates/bson) `2.15.0`（`--release --locked`）。`sh packages/bson/bench/run_bench.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。公平口径：W1 的 `rust_ref` 严格按引用遍历 `Document`（无 `doc.clone()`），并另列零拷贝 `RawDocument` 遍历 `rust_raw`（快于 Pion 1.92×，如实列出）；W3 中 Rust 公开 ExtJSON API 经 `serde_json::Value` 且消费输入（每文档需 `doc.clone()`）。详见 [`packages/bson/README.md`](packages/bson/README.md)。

#### W1: BSON Decode (50,000 composite documents, 12,012,500 B)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_ref`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`, owned `BsonDocument` + walk) | 59.839 | 57.878 | 67.074 | 200.75 | 1196.77 | 2.83 MiB | **1.67x** |
| `rust_ref` (`bson 2.15.0`, `Document::from_reader` + walk by ref) | 99.650 | 97.915 | 110.859 | 120.55 | 1993.01 | 2.84 MiB | 1.00x (baseline) |
| `rust_raw` (`bson 2.15.0`, `RawDocument::from_bytes` zero-copy walk) | **31.190** | 30.627 | 32.818 | 385.14 | 623.80 | 2.50 MiB | **3.19x** (`rust_raw` is **1.92x** faster than Pion) |

- Verified stdout SHA-256: `5aaa2cd2a70a7fd150fdbe14ebfe1ef0c98b0a5c6cc23cd95f70595cae079a09`
- Note: `rust_ref` walks `Document` strictly by reference (no `doc.clone()`). For read-only traversal without materializing an owned DOM, Rust's zero-copy `RawDocument` API (`rust_raw`) validates every element on the fly and is ~1.92x faster than Pion's owned-tree decode.

#### W2: BSON Encode (50,000 composite documents, 12,012,500 B)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_bson`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | 44.761 | 44.409 | 45.382 | 268.37 | 895.23 | 4.45 MiB | **1.05x** |
| `rust_bson` (`2.15.0`, `--release --locked`) | 47.095 | 46.181 | 48.115 | 255.07 | 941.90 | 5.72 MiB | 1.00x (baseline) |

- Verified stdout SHA-256: `fb667c1dcaef24a105c6ba39aa0d733c65a33f7b9327d7877b94392fb11a7d7f`

#### W3: BSON ↔ Extended JSON v2 Canonical + Relaxed Roundtrip (20,000 docs, 4,805,000 B)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_bson`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | 175.664 | 173.493 | 189.812 | 27.35 | 8783.22 | 4.73 MiB | **1.40x** |
| `rust_bson` (`2.15.0`, `--release --locked`) | 245.903 | 243.389 | 253.249 | 19.54 | 12295.13 | 5.98 MiB | 1.00x (baseline) |

- Verified stdout SHA-256: `f3a6ca6a2132d4c515a511e57fcfc1b1c126809eb78834e70af071b89ad9d016`
- Note: Rust `bson`'s public Extended JSON API goes through `serde_json::Value` (with `preserve_order` / `IndexMap`), and `into_*_extjson(self)` consumes its input (requiring a `doc.clone()` per document). Pion serializes/parses directly between `BsonDocument` and JSON text.

### resp

参考实现：Rust [`redis-protocol`](https://crates.io/crates/redis-protocol) `6.0.0`（`--release`，锁定 `Cargo.lock`）。`sh packages/resp/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。公平口径：Rust 侧使用惯用零拷贝 `decode_bytes_mut`（红队修复中去掉了 `buf.clone().freeze()`），W3 双方都解析 `MOVED` 与 `ASK` 并物化 owned `host`。详见 [`packages/resp/README.md`](packages/resp/README.md)。

#### W1: 200,000 Mixed RESP3 Responses Streaming Decode (137B chunks)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Input: `5,731,182 B` | Ops: `200,000` | Stdout SHA-256: `b0e9a02f61dab29da01cc60bc45f762ab23d89118c6a46803b38bedc5d2989f9`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_redis_protocol`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | 53.333 | 53.107 | 53.644 | 107.46 | 266.66 | 12.67 MiB | 0.94x |
| `rust_redis_protocol` (`6.0.0`, `--release`) | **50.346** | **49.699** | **50.428** | **113.84** | **251.73** | **7.55 MiB** | **1.00x (baseline)** |

#### W2: 500,000 Pipelined Commands Encode + Decode Roundtrip (`SET`/`GET`/`HSET`/`MGET`)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Ops: `500,000` | Stdout SHA-256: `378354e9ec08373e4055fba30435922b5f828c3dee13f0d6a793834c941816c0`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_redis_protocol`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | 278.751 | 278.111 | 298.877 | 557.50 | 2.80 MiB | 0.75x |
| `rust_redis_protocol` (`6.0.0`, `--release`) | **207.744** | **206.120** | **214.488** | **415.49** | **2.31 MiB** | **1.00x (baseline)** |

#### W3: 2,000,000 Cluster `key_slot` (`{hash_tag}`) + 500,000 `MOVED`/`ASK` Redirect Parse

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Ops: `2,000,000` | Stdout SHA-256: `dcb9d7eab4bae30aa394d5aab73c52a40d4545a0665a28eca07c9b94285ebf00`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_redis_protocol`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | 48.325 | 47.142 | 48.850 | 24.16 | **1.73 MiB** | 0.67x |
| `rust_redis_protocol` (`6.0.0`, `--release`) | **32.137** | **31.968** | **32.798** | **16.07** | 1.94 MiB | **1.00x (baseline)** |

> **Honest Performance Analysis**:
> - **W1 (0.94x vs Rust `redis-protocol` zero-copy `decode_bytes_mut`)**: After fixing the Rust harness to use idiomatic zero-copy `decode_bytes_mut` (eliminating `buf.clone().freeze()`) and upgrading Pion's `StreamDecoder` to an O(n) incremental state machine, Pion reaches near parity with Rust (`53.3 ms` vs `50.3 ms`, `107.5 MB/s` vs `113.8 MB/s`).
> - **W2 (0.75x)**: `redis-protocol` uses zero-copy `bytes::Bytes` reference-counted sub-slicing during batch decode, whereas Pion allocates owned `Bytes` slices per `BulkString`.
> - **W3 (0.67x, improved from 0.31x)**: Both sides now parse `MOVED` and `ASK` and materialize an owned `host` string; Pion's single-pass `key_slot` and zero-`to_bytes()` `parse_cluster_redirect` cut median runtime from `109.9 ms` to `48.3 ms` (`2.27x` faster), with the remaining gap due to bounds-checked CRC16 table lookups vs Rust's `crc16` crate.

### hcl

参考实现：Go [`github.com/hashicorp/hcl/v2`](https://github.com/hashicorp/hcl) `v2.23.0`（`hclsyntax` / `hclwrite` / `cty`）。`sh packages/hcl/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行；W3 `format_hcl` 输出与 `hclwrite.Format` 逐字节一致。详见 [`packages/hcl/README.md`](packages/hcl/README.md)。

#### W1: Large Terraform Infra Config (`1,111` top-level / `2,111` total blocks) Parse + AST Walk (`15x`)

10 `variable` blocks, 1 `locals` block, 1,000 `resource "aws_instance"` blocks (each with tags, `<<-EOF` heredoc with template interpolation, and nested `root_block_device` block), and 100 `module` blocks.
SHA-256: `e436af329e7f4df18a33834d963893262b40bfbdefe75b17231a2a508bb06e5f`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_hcl`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 590.412 | 556.260 | 636.540 | 39360769.47 | 24.05 MiB | 0.71x |
| `go_hcl` | 420.075 | 402.781 | 431.032 | 28004966.67 | 59.62 MiB | 1.00x (baseline) |

#### W2: Batch Parse + `EvalContext` Full Expressions / `for` / Templates / Built-ins (`1,000x`)

End-to-end parse + `EvalContext` evaluation of templates (`${...}`, `%{for}`, `%{if}`, `~`), `for` tuple & object (`...` grouping) comprehensions, full splat `[*]`, ternary with type unification, arbitrary-precision `BigDec` arithmetic (with exact small-integer fast path), and built-ins (`lower`, `upper`, `join`, `concat`, `merge`, `length`, `min`, `max`), serialized via streaming budgeted canonical JSON.
SHA-256: `93ab6ab3ed8ffd56375ac5bbd2ac59a08af2db8f8e0bfbda4ae50e6034cc2b8b`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_hcl`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 42.036 | 41.320 | 42.280 | 42036.46 | 3.00 MiB | **3.08x** |
| `go_hcl` | 129.594 | 126.871 | 131.298 | 129593.58 | 15.12 MiB | 1.00x (baseline) |

#### W3: Batch Canonical Formatting `format_hcl` vs `hclwrite.Format` (`3,000x`)

Realistic Terraform configuration featuring multi-line `tags = { ... }` attribute blocks (breaking `=` alignment groups), multi-line lists, aligned trailing `#`/`//` comments, nested `versioning`/`lifecycle` blocks, `locals` with `for` comprehension, blank lines, and heredoc preservation — verified byte-for-byte identical to `hclwrite.Format`.
SHA-256: `7a4ec307b3a987955ac58fb6a748b43c0242950e35c5a4b48480c14a7de98224`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_hcl`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 123.722 | 122.713 | 126.061 | 41240.79 | 2.56 MiB | **1.37x** |
| `go_hcl` | 169.535 | 165.330 | 172.597 | 56511.75 | 18.41 MiB | 1.00x (baseline) |

#### Objective Performance & Tradeoff Notes

- **Expression & Template Evaluation (W2, 3.08x faster, 5.0x lower RSS)**: `packages/hcl` evaluates a flat `Array[ExprNode]` arena directly over `HclValue`, combining an exact small-integer fast path with pure-Pion arbitrary-precision `BigDec` arithmetic and a streaming `max_output_bytes`-budgeted JSON encoder, avoiding `go-cty`'s reflection/type-descriptor boxing while preserving `go-cty` precision and safety budgets.
- **Canonical Formatting (W3, 1.37x faster, 7.2x lower RSS)**: Even with a full syntax validation pass (`parse_file_impl`) and full multi-line value group breaking + trailing comment alignment, `format_hcl` outperforms `hclwrite.Format` on realistic Terraform configurations with 7.2x lower peak RSS.
- **Large Config Parsing (W1, 0.71x speed, 2.5x lower RSS)**: After upgrading `ExprNode::LitNumber` to carry full `HclValue` (supporting exact `BigDec` literals) and adding full bracket-newline tracking, single-pass parsing on 2,111-block files is currently ~0.71x of Go's `hclsyntax.ParseConfig` while maintaining 2.5x lower peak RSS (24.05 MiB vs 59.62 MiB).
- **Safety & Cross-Runtime Guarantees**: All recursion paths clamp `max_depth` to a stack-safe ceiling (`160`) to prevent native stack overflow (`SIGSEGV`) and Wasm32 `RangeError`; all number-to-integer conversions are range-checked to avoid Wasm32 `f64→i32/i64` traps; `max_output_bytes` bounds templates, `join`, `format`, `jsonencode`, and `eval_body_to_json` incrementally.

### email

参考实现：Rust [`mail-parser`](https://crates.io/crates/mail-parser) `0.9.4`（`--release --locked`）、Go 标准库 `net/mail` 与 [`github.com/emersion/go-msgauth`](https://github.com/emersion/go-msgauth) `v0.7.0`（`-mod=readonly`）。`sh packages/email/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。详见 [`packages/email/README.md`](packages/email/README.md)。

#### W1: 5,000 Multi-Part MIME Emails Parse & Body/Attachment Hash

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Input: `6,345,580 B` | Ops: `5,000` | SHA-256: `38ce7a358e162dc3d24eac354cec116c69bb18e9285ee0bf01e87773ce8a59d4`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_mail_parser) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 48.458 | 48.087 | 50.830 | 130.95 | 9691.67 | 3.23 MiB | 0.52x |
| `rust_mail_parser` | 25.434 | 25.074 | 26.399 | 249.49 | 5086.76 | 2.69 MiB | 1.00x (baseline) |

#### W2: 100,000 Complex RFC 5322 Address-List & Date Parses

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Input: `12,492,000 B` | Ops: `100,000` | SHA-256: `1d0df93f8a814b8bdecfc1a80825b48d26caeb67c3cbcdbbc9c5835608d786a6`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs go_net_mail) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 120.999 | 120.128 | 122.108 | 103.24 | 1209.99 | 2.36 MiB | **1.73x** |
| `go_net_mail` | 208.833 | 204.809 | 214.841 | 59.82 | 2088.32 | 17.27 MiB | 1.00x (baseline) |

#### W3: 2,000 Email Build + DKIM `relaxed/relaxed` Ed25519 Sign/Verify Roundtrip

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Ops: `2,000` | SHA-256: `22223d47651049b1e97bcb09f9a11326f3dc32ac91d74fb790a04d19fabe7eda`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs go_msgauth) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 575.242 | 572.885 | 576.752 | 287620.96 | 2.38 MiB | 0.21x |
| `go_msgauth` | 121.817 | 119.132 | 123.446 | 60908.71 | 16.98 MiB | 1.00x (baseline) |

> **Honest Assessment**: `packages/email` outperforms Go `net/mail` by **1.73x** (with 7.3x lower RSS) on complex RFC 5322 address-list and date parsing (W2), reaches **130.95 MB/s** (0.52x of Rust `mail-parser`, up from 113 MB/s) on full multi-part MIME tree parsing + charset validation + QP/Base64 decoding (W1), and runs at **0.21x** of `github.com/emersion/go-msgauth v0.7.0` (with 7.1x lower RSS) on full end-to-end DKIM sign/re-parse/verify (W3) because `packages/crypto` uses portable pure-Pion Ed25519 curve arithmetic versus Go's assembly implementation.

### jsonpath

参考实现：Rust [`serde_json_path`](https://crates.io/crates/serde_json_path) `0.7.2` + [`json-patch`](https://crates.io/crates/json-patch) `4.2.0` + `serde_json 1.0.154`（`cargo build --locked --release`）。`sh packages/jsonpath/bench/run_bench.sh` 在 `Darwin arm64` 上经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。详见 [`packages/jsonpath/README.md`](packages/jsonpath/README.md)。

| Workload | Ops | Pion Median (ms) | Rust Median (ms) | Pion ns/op | Rust ns/op | Pion RSS | Rust RSS | Pion vs Rust | SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| W1 复杂 K8s / OpenAPI JSONPath 编译 + 查询 + 规范化路径 | 120 | **47.282** | 185.938 | **394,018** | 1,549,480 | **4.67 MiB** | 5.95 MiB | **3.93x** | `c7c81662...` |
| W2 预编译 JSONPath 热路径吞吐 | 50,000 | 67.176 | **37.848** | 1,344 | **757** | 2.62 MiB | 2.59 MiB | 0.56x | `7cca3a68...` |
| W3 RFC 6902 `diff_patch` + `apply_patch` + RFC 7396 `merge_patch` 往返 | 5,000 | 32.687 | **24.468** | 6,537 | **4,894** | 3.03 MiB | 2.92 MiB | 0.75x | `3a784896...` |

诚实说明：W1 的 3.93× 主要来自 `serde_json_path 0.7.2` 在 `match()` / `search()` 中对**每个被求值节点**调用 `Regex::new`，而 Pion 在解析期预编译常量 I-Regexp；按查询类别拆分（`audit/REPORT.md` §7），含正则的 2 条查询 Pion 快 3.25–6.08×，不含正则的 4 条仅快 1.12–1.16×。W2（0.56×）与 W3（0.75×）落后于 Rust 借用 `&Value` 零拷贝与原地 `&mut Value` 修改，峰值 RSS 相当（约 2.6–3.0 MiB）。

红队：14 / 14 单测（依赖树合计 37 / 37，复用 `regex`），`audit/` 零改动且 `run_audit.sh` **301 PASS / 0 FAIL**（官方 CTS 715 / 715、194 例 RFC 差分、4 模一致与 DoS 探针；2 P0 + 2 P1 + 5 P2 全部修复）。

### svg

参考实现：Rust [`svgtypes`](https://crates.io/crates/svgtypes) `0.15.3` / [`roxmltree`](https://crates.io/crates/roxmltree) `0.20.0` 同算法实现（基线）、地道 Rust `svgtypes::SimplifyingPathParser` + [`kurbo`](https://crates.io/crates/kurbo) `0.11.3`，以及非等价参考 Node `svgo@3.3.2`。`sh packages/svg/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。详见 [`packages/svg/README.md`](packages/svg/README.md)。

| Workload | Input | Pion Median (ms) | Reference Median (ms) | Pion vs Ref | Pion RSS | Ref RSS | SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| W1a 50,000 路径解析 + 三次归一 + 精确包围盒（同 F.6.5 / bbox 算法） | 3,836,510 B | 65.902 | **31.062** (`rust_svgtypes_same_algo`) | 0.47x | 9.08 MiB | **5.59 MiB** | `2afc7ef3...` |
| W1b 同输入，地道 `svgtypes` + `kurbo`（弧近似容差 0.1，校验和不同） | 3,836,510 B | 65.902 | **43.426** (`rust_svgtypes_kurbo`) | 0.66x | 9.08 MiB | **5.66 MiB** | `5b88be8c...`（Rust） |
| W2 2,000 嵌套图标 DOM + 变换 + 形状转路径 + 精确包围盒 | 1,742,279 B | 34.072 | **18.748** (`rust_roxmltree_svgtypes`) | 0.55x | 5.92 MiB | **3.95 MiB** | `f54a394e...` |
| W3a 2,000 图标优化（同 pass，输出 1,146,400 B / -33.4%） | 1,742,279 B | 30.566 | **19.720** (`rust_roxmltree_svgtypes`) | 0.65x | 5.95 MiB | **3.89 MiB** | `dd7a5dad...` |
| W3b 非等价参考：`svgo@3.3.2` 默认约 30 插件（输出 885,794 B / -48.5%，含约 100 ms Node 启动） | 1,742,279 B | — | 671.579 (`node_svgo`) | 不计倍率 | — | 176.77 MiB | `0775ffca...` |

诚实说明：同算法下 Pion 全部落后 Rust（0.47× / 0.55× / 0.65×），换来的是 0-ULP IEEE-754 数值解析、Payne-Hanek 确定性三角函数与完整 XML 1.0 合法性检查，四模输出逐字节一致；W3b 的 `svgo` 压缩率更高、做的 pass 更多，仅作非等价参考，不报加速比。

红队：29 / 29 单测，`audit/` 零改动且 `QUICK=1 run_audit.sh` 全绿（P0 3 / 3、P1 38 / 38、P2 69 / 69、control 25 / 25，4 模字节一致 9 / 9；6 P1 + 21 P2 全部修复）。

### promql

参考实现：Go [`github.com/prometheus/prometheus`](https://github.com/prometheus/prometheus) `v0.302.1`（`promql/parser`；W3 为 `promql.Engine` + `util/teststorage` 内存 TSDB head，`-mod=readonly`）。`sh packages/promql/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。详见 [`packages/promql/README.md`](packages/promql/README.md)。

| Workload | Ops | Pion Median (ms) | Go Median (ms) | Pion ns/op | Go ns/op | Pion RSS | Go RSS | Pion vs Go | SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| W1 10 条生产告警 / 看板查询解析 + 规范 `String()` | 20,000 | 210.604 | **151.355** | 10530.20 | **7567.73** | **2.98 MiB** | 30.53 MiB | 0.72x | `4468c0ee...` |
| W2 5 个复杂指标选择器解析 + 匹配器 / 区间 / `offset` 抽取 | 50,000 | 357.538 | **143.705** | 7150.76 | **2874.09** | **2.91 MiB** | 29.69 MiB | 0.40x | `b30b421d...` |
| W3 `histogram_quantile` 即时求值 + `sum by (job) (rate(...))` 区间求值（5,600 点） | 200 | **17.750** | 46.888 | **3169.73** | 8372.87 | **2.80 MiB** | 35.97 MiB | **2.64x** | `86a8fa5b...` |

诚实说明：W3 领先含 Go `teststorage` 建 TSDB head 的约 20 ms 开销（审计复测 Go 纯循环 37.02 ms、`promql.Engine` 38.92 ms，Pion 13.22 ms）。W1 / W2 是 Pion 弱项：解析期对每个 `=~` / `!~` 匹配器在 `packages/regex` 中完整构建 NFA + LazyDFA 以校验语法并拒绝空匹配选择器，而 Go 借 `FastRegexMatcher` 对常见字面量 / 选择分支跳过 DFA 构建。三项峰值 RSS 均低 10.2–12.8×。

红队：19 / 19 单测（依赖树合计 42 / 42，复用 `regex`），`audit/` 零改动且 `run_audit.sh` **53 / 53** 全绿（570 手写 + 2,000 变异解析例、188 求值例、31 个 DoS 场景；1 P0 + 9 P1 + 9 P2 全部修复）。

### lua

参考实现：Go [`github.com/yuin/gopher-lua`](https://github.com/yuin/gopher-lua) `v1.1.1`（`-mod=readonly`；语义基准为 PUC-Rio Lua 5.4.7）。`sh packages/lua/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。详见 [`packages/lua/README.md`](packages/lua/README.md)。

| Workload | Pion Median (ms) | `gopher_lua` Median (ms) | Pion vs Go | Pion RSS | Go RSS | SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| W1 Sieve(4000) × 20 + Fib(24) + 表排序 / 聚合 | 124.518 | **28.668** | 0.23x | **4.47 MiB** | 11.27 MiB | `d7cc60262c67e477...` |
| W2 闭包 + 元表 OOP + 模式 `gsub` / `gmatch` / `format`（1,500 轮） | 50.590 | **33.985** | 0.67x | **6.56 MiB** | 12.41 MiB | `1491a40b15329ee8...` |
| W3 公平：编译 + 新建沙箱 VM 执行 2,000 脚本（Go `SkipOpenLibs` + `base/table/string/math`） | **43.806** | 103.180 | **2.36x** | **2.78 MiB** | 19.97 MiB | `364896bb37ecca3a...` |
| W3 全库：同上，Go 默认 `lua.NewState()` 打开全部库 | **46.906** | 165.528 | **3.53x** | **2.78 MiB** | 13.56 MiB | `364896bb37ecca3a...` |

诚实说明：领先仅在新建沙箱启动（W3，公平配置 2.36×）；W1（0.23×）与 W2（0.67×）的持续紧循环明显落后，原因是逐指令扣燃料、`LuaValue` 带标签装箱与每次访问的栈 / 表句柄边界检查。红队审计指出 W3 早期 2.81× 对比了 Go 全库 `NewState`，公平化后（Go 只开同等库子集）审计时为 1.76×，修复后的公平配置为 2.36×。

红队：19 / 19 单测，`audit/` 零改动且 `run_audit.sh tests` **44 / 45**（11 P0 + 21 P1 + 10 P2 修复；唯一 FAIL `p1_7_int_float_compare_exact` 为不可变用例期望笔误：`2^53 + 1 > 2^53 + 0.0` 两侧均为浮点，PUC-Rio Lua 5.4.7 输出 `false`，测试却期望 `true`）。

### openapi

参考实现：Go [`github.com/getkin/kin-openapi`](https://github.com/getkin/kin-openapi) `v0.131.0`（`openapi3` 加载 + `doc.Validate`、`routers/gorillamux`、`openapi3filter`，`-mod=readonly`）。`sh packages/openapi/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。详见 [`packages/openapi/README.md`](packages/openapi/README.md)。

| Workload | Ops | Pion Median (ms) | Go Median (ms) | Pion ns/op | Go ns/op | Pion RSS | Go RSS | Pion vs Go | SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| W1 大型规范解析 + `$ref` + 静态校验（`parse` + `validate`） | 10 | **21.078** | 124.374 | **2,107,816.70** | 12,437,408.30 | **4.48 MiB** | 20.84 MiB | **6.05x** | `6aa62f1f...` |
| W1 同工作量：`parse` + `validate` + `Validator::from_doc` | 10 | **32.626** | 124.374 | **3,262,595.80** | 12,437,408.30 | **6.77 MiB** | 20.84 MiB | **3.81x** | `6aa62f1f...` |
| W2 RFC 6570 路由 + 路径参数抽取 | 50,000 | **19.483** | 222.918 | **389.66** | 4,458.37 | **4.50 MiB** | 23.38 MiB | **11.44x** | `4c4d7b67...` |
| W3 请求体 + 参数校验 | 10,000 | **20.895** | 66.362 | **2,089.48** | 6,636.23 | **6.95 MiB** | 21.47 MiB | **3.18x** | `070f4fda...` |

诚实说明：W1 中 Go `LoadFromData` 占其总时间约 96–99%（构建类型化 `Schema` 与解析引用），因此同工作量口径应以 Pion `parse` + `validate` + `Validator::from_doc`（解析并编译全部请求 / 响应视图 Schema）对比，为 **3.81×**。W2 中 Go `http.NewRequest` 构造约占 9%，其余为 `gorillamux` 逐路由正则匹配。W3 中 Go 的 `http.NewRequest` + `FindRoute` 约占 74%，`kin-openapi` 纯 `ValidateRequest` 约 1.7 µs / 请求（首错即停），Pion 完整循环（路由 + 收集全部错误的参数 / 请求体校验）约 2.1 µs / 请求，**纯校验大致持平**，3.18× 端到端领先主要来自前缀树路由与免 `net/http.Request` 开销。外部文件 / HTTP `$ref` 不在本包（零 `World`）范围内。

红队：24 / 24 单测（依赖树合计 700 / 700，复用 `json5` + `yaml` + `jsonschema`），`audit/` 零改动且红队单测 **31 / 31**、对 Go 差分 **109 / 110**（1 P0 + 12 P1 + 11 P2 修复；唯一剩余 `param.dangling_ref` 为不可变审计内部单测（要求加载成功且不再放行请求）与差分（要求加载期报错）互斥）。

### avro

参考实现：Go [`github.com/hamba/avro/v2`](https://github.com/hamba/avro) `v2.28.0`（`go.sum` 锁定），基线为与 Pion 动态 `AvroValue` 同口径的 `map[string]any`，另列编译期 typed `struct` 反射路径。50,000 条嵌套 `TelemetryEvent` 记录（Go 线格式输入 2,607,112 B）。`sh packages/avro/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行，同时双向校验 Rabin 指纹、50,000 条二进制数据与 5,000 条 OCF 的互操作。详见 [`packages/avro/README.md`](packages/avro/README.md)。

| Workload | Pion Median (ms) | `go_hamba_any` Median (ms) | `go_hamba_struct` Median (ms) | Pion RSS | `any` RSS | `struct` RSS | Pion vs `any` | SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| W1 二进制编码 + 解码往返 | 109.163 | 79.457 | **33.958** | 72.03 MiB | 98.31 MiB | **56.73 MiB** | 0.73x | `f2ea3fe5...` |
| W2 Schema 演进 Writer v1 → Reader v2 批量解码 | 47.841 | 34.008 | **15.572** | 51.42 MiB | 41.69 MiB | **17.83 MiB** | 0.71x | `75f2b111...` |
| W3 `.avro` OCF deflate 50 块写 + 读 | 146.121 | 99.143 | **54.536** | 69.03 MiB | 104.55 MiB | **54.16 MiB** | 0.68x | `5ba2533c...` |

诚实说明：对同口径动态 `go_hamba_any`，Pion 迭代式栈安全动态 `AvroValue` 路径为 **0.68–0.73×**，W1 / W3 峰值 RSS 低 27–34%（W2 高 23%）；Go 编译期 typed `struct` 路径免去逐记录动态 AST 分配，比 `go_hamba_any` 快 1.82–2.34×、比 Pion 快 2.68–3.21×，如实列出。

红队：23 / 23 单测（依赖树合计 43 / 43，复用 `flate`），`audit/` 零改动且红队单测 **25 / 25**、对 hamba 差分 **10,053 / 10,054**（2 P0 + 3 P1 + 9 P2 修复；唯一剩余 `res:alias-and-name-both-in-writer` 为 F-07 修复后 Pion 取原名字段、hamba 取别名字段的预期分歧，验收判定为 `hamba-deviation`）。

### kdl

参考实现：Rust [`kdl`](https://crates.io/crates/kdl) `6.7.1`（`--release --locked`）。`sh packages/kdl/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。详见 [`packages/kdl/README.md`](packages/kdl/README.md)。

| Workload | Input | Pion Median (ms) | Rust Median (ms) | Pion MB/s | Rust MB/s | Pion RSS | Rust RSS | Pion vs Rust | SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| W1 大型真实 KDL v2 配置解析（3 × 2,685,430 B） | 8,056,290 B | **204.810** | 3,999.952 | **39.34** | 2.01 | **25.97 MiB** | 104.06 MiB | **19.53x** | `4d534077...` |
| W2 解析 + 格式化 + 重解析往返（20 × 73,467 B） | 1,469,340 B | **109.090** | 1,503.416 | **13.47** | 0.98 | **2.97 MiB** | 8.17 MiB | **13.78x** | `758d0f0b...` |
| W3 小配置高频解析 + 抽取（AST 访问器） | 3,744,000 B | **137.341** | 1,562.345 | **27.26** | 2.40 | **2.05 MiB** | 2.52 MiB | **11.38x** | `5bc8e0df...` |
| W3 同上，Pion `kdl::query` 选择器引擎 | 3,744,000 B | **125.344** | 1,562.345 | **29.87** | 2.40 | **2.08 MiB** | 2.52 MiB | **12.46x** | `5bc8e0df...` |
| W4 10 万属性宽节点解析（3 × 1,277,790 B） | 3,833,370 B | **154.170** | 1,569.316 | **24.86** | 2.44 | **29.86 MiB** | 84.44 MiB | **10.18x** | `a2cbf936...` |

诚实说明：Rust `kdl 6.7.1` 是保留注释、空白、原始数字 / 字符串表示与 span 的**无损 CST** 解析器（`winnow` + `miette`，`i128` 整数），支持保格式编辑；`packages/kdl` 是单遍手写字节扫描的**语义 AST** 解析器（`Int64` + Eisel-Lemire `Double`），以放弃注释 / 空白保留与 `i128` 范围换取 10–19× 吞吐与 1.2–4.0× 更低 RSS。本榜对照的是参考 crate，而非同构的纯 AST Rust 解析器。W2 中 Rust 额外对 CST 做 `autoformat()` 的 trivia 改写；W3 Rust 查询 API 默认关闭，故基线与 `pion_accessor` 均走直接访问器。

红队：32 / 32 单测，`audit/` 零改动且 `run_audit.sh` **840 PASS / 8 FAIL**（1 P0 + 4 P1 + 10 P2 修复，0 P0 / 0 P1 剩余；8 项 FAIL 均为不可变审计既定约束：5 例超 `Int64` 整数、1 例 `n{a}`、2 例旧硬编码字节长），官方 v2 套件 317 / 319。

### xpath

参考实现：Rust [`sxd-xpath`](https://crates.io/crates/sxd-xpath) `0.4.2`（`--locked --release`，基线）与 C `libxml2`（`cc -O2`）。`sh packages/xpath/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，三方 stdout SHA-256 逐字节一致）运行；共享机器上交替运行约有 5–20% 波动。详见 [`packages/xpath/README.md`](packages/xpath/README.md)。

| Workload | Input | Pion Median (ms) | `rust_sxd` Median (ms) | `c_libxml2` Median (ms) | Pion RSS | Rust RSS | C RSS | vs Rust | vs C | SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| W1 3,000 书目录 10 条预编译复合查询（5 轮） | 866,214 B | 101.466 | 320.295 | **85.358** | 13.88 MiB | 23.47 MiB | **13.55 MiB** | **3.16x** | 0.84x | `960c749c...` |
| W2 高频编译 + 求值（20,000 次 × 10 条） | 50 items | 420.083 | 535.888 | **299.880** | 2.73 MiB | 3.09 MiB | **2.08 MiB** | **1.28x** | 0.71x | `921d3a93...` |
| W3 深层递归轴 + 聚合（5 轮） | 156,950 B | 49.204 | 69.649 | **42.092** | 5.20 MiB | 7.03 MiB | **4.55 MiB** | **1.42x** | 0.86x | `53319d51...` |
| W4 大节点集比较 `= != < >`（8,000 × 8,000，5 轮） | 182,939 B | **36.693** | 276.451 | 585.176 | 10.00 MiB | 23.98 MiB | **7.45 MiB** | **7.53x** | **15.95x** | `e3d9fad7...` |
| W5 > 1 MB 文档（50,000 元素 + 属性，默认 `XPathLimits`，5 轮） | 1,188,939 B | **168.141** | 404.483 | 195.615 | **27.69 MiB** | 46.75 MiB | 29.89 MiB | **2.41x** | **1.16x** | `943118fc...` |

诚实说明：5 项全部快于 Rust `sxd-xpath`（1.28–7.53×，RSS 低 1.13–2.40×）；对 C `libxml2` 在 W4（O(n + m) 哈希集 `=`、单遍 `!=` 与最值归约，**15.95×**）与 W5（扁平数组连续扫描与 `//@attr` 融合，**1.16×**）领先，但 W1（0.84×）、W2（0.71×，高频短查询编译）、W3（0.86×）落后 14–29%。

红队：29 / 29 单测（依赖树合计 67 / 67，复用 `xml`），`audit/` 零改动且 `run_audit.sh` **exit 0**（红队单测 38 / 38、数值模型 2,700 / 2,700、11,705 例语料 4 模逐字节一致、DoS 0 失败；0 P0 + 8 P1 + 4 P2 全部修复）。

### json

参考实现：Rust [`serde_json`](https://crates.io/crates/serde_json) `=1.0.145`（`--release`，默认特性，`bench/rust_bench/Cargo.lock` 锁定）与 Go `encoding/json`（go1.27.3 标准库）。`sh packages/json/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。详见 [`packages/json/README.md`](packages/json/README.md)。

| Workload | Input | Pion Median (ms) | Rust Median (ms) | Go Median (ms) | Pion MB/s | Pion RSS | Rust RSS | Go RSS | vs Rust | vs Go | SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| W1 大型真实 JSON 文档解析（5 × 3,444,775 B） | 17,223,875 B | 100.040 | **55.022** | 147.643 | 172.17 | 30.53 MiB | **29.23 MiB** | 44.64 MiB | 0.55x | **1.48x** | `f6dc207b...` |
| W2 解析 + 抽取 / 过滤 / 修改 + 序列化往返（8 × 2,074,535 B） | 16,596,280 B | 171.425 | **96.097** | 171.952 | 96.81 | **27.55 MiB** | 31.47 MiB | 44.12 MiB | 0.56x | 1.00x | `00d7bc92...` |
| W3 5 万键对象解析 + 25 万次随机查找 + RFC 8785 规范化（5 × 1,550,101 B） | 7,750,505 B | 156.211 | **100.787** | 379.590 | 49.62 | 22.33 MiB | **11.62 MiB** | 29.77 MiB | 0.65x | **2.43x** | `db0c9e14...` |

诚实说明：三项全部落后 Rust `serde_json`（0.55–0.65×），领先 / 持平 Go `encoding/json`。口径并不完全对等：`serde_json` 默认未开 `float_roundtrip`，浮点解析走更快但不保证 0-ULP 的路径，而本包严格 0-ULP；W3 中 Rust 用 `BTreeMap`（O(log n) 查找）并逐键分配字符串，略吃亏，W1 / W2 则略偏向 Rust。剩余差距来自解析前的整串 UTF-8 校验与带边界检查的字节扫描。W3 峰值 RSS 为 Rust 的 1.9 倍（索引与保序双结构）。对抗负载（`audit/run_audit.sh bench`）：4 万碰撞键 13.1 ms（Rust 的 0.83×，与普通键相差 1.1×），修复前为 2,624 ms。

红队：28 / 28 单测，`audit/` 零改动；2 P0 + 5 P1 + 5 P2 全部修复，发布验证中 `run_audit.sh tests jcs ptr utf8 hashdos` 全部通过；`wasm_smoke` 4 模式 stdout 均为 `446 B`、SHA-256 `0c0ec01bb7ab362dcf231b0bef02bde9c8cd31e640054d5940dd8586a475f8f9`。

### sse

参考实现：Rust [`eventsource-stream`](https://crates.io/crates/eventsource-stream) `=0.2.3`（`--release --locked`，直接以 `Waker::noop()` 轮询 `EventStream`，无异步运行时开销）。`sh packages/sse/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。详见 [`packages/sse/README.md`](packages/sse/README.md)。

| Workload | Input | Pion Median (ms) | Rust Median (ms) | Pion MB/s | Rust MB/s | Pion ns/event | Pion RSS | Rust RSS | Pion vs Rust | SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| W1 4 KiB 分块高吞吐流式解析（250,000 事件） | 21,433,090 B | **154.053** | 188.726 | **139.13** | 113.57 | **616.21** | 5.84 MiB | **4.59 MiB** | **1.23x** | `f012a70d...` |
| W2 64 B 网络碎片分块解析（100,000 事件） | 8,440,170 B | **79.450** | 80.230 | **106.23** | 105.20 | **794.50** | 3.52 MiB | **3.22 MiB** | 1.01x | `cb0286ac...` |
| W3 编码 + 解析往返（80,000 事件） | 6,752,136 B | 80.989 | **77.786** | 83.37 | **86.80** | 1,012.36 | 6.52 MiB | **6.19 MiB** | 0.96x | `b88c0954...` |

诚实说明：W1 领先来自直接在传入 `Bytes` 上按行扫描、不移动内部缓冲（`eventsource-stream` 每行 `split_off`）；W2 / W3 在噪声范围内持平。W3 两侧都按 4 KiB 分块喂入，避免触发 `eventsource-stream` 在单个大缓冲上的 O(N²) 缓冲移动。语料不含前导 BOM 与非法 UTF-8，因为上游 0.2.3 遇前导 BOM 会 panic、遇非法 UTF-8 会停滞。峰值 RSS 三项均比 Rust 高 0.30–1.25 MiB（每块返回的 `Array[SseEvent]` 与运行时堆规模）。

红队：20 / 20 单测，`audit/` 零改动；0 P0 + 3 P1 + 5 P2 全部修复，`audit/run_audit.sh` **exit 0**（3,087 条流 × 6 种分块对 §9.2.6 参考解析器 3,087 / 3,087 一致，Strict 模式 3,087 / 3,087，4 模逐字节一致）；`wasm_smoke` 4 模式 stdout 均为 `28 B`、SHA-256 `47b0f3077f6ce7915ba8c20cb42651dbc566b9fecf7571822b0148e3c6741312`。

### proxy

参考实现：Go `go1.27.3`。W1 为手写 Go 参考实现 `go_ref`（`net/url` + `net/netip` + 自写 `NO_PROXY` 匹配器，非 `x/net/http/httpproxy`，以保证双方 stdout 逐字节一致）；W2 为手写内联 Go 字节切片帧检查（非 `x/net/proxy`），Pion 侧走完整的类型化 `SocksGreeting` / `SocksRequest` / `SocksReply` 编解码；W3 为 Go `net/http.ReadRequest` / `ReadResponse` 加固定头重发（不做完整 CL/TE 走私校验），Pion 侧跑完整的 `parse_and_sanitize_forward_request` 防走私流水线。`sh packages/proxy/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。详见 [`packages/proxy/README.md`](packages/proxy/README.md)。

| Workload | Pion Median (ms) | Go Median (ms) | Pion ns/op | Pion RSS | Go RSS | Pion vs Go | SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| W1 代理 URL 解析 + 强制脱敏 + `NO_PROXY` 匹配（200,000 ops，vs `go_ref`） | **59.627** | 71.454 | 298.14 | **1.84 MiB** | 16.00 MiB | **1.20x** | `96dfab9a...` |
| W2 SOCKS5 完整双向握手（`UserPass` + `ATYP=0x03`，500,000 rounds，vs `go_ref`） | 213.555 | **39.357** | 427.11 | **1.83 MiB** | 9.20 MiB | 0.18x | `04347885...` |
| W3 HTTP `CONNECT` + 明文正向代理头清洗（100,000 requests，vs `go_net_http`） | **245.813** | 382.039 | 2,458.13 | **1.95 MiB** | 19.59 MiB | **1.55x** | `97be02e5...` |

诚实说明（v0.1.1 性能补丁，API 与输出不变）：W3 领先 Go `net/http` **1.55x**（v0.1.0 为 0.85x），且 Pion 额外做了 Go 基准循环省略的 CL/TE 走私校验，峰值 RSS 低 10.0 倍；W1 领先手写 Go 参考 **1.20x**（v0.1.0 为 0.54x，RSS 低 8.7 倍），来自零分配 `NoProxyMatcher::matches` 与按 `code_unit_at` 直接扫描 URL；W2 仍落后（0.18x，v0.1.0 为 0.15x，271 → 214 ms，RSS 低 5.0 倍），Go 侧是不分配的内联字节切片循环，ARM64 反汇编显示余下差距主要是每轮约 42 对装箱 `Result[DecodeStatus[T], ProxyError]` / 枚举 / 非 `val` 结构体的分配与释放及 `Bytes::slice().to_string()` 双重拷贝。

红队：16 / 16 单测，`audit/` 零改动；2 P0 + 2 P1 + 11 P2 全部修复，`audit/run_audit.sh` **exit 0**（15 / 15 finding 与 10 / 10 control 通过、6 万例流式 fuzz `violations=0`、4 模 SHA-256 一致）；`wasm_smoke` 4 模式 stdout 均为 `30 B`、SHA-256 `f55443b19671d3efef568b67f2a3a147789897004ce10771f1be4961e0f26245`。

### gif

参考实现：Go `image/gif`（go1.27.3 标准库）。`decode_first` = Go `gif.Decode`（仅首帧）+ 调色板 → RGBA8888 对 Pion `decode_first_frame`；`decode_all` = Go `gif.DecodeAll` + 同语义合成（裁剪 / 透明 / Disposal，每帧一份快照）对 Pion `decode`。两侧都把每帧 RGBA 写到 stdout。`sh packages/gif/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。

| Workload | Pion Median (ms) | Pion Min / P95 (ms) | Go Median (ms) | Pion MB/s | Pion RSS | Go RSS | Pion vs Go | SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 静态 512×512 × 60（红队修复后包基准） | — | — | — | — | — | — | **1.10x** | `86f9ea43...` |
| 动画 256×256 × 24 帧 × 30（红队修复后包基准） | — | — | — | — | — | — | **1.15x** | `17bfe25f...` |
| 静态 512×512 × 60（Wave 19 发布审计复测） | **84.769** | 82.208 / 89.078 | 90.543 | 742.18 | **4.23 MiB** | 11.92 MiB | **1.07x** | `86f9ea43...` |
| 动画 256×256 × 24 帧 × 30（Wave 19 发布审计复测） | **66.250** | 64.818 / 67.800 | 78.357 | 2,848.96 | **17.53 MiB** | 21.38 MiB | **1.18x** | `17bfe25f...` |

诚实说明：两项均领先 Go `image/gif`，峰值 RSS 更低；倍率在同机不同时段于 1.07–1.18x 间波动（发布复测时机器负载约 6）。两份基准输入都由 Go 编码器生成（满表 Clear 的 LZW、无隔行、无 LCT），未计时隔行与 Deferred Clear 路径，这两条路径的正确性由 439 份差分语料覆盖。Go 为 `RestoreToPrevious` 额外保存帧矩形，Pion 直接在快照上合成，属合理设计差异。对抗负载（`audit/run_audit.sh dos`）：1×1 画布 256 个 4096² 子帧炸弹 0.087 s 返回 `LimitExceeded`（修复前 5.4 s），1,088 MiB LZW 炸弹 2.57 s（修复前 30 s 不结束）。

红队：11 / 11 单测，`audit/` 零改动；2 P1 + 2 P2 全部修复，`audit/run_audit.sh` **exit 0**（`AUDIT PASS`：control 与红队用例全部通过，对 Go `image/gif` 439 / 439 语料 4 模 SHA-256 一致，3 万例变异 fuzz 0 崩溃、两侧都接受的 3,024 例全部一致）；`wasm_smoke` 4 模式 stdout 均为 `54 B`、SHA-256 `3d33ca29ba071d9042345a0c828b2f89c592d18910aaa068b1fa59c2a26392b7`。

### webvtt

参考实现：无可直接对拍的第三方 Go / Rust WebVTT 解析器输出，故基线为同规则、同输出的手写 Go 镜像：`go_ref`（`bench/go_bench`，包自带）与红队 F20 补充的 `go_tuned`（`audit/bench/go_tuned`，零拷贝行偏移与载荷、手写定宽时间戳与分词，并像 Pion 一样解析 `line` / `position` / anchor）。负载为 20 × 8,000 cues（27.5 MB）的解析 + `plain_text` + 2,000 次时间轴查询，`warmup=2`、`rounds=9` 严格交替，三方 stdout SHA-256 逐字节一致。

| Implementation | Median (ms) | Min (ms) | P95 (ms) | MB/s | Peak RSS | vs `go_ref` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion`（红队修复后包基准） | — | — | — | — | **6.7 MiB** | **1.04x**（vs `go_tuned` 0.90x） |
| `go_ref` / `go_tuned`（红队修复后包基准） | — | — | — | — | 16.0 / 17.5 MiB | 1.00x / — |
| `pion`（Wave 19 发布审计复测） | 107.692 | 106.276 | 109.044 | 255.68 | **6.70 MiB** | **1.02x** |
| `go_ref`（Wave 19 发布审计复测） | 110.258 | 108.024 | 115.131 | 249.73 | 16.28 MiB | 1.00x (baseline) |
| `go_tuned`（Wave 19 发布审计复测） | **96.302** | 93.455 | 97.996 | 285.92 | 17.12 MiB | 1.14x |

诚实说明（红队 F20）：对包自带 `go_ref` 的 1.02–1.04x 领先主要来自后者的分配习惯（整串 `strings.Split`、逐时间戳 `strconv.ParseInt`、逐 cue `strings.Fields` / `strings.Join`）；对同规则零拷贝的 `go_tuned` Pion **落后**，为 0.89–0.90x。峰值 RSS 低 2.4–2.6×。语料已按时间排序（排序路径未计时）。时间轴热路径：10 万 cue 时约 `0.3 µs/query`；红队 F17 最坏情形（一条覆盖全程的早期长 cue）发布复测 0.17 µs/query（无长 cue 0.11 µs/query），修复前为 376 µs/query。

红队：16 / 16 单测，`audit/` 零改动；5 P1 + 15 P2 全部修复，`audit/run_audit.sh` **ALL GATES PASS**（W3C WPT `file-parsing` 52 / 52 + `cue-text-parsing` 78 / 78 共 130 / 130，Native 与 Wasm32 结果逐字节一致；F4 变异探针、F5 30 万层嵌套、F17 / F19 复杂度门禁全部通过）；`wasm_smoke` 4 模式 stdout 均为 `187 B`、SHA-256 `9fdfd81424b46738f872cc0e62ff3d0032ea701c49aa32528920423198982257`。

### webp

参考实现：Go `golang.org/x/image/webp` `v0.48.0`（go1.27.3）。基准输入是 `bench/go` 确定性生成的 512×512 WebP（VP8L 无损、VP8 有损、VP8X + ALPH），两侧各解码 30 次并输出 1,048,576 B RGBA8888；MB/s 按 30 MiB RGBA 输出计。`sh packages/webp/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行。

| Workload | Pion Median (ms) | Pion Min / Max / P95 (ms) | Go Median (ms) | Go Min / Max (ms) | Pion MB/s | Go MB/s | Pion RSS | Go RSS | Pion vs Go | SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| VP8L 无损（Wave 20 发布复测） | **130.652** | 128.435 / 132.096 / 132.033 | 154.463 | 147.902 / 163.227 | 240.77 | 203.66 | **4.47 MiB** | 11.95 MiB | **1.18x** | `d17d1dff27faae74...` |
| VP8 有损（Wave 20 发布复测） | 147.946 | 138.070 / 168.802 / 166.400 | **143.284** | 142.104 / 150.921 | 212.63 | 219.54 | **4.39 MiB** | 12.89 MiB | 0.97x | `290259f8f8ad61a0...` |
| VP8X + ALPH（Wave 20 发布复测） | **179.968** | 175.499 / 185.194 / 184.285 | 192.009 | 187.954 / 205.486 | 174.79 | 163.83 | **4.80 MiB** | 11.97 MiB | **1.07x** | `19475dec78b0d4ff...` |
| VP8L / VP8 / VP8X + ALPH（`audit/run_audit.sh` 基准段，同机数分钟前） | 137.7 / 146.5 / 179.1 | — | 151.6 / 146.4 / 200.1 | — | — | — | — | — | 1.10x / 1.00x / 1.12x | 同上 |
| v0.2.0 VP8L 无损编码 512×512 RGBA（`exact`，进程内 ×10，Linux x86_64 vs C `libwebp 1.5.0 -z 4`） | **583.544** | 537.638 / — / 606.467 | 1267.907 | 1224.872 / 1446.911 (P95) | **17.97** | 8.27 | **8.79 MiB** | 27.07 MiB | **2.17x** | `e7da69a9c55682bc...` |

v0.2.0 编码基准说明（Linux x86_64，同机 `sh packages/webp/bench/run_bench.sh`）：基线为进程内 C `-O2 -lwebp` 基准程序（`packages/webp/bench/c/libwebp_encode_bench.c`，调用 `WebPEncode` + `WebPConfigLosslessPreset(&config, 4)` + `config.exact = 1`），两侧均一次性将 `alpha_512.rgba`（1,048,576 B）读入内存并在单进程内连续编码 10 次，最后将编码结果解码回 RGBA8888 输出到 stdout 并通过 `bench_compare.py` 强制校验与原始输入 RGBA8888 的 SHA-256（`e7da69a9c55682bc...`）逐字节一致。Pion 编码速度快 2.17×、峰值 RSS 低 3.08×（8.79 MiB vs 27.07 MiB）；编码体积为 190,690 B（5.50×），比 `libwebp -z 4`（169,386 B，6.19×）大约 12.6%（未启用 CrossColor 与 Meta-Huffman）。

诚实说明：VP8L 无损与 VP8X + ALPH 领先 Go；VP8 有损基本持平，本次发布复测落后 3%（0.97x，Pion 样本离散较大：138–169 ms），同机审计基准段为 1.00x（机器负载约 6–7）。三项峰值 RSS 均低 2.5–2.9×。三份输入都是确定性生成的单一图像，未计时 ANIM（本包不支持动画）、Meta-Huffman 大分组与多分区 VP8 路径，这些路径的正确性由差分语料与 fuzz 覆盖。对抗负载（`audit/run_audit.sh dos`，native release）：分配前拒绝的宽高炸弹均 ≤ 0.01 ms，34 字节 → 64 MiB RGBA 的 4096² 实心 VP8L 102.65 ms / 66.0 MiB，2,600 组完整最大 Huffman 码 194.23 ms / 77.4 MiB（libwebp 42 MiB），2,600 组不完整码 0.07 ms 返回 `InvalidHuffman`。

红队：11 / 11 单测，`audit/` 零改动；1 P0 + 5 P2 全部修复，`audit/run_audit.sh` **exit 0**（`AUDIT PASS`：20 / 20 红队与 control 用例 4 模通过，5 / 5 libwebp 裁决向量一致，622 份差分语料 4 模与 Go 一致（601 份 RGBA SHA-256 一致、21 份双方都拒绝），1 万例变异 fuzz 0 崩溃（8,373 双方拒绝、1,597 与 Go 一致、25 例 Pion 与 libwebp 拒绝而 Go 接受、4 例 Pion 与 libwebp 一致而 Go 不同、1 例两参考都拒绝而 Pion 宽松接受），Native 与 Wasm32 1 万例全部一致，12 / 12 DoS 炸弹在预算内，0 `extern "C"` / 0 `World` / 0 模块级可变状态）；`wasm_smoke` 4 模式 stdout 均为 `55 B`、SHA-256 `8a00bb493b1061cbc6ec503a8fe400de88fbf6fb5fc39956ca9f54e41bd65eec`。

### wgsl

参考实现：Rust [`naga`](https://github.com/gfx-rs/wgpu/tree/trunk/naga) `=24.0.0`（`--release`，`bench/rust_bench`）。输入为 `bench/gen_corpus.py` 确定性生成的 3 份真实着色器（PBR 顶点 + 片元、Compute Reduction、Particle Physics Compute，合计 5,070 B），两侧各跑 200 轮，每轮 7 次完整编译（解析 + 校验 + MSL 生成 + GLSL 生成，按入口点分别生成 GLSL），共 1,400 次；MB/s 按 1,014,000 B 输入计。`sh packages/wgsl/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行，Darwin arm64（Apple M5 Max (Darwin arm64)，Apple M5 Max，机器负载约 5–6）。

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_naga`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_wgsl`（Wave 21 发布复测） | **121.677** | 118.496 | 125.682 | 8.33 | 86911.79 | **3.19 MiB** | **1.36x** |
| `rust_naga`（Wave 21 发布复测） | 165.073 | 154.963 | 218.984 | 6.14 | 117909.02 | 4.47 MiB | 1.00x (baseline) |
| `pion_wgsl`（`audit/run_audit.sh` 基准段，同机数分钟前） | **119.795** | 115.927 | 125.521 | 8.46 | 85568.07 | **3.19 MiB** | **1.34x** |
| `rust_naga`（`audit/run_audit.sh` 基准段，同机数分钟前） | 160.174 | 148.294 | 168.398 | 6.33 | 114409.76 | 4.47 MiB | 1.00x (baseline) |

两侧 stdout 均为 `74 B`、SHA-256 `6e66de24898b48469f8f2344442668fc1e35ede7ba40009fe3d884c55b0d03f1`。红队修复前的包基准（93.374 ms vs 175.349 ms，1.88x）已作废：修复给校验器补上了名称解析、类型与控制流检查，并让生成的 MSL / GLSL 真正可编译，修复后 Pion 侧中位数为 121.677 ms（不同时段同机测得，未做严格对照）。

| 阶段分拆（200 × 3 份着色器，各 1 遍，`run_audit.sh bench`） | 仅解析 | 解析 + 校验 |
| --- | ---: | ---: |
| `pion_wgsl` | 26 ms | 41 ms |
| `naga =24.0.0` | 45.6 ms（含名称解析与 IR 降级） | 49.7 ms |

诚实说明（红队 P2-5）：两端管线做的工作不同，倍率不能当作同等功能编译器的对比。`pion_wgsl` 词法 / 语法分析得到 AST，在 AST 上做静态校验（名称解析、类型检查、属性 / 布局 / 入口点与控制流规则）后直接生成 MSL 与 GLSL；naga 先解析并降为 naga IR（名称解析、完整类型推导），再以 `naga::valid::Validator` + `ValidationFlags::all()` 做一致性、uniformity 与控制流校验，最后经 IR 后端生成。阶段分拆显示 Pion 的校验阶段（约 15 ms）比 naga（约 4 ms）重，领先主要来自解析与直接生成。基准 stdout 只是 6 个计数器（入口点数、绑定数、`wg_x` 之和、MSL / GLSL 成功数），SHA-256 门禁只证明两侧处理了同一语料，不证明生成代码相同；`glsl_ok` 仅检查 `#version ` 前缀。生成代码是否真能编译由审计 `judge` 门禁单独裁决：三份基准着色器的 MSL 经 `xcrun -sdk macosx metal -std=macos-metal2.4`、GLSL 经 `glslangValidator` 16.6.0 均编译通过。

红队：20 / 20 单测，`audit/` 零改动；4 P0 + 7 P1 + 5 P2 全部修复，`audit/run_audit.sh` **exit 0**（`AUDIT RESULT: PASS`：0 `extern "C"` / 0 `World` / 0 模块级可变状态；56 例（7 control + 49 红队）× 4 模通过；`judge` 47 / 47 份 naga 接受的合法着色器返回 `Ok` 且 MSL 经 `xcrun metal`、GLSL 经 `glslangValidator` 编译通过，49 / 49 份 naga 拒绝的非法着色器被拒；`gpu` 10 / 10 计算核在本机 Apple Silicon Metal GPU 上与 WGSL 规定结果一致（`- -x`、`arrayLength`、`continue` → `continuing`、`vec3` / `@size` 布局、`round` 银行家舍入、零初始化与 3 个对照）；`dos` 104 / 104（26 个最大 2 MB 的对抗输入 × 4 模，含 `ParseLimits` 设为 0 / 负值）≤ 0.23 s 结束、0 崩溃；`fuzz` 5,000 例 × 4 模（seed `20261124`）0 崩溃 / 0 挂起、4 模判定逐字节一致，与 naga 的一致性（仅供参考）：双方接受 62、双方拒绝 4,741、Pion 接受而 naga 拒绝 13、Pion 拒绝而 naga 接受 184（其中 174 例是截断成只剩注释或空白的变异体，naga 当作空模块接受，Pion 返回 `EmptySource`；10 例为解析拒绝））；`wasm_smoke` 4 模式 stdout 均为 `5,312 B`、SHA-256 `e6cfe5f0fefe1503c736e7a303b5cf6e436b95d55e603f71bfacfe7a38ff9455`。

### exif

参考实现：Rust [`kamadak-exif`](https://github.com/kamadak/exif-rs) `=0.6.2`（`--release`，锁定 `Cargo.lock`，`bench/rust_bench`）。输入为 `bench/gen_corpus.py` 确定性生成的 4 容器相机尺寸语料（JPEG：APP0 + EXIF APP1 + XMP + ICC + 256 KB 扫描数据；大端 TIFF；WebP：VP8X / ICCP / VP8L + EXIF；PNG：`eXIf` + 4 KB IDAT；合计 436,924 B，每文件 72 个 tag，覆盖 IFD0 / ExifIFD / GPSIFD / InteropIFD / IFD1，含 30 KB MakerNote 与 11 KB 缩略图），两侧各解析 25,000 轮（100,000 次解析，输入 10,923,100,000 B）并输出规范化 tag 转储供逐字节校验；MB/s 按全部输入字节计。`EXIF_BENCH_ITERS=25000 sh packages/exif/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行，Darwin arm64（Apple M5 Max (Darwin arm64)，Apple M5 Max，机器负载约 8–9）。

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_kamadak_exif`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_exif`（Wave 22 发布复测） | **465.537** | 451.831 | 469.664 | 23463.46 | 4655.37 | **3.45 MiB** | **1.33x** |
| `rust_kamadak_exif`（Wave 22 发布复测） | 618.723 | 577.935 | 641.880 | 17654.26 | 6187.23 | 4.09 MiB | 1.00x (baseline) |
| `pion_exif`（`audit/run_audit.sh` 基准段，同机数分钟前） | **445.268** | 436.595 | 471.288 | 24531.50 | 4452.68 | **3.20 MiB** | **1.40x** |
| `rust_kamadak_exif`（`audit/run_audit.sh` 基准段，同机数分钟前） | 621.175 | 583.293 | 672.827 | 17584.57 | 6211.75 | 4.02 MiB | 1.00x (baseline) |
| `pion_exif`（包基准，`packages/exif/README.md`） | **455.693** | 432.801 | 477.372 | 23970.31 | 4556.93 | **3.20 MiB** | **1.32x** |
| `rust_kamadak_exif`（包基准，`packages/exif/README.md`） | 600.636 | 596.498 | 605.550 | 18185.88 | 6006.36 | 3.95 MiB | 1.00x (baseline) |

两侧 stdout 均为 `248,232 B`、SHA-256 `02764eb38819db71c2dfdbe4a5026fb7a9cbcf59c1b7116415a0901c73c46c8e`（与包 README 一致）。三次测量为不同时段同机结果，差异属负载波动。

| 红队 `gen_bench_real.py` 相机尺寸 EXIF 对照（同一组 `--release` 二进制，`run_audit.sh bench`） | Pion | `kamadak-exif` | ns/op（Pion vs Rust） | Speedup |
| --- | ---: | ---: | ---: | ---: |
| 1,500 B MakerNote | **84.2 ms** | 86.5 ms | 4,210 vs 4,325 | **1.03x** |
| 30,000 B MakerNote | **94.8 ms** | 123.8 ms | 4,741 vs 6,192 | **1.31x** |

诚实说明（红队 P1-2）：修复前的包基准 `1.01x` 只在不具代表性的小语料上成立，且 `UNDEFINED` 字段逐字节复制；修复后 `UNDEFINED` 改为 `Bytes::slice` 零拷贝，基准语料扩为含 30 KB MakerNote 的相机尺寸 4 容器语料。领先主要来自大 `UNDEFINED` 值（MakerNote / 缩略图）不复制：MakerNote 只有 1,500 B 时两者基本持平（1.03x），30 KB 时为 1.31x。两侧语义差异如实列出（审计 `fuzz` 分类）：Pion 在 SOS 处停止、忽略 IEND 之后的 `eXIf`、要求 `eXIf` 的 4 字节 CRC 存在、拒绝 IFD0 偏移 0（`kamadak-exif` 返回 0 个字段）；Pion 跳过零值 / `count != 1` / 非 LONG 的子 IFD 指针并忽略子 IFD 的 next 指针（`kamadak-exif` 报错），接受带 `Exif\0\0` 前缀的 WebP `EXIF` 分块，并把类型 13（IFD，TIFF TN1）按 LONG 解码。基准语料上两侧输出逐字节一致。

红队：10 / 10 单测，`audit/` 零改动；0 P0 + 2 P1 + 6 P2 全部修复，`STRICT=1 audit/run_audit.sh` **exit 0**（`AUDIT PASS (0 P0)`、0 OPEN：11 例（5 红队 + 6 control）× 4 模通过；`diff` 37 / 37 份合法样本（12 种类型 LE / BE 内联与外部值、相机 IFD0 / Exif / GPS / Interop / IFD1、JPEG / WebP / PNG 容器与 `kamadak-exif` 自带测试图）逐字段与访问器均与 `kamadak-exif 0.6.2` 一致；`adv` 209 / 209 份对抗容器 / TIFF 结构 / GPS / 限额样本符合预期、4 模一致；`trunc` 6,755 个逐字节前缀 × 4 模 0 崩溃 / 0 超时（双方拒绝 5,829、一致 922、Pion 因要求 `eXIf` CRC 更严 4）；`fuzz` 10,000 例变异（LCG seed `0x5EEDE1F0`）× 4 模 0 崩溃 / 0 超时（双方拒绝 6,904、一致 2,280、类型 13 / 指针类型差异但值相同 469、Pion 对指针宽松 276 + 子 IFD next 宽松 37、Pion 更严 27 + 7）；`dos` 14 / 14 资源炸弹 native 与 wasm32 均 0 违例（65,535 条目 0.001 ms 拒绝、4,096 条目 0.12 ms、4 MiB 重叠外部值 ≤ 0.076 ms / 2.4 MiB、1 MiB NUL ASCII 3.57 ms / 15.1 MiB），`format_canonical` 4,096 条目升序 458 µs / 降序 462 µs；`harness` 注入 panic 与静默值错误均被门禁捕获；0 `extern "C"` / 0 `World` / 0 import / 0 依赖 / 0 模块级可变状态）；`wasm_smoke` 4 模式 stdout 均为 `56 B`、SHA-256 `87f92b30cb019e7116d9996b19ef2de8a60e1700d9d723dba062cb0035d98ffa`（与包 README 一致）。

### icc

参考实现：Rust [`qcms`](https://crates.io/crates/qcms) `=0.3.0`（`--release`，启用 `precache_output_transform()`，即 Firefox 生产配置，记作 `rust_qcms_pre`，为基线）与 [`moxcms`](https://crates.io/crates/moxcms) `=0.9.2`（`--release`，ARM64 NEON），锁定 `Cargo.lock`，`bench/rust_bench`。输入由 `bench/gen_corpus.py` 确定性生成：Display-P3 v4（`para` type 3 + `mluc`，444 B）、sRGB v2（`curv[1024]`，2,476 B）、AdobeRGB v2（`curv` gamma，432 B）、Rec.2020 v4（`para` type 3 709 TRC，440 B）与一帧 1920×1080 RGBA8（8,294,400 B）。Scenario A 每次迭代完成「解析 + 建 sRGB 变换 + 变换饱和非中性探针 `(200, 70, 40)`」并输出探针结果；Scenario B 对同一帧做 20 次 Display-P3 → sRGB 原地变换并输出全帧 RGB 摘要，两者 stdout 都依赖实际色彩计算（红队 P2-5）。`sh packages/icc/bench/run_bench.sh` 经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行，Darwin arm64（Apple M5 Max (Darwin arm64)，Apple M5 Max，机器负载约 4–6），Wave 23 发布复测。

1080p 像素精度门禁（单帧，基准前执行）：Pion 与 `qcms_pre` max_err **2 LSB**、逐字节一致 97.77%、≤ 1 LSB **99.9995%**；与 `moxcms` max_err **2 LSB**、逐字节一致 97.15%、≤ 1 LSB **99.9981%**；Alpha 100% 不变，输出与输入不同（抗恒等检查）。三者对精确 ICC 浮点参考的误差见下方红队 `diff` 段。

#### Scenario A：解析 + `Transform::to_srgb` + 饱和探针（每 profile 20,000 次）

| Profile | Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_qcms_pre`) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Display-P3 v4 `para3` | `pion_icc` | **30.258** | 30.012 | 30.844 | 293.48 | 1512.88 | **2.06 MiB** | **1.68x** |
| | `rust_qcms_pre` | 50.890 | 49.884 | 51.117 | 174.49 | 2544.50 | 2.41 MiB | 1.00x (baseline) |
| | `rust_moxcms` | 856.125 | 852.541 | 860.394 | 10.37 | 42806.27 | 2.80 MiB | 0.06x |
| sRGB v2 `curv[1024]` | `pion_icc` | 60.565 | 59.318 | 63.238 | 817.64 | 3028.24 | **2.08 MiB** | 0.91x |
| | `rust_qcms_pre` | **54.914** | 53.683 | 57.225 | 901.77 | 2745.70 | 2.34 MiB | 1.00x (baseline) |
| | `rust_moxcms` | 842.186 | 834.556 | 856.543 | 58.80 | 42109.31 | 2.81 MiB | 0.07x |
| AdobeRGB v2 `curv` gamma | `pion_icc` | **70.213** | 65.896 | 74.105 | 123.05 | 3510.64 | **2.06 MiB** | **1.17x** |
| | `rust_qcms_pre` | 82.256 | 80.362 | 84.743 | 105.04 | 4112.80 | 2.36 MiB | 1.00x (baseline) |
| | `rust_moxcms` | 895.762 | 877.232 | 899.644 | 9.65 | 44788.11 | 2.69 MiB | 0.09x |
| Rec.2020 v4 `para3` | `pion_icc` | 71.605 | 67.460 | 72.501 | 122.90 | 3580.26 | **2.06 MiB** | 0.71x |
| | `rust_qcms_pre` | **50.809** | 49.297 | 52.042 | 173.20 | 2540.45 | 2.41 MiB | 1.00x (baseline) |
| | `rust_moxcms` | 860.987 | 855.620 | 898.413 | 10.22 | 43049.35 | 2.89 MiB | 0.06x |

stdout 各 41 B，SHA-256：Display-P3 `bfab1395f954808782156ed4125543d12e82495c818e9589ddcd4cd2aadfc164`、sRGB `4f0219fbd2f566ab0b8b91b71c3531f9fb896964d91f14a2e22d267634759dd1`、AdobeRGB `fc752cea3860aee23c0273c3235c0e849f33af105dad5e3754951af14a5b1cea`、Rec.2020 `3fc88aa71cd3806015d59947f1f7fd0d75cf91e6bcb39423a0b047b71fbd6a03`（三方全部轮次一致）。

#### Scenario B：1920×1080 RGBA8 Display-P3 → sRGB（20 帧，41,472,000 px，165,888,000 B）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | MP/s | ns/px | Peak RSS | Speedup (vs `rust_qcms_pre`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_moxcms`（`0.9.2 --release`，NEON） | **52.097** | 51.269 | 55.635 | 3184.19 | 796.1 | 1.26 | 18.33 MiB | **1.93x** |
| `rust_qcms_pre`（`0.3.0 --release`，预缓存标量） | 100.764 | 99.100 | 101.599 | 1646.31 | 411.6 | 2.43 | **10.16 MiB** | 1.00x (baseline) |
| `pion_icc`（`--release`，纯标量） | 107.813 | 107.513 | 110.297 | 1538.66 | 384.7 | 2.60 | 17.98 MiB | 0.93x |

stdout 70 B，SHA-256 `304ed618391e46e05dcb4c4b9ba8c728aff1cb8539466affa99642f2a2da176a`（三方全部轮次一致）。

如实说明：领先项为 Display-P3（1.68x）与 AdobeRGB（1.17x）的解析 + 建变换，以及对 `moxcms` 全部 4 个 profile 的建变换（12.0–28.3x，`moxcms` 建变换开销固定在约 42–45 µs）。落后项：sRGB `curv[1024]`（0.91x）与 Rec.2020 `para3`（0.71x）的解析 + 建变换慢于预缓存 `qcms`；1080p 像素变换为预缓存 `qcms` 的 0.93x（纯标量 Q14 整数管线，峰值 RSS 高 7.8 MiB），仅为 NEON `moxcms` 的 0.48x。红队前包 README 声称的 Scenario A `245x` / Scenario B `1.99x` 是对未开预缓存的 `qcms` 与恰好命中编译期 LUT 捷径的单一 Display-P3 语料得出的（红队 P1-1 / P1-2），修复后基线改为预缓存 `qcms` 并扩为 4 个 profile；本表为 Wave 23 发布复测，与包 README 中修复时的数据（1.72x / 0.90x / 1.14x / 0.66x / 0.84x）同向，差异属负载波动。

红队：10 / 10 单测，`audit/` 与 `src/` 零改动；1 P0 + 3 P1 + 6 P2 全部修复。`STRICT=1 sh packages/icc/audit/run_audit.sh <段>` 10 个核心门禁段逐段 `AUDIT PASS (0 P0)`、0 OPEN、exit 0：`build` 4 模编译 + `qcms 0.3.0` / `moxcms 0.9.2` oracle（`cargo --locked`）+ 语料（diff 37、adv 149、trunc 2,464、fuzz 10,000、dos 12，另 11 份 macOS ColorSync 配置文件参与差分、3 份 LUT 配置文件参与 adv，仓库外只读）；`cases` 9 / 9（5 红队 + 4 control）× 4 模；`unit` 包单测 10 / 10 + 审计 9 / 9；`diff` 48 份合法配置文件 × 40,033 像素 × 4 模，对精确 ICC 浮点参考最差 **1 LSB**（`zero_matrix.icc` 一栏 `moxcms` 拒绝建变换，不涉及 Pion）；`adv` 152 条记录 × 4 模 0 崩溃 / 0 超时，145 例符合预期 + 4 例原 P0-1 / P2-3 / P2-4 已不复现 + 3 份系统 CMYK / Lab / XYZ LUT 配置文件返回 `UnsupportedProfile`；`trunc` 2,464 个逐字节前缀 × 4 模 0 崩溃 / 0 超时；`fuzz` 10,000 例变异（LCG seed `0x5EED1CC`）× 4 模 0 崩溃 / 0 超时；`dos` 12 / 12 炸弹 native 0 违例（预算 250 ms / 512 MiB，重复标签炸弹 ≤ 2.0 ms 以 `InvalidTagTable` 拒绝，最重 `single_desc_16MiB` 27.7 ms / 52.7 MiB；wasm32 最重 `jpeg_255x65519_chunks` 40.3 ms）；`portability` 0 依赖 / 0 模块级 `let mut` / 仓库内 0 份 `.icc` / `.icm`；`smoke` 4 模输出一致且与 README 相同。审计脚本的 `bench` 段（`run_audit.sh` 第 276–303 行）硬编码修复前的断言 `sp >= 245.31 / 2` 与 `s2 >= 1.99 * 0.75`，与 P1-1 / P1-2 要求的预缓存 `qcms` 公平对拍互斥；按 `audit/` 不可改原则未运行该段，改由上方 `bench/run_bench.sh` 完整复测（1080p 精度门禁 + 5 / 5 场景 SHA-256 一致）代替。`wasm_smoke` 4 模式（native debug / native `--release` / wasm32 debug / wasm32 `--release`）stdout 均为 `57 B`（`icc_wasm_smoke: OK pixels=216 fnv64=10050272235678599435`）、SHA-256 `b56030c6f7788a959d955facedb0df32e7750f5380f7d5cb7f8d11e6e5072354`（与包 README 一致）。

### encoding

参考实现：Mozilla Rust [`encoding_rs`](https://crates.io/crates/encoding_rs) `=0.8.44`（`--release`，默认特性；解码走 ARM64 NEON SIMD ASCII / UTF-8 快路，编码走默认特性的直查 / 线性表），锁定 `Cargo.lock`，`bench/rust_bench`。输入由 `bench/gen_corpus.py` 确定性生成约 1 MiB 的真实 HTML：解码为 UTF-8（1,048,098 B）、GB18030（1,048,152 B）、Shift_JIS（1,048,302 B）三份，各迭代 100 次；编码为四份 UTF-8 HTML（含目标编码不可表示字符，走 WHATWG HTML `&#...;` NCR 回退），分别以 `encode_html` 编为 Big5（1,048,182 B）、gb18030（1,048,550 B）、Shift_JIS（1,048,140 B）、EUC-KR（1,048,274 B），各迭代 20 次；两端 stdout 均为输出摘要，依赖实际编解码结果。`sh packages/encoding/bench/run_bench.sh`（由 `STRICT=1 sh packages/encoding/audit/run_audit.sh bench` 原样调用）经 `scripts/bench_compare.py`（`warmup=1`、`rounds=5`，严格交替，stdout SHA-256 逐字节一致）运行，Darwin arm64（Apple M5 Max (Darwin arm64)，Apple M5 Max，机器负载约 7–11），Wave 24 发布复测。

| Workload | Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_encoding_rs`) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Decode UTF-8 HTML | `pion_encoding` | 47.195 | 46.864 | 47.740 | 2220.79 | 471948.33 | 5.19 MiB | 0.30x |
|  | `rust_encoding_rs` | **14.345** | 14.042 | 15.500 | 7306.60 | 143445.41 | 9.16 MiB | 1.00x (baseline) |
| | stdout `66 B`，SHA-256 `a91a4e2b8cc8af6ea8de77d80bc6c867d3afc815e6bb08d55dfaabaca7765b77` | | | | | | | |
| Decode GB18030 HTML | `pion_encoding` | 243.813 | 237.194 | 249.301 | 429.90 | 2438130.42 | 14.20 MiB | 0.26x |
|  | `rust_encoding_rs` | **64.240** | 62.885 | 68.314 | 1631.63 | 642395.00 | 9.20 MiB | 1.00x (baseline) |
| | stdout `69 B`，SHA-256 `94487d91ee2a0125581c167ab66a7abc3ed06c2a44fc6fd72f1690e66811e2e7` | | | | | | | |
| Decode Shift_JIS HTML | `pion_encoding` | 226.179 | 221.879 | 230.276 | 463.48 | 2261787.08 | 8.42 MiB | 0.38x |
|  | `rust_encoding_rs` | **86.963** | 86.726 | 90.576 | 1205.46 | 869628.75 | 9.17 MiB | 1.00x (baseline) |
| | stdout `66 B`，SHA-256 `a4fa59d716856512279f24d5725713a263b4202a6a0f47ccd4f14aee7560fc27` | | | | | | | |
| Encode Big5 HTML | `pion_encoding` | **357.426** | 355.995 | 364.414 | 58.65 | 17871327.10 | 6.84 MiB | 1.11x |
|  | `rust_encoding_rs` | 397.445 | 390.358 | 412.585 | 52.75 | 19872245.85 | 5.17 MiB | 1.00x (baseline) |
| | stdout `69 B`，SHA-256 `50b401286a01be27101b76c0c2c263c25c1f32f73dbfe7805400e3ef1560cf42` | | | | | | | |
| Encode gb18030 HTML | `pion_encoding` | **363.519** | 356.892 | 370.631 | 57.69 | 18175943.75 | 6.77 MiB | 1.01x |
|  | `rust_encoding_rs` | 367.104 | 364.368 | 375.116 | 57.13 | 18355214.55 | 9.20 MiB | 1.00x (baseline) |
| | stdout `72 B`，SHA-256 `c7778ca8e20d6ca0171ec9a0e4941dd0a288210adc1cdca777b46a2d3b313673` | | | | | | | |
| Encode Shift_JIS HTML | `pion_encoding` | 195.433 | 193.652 | 201.599 | 107.26 | 9771658.35 | 6.77 MiB | 0.56x |
|  | `rust_encoding_rs` | **109.661** | 108.865 | 112.372 | 191.16 | 5483029.20 | 5.17 MiB | 1.00x (baseline) |
| | stdout `69 B`，SHA-256 `7735b27e122dc82b854b9ae271384e70a3e20a87eb050a9ee3945c5f3425a4c5` | | | | | | | |
| Encode EUC-KR HTML | `pion_encoding` | 308.335 | 303.767 | 310.073 | 68.00 | 15416768.75 | 6.80 MiB | 0.20x |
|  | `rust_encoding_rs` | **60.401** | 59.792 | 62.546 | 347.10 | 3020066.65 | 5.16 MiB | 1.00x (baseline) |
| | stdout `70 B`，SHA-256 `688d78b8655634da22a5e8ddc9b9a9e2fd561a66e9526c01d1812e9cdd61a285` | | | | | | | |

如实说明：领先项为 `encode_html` Big5（**1.11x**）与 gb18030（**1.01x**，持平），以及 UTF-8 解码峰值 RSS（5.19 vs 9.16 MiB）、gb18030 编码峰值 RSS（6.77 vs 9.20 MiB）。落后项：三项解码为 `encoding_rs` 的 0.26–0.38x（`encoding_rs` 以 NEON 16 字节 SIMD 批量跳过 ASCII 并校验 UTF-8，本包为纯标量 Pion，UTF-8 仅 8 字节展开校验；GB18030 解码峰值 RSS 高 5.0 MiB）；`encode_html` Shift_JIS 0.56x、EUC-KR 0.20x（`encoding_rs` 对部分常用区段有专用快路，见下方 GBK `U+3042` / EUC-KR `U+AC00` 单码点 16 ms vs 1 ms；本包 CJK 编码统一走码点有序不可变表的 O(log N) 二分，以换取零启动分配与零模块级可变状态）。不在随包基准内的单码点最坏情况（`dos` 段，1 MiB 单一码点 `encode_html`）：Big5 `U+00E9` 36 ms vs `encoding_rs` 289 ms、gb18030 `U+4E2D` 11 ms vs 47 ms；落后的是 `encoding_rs` 有直查快路的 GBK `U+3042` / EUC-KR `U+AC00`（16 ms vs 1 ms）、Big5 `U+20000`（17 ms vs 5 ms）与 windows-1252 不可表示字符 NCR（11 ms vs 4 ms）。本表与包 README 中修复时的数据（0.30x / 0.25x / 0.39x / 1.09x / 0.99x / 0.56x / 0.20x）同向，差异属负载波动。

红队：36 / 36 单测，`audit/` 与 `src/` 零改动；0 P0 + 2 P1 + 5 P2 全部修复（P1-1 旧 CJK 编码器线性查表最坏 1.4–5.6 s / MiB；P1-2 模块级可变 `FixedArray` 码表；P2-1 ISO-2022-JP `encode_html` 在 NCR 前离开 Roman 态；P2-2 `last = true` 后 `had_errors()` 丢失；P2-3 `DecodeError` 偏移按块计且可为负；P2-4 非法 UTF-8 `String` 使编码器出错；P2-5 README 声明无依据）。`STRICT=1 sh packages/encoding/audit/run_audit.sh <段>` 9 个可单独运行的核心门禁段逐段 `AUDIT PASS (0 P0)`、0 OPEN、exit 0，且每段末尾都执行 `clean_check`（`git status --porcelain --ignored -- packages/encoding` 干净；脚本无独立的 `clean_check` 段参数）：`build` 4 模编译 + `encoding_rs 0.8.44` oracle（`cargo --locked`）+ 10 组语料；`cases` 10 / 10（6 control + 4 红队）× 4 模；`unit` 包单测 36 / 36 + 审计 10 / 10；`diff` **1,921,335** 例（标签 7,766、单字节 15,196、DBCS 394,752、三字节 39,048、四字节 83,557、ISO-2022-JP 200,960、UTF 360,696、BOM 157,920、流式 96,000、编码 565,440）× 4 模逐字节一致，对 `encoding_rs` 0 差异；`dos` 4 MiB 解码炸弹（gb18030 4 字节回退 / 截断前导、GBK、ISO-2022-JP 转义、UTF-8 / UTF-16 截断、Big5、EUC-JP、Shift_JIS、EUC-KR、`x-user-defined`、windows-1252、`replacement`）native 整块 ≤ 77 ms、1 字节流式 ≤ 250 ms、RSS ≤ 48 MiB，wasm32 1 MiB gb18030 回退炸弹 1 字节流式 105 ms、Big5 `U+00E9` 编码最坏 42 ms；`portability` 0 `extern "C"` / 0 `World` / 0 import / 0 依赖 / 0 模块级 `let mut`（50 个不可变 `String` 表）；`smoke` 4 模输出一致且与 README 相同；`bench` 7 / 7 场景 SHA-256 一致；`harness` 注入 4 种解码缺陷（gb18030 回退字节、Big5 ASCII 尾字节、UTF-8 `EF BB` 续读、ISO-2022-JP 转义回放）均被差分门禁捕获。审计脚本的 `docs` 段（`run_audit.sh` 第 222 行）硬编码修复前的体积断言 `[ "$got" = "358 423 296 297" ]`，与 P1-1 新增 O(log N) 不可变反查表后的实测体积 `553 633 495 496` KiB（与包 README 一致）互斥；按 `audit/` 不可改原则未运行该段。`wasm_smoke` 4 模式（native debug / native `--release` / wasm32 debug / wasm32 `--release`，553 / 633 / 495 / 496 KiB）stdout 均为 `60 B`（`encoding_wasm_smoke: OK checks=13 fnv64=5273225285721917244`）、SHA-256 `0d48911ddc9b1d317b8d4ff6d2d2a2ab0868f1a67d231dec65589e56001ce4df`（与包 README 一致）。

### css_color

参考实现：Rust Linebender [`color`](https://crates.io/crates/color) `=0.3.3`（`--release`，`f32` + 平台 `libm`，锁定 `Cargo.lock`，`bench/rust_bench`，记作 `rust_color`，为基线）。输入由 `bench/gen_corpus.py` 确定性生成 2,042 条 `color 0.3.3` 也接受的 CSS Color 4 颜色串（62,507 B：命名色、hex、`rgb()` / `hsl()` / `hwb()`、`lab()` / `lch()` / `oklab()` / `oklch()`、`color()` 各空间）。Scenario A 每条解析并转为 sRGB、钳位后累加，迭代 100 次（204,200 次，6,250,700 B）；Scenario B 对同一批颜色做 4 段转换 `sRGB → Oklch → Display-P3 → Lab → sRGB`，迭代 200 次（408,400 次）；两端 stdout 均为依赖计算结果的累加器摘要，防死代码消除。`sh packages/css_color/bench/run_bench.sh`（`scripts/bench_compare.py`，`--warmup 1 --rounds 5` 严格交替）；本表为 Wave 25 发布复测，同次 `STRICT=1 audit/run_audit.sh` 的 `bench` 段复测为 0.45x / 0.25x。

#### Scenario A：CSS Color 4 解析 + sRGB 转换（2,042 条 × 100，204,200 次，6,250,700 B）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_color`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_css_color`（`--release`，纯 Pion 软件 `f64`） | 66.646 | 66.390 | 67.075 | 93.79 | 326.38 | 2.36 MiB | 0.45x |
| `rust_color`（`0.3.3 --release`，`f32` + `libm`） | **29.791** | 29.613 | 30.059 | 209.81 | 145.89 | **2.23 MiB** | 1.00x (baseline) |

stdout 36 B，SHA-256 `c388997920336ccd903e0c995941b01604987512094f34bfe146c1521c8599fb`（两端全部轮次一致）。

#### Scenario B：4 段色彩空间管线 `sRGB → Oklch → Display-P3 → Lab → sRGB`（2,042 色 × 200，408,400 次）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_color`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_css_color`（`--release`，纯 Pion 软件 `f64`） | 296.204 | 295.065 | 299.662 | 725.28 | 2.56 MiB | 0.25x |
| `rust_color`（`0.3.3 --release`，`f32` + `libm`） | **74.826** | 74.063 | 75.912 | 183.22 | **2.30 MiB** | 1.00x (baseline) |

stdout 38 B，SHA-256 `24a5eb3e4f3021341d8fffe960b9616ab5544804029514e6c80e9c580af23288`（两端全部轮次一致）。Scenario B 无字节输入，不计 MB/s。

差分精度（`bench/diff_oracle.py`，基准前执行，仅含 `color 0.3.3` 接受的输入）：

| Suite | Cases | Max Float Error | Max 8-bit Error | Pass Rate |
| --- | ---: | ---: | ---: | ---: |
| 解析 + 空间转换（`Srgb` / `Oklab` / `DisplayP3`） | 2,042 | `9.3e-5` | `0 LSB` | `100.00%` 精确 |
| `color-mix()`（14 空间 + 4 种色相插值 + alpha 缩放） | 360 | `3.0e-6` | `1 LSB` | `100.00%` ≤ 1 LSB |
| Oklch 二分色域映射 | 160 | — | — | `160 / 160` 落入色域 |

如实说明：两项均落后 `color 0.3.3`——解析 + sRGB 转换 **0.45x**（包 README 修复时 0.43x），4 段管线 **0.25x**，峰值 RSS 略高（2.36 / 2.56 vs 2.23 / 2.30 MiB）。原因：本包全部超越函数（`pow` / `cbrt` / `sin` / `cos` / `atan2` / `sqrt`）以纯 Pion IEEE-754 软件 `f64` 实现、零 `extern "C"`，以换取 Native / Wasm32 debug / release 4 模逐位一致与对 ED 参考 ≤ 1e-9 的精度；`color` 以 `f32` 计算并调用平台 `libm`。Scenario B 每次转换都经过多次 `cbrt` / `pow` / `atan2` / `sin` / `cos`，差距大于以解析为主的 Scenario A。

红队：40 / 40 单测，`audit/` 与 `src/` 零改动；0 P0 + 2 P1 + 14 P2 全部修复。`STRICT=1 sh packages/css_color/audit/run_audit.sh`（全部 13 段）`AUDIT PASS (0 P0)`、0 OPEN、exit 0：`cases` 25 / 25 × 4 模；WPT 11,654 条向量 11,405 通过、247 条超出范围、2 条 `rec2020` 已知裁决差异、0 条无法解释；`determinism` 全部语料 + 1,424 例色域映射 + 228 个 DoS 炸弹 + 32,368 次 API 极值调用 4 模逐字节一致；`dos` 最坏 0.71 ms（Wasm32 1.50 ms）；`harness` 5 / 5 注入缺陷被捕获。`wasm_smoke` 4 模 stdout `62 B`，SHA-256 `74a7423765ce57c187e60dbb52669bd4d3fee96f6d1ebcba914c45546d1e5455`。

### cookie

参考实现：Rust [`cookie`](https://crates.io/crates/cookie) `=0.18.3`（`--release`，记作 `rust_cookie`）与 [`psl`](https://crates.io/crates/psl) `=2.1.261`（`--release`，整张 PSL 在编译期生成 `match` 树，记作 `rust_psl`），锁定 `bench/rust/Cargo.lock`，两者分别为对应场景的基线。输入由 `bench/gen_data.py` 确定性生成：200 条只含两端语义重叠属性（`Expires` / `Max-Age` / `Domain` / `Path` / `Secure` / `HttpOnly` / `SameSite` / `Partitioned`、引号值、多 `=`、重复属性）的 `Set-Cookie` 头（13,000 B），以及 106 个 ASCII / Punycode 域名（Mozilla `test_psl.txt` 向量 + 常见 ICANN / Private / 通配符 / 例外 / IP，1,393 B）；各迭代 2,000 次。基准前先以 `iters=0` 逐行差分：`Set-Cookie` **200 / 200**、PSL **106 / 106**，0 分歧。两端 stdout 均为依赖解析结果的摘要，防死代码消除。`sh packages/cookie/bench/run_bench.sh`（`scripts/bench_compare.py`，`--warmup 1 --rounds 5` 严格交替）；本表为 Wave 26 发布复测，同次 `STRICT=1 audit/run_audit.sh` 的 `bench` 段复测为 0.49x / 0.21x，包 README 修复时为 0.51x / 0.22x。

#### Scenario A：RFC 6265bis `Set-Cookie` 解析（200 条 × 2,000，400,000 次，26,000,000 B）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_cookie`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_cookie`（`--release`） | 121.602 | 121.055 | 122.349 | 213.81 | 304.00 | **2.03 MiB** | 0.50x |
| `rust_cookie`（`0.18.3 --release`） | **60.322** | 59.099 | 60.989 | 431.02 | 150.80 | 2.30 MiB | 1.00x (baseline) |

stdout 67 B，SHA-256 `1d47970dd34f311281a9a1edefe14da268686e40c1f240c1265a6f6e94336efd`（两端全部轮次一致）。

#### Scenario B：Mozilla PSL 可注册域 + 公共后缀查找（106 域 × 2,000，212,000 次，2,786,000 B）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_psl`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_cookie`（`--release`，167.9 KiB 只读有序表二分） | 88.841 | 86.994 | 89.070 | 31.36 | 419.06 | **2.19 MiB** | 0.20x |
| `rust_psl`（`2.1.261 --release`，编译期 `match` 树） | **17.468** | 16.497 | 17.994 | 159.49 | 82.40 | 2.58 MiB | 1.00x (baseline) |

stdout 64 B，SHA-256 `cc25e7a528a65575e17713dee9c60da3799d06b35085150f88016f9cde06ca0a`（两端全部轮次一致）。

如实说明：两项均落后 Rust——`Set-Cookie` 解析 **0.50x**，PSL 查找 **0.20x**；峰值 RSS 两项均略低（2.03 / 2.19 vs 2.30 / 2.58 MiB）。原因：本包的解析器按 RFC 6265bis 完整执行 CTL 拒绝、4096 / 1024 B 上限、§5.1.1 cookie-date 算法、前缀校验与无效 `Path` / `SameSite` 回落，`cookie 0.18.3` 不做这些检查（审计差分中 3,922 例里 1,774 例因此不同，Pion 均与 draft-22 参考模型一致）；`psl` 把整张 PSL 编译进 Rust `match` 树（每次约 82 ns），本包把 10,472 条规则存为 167.9 KiB 不可变有序串 + 节点标志索引，每次匹配约 7.3 次二分（审计信息：按节点标志遍历可降到约 2.4 次），换来零启动分配、零模块级可变状态、Wasm32 release 457 KiB 与 Native / Wasm32 4 模逐字节一致，且查询前做 UTS #46 规范化与 Punycode，Unicode IDN 与 `xn--` 写法结果相同。

红队（独立 Opus，三轮复审后 `SIGN-OFF`）：15 / 15 单测，`audit/` 与 `src/` 零改动；0 P0 + 6 P1 + 12 P2 全部修复。`STRICT=1 sh packages/cookie/audit/run_audit.sh`（全部 13 段）`RESULT: clean`、0 P0、0 OPEN、exit 0：`cases` 28 / 28 × 4 模；参考模型对 parse 3,922 / date 4,027 / match 2,032 例与 jar 450 个场景 0 分歧（psl 31,499 例中 8 例为可接受的 fail-closed 拒绝）；`test_psl.txt` 77 / 77；内嵌表与钉住的 PSL `@763a4c200052` 10,472 条规则逐条一致；全部语料 + 15 个 DoS 炸弹 + API 极值扫描 4 模逐字节一致；`dos` 最坏 0.344 s（Wasm32 0.528 s）；`harness` 5 / 5 注入缺陷被捕获。`wasm_smoke` 4 模（native debug / native `--release` / wasm32 debug / wasm32 `--release`，524,792 / 673,416 / 467,637 / 468,077 B）stdout `189 B`，SHA-256 `0769a8149bcd31b944aee1db152d40abe8bd34ea02a29936ff9d5e93caf08c4a`（与包 README 一致）。

### opentype

参考实现：Rust [`ttf-parser`](https://crates.io/crates/ttf-parser) `0.25.1`（`--release`，`opt-level = 3`、`lto = true`、`codegen-units = 1`，记作 `rust_ttf_parser`），锁定 `bench/rust_bench/Cargo.lock`。环境：Apple M5 Max (Darwin arm64)，`pionc 0.1.0`，`--release`。负载：每次迭代惰性 `Face::parse` + 256 次 `cmap` / `hmtx` 查询 + 64 个 `glyf` 轮廓，共 200 次；`Face::parse` 只触及被查询的表，因此报告单次迭代耗时（µs/op）而非整文件 MB/s（表中 Throughput 为 bench_compare 按整文件字节数折算的名义值，仅供参考）。输入：系统字体在原位只读（不复制、不提交），另由 `bench/gen_fallback_font.py` 确定性生成 512 字形 2 轴可变字体 `synthetic_512.ttf`（22,796 B）作为无系统字体环境的兜底。基准前先做逐项差分（TTC 面数、`head` / `hhea` / `OS/2` / `post`、全 Unicode `cmap` 摘要、全 `hmtx` 摘要、`gid < 256` 字偶对矩阵、全 `glyf` 包围盒、`gid < 512` 轮廓命令流、`fvar` 轴表）：**8 / 8** 字体面（`synthetic_512.ttf`、Arial、Georgia、Times New Roman、Courier New、Helvetica TTC 面 0 / 1、SFNS 可变字体）0 分歧。`sh packages/opentype/bench/run_bench.sh`（`scripts/bench_compare.py`，`--warmup 1 --rounds 5` 严格交替）；本表为 Wave 27 发布复测，同次 `STRICT=1 audit/run_audit.sh` 的 `bench` 段复测为 0.61x / 0.74x，包 README 记为 0.62x / 0.70x（测试时本机有其他并发负载，比值有数个百分点波动）。

#### Scenario A：Arial.ttf（3,381 字形，200 次，154,647,200 B）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | µs/op | Peak RSS | Speedup (vs `rust_ttf_parser`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_opentype`（`--release`） | 17.542 | 15.827 | 17.757 | 8815.93 | 87.71 | 3.44 MiB | 0.56x |
| `rust_ttf_parser`（`0.25.1 --release`，LTO） | **9.860** | 9.422 | 10.841 | 15684.43 | 49.30 | **2.72 MiB** | 1.00x (baseline) |

stdout 45 B，SHA-256 `844d1e676bcb6b0bf0569fb430e6ab7f76fc845c5350445de896495bc37f5b7c`（两端全部轮次一致）。

#### Scenario B：`synthetic_512.ttf`（512 字形 2 轴可变字体，200 次，4,559,200 B）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | µs/op | Peak RSS | Speedup (vs `rust_ttf_parser`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_opentype`（`--release`） | 12.215 | 11.072 | 13.346 | 373.24 | 61.08 | 2.00 MiB | 0.79x |
| `rust_ttf_parser`（`0.25.1 --release`，LTO） | **9.698** | 8.500 | 12.575 | 470.14 | 48.49 | 2.00 MiB | 1.00x (baseline) |

stdout 43 B，SHA-256 `743e55b9beb82d9cda6edd244071c1bfac6f1f34b38520bbd4ad4aae3928f3f7`（两端全部轮次一致）。

如实说明：两项均落后 Rust——Arial **0.56x**、`synthetic_512` **0.79x**；Arial 峰值 RSS 略高（3.44 vs 2.72 MiB），合成字体持平。审计 `dos` 段另对 19 个畸形字体炸弹计时：本包 native 最坏 21 ms、Wasm32 最坏 50 ms，`ttf-parser` 在其中 2 个（`diamond_16e8` 复合字形菱形引用、`cmap_many_records` 900 条别名编码记录）上超时（> 10 s）。

红队（独立 Opus，多轮复审后 `SIGN-OFF`）：33 / 33 单测；0 P0 + 2 P1 + 12 P2 全部修复。`STRICT=1 sh packages/opentype/audit/run_audit.sh` `AUDIT PASS (0 P0)`、0 OPEN、exit 0：`cases` 16 / 16 × 4 模；152 个合成字体与 553 个系统字体面对 `ttf-parser 0.25.1` / `skrifa 0.44.0` 0 条未归因分歧；20,000 + 1,600 个变异输入 4 模一致无崩溃；19 个炸弹全部在预算内；`harness` 5 / 5 注入缺陷被捕获。`wasm_smoke` 4 模（native debug / native `--release` / wasm32 debug / wasm32 `--release`，125,592 / 141,784 / 79,678 / 80,092 B）stdout `66 B`，SHA-256 `c6ff6601c00f35604a1d44c21c8301f64a0ac68b62ac33594ae0ec0b168e2cda`（与包 README 一致）。

### hls

参考实现：Rust [`m3u8-rs`](https://crates.io/crates/m3u8-rs) `6.0.1`（`--release --locked`，记作 `rust_m3u8_rs`），锁定 `bench/rust_bench/Cargo.lock`。环境：Apple M5 Max (Darwin arm64)，`pionc 0.1.0`，`--release`。`m3u8-rs` 是宽松解析器而非校验器，Rust 端自行计算隐式字节范围偏移；两端输出相同字段子集的摘要。差分（`bench/diff_oracle.py`）：200 个合成合法 Master、Media（VOD / EVENT、显式与隐式 `BYTERANGE`、`KEY`、`MAP`、`DISCONTINUITY`）与 LL-HLS 播放列表，**0 / 2,350** 字段记录偏差。

#### 主语料：`bench/gen_corpus.py`（70 个播放列表 × 50 次，3,500 次解析，21,627,600 B）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_m3u8_rs`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_hls`（`--release`） | **97.242** | 96.304 | 98.990 | 222.41 | 27783.31 | 4.03 MiB | **1.39x** |
| `rust_m3u8_rs`（`6.0.1 --release`） | 134.893 | 134.446 | 136.028 | 160.33 | 38540.90 | **3.52 MiB** | 1.00x (baseline) |

stdout 71 B，SHA-256 `79b0e9cdc47d0b92698be972697b6d660bd8896edbf6cfc2f20e08b790d3bcce`（两端全部轮次一致）。

#### 现实语料：`audit/diff/altbench.py`（60 个播放列表 × 5 次，300 次解析，42,287,085 B）

长绝对 URL、每个分片带 `EXT-X-PROGRAM-DATE-TIME`、每 10 个分片 AES-128 密钥轮换（含 `IV`）、显式字节范围与更大的 Master；只使用两端处理一致的特性。

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_m3u8_rs`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_hls`（`--release`） | 126.932 | 126.468 | 130.474 | 333.15 | 423106.53 | 27.44 MiB | 0.91x |
| `rust_m3u8_rs`（`6.0.1 --release`） | **115.993** | 114.931 | 118.008 | 364.57 | 386641.67 | **13.77 MiB** | 1.00x (baseline) |

SHA-256 `5435f14cac58923a0ea773283d88c4212c0bd043e4e3d5f1150582c4e6a482e4`（两端全部轮次一致）。

如实说明：主语料领先 **1.39x**，峰值 RSS 略高（4.03 vs 3.52 MiB）；现实语料落后（**0.91x**），峰值 RSS 约为 Rust 的 2 倍（27.44 vs 13.77 MiB），原因是本包执行完整 RFC 8216bis 严格校验、ISO 8601 日期校验并保留逐分片元数据，而 `m3u8-rs` 不做这些校验。包 README 记录的上一次测量为主语料 1.35x、现实语料 0.84x，与本次同机复测方向一致。

红队（独立 Opus，多轮复审后 `SIGN-OFF`）：13 / 13 单测；1 P0 + 6 P1 + 14 P2 共 21 项全部修复。`STRICT=1 sh packages/hls/audit/run_audit.sh` `no open findings`、exit 0：红队 + 对照用例 28 / 28 × 4 模；4,280 个输入（260 命名 + 4,020 种子与变异）对独立 RFC 8216bis 参考模型 0 条未解释偏差；命名、变异、API 与 DoS 输出 4 模逐字节一致；18 个 DoS 炸弹在 native 与 Wasm32 `--release` 上全部在预算内；5 / 5 注入缺陷被捕获。`wasm_smoke` 4 模（native debug / native `--release` / wasm32 debug / wasm32 `--release`）stdout SHA-256 `ccb403999c3dd751365666e2813bb49a01ea55e6fd3bfe0c34a52f4ebb4fb933`（与包 README 一致），Wasm32 debug / `--release` 实测 239,459 / 237,733 B。

### dash

参考实现：Rust [`dash-mpd-core`](https://crates.io/crates/dash-mpd-core) `=0.1.0`（`dash-mpd 0.21.0` 的核心 MPD 解析 crate，`--release --locked`，记作 `rust_dash_mpd`），锁定 `bench/rust_bench/Cargo.lock`。环境：Apple M5 Max (Darwin arm64)，`pionc 0.1.0`（`AFK-surf/pion@1e609a5`），`--release`；发布复测时机器负载较高（load average ≈ 19）。`dash-mpd-core` 是宽松解析器，不做 XML 1.0 与 xs 词法严格校验；两端输出相同字段子集的摘要。差分（`sh packages/dash/bench/run_bench.sh` 的 parity 段，`iters=0`）：60 个合成 MPD（15 个静态 `SegmentBase`、15 个动态 `SegmentTemplate` + `SegmentTimeline`、15 个多 `Period` Widevine / PlayReady `cenc:pssh` DRM、15 个 `SegmentList`）在 `MPD` / `Period` / `AdaptationSet` / `Role` / `ContentProtection` / `SegmentTemplate` / `SegmentTimeline` / `Representation` / `SegmentBase` / `SegmentList` 上逐字段比对，**60 / 60 一致，0 偏差**。

#### 主语料：`bench/gen_data.py`（60 个 MPD × 200 次，12,000 次解析，23,996,400 B）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_dash_mpd`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_dash`（`--release`） | **212.539** | 189.593 | 226.348 | 112.90 | 17711.61 | **2.94 MiB** | **1.30x** |
| `rust_dash_mpd`（`0.1.0 --release`） | 277.300 | 247.499 | 284.851 | 86.54 | 23108.36 | 8.61 MiB | 1.00x (baseline) |

stdout 54 B，SHA-256 `a3b2d1251c237963f906d078a0d9db5daf1b579f080af22dc3753e1412cae7ba`（两端全部轮次一致）。

#### 现实语料：`audit/diff/altbench.py`（12 个 MPD，1,078,211 B）

多 `Period` 插播广告、Widevine + PlayReady `pssh`、2 小时 `SegmentTimeline`、带令牌的长 URL；由 `STRICT=1 sh packages/dash/audit/run_audit.sh` 的 `bench` 段产出。

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_dash_mpd`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_dash`（`--release`） | **334.877** | 318.330 | 449.944 | 64.39 | 1395321.00 | **9.80 MiB** | **1.18x** |
| `rust_dash_mpd`（`0.1.0 --release`） | 395.973 | 386.542 | 438.451 | 54.46 | 1649887.85 | 15.39 MiB | 1.00x (baseline) |

SHA-256 `8491d0142aa2faeb74a3f6c6b6e82a44ef9042b0caf4762d4b367042c3aea3d8`（两端全部轮次一致）。

如实说明：两组语料均领先且峰值 RSS 更低（主语料 2.94 vs 8.61 MiB，现实语料 9.80 vs 15.39 MiB），但 `pion_dash` 的 P95 在现实语料上高于 Rust（449.944 vs 438.451 ms），绝对吞吐也明显低于包 README 记录的低负载测量（131.13 MB/s、1.31x）。本次为高负载下的同机复测，审计 `bench` 段同时复测主语料为 1.35x / 111.6 MB/s；红队 `SIGN-OFF` 记录的低负载测量为主语料 1.39x、现实语料 1.96x，倍率随负载波动，方向一致。

红队（独立 Opus，多轮复审后 `SIGN-OFF`）：26 / 26 单测；1 P0 + 6 P1 + 11 P2 共 18 项全部修复。`STRICT=1 sh packages/dash/audit/run_audit.sh` `no open findings`、exit 0：红队 + 对照用例 28 / 28 × 4 模；2,225 个 MPD（225 命名 + 2,000 种子与变异）与 387 个 API 向量对独立参考模型 0 条未解释偏差；XML 层对 `pyexpat` 0 条分歧；命名、变异、API 与 `format_mpd` 输出 4 模逐字节一致；36 / 36 个 DoS 炸弹在 native 与 Wasm32 `--release` 上全部在预算内；5 / 5 注入缺陷被捕获。`wasm_smoke` 4 模（native debug / native `--release` / wasm32 debug / wasm32 `--release`）stdout SHA-256 `2ce81a010a29ef5fc9e0715fb3a1c7af049a3ebea6ed2c41549a1b08074ec625`（与包 README 一致），Wasm32 debug / `--release` 实测 226,079 / 219,335 B。

### lepton

参考实现：Rust [`lepton_jpeg`](https://crates.io/crates/lepton_jpeg) `0.5.8`（`--release`，`DEFAULT_THREAD_POOL` 多线程，记作 `rust_lepton_jpeg`）。环境：Linux `x86_64`（Debian 6.12.118-1，Intel Xeon Platinum 8581C），`pionc 0.1.0`（`--release`），`rustc 1.96.0`。由 `sh packages/lepton/bench/run_bench.sh`（`scripts/bench_compare.py`，`--warmup 1 --rounds 5` 严格交替）生成确定性 512×512 基线 RGB（`SOF0`，50,288 B）与渐进式灰度（`SOF2`，44,142 B）JPEG；每轮向 stdout 输出还原后的完整 JPEG 字节流并与原图 SHA-256 逐字节比对一致。

#### Baseline 512×512 RGB JPEG (`SOF0`, 50,288 B) 往返 ×10（502,880 B）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_lepton_jpeg`) | Compressed Size |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_lepton`（`--release`，单线程） | 446.070 | 294.785 | 664.138 | 1.13 | **4.89 MiB** | 0.48x | 37,509 B (−25.41%) |
| `rust_lepton_jpeg`（`0.5.8 --release`，多线程） | **212.924** | 170.263 | 281.221 | **2.36** | 8.71 MiB | 1.00x (baseline) | **36,349 B (−27.72%)** |

stdout 50,288 B，SHA-256 `7e9035d180b1c0be324c85c16b4048a7500c10b2c65d71e11ac903945216689d`（两端全部轮次与原图逐字节一致）。

#### Progressive 512×512 Luma JPEG (`SOF2`, 44,142 B) 往返 ×10（441,420 B）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_lepton_jpeg`) | Compressed Size |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_lepton`（`--release`，单线程） | 385.331 | 331.269 | 859.268 | 1.15 | **4.58 MiB** | 0.68x | 33,267 B (−24.64%) |
| `rust_lepton_jpeg`（`0.5.8 --release`，多线程） | **262.010** | 172.908 | 319.787 | **1.68** | 8.26 MiB | 1.00x (baseline) | **32,551 B (−26.26%)** |

stdout 44,142 B，SHA-256 `ae6a32d2b290b90721081c6723ac8e17660aaaf467d279735d59fe5e2b11839d`（两端全部轮次与原图逐字节一致）。

#### Baseline 512×512 RGB JPEG (`SOF0`, 50,288 B) 解码 ×10（502,880 B）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_lepton_jpeg`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_lepton`（`--release`，单线程） | 216.703 | 176.899 | 329.129 | 2.32 | **4.30 MiB** | 0.72x |
| `rust_lepton_jpeg`（`0.5.8 --release`，多线程） | **155.921** | 121.523 | 251.847 | **3.23** | 8.13 MiB | 1.00x (baseline) |

stdout 50,288 B，SHA-256 `7e9035d180b1c0be324c85c16b4048a7500c10b2c65d71e11ac903945216689d`（两端全部轮次与原图逐字节一致）。

如实说明：单线程纯 Pion `lepton` 在三项吞吐上均落后多线程 Rust `lepton_jpeg`（`0.48x`–`0.72x`），压缩率相差 1.6–2.3 个百分点（基线 −25.41% vs −27.72%，渐进 −24.64% vs −26.26%）；由于 `rust_lepton_jpeg` 使用 `DEFAULT_THREAD_POOL`（多线程），其峰值 RSS 与多核加速比会随线程数与共享 Linux VM 负载波动（Pion 峰值 RSS 约低 1.3–1.9×，本次实测 4.30–4.89 MiB vs 8.13–8.71 MiB）。`wasm_smoke` 4 模（native debug / native `--release` / wasm32 debug / wasm32 `--release`）输出 `lepton_wasm_smoke: OK checks=4 base=151 prog=1201 fnv64=979157046982172007`，SHA-256 `311e4623416b52a481bfadd5dcf1d1e37a4dd03df06ac336fc2fde7e0bbe60c0` 全部一致。

### bzip2

参考实现：Rust [`bzip2`](https://crates.io/crates/bzip2) `0.6.1`（锁定 `libbz2-rs-sys` `=0.2.7` 后端，`--release`，记作 `rust_bzip2`；编码器金标测试另对齐 `libbz2-rs-sys 0.2.3`）。环境：Intel Xeon Platinum 8581C（`Linux x86_64`），`pionc 0.1.0 (amd64_sysv, self-hosted)` `--release`，`rustc 1.96.0`。`sh packages/bzip2/bench/run_bench.sh`（`scripts/bench_compare.py`，`--warmup 1 --rounds 5` 严格交替）。输入为确定性生成的 768 KiB（`786,432 B`）结构化 JSON/HTTP 日志语料；基准前先做全量字节 SHA-256 校验，压缩输出（`786,432 B → 34,946 B`，`sha256:d4cb2a2a092f2c02...`）与解压输出（`34,946 B → 786,432 B`，`sha256:ea091dc1e46ec9ab...`）两端均逐字节一致。

#### 1. L6 压缩（768 KiB × 3 = 2,359,296 B）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_bzip2`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_bzip2`（`--release`） | 656.495 | 518.935 | 1252.113 | 3.59 | 15.34 MiB | 0.41x |
| `rust_bzip2`（`0.6.1 --release`） | **269.012** | 259.422 | 386.063 | 8.77 | **7.77 MiB** | 1.00x (baseline) |

stdout 98 B，SHA-256 `07e5114911044ec15c475eca5f1bf25c341775bb97a9827a93c381a2c735b725`（两端全部轮次一致）。

#### 2. L6 解压（768 KiB × 10 = 7,864,320 B）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_bzip2`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_bzip2`（`--release`） | 267.268 | 220.058 | 348.702 | 29.42 | 8.79 MiB | 0.68x |
| `rust_bzip2`（`0.6.1 --release`） | **182.432** | 150.926 | 224.205 | 43.11 | **6.46 MiB** | 1.00x (baseline) |

stdout 94 B，SHA-256 `ccde469114e3ca2cddabfae68d2ee9c68bdea42889495e9d4119e3960495cff2`（两端全部轮次一致）。

如实说明：两项均落后 Rust——L6 压缩 **0.41x**（主要在 BWT 块排序内循环，Peak RSS 15.34 vs 7.77 MiB），L6 解压 **0.68x**（Peak RSS 8.79 vs 6.46 MiB）。12 / 12 单测通过；`wasm_smoke` 4 模（native debug / native `--release` / wasm32 debug / wasm32 `--release`）stdout SHA-256 `3e8ba80c873e78ff09aa9f9cdc8c6dde0b9aeb3ecc48890e141b6594a6594de4` 逐字节一致。

### preflate

参考实现：Rust [`preflate-rs`](https://crates.io/crates/preflate-rs) `0.7.6`（`--release`，记作 `rust_preflate_rs`）。环境：Linux x86_64（AMD Ryzen 7 PRO 8845HS），`pionc 0.1.0 --release`。负载：由 `sh packages/preflate/bench/run_bench.sh` 确定性生成 `964,166 B`（~942 KiB）合成重复结构化 JSON/日志明文语料，经 Python `zlib`（`wbits=-15`）压缩为 L1 / L6 / L9 原始 DEFLATE 流；每轮执行 `3` 次完整 `analyze` + `reencode` 往返（共处理 `2,892,498 B` 明文），并将重建的原始 DEFLATE 流写至 stdout，由 `scripts/bench_compare.py`（`--warmup 1 --rounds 5`，严格交替）强制校验与原始 DEFLATE 流 SHA-256 逐字节一致。

#### zlib L1（186,902 B DEFLATE，× 3 = 2,892,498 B 明文）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Corrections | Speedup (vs `rust_preflate_rs`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion`（`--release`） | 90.985 | 87.427 | 100.869 | 31.79 | **7.04 MiB** | 57 B (0.03%) | 0.51x |
| `rust_preflate_rs`（`0.7.6 --release`） | **46.661** | 46.158 | 47.482 | 61.99 | 7.56 MiB | **28 B** (0.01%) | 1.00x (baseline) |

stdout `186,902 B`，SHA-256 `751431aadfa8321968d213859d618ed38f5c3a45b1fc97b5ae668770d5254a18`（与原始 DEFLATE 及两端全部轮次逐字节一致）。

#### zlib L6（151,737 B DEFLATE，× 3 = 2,892,498 B 明文）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Corrections | Speedup (vs `rust_preflate_rs`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion`（`--release`） | 164.980 | 159.876 | 176.674 | 17.53 | **6.96 MiB** | **46 B** (0.03%) | 0.50x |
| `rust_preflate_rs`（`0.7.6 --release`） | **82.277** | 80.235 | 101.630 | 35.16 | 7.59 MiB | 7,166 B (4.72%) | 1.00x (baseline) |

stdout `151,737 B`，SHA-256 `d2c58f601a6a2bdbd1f893c5de3a42f1f17f587069d11f0f5780b6d5321025eb`（与原始 DEFLATE 及两端全部轮次逐字节一致）。

#### zlib L9（136,769 B DEFLATE，× 3 = 2,892,498 B 明文）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Corrections | Speedup (vs `rust_preflate_rs`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion`（`--release`） | 468.736 | 447.986 | 566.958 | 6.17 | **6.87 MiB** | **46 B** (0.03%) | 0.24x |
| `rust_preflate_rs`（`0.7.6 --release`） | **112.447** | 108.326 | 157.295 | 25.72 | 7.38 MiB | 8,744 B (6.39%) | 1.00x (baseline) |

stdout `136,769 B`，SHA-256 `8ca8b1c8a544151b6295829abddef3f9deef3af7a9d361096e9766ff46af4d20`（与原始 DEFLATE 及两端全部轮次逐字节一致）。

如实说明：吞吐方面三档均落后 Rust `preflate-rs 0.7.6`（L1 **0.51x**、L6 **0.50x**、L9 **0.24x**），主要差距在于纯 Pion 标量哈希链查找在深链（L6 / L9）上的循环开销；峰值 RSS 三档均略低于 Rust（**6.87–7.04 MiB** vs 7.38–7.59 MiB）；修正流紧凑度方面，在该合成重复 JSON 日志语料上 L6 / L9 仅 **46 B**（0.03%），分别比 `preflate-rs` 的 7,166 B / 8,744 B 小 **155.8×** 与 **190.1×**（L1 为 57 B vs 28 B；真实异构语料下的压缩比会随上游压缩器家族与熵分布变化）。`wasm_smoke` 4 模（native debug / native `--release` / wasm32 debug / wasm32 `--release`）stdout `318 B`，SHA-256 `d8af29f4fc481ddc1bc36529945e7df6d1c5ec86e80c724da7933ddc3244753f` 逐字节一致。

### idna

参考实现：Rust [`idna`](https://crates.io/crates/idna) `=1.1.0`（`--release`，LTO，记作 `rust_idna`），锁定 `bench/rust_bench/Cargo.lock`。环境：Apple M5 Max (Darwin arm64)，`pionc 0.1.0`（`AFK-surf/pion@1e609a5`），`--release`；`sh packages/idna/bench/run_bench.sh` 复测时 load average ≈ 6。工作量：每组 200 个域名 × 200 次，每次 `to_ascii` + `to_unicode`，共 80,000 次操作。差分先行：`bench/run_bench.sh` 的 258 例全选项差分语料（`url` 与 `strict_hyphens` 两组选项，`to_ascii` 输出 + `to_unicode` 有效性与输出）对 Rust `idna 1.1.0` **258 / 258 逐字节一致、0 偏差**。

#### 语料 1：多语种 IDN（100% IDN / Punycode / NFD / 全角，649,000 B）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_idna`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_idna`（`--release`） | 77.321 | 60.707 | 108.474 | 8.39 | 966.52 | 2.48 MiB | 0.34x |
| `rust_idna`（`1.1.0 --release`，LTO） | **26.143** | 21.885 | 63.289 | 24.82 | 326.79 | **2.17 MiB** | 1.00x (baseline) |

stdout 88 B，SHA-256 `2c0f91c034c05db0125d616d557f0925e75817cb9684987aaf23452853673d1b`（两端全部轮次一致）。

#### 语料 2：真实浏览器流量（70% ASCII / 30% IDN 与 Punycode，722,000 B）

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_idna`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_idna`（`--release`） | 24.835 | 23.967 | 28.221 | 29.07 | 310.44 | 2.48 MiB | 0.79x |
| `rust_idna`（`1.1.0 --release`，LTO） | **19.740** | 18.999 | 20.335 | 36.58 | 246.75 | **2.11 MiB** | 1.00x (baseline) |

stdout 89 B，SHA-256 `fe08124d195da1027bb2c0a777a7085590492f2f1343a6502de21720e6127528`（两端全部轮次一致）。

如实说明：两组语料均落后 Rust `idna 1.1.0`，峰值 RSS 也略高（2.48 vs 2.11–2.17 MiB）。语料 1 本次复测抖动较大（两端 P95 均明显高于中位数）；同次发布中 `STRICT=1 sh packages/idna/audit/run_audit.sh` 的 `bench` 段独立复测为语料 1 **0.43x**（46.549 vs 19.796 ms）、语料 2 **0.70x**（16.952 vs 11.828 ms），包 README 记录为 0.46x / 0.71x。审计的第二语料 `audit/diff/altbench.py`（200 个 63 字节长标签、NFD 密集、A-label 为主、含 Bidi）为 **0.35x**（104.750 vs 36.581 ms，SHA-256 `08a305845bd57fa3e8af4d4f379eb8cd33335cb4f296a3aecdb4ce36399159b5`，REPORT.md `INFO-8`）。差距主要来自纯 Pion 标量 UTF-8 / NFC / 映射表查找与每个标签的 `String` 分配，Rust 侧为 ICU4X 预编译 trie 与 ASCII 快路径。`display_domain` / `skeleton`（UTS #39 防同形异义）无 Rust 对等实现，审计内仅测 Pion 自身：`display_domain_default` 519–1,937 ns/op、`skeleton` 726–801 ns/op。

红队（独立 Opus，多轮复审后 `SIGN-OFF`）：31 / 31 单测；6 P1 + 11 P2 共 17 项全部修复。`STRICT=1 sh packages/idna/audit/run_audit.sh` `no open findings`、exit 0：红队 + 对照用例 33 / 33 × 4 模；独立 Python 参考模型 191,710 项与 Rust `idna 1.1.0` 40,360 项检查 0 条未解释偏差；10,090 个输入的 `bidiSkeleton` 与完整 UAX #9 16.0 参考模型 100% 一致；20 / 20 个 DoS 炸弹在 native 与 Wasm32 `--release` 上全部在预算内（最坏 1 MB `skeleton` native 0.035 s / Wasm32 0.084 s）；7 / 7 注入缺陷被对照用例捕获。
