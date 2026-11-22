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

| Package | Version | Description | Upstream Reference | Native | Wasm32 | Benchmark |
| --- | --- | --- | --- | --- | --- | --- |

*(暂无已发布包，将随 Wave 1+ 陆续合入。)*

## 贡献与移植流程

详细规范见 [`AGENTS.md`](AGENTS.md)，核心步骤：

1. **Red 阶段**：在 `packages/<name>/` 下完整移植上游官方测试套件与测试向量 + API 桩代码，确认 `pionc check --json` 通过且 `pionc test --json` 失败。
2. **Green 阶段**：通读上游源码并以地道 Pion 实现，通过 Native `pionc test --json`、`pionc fmt --check` 与 `pionc build --target wasm32`。
3. **头对头基准**：在 `packages/<name>/bench/` 编写与上游参考实现同输入的基准，用 `python3 scripts/bench_compare.py` 跑预热 + 至少 5 轮严格交替采样并通过 SHA-256 逐字节一致门禁，结果同步至 [`BENCHMARKS.md`](BENCHMARKS.md)。
4. **注册索引**：在 `index/<name>.toml` 添加符合 `pion` `SPEC.md` §6 的 registry 条目，并更新 `pion.toml` 与本 README 表格。
5. **仓库快检**：运行 `sh scripts/verify.sh` 确认全仓格式化、检查、测试通过且 `git status --ignored` 干净。
