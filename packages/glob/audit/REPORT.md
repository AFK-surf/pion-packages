# `packages/glob` 红队审计报告

- 被审版本：`origin/main` `7a40e8f`（含性能提交 `d12eead`）
- 对照：Rust `globset 0.4.21`、`ignore 0.4.34`（`--release`，`oracle/Cargo.lock` 锁定）、`git 2.54.0 check-ignore`
- 环境：Darwin arm64（共享机，负载高），所以基准用 **user+sys CPU 时间**，不用墙钟
- 一键复现：`sh packages/glob/audit/run_audit.sh`（`--quick` 跑小基准）；单跑失败测试：`pionc test packages/glob/audit`

## 结论

**不能宣称与 `globset` + `ignore` 等价，也不能宣称全面快于 Rust。** 2.48× 只在字面量/扩展名快表能覆盖的规则集上成立；规则一旦落到 NFA，Pion 反被 Rust 超过 5–417 倍，编译最高慢 454 倍。

| 级别 | 编号 | 铁证 | 关键数字 |
|---|---|---|---|
| **P0** | G1 | `.gitignore` 一行写错，**整个文件解析失败**，所有规则失效 | 10 份文件 / 540 项检查，git 与 `ignore` 均正常 |
| **P0** | B1 | 复杂规则 `GlobSet` 编译超线性爆炸 | 5000 条：**21.9 s / 1285 MiB** vs Rust 48 ms / 59 MiB（454× / 21.9×） |
| **P0** | B2 | DFA 超 256 状态后退回宽位 NFA，匹配崩溃 | 200 条规则 **417×**；2000 条复杂规则 >26×（Pion 超时） |
| **P0** | T1 | 移植测试把上游断言**写反**，掩盖真实缺陷，违反 `AGENTS.md` §1.1 | 上游向量 124 条，3 条失败 |
| P1 | R2 | `?` 与 `[...]` 按码点匹配，上游和 git 都按**字节** | 4902 项分歧；`.gitignore` 14 项 Pion 独错 |
| P1 | R1 | `{**/}` 在 `GlobSet` 里匹配一切，与自家 `Glob` 矛盾 | 单规则 1980 项假阳性 |
| P1 | B3 | 命中结果用插入排序去重，多命中时 O(k²) | 3000 条全命中 **27×** |
| P1 | B4 | `ByteTrie` 每节点 128 槽，内存膨胀 | 2 万条长前缀 792 MiB vs 145 MiB（5.5×） |
| P2 | R3 | README 称完整兼容，但 POSIX 类是上游没有的扩展 | 2903 项分歧（git 支持，见下） |
| P2 | A1 | API 缺口：`Candidate`、Builder、`GlobMatcher` 等 | 见 §4 |
| P2 | R5 | `*.` 匹配 `..` 时单 `Glob` 与上游不同 | 11 项 |

### 需要指挥官注意：任务书有一条前提被实测推翻

任务书要求「`?` 必须匹配单个 Unicode 标量值」。**真实 `globset` 和 git 都不是这样**：`?` 匹配单**字节**，所以 `?` 不匹配 `中`，`???` 才匹配。Pion 的码点语义恰恰是偏离点。本报告按真实行为断言（R2）。码点语义对用户可能更直观，但要保留就必须写明是有意偏离，不能再称兼容。

## 1. 正确性铁证

差分规模：298 模式 × 208 路径 × 10 组选项 = 619,840 项，另有 400 组多模式集合 24,000 项；`.gitignore` 180 份 × 54 路径 = 9,720 项，三方对照。明细在 `$AUDIT_OUT/diff/diff_divergences.txt`。`tests/redteam_test.pion` 共 29 个测试，期望值全部由 `gen_redteam.py` 从真实 oracle 读出，**当前 29 个全部失败**。

### G1（P0）一行坏规则杀死整个 `.gitignore`
`src/gitignore.pion:284` 遇到编译错误直接 `return Err`。git 把坏行当作不匹配，`ignore` 跳过坏行并继续。

```text
foo
[z-a]        # 或 {bad、bar}、行尾 \
```
git 与 `ignore`：`foo` 被忽略。Pion：`parse_gitignore` 返回 `Err`，没有任何规则可用。测试：`g1_*`（6 个）。

