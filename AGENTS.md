# Working on `AFK-surf/pion-packages` (for agents)

`pion-packages` 是 Pion 生态标准外包与社区包的统一 Monorepo 及内置 Git-Index Registry。所有在本仓库中移植、开发、验收和发布包的 agent 必须严格遵守以下铁律。

## 1. 生态移植铁律（Non-Negotiable）

### 1.1 先移植测试（Red → Green）
每个包必须分两阶段验证（推荐拆分为独立提交或明确的两阶段日志证据）：
1. **Red 阶段**：先完整移植上游官方 spec / compliance / unit 测试套件、测试向量与公开 API 桩代码（占位实现），运行 `pionc check --json` 确认**编译通过**，再运行 `pionc test --json` 确认未实现前测试明确 **FAIL**。严禁先写实现再补测，严禁删减或弱化上游测试用例。
2. **Green 阶段**：通读上游参考源码后，用最适合 Pion 的方式实现，直至所有移植测试 100% 通过：
   - 零分配热路径优先；
   - 合理使用 `val struct`、`FixedArray[T]`、`Bytes`、`StringBuilder` 与 `mut` 参数；
   - 显式 `Result[T, E]` / `Option[T]` 错误处理，不滥用 `panic`；
   - 纯算法/数据结构/协议解析包**不依赖 `World`**，对外暴露的类型尽可能为不可变 `Send` 值。

### 1.2 双端验证（Native + Wasm32）
每个纯 Pion 包在验收前必须同时通过：
- **Native**：
  - `pionc fmt --check <pkg>`
  - `pionc check --json <pkg>`
  - `pionc test --json <pkg>`
- **WebAssembly**：
  - `pionc build --target wasm32` 编译检查通过（零错误；纯库包应提供可编译的 wasm32 入口或烟雾检查入口）。

### 1.3 客观头对头 Benchmark
- 每个包在 `packages/<name>/bench/` 下提供与上游参考实现（Rust `--release` / Go / C `-O2`/`-O3` / Node.js 等）**同机、同真实输入**的基准对比。
- 统一通过根目录 `scripts/bench_compare.py` 运行（至少 `--warmup 1 --rounds 5`，严格交替轮转顺序）。
- **强制 stdout SHA-256 逐字节一致校验**：所有参与对比的实现必须输出完全一致的 stdout 字节流；任何哈希不一致视为基准无效，必须立即修到一致，禁止输出伪造或跳过校验的榜单。
- 报告中位数（ms）、min、p95、吞吐（MB/s 或 ns/op）、峰值 RSS 与相对基线倍率。**如实记录领先与落后项**，禁止挑拣有利输入或隐瞒弱项，并将汇总同步到根目录 `BENCHMARKS.md`。

### 1.4 内置 Git-Index Registry
- 每个通过验收的包必须在 `index/<name>.toml` 注册，格式严格遵循 `AFK-surf/pion` `SPEC.md` §6：
  ```toml
  name = "<name>"
  version = "0.1.0"
  git = "https://github.com/AFK-surf/pion-packages.git"
  rev = "<commit-sha>" # 或 tag = "<name>-v0.1.0"（tag / rev / branch 至多选其一）
  subdir = "packages/<name>"
  ```
- 注册后必须实测下游项目可通过：
  ```sh
  pionc add <name> --registry https://github.com/AFK-surf/pion-packages.git
  ```
  正常解析、写入 `pion.lock` 并通过 `pionc check`。

### 1.5 零 worktree 污染
- 遵循 Pion 全局内容寻址缓存（`$PION_CACHE_DIR`，默认 `~/.cache/pion/cas`），严禁在仓库树内生成或提交 `target/`、`_build/`、临时二进制或基准缓存文件。
- 所有验证步骤结束后，`git status --ignored` 与 `git status --porcelain` 必须保持完全干净。

## 2. 仓库结构

```text
pion.toml               # 根 [workspace] 与 [registry] 清单
AGENTS.md               # 本文件（生态移植与验收铁律）
CLAUDE.md               # @AGENTS.md
README.md               # 项目说明、使用方式与包清单
BENCHMARKS.md           # 跨语言头对头基准总榜
index/<name>.toml       # Git-Index Registry 条目（遵循 pion SPEC.md §6）
packages/<name>/        # 独立 Pion 包（含 pion.toml, src/, *_test.pion, bench/）
scripts/verify.sh       # 统一快检脚本（fmt / check / test / git status）
scripts/bench_compare.py# 零依赖 Python 3 头对头基准与 SHA-256 校验框架
```

## 3. 常用验证命令

```sh
sh scripts/verify.sh                     # 全仓快检（fmt / check / test / clean worktree）
sh scripts/verify.sh packages/<name>     # 单包快检
python3 scripts/bench_compare.py --help  # 查看头对头基准框架参数
```
