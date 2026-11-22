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
| [`markdown`](packages/markdown) | `0.1.0` | CommonMark 0.31.2 + GFM（表格、删除线、任务列表、自动链接）+ CJK 友好强调的 Markdown 解析与 HTML 渲染 | [`pulldown-cmark/pulldown-cmark`](https://github.com/pulldown-cmark/pulldown-cmark) `v0.13.1` (Rust, MIT) | 702 / 702 | ✅ `wasm_smoke` | [CommonMark 2.46 MB · GFM 2.50 MB](BENCHMARKS.md#markdown) | `pionc add markdown --registry https://github.com/AFK-surf/pion-packages.git` |
| [`texmath`](packages/texmath) | `0.1.0` | TeX 数学公式解析、KaTeX 兼容 MathML 序列化与 TeXbook 盒模型布局 IR | [`KaTeX/KaTeX`](https://github.com/KaTeX/KaTeX) `v0.19.1` (JavaScript, MIT) | 180 / 180 | ✅ `wasm_smoke` | [10,000 ops MathML](BENCHMARKS.md#texmath) | `pionc add texmath --registry https://github.com/AFK-surf/pion-packages.git` |
| [`mermaid`](packages/mermaid) | `0.1.0` | Mermaid 流程图 / 时序图 / 状态图 / 类图 / ER 图解析、Sugiyama 分层布局与 SVG 渲染 | [`mermaid-js/mermaid`](https://github.com/mermaid-js/mermaid) + [`dagrejs/dagre`](https://github.com/dagrejs/dagre) (JavaScript, MIT) | 137 / 137 | ✅ `wasm_smoke` | [解析 + 布局（稳态 / 冷启动）](BENCHMARKS.md#mermaid) | `pionc add mermaid --registry https://github.com/AFK-surf/pion-packages.git` |
| [`time`](packages/time) | `0.1.0` | 公历日期 / 时间 / 时间戳 / 有符号时长值类型，RFC 3339、RFC 2822、HTTP-date 与 ISO 8601 时长解析格式化 | [`BurntSushi/jiff`](https://github.com/BurntSushi/jiff) `0.2` (Rust, MIT/Unlicense) | 249 / 249 | ✅ `wasm_smoke` | [RFC 3339 200k · Civil 2M](BENCHMARKS.md#time) | `pionc add time --registry https://github.com/AFK-surf/pion-packages.git` |

全仓合计 **1,268 / 1,268** 单测通过（`sh scripts/verify.sh`）。

## 贡献与移植流程

详细规范见 [`AGENTS.md`](AGENTS.md)，核心步骤：

1. **Red 阶段**：在 `packages/<name>/` 下完整移植上游官方测试套件与测试向量 + API 桩代码，确认 `pionc check --json` 通过且 `pionc test --json` 失败。
2. **Green 阶段**：通读上游源码并以地道 Pion 实现，通过 Native `pionc test --json`、`pionc fmt --check` 与 `pionc build --target wasm32`。
3. **头对头基准**：在 `packages/<name>/bench/` 编写与上游参考实现同输入的基准，用 `python3 scripts/bench_compare.py` 跑预热 + 至少 5 轮严格交替采样并通过 SHA-256 逐字节一致门禁，结果同步至 [`BENCHMARKS.md`](BENCHMARKS.md)。
4. **注册索引**：在 `index/<name>.toml` 添加符合 `pion` `SPEC.md` §6 的 registry 条目，并更新 `pion.toml` 与本 README 表格。
5. **仓库快检**：运行 `sh scripts/verify.sh` 确认全仓格式化、检查、测试通过且 `git status --ignored` 干净。