### T1（P0）移植测试写反了上游断言
上游 `globset/src/glob.rs`：`matches!(matchslash4, "abc[/]def", "abc/def", SLASHLIT)`。
Pion `glob_test.pion:509`：`check_nmatch("abc[/]def", "abc/def", opt_litsep())`。

实现在 `src/nfa.pion:532` 禁止字符类匹配 `/`，测试被改成与实现一致，于是全绿。上游向量回放失败 3 条：`matchslash4`、`class_includes_separator`、`class_separator_range`。

修复时要注意：**`.gitignore` 场景下 git 的行为与 Pion 现状相同**（`a[/]b` 不匹配 `a/b`），是 `ignore` 与 git 不一致。所以应修 `GlobOptions` 语义，并单独决定 `.gitignore` 走哪边，不能一刀切。

### R2（P1）码点语义 vs 字节语义
`src/nfa.pion:568` 先解码 UTF-8 再匹配；上游正则运行在 `(?-u)` 字节模式。

| 模式 | 路径 | globset | git | Pion |
|---|---|---|---|---|
| `?` | `中` | 否 | 否 | **是** |
| `???` | `中` | 是 | 是 | **否** |
| `[中]文` | `中文` | 否 | 否 | **是** |
| `[!a]` | `中` | 否 | — | **是** |

### R1（P1）`{**/}` 让 `GlobSet` 匹配一切
`src/globset.pion:797` 展开花括号后，分支变成单个 `RecursivePrefix`，命中 `src/nfa.pion:71` 的「整个 glob 是 `**`」特判，变成 `.*`。同一模式的 `Glob` 正确返回不匹配，集合却对所有路径返回匹配。

### R3（P2）POSIX 字符类
`globset` **没有** POSIX 类：`[[:digit:]]` 不匹配 `0`，反而匹配 `:]` 这类输入。Pion 实现了它，git 也支持。这对 `.gitignore` 是加分，对 `globset` 兼容是偏离。README 的「Full `BurntSushi/globset` syntax」需要改口。

## 2. 性能铁证

根因：
- **B1**：`src/nfa.pion:182` 为每个状态存完整闭包位图，内存 O(状态数²/64)；另有逐字节类签名和被放弃的子集构造。
- **B2**：`src/nfa.pion:291` 上限 256 状态，超出就丢弃 DFA，退回每字节 O(活跃状态 × 字宽) 的 `run_wide`；上游用惰性 DFA。
- **B3**：`src/globset.pion:922` 插入排序，多表结果拼接后接近最坏情况。
- **B4**：`src/fast_tables.pion:246` 每个 trie 节点固定 128 个 `Int`。

下表 `match` 阶段含编译时间。「stdout」为两边输出的 SHA-256 比对，超时项无法比对。

