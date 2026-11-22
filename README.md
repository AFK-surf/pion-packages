# pion-packages

Pion 生态包仓库与内置 Git-Index Registry（`AFK-surf/pion-packages`）。

每个包均以纯 Pion 实现（遵循零分配热路径、显式 `Result[T, E]`、纯逻辑无 `World` 依赖与 `Send` 值语义），配备移植自上游官方套件的完整测试、Native / Wasm32 双端验证，以及经 SHA-256 逐字节一致性校验的跨语言头对头基准对比。

## 使用方式

### 通过内置 Registry 添加包

在目标项目的 `pion.toml` 目录下直接执行：

```sh
pionc add <package-name> --registry https://github.com/AFK-surf/pion-packages.git
```

或在目标项目的 `pion.toml` 中配置默认 registry：

```toml
[registry]
url = "https://github.com/AFK-surf/pion-packages.git"
```

之后即可直接运行：

```sh
pionc add <package-name>
```

## 包清单

| Package | Version | Description | Upstream Reference | Tests (Native) | Wasm32 | Benchmark | Install |
| --- | --- | --- | --- | ---: | --- | --- | --- |
| [`markdown`](packages/markdown) | `0.2.1` | CommonMark 0.31.2 + GFM（表格、删除线、任务列表、自动链接）+ CJK 友好强调的 Markdown 解析与 HTML 渲染 | [`pulldown-cmark/pulldown-cmark`](https://github.com/pulldown-cmark/pulldown-cmark) `v0.13.1` (Rust, MIT) | 708 / 708 | ✅ `wasm_smoke` | [CommonMark 0.84× · GFM 0.85× · O(N²) DoS 消除](BENCHMARKS.md#markdown) | `pionc add markdown --registry https://github.com/AFK-surf/pion-packages.git` |
| [`texmath`](packages/texmath) | `0.2.0` | TeX 数学公式解析、KaTeX 兼容 MathML 序列化与 TeXbook 盒模型布局 IR | [`KaTeX/KaTeX`](https://github.com/KaTeX/KaTeX) `v0.19.1` (JavaScript, MIT) | 185 / 185 | ✅ `wasm_smoke` | [10,000 ops MathML · Native / Wasm32](BENCHMARKS.md#texmath) | `pionc add texmath --registry https://github.com/AFK-surf/pion-packages.git` |
| [`mermaid`](packages/mermaid) | `0.2.0` | Mermaid 流程图 / 时序图 / 状态图 / 类图 / ER 图解析、Sugiyama 分层布局与 SVG 渲染 | [`mermaid-js/mermaid`](https://github.com/mermaid-js/mermaid) + [`dagrejs/dagre`](https://github.com/dagrejs/dagre) (JavaScript, MIT) | 137 / 137 | ✅ `wasm_smoke` | [解析 + 布局 · 对抗布局 82–217×](BENCHMARKS.md#mermaid) | `pionc add mermaid --registry https://github.com/AFK-surf/pion-packages.git` |
| [`time`](packages/time) | `0.2.0` | 公历日期 / 时间 / 时间戳 / 有符号时长值类型，RFC 3339、RFC 2822、HTTP-date 与 ISO 8601 时长解析格式化 | [`BurntSushi/jiff`](https://github.com/BurntSushi/jiff) `0.2` (Rust, MIT/Unlicense) | 262 / 262 | ✅ `wasm_smoke` | [RFC 3339 200k · Civil 2M（typed / raw）](BENCHMARKS.md#time) | `pionc add time --registry https://github.com/AFK-surf/pion-packages.git` |
| [`toml`](packages/toml) | `0.2.0` | TOML v1.0.0 解析、序列化（保留插入顺序、IEEE 754 位精确浮点）与 `toml-test` tagged JSON 编码 | [`toml-lang/toml-test`](https://github.com/toml-lang/toml-test) `v1.0.0`；基准对照 Rust `toml` `0.8` / Go `BurntSushi/toml` `v1.4.0` | 729 / 729 | ✅ `wasm_smoke` | [150.5 KB 配置 × 50](BENCHMARKS.md#toml) | `pionc add toml --registry https://github.com/AFK-surf/pion-packages.git` |
| [`yaml`](packages/yaml) | `0.2.0` | YAML 1.2（Core Schema）多文档解析、锚点/别名/合并键、Billion Laughs 防护、发射器与规范化 JSON | [`yaml/yaml-test-suite`](https://github.com/yaml/yaml-test-suite)；基准对照 Rust `yaml-rust2` `0.10.4` / Go `yaml.v3` `v3.0.1` | 384 / 384 | ✅ `wasm_smoke` | [3.00 MB K8s/CI/OpenAPI 语料](BENCHMARKS.md#yaml) | `pionc add yaml --registry https://github.com/AFK-surf/pion-packages.git` |
| [`diff`](packages/diff) | `0.2.0` | Myers / Histogram 行 diff、缩进滑块后处理、unified diff 生成/解析/应用与三路合并 | [`pascalkuthe/imara-diff`](https://github.com/pascalkuthe/imara-diff) `v0.2.0` (Rust, Apache-2.0) | 143 / 143 | ✅ `wasm_smoke` | [Histogram · Myers · helix · HashDoS 对抗](BENCHMARKS.md#diff) | `pionc add diff --registry https://github.com/AFK-surf/pion-packages.git` |
| [`cbor`](packages/cbor) | `0.2.0` | CBOR（RFC 8949）编解码、Core Deterministic / CTAP2 规范编码、float16、诊断记法与 DoS/OOM 防护解码 | [`fxamacker/cbor`](https://github.com/fxamacker/cbor) `v2.9.0` (Go, MIT)；另对照 Rust `ciborium` `0.2` | 218 / 218 | ✅ `wasm_smoke` | [50k 编码 · 80k 解码](BENCHMARKS.md#cbor) | `pionc add cbor --registry https://github.com/AFK-surf/pion-packages.git` |
| [`crdt`](packages/crdt) | `0.2.0` | Yjs / YATA 协同 CRDT 引擎：`YText`（UTF-16 索引）/ `YArray` / `YMap`、Yjs Update v1 + lib0 二进制线协议兼容、状态向量增量同步、`merge_updates` / `diff_update` | [`yjs/yjs`](https://github.com/yjs/yjs) + [`dmonad/lib0`](https://github.com/dmonad/lib0) (JavaScript, MIT) | 132 / 132 | ✅ `wasm_smoke` | [vs `yjs` / `yrs` · append 200k · automerge trace](BENCHMARKS.md#crdt) | `pionc add crdt --registry https://github.com/AFK-surf/pion-packages.git` |
| [`highlight`](packages/highlight) | `0.2.0` | 24 种语言（含 Java、Kotlin、Swift、C#、PHP、Ruby、Dockerfile、Markdown）零正则回溯、逐行增量（`LineState`）语法高亮与 HTML 序列化 | [`PrismJS/prism`](https://github.com/PrismJS/prism) (JavaScript, MIT) | 216 / 216 | ✅ `wasm_smoke` | [HTML 端到端 6.67–15.55×](BENCHMARKS.md#highlight) | `pionc add highlight --registry https://github.com/AFK-surf/pion-packages.git` |
| [`glob`](packages/glob) | `0.2.0` | Glob / 多模式 `GlobSet`（字面量/扩展名/前后缀表 + 预乘 DFA）与完整 `.gitignore` 语义（含嵌套栈与父目录排除） | [`BurntSushi/globset`](https://github.com/BurntSushi/ripgrep/tree/master/crates/globset) `0.4` + `ignore` (Rust, MIT/Unlicense) | 188 / 188 | ✅ `wasm_smoke` | [50k 路径 × 80 规则 × 20 · 5000 规则编译](BENCHMARKS.md#glob) | `pionc add glob --registry https://github.com/AFK-surf/pion-packages.git` |
| [`websocket`](packages/websocket) | `0.2.0` | RFC 6455 Sans-IO WebSocket：Upgrade 握手（内置 SHA-1 / Base64）、帧编解码与掩码、流式分片重组、严格 UTF-8 与关闭码校验 | [`coder/websocket`](https://github.com/coder/websocket) `v1.8.14` (Go, ISC)；另对照 Rust `tungstenite` `0.26.2` | 186 / 186 | ✅ `wasm_smoke` | [大帧 1.63 GB/s · 小帧 / 分片风暴](BENCHMARKS.md#websocket) | `pionc add websocket --registry https://github.com/AFK-surf/pion-packages.git` |
| [`tar`](packages/tar) | `0.1.0` | USTAR / PAX / GNU（含 4 种 sparse）/ V7 / STAR TAR 流式读写，`Int64` 溢出安全、默认 `Limits` 防 PAX / sparse 炸弹，`clean_extract_path` 路径穿越防护 | Go `archive/tar`（Go 1.27.3 stdlib, BSD-3-Clause）；另对照 Rust `tar` `0.4.46` | 35 / 35 | ✅ `wasm_smoke` | [全量读 1.25× · 写 0.90×（vs Go）](BENCHMARKS.md#tar) | `pionc add tar --registry https://github.com/AFK-surf/pion-packages.git` |
| [`semver`](packages/semver) | `0.1.0` | SemVer 2.0.0 解析 / 全序 / 优先级比较与 Cargo `VersionReq` 约束匹配（完整 `u64` 值域、32 comparator 上限） | [`dtolnay/semver`](https://github.com/dtolnay/semver) `=1.0.28` (Rust, MIT/Apache-2.0) | 35 / 35 | ✅ `wasm_smoke` | [解析排序 0.38× · matches 0.27× · 复杂 req 1.06× · 脏输入 1.36×](BENCHMARKS.md#semver) | `pionc add semver --registry https://github.com/AFK-surf/pion-packages.git` |
| [`uuid`](packages/uuid) | `0.1.0` | RFC 9562 UUID（v1/v3/v4/v5/v6/v7/v8/Nil/Max，内置 MD5 / SHA-1）与 Crockford Base32 ULID（含单调生成器），零堆分配 128-bit `val struct` | [`uuid-rs/uuid`](https://github.com/uuid-rs/uuid) `1.29.3` + [`dylanhart/ulid-rs`](https://github.com/dylanhart/ulid-rs) `1.2.1` (Rust) | 20 / 20 | ✅ `wasm_smoke` | [UUID 批量 0.73× · v5+v7 0.66× · ULID 0.70×（raw）](BENCHMARKS.md#uuid) | `pionc add uuid --registry https://github.com/AFK-surf/pion-packages.git` |
| [`url`](packages/url) | `0.1.0` | WHATWG URL Standard 解析 / 相对解析 / setters、Unicode 16.0.0 UTS #46 IDNA + Punycode、IPv4/IPv6、percent-encoding 与 `QueryParams`（`URLSearchParams`） | [`servo/rust-url`](https://github.com/servo/rust-url) `2.5.9` (Rust, MIT/Apache-2.0) | 43 / 43 | ✅ `wasm_smoke` | [混合解析 1.05× · URLSearchParams 0.97×](BENCHMARKS.md#url) | `pionc add url --registry https://github.com/AFK-surf/pion-packages.git` |

全仓 16 个包合计 **3,621 / 3,621** 单测通过（`sh scripts/verify.sh`）。

### v0.2.0：红队对抗审计

`v0.2.0` 是全部 12 个包经红队对抗审计并修复后的版本。每个包都随附 `packages/<name>/audit/` 审计套件：失败即证据的红队测试、对上游参考实现的差分 / fuzz 脚本、DoS 探针、对抗性头对头基准与 `REPORT.md`（P0 / P1 / P2 发现与复现命令），可用 `sh packages/<name>/audit/run_audit.sh` 一键复现。审计套件不属于 workspace 成员，不计入上表的单测数。修复后的基准见 [`BENCHMARKS.md`](BENCHMARKS.md)。

### Wave 4：`tar` / `semver` / `uuid` / `url` `v0.1.0` 与 `markdown` `v0.2.1`

Wave 4 新增的 4 个包同样按 Red → Green → 红队审计 → 修复流程交付，首发即为红队修复后的版本，各自随附 `packages/<name>/audit/` 套件。`markdown` `v0.2.1` 为 P49 性能优化版（CommonMark 0.84×、Mixed GFM 0.85× 于 Rust `pulldown-cmark`，峰值 RSS 均低于 Rust）。

## 贡献与移植流程

详细规范见 [`AGENTS.md`](AGENTS.md)，核心步骤：

1. **Red 阶段**：在 `packages/<name>/` 下完整移植上游官方测试套件与测试向量 + API 桩代码，确认 `pionc check --json` 通过且 `pionc test --json` 失败。
2. **Green 阶段**：通读上游源码并以地道 Pion 实现，通过 Native `pionc test --json`、`pionc fmt --check` 与 `pionc build --target wasm32`。
3. **头对头基准**：在 `packages/<name>/bench/` 编写与上游参考实现同输入的基准，用 `python3 scripts/bench_compare.py` 跑预热 + 至少 5 轮严格交替采样并通过 SHA-256 逐字节一致门禁，结果同步至 [`BENCHMARKS.md`](BENCHMARKS.md)。
4. **注册索引**：在 `index/<name>.toml` 添加符合 `pion` `SPEC.md` §6 的 registry 条目，并更新 `pion.toml` 与本 README 表格。
5. **仓库快检**：运行 `sh scripts/verify.sh` 确认全仓格式化、检查、测试通过且 `git status --ignored` 干净。