| workload | rules | phase | Pion | Rust globset | time Pion/Rust | RSS Pion/Rust | stdout |
|---|---:|---|---:|---:|---:|---:|---|
| complex_rules_100 | 100 | build | 30.4 ms / 7.3 MiB | 4.3 ms / 4.2 MiB | 7.12× | 1.73× | same |
| complex_rules_100 | 100 | match | 638.3 ms / 7.5 MiB | 129.6 ms / 18.5 MiB | 4.92× | 0.40× | same |
| complex_rules_500 | 500 | build | 319.9 ms / 38.2 MiB | 7.2 ms / 8.5 MiB | 44.22× | 4.51× | same |
| complex_rules_500 | 500 | match | 10663.0 ms / 38.3 MiB | 1200.5 ms / 151.6 MiB | 8.88× | 0.25× | same |
| complex_rules_2000 | 2000 | build | 3632.8 ms / 269.0 MiB | 20.5 ms / 25.4 MiB | 177.05× | 10.60× | same |
| complex_rules_2000 | 2000 | match | **TIMEOUT** (>30154 CPU ms, 269 MiB) | 1138.1 ms / 2139.2 MiB | >26.50× | 0.13× | n/a |
| complex_rules_5000 | 5000 | build | 21921.9 ms / 1285.0 MiB | 48.2 ms / 58.7 MiB | 454.46× | 21.88× | same |
| complex_rules_5000 | 5000 | match | **TIMEOUT** (>28882 CPU ms, 1285 MiB) | **OOM_GUARD** (>751 CPU ms, 6308 MiB) | >38.45× | 0.20× | n/a |
| complex_rules_500_cjk_paths | 305 | build | 175.0 ms / 25.8 MiB | 6.5 ms / 6.6 MiB | 27.08× | 3.89× | same |
| complex_rules_500_cjk_paths | 305 | match | 6782.1 ms / 25.9 MiB | 641.1 ms / 78.5 MiB | 10.58× | 0.33× | same |
| complex_rules_2000_cjk_paths | 1253 | build | 2198.4 ms / 190.4 MiB | 15.6 ms / 17.8 MiB | 140.75× | 10.67× | same |
| complex_rules_2000_cjk_paths | 1253 | match | 19152.4 ms / 190.4 MiB | 631.9 ms / 1041.2 MiB | 30.31× | 0.18× | same |
| long_prefix_2000 | 2000 | build | 28.2 ms / 148.0 MiB | 13.5 ms / 16.6 MiB | 2.09× | 8.91× | same |
| long_prefix_2000 | 2000 | match | 30.8 ms / 148.6 MiB | 14.2 ms / 16.6 MiB | 2.18× | 8.95× | same |
| long_suffix_2000 | 2000 | build | 19.1 ms / 78.8 MiB | 12.4 ms / 16.5 MiB | 1.53× | 4.79× | same |
| long_suffix_2000 | 2000 | match | 20.2 ms / 79.3 MiB | 13.2 ms / 16.5 MiB | 1.53× | 4.81× | same |
| long_prefix_20000 | 20000 | build | 315.7 ms / 792.5 MiB | 155.3 ms / 144.8 MiB | 2.03× | 5.47× | same |
| long_prefix_20000 | 20000 | match | 300.7 ms / 792.5 MiB | 126.0 ms / 144.8 MiB | 2.39× | 5.47× | same |
| long_suffix_20000 | 20000 | build | 172.8 ms / 702.2 MiB | 108.8 ms / 130.4 MiB | 1.59× | 5.38× | same |
| long_suffix_20000 | 20000 | match | 194.0 ms / 702.2 MiB | 110.5 ms / 130.4 MiB | 1.76× | 5.38× | same |
| all_rules_hit_3000x | 3000 | build | 7.6 ms / 6.1 MiB | 5.3 ms / 5.2 MiB | 1.45× | 1.16× | same |
| all_rules_hit_3000x | 3000 | match | 1901.7 ms / 6.1 MiB | 70.3 ms / 5.4 MiB | 27.04× | 1.13× | same |
| redos_star_a_x12_5k_path | 1 | build | 2.5 ms / 2.0 MiB | 2.5 ms / 2.4 MiB | 1.01× | 0.81× | same |
| redos_star_a_x12_5k_path | 1 | match | 4.8 ms / 5.5 MiB | 3.3 ms / 3.5 MiB | 1.45× | 1.59× | same |
| redos_star_a_x50_5k_path | 1 | build | 2.5 ms / 2.2 MiB | 2.3 ms / 2.7 MiB | 1.08× | 0.82× | same |
| redos_star_a_x50_5k_path | 1 | match | 2.9 ms / 2.6 MiB | 2.3 ms / 2.8 MiB | 1.24× | 0.91× | same |
| redos_doublestar_x12 | 1 | build | 2.0 ms / 2.2 MiB | 2.3 ms / 2.6 MiB | 0.87× | 0.84× | same |
| redos_doublestar_x12 | 1 | match | 2.6 ms / 2.5 MiB | 2.7 ms / 2.7 MiB | 0.95× | 0.91× | same |
| brace_bomb_20_groups | 1 | build | 2.4 ms / 2.1 MiB | 2.7 ms / 2.6 MiB | 0.89× | 0.80× | same |
| brace_bomb_20_groups | 1 | match | 2.8 ms / 3.0 MiB | 3.0 ms / 3.0 MiB | 0.92× | 1.01× | same |
| brace_bomb_nested_90 | 1 | build | 2.5 ms / 2.1 MiB | 2.7 ms / 3.3 MiB | 0.94× | 0.64× | same |
| brace_bomb_nested_90 | 1 | match | 3.0 ms / 3.1 MiB | 3.2 ms / 3.6 MiB | 0.92× | 0.86× | same |
| dfa_cap_blowup_x200 | 200 | build | 210.5 ms / 8.9 MiB | 4.5 ms / 5.4 MiB | 46.38× | 1.65× | same |
| dfa_cap_blowup_x200 | 200 | match | 4504.1 ms / 8.9 MiB | 10.8 ms / 6.1 MiB | 417.43× | 1.46× | same |

## 3. 已查无罪（如实记录）

这些攻击**没有**打出缺陷，不应再作为指控：

- **ReDoS**：`*a` ×50 配 5000 字节路径、`**/a/` ×12，与 Rust 同量级，线性。
- **花括号炸弹**：20 组 `{a,b}`（理论 100 万分支）与 90 层嵌套，无爆炸，耗时与 Rust 相当。
- **语法边界**：`[]a]`、`[!]]`、`[a-z-]`、`[--0]`、`[^a]`、未闭合类、`**` 边界、`///`、转义、`empty_alternates`，除上述根因外**零残余分歧**（`R9_residual = 0`）。
- **`case_insensitive`**：上游同样只折叠 ASCII，没有分歧。
- **`.gitignore` 基础语义**：尾随空格、`\#`、`\!`、CRLF、BOM、仅目录、父目录排除，未发现 Pion 独有错误。有 296 项是 **Rust `ignore` 与 git 不一致而 Pion 与 git 一致**，这是 Pion 的优势。另有 169 项 Pion 与 `ignore` 同样偏离 git（如 `{foo,bar}` 在 git 里是字面量），属继承行为。
- **内存**：复杂规则的匹配阶段 Pion RSS 反而更低（Rust 的 0.13–0.40×）。Rust 惰性 DFA 在 2000 条时用到 2.1 GiB，5000 条时超过本审计 6 GiB 保护线被杀。

## 4. API 差距（A1，P2）

`GlobBuilder` 的 5 个选项 Pion 全部具备。缺失项：

| 上游 | Pion |
|---|---|
| `Candidate::new` / `from_bytes`，`is_match_candidate`、`matches_candidate(_into)`、`matches_all_candidate` | 无，多个集合匹配同一路径时不能复用预处理 |
| `GlobSetBuilder`（增量 `add`） | 只能一次传数组 |
| `GlobMatcher` / `compile_matcher`，`Glob::regex()` | 无独立匹配器，无法查看编译结果 |
| `Error::glob()` / `kind()` | 有等价字段 |
| `GitignoreBuilder::add` / `add_line`、**部分错误返回** | 无（直接导致 G1） |
| `Gitignore::global()`、`gitconfig_excludes_path()` | 无 |
| `Match` 携带规则（`original`/`actual`/`from`/`is_only_dir`） | 只有行号 |

## 5. 未覆盖

- `GitignoreStack` 多层嵌套未与 git 做差分。
- `ignore` crate 的 `ignored!` 测试向量未回放（只回放了 `globset` 的 124 条）。
- 未在 wasm32 上跑对抗基准；未重新测量原 80 条规则的 2.48×。
- 共享机负载高，小于约 10 ms 的项以进程启动为主，倍率不具参考意义。

## 6. 交付物

| 文件 | 作用 |
|---|---|
| `tests/redteam_test.pion`（根目录软链 `redteam_test.pion`，因 `pionc test` 不扫描 `tests/`） | 29 个失败测试 |
| `gen_redteam.py` | 从真实 oracle 生成上述测试 |
| `differential.py` / `minimize_sets.py` | 差分矩阵 / 多模式最小化 |
| `upstream_vectors.py` | 回放上游向量，检测被写反的断言 |
| `adversarial_bench.py` | 对抗基准 |
| `oracle/`、`driver/` | Rust 对照程序、Pion 驱动 |
| `run_audit.sh` | 一键运行 |
