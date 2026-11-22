# `packages/semver` 红队审计报告（对标 `dtolnay/semver` `=1.0.28`）

- 被审对象：`origin/feat/pkg-semver` @ `390a500`（`packages/semver/src/**`，只读）
- 参照实现：Rust `semver = "=1.0.28"`（`audit/oracle_rust`，`--release`，`Cargo.lock` 生成在 `$AUDIT_OUT` 并核对为 `1.0.28`）
- 环境：`Darwin arm64`、`pionc 0.1.0 (arm64_apple, self-hosted)`、`rustc` stable
- 一键复现：`sh packages/semver/audit/run_audit.sh`（产物全部写在 `${AUDIT_OUT:-/tmp/pion-semver-audit}`，worktree 保持干净；`SKIP_PERF=1` 跳过性能段）。所有发现修好之前退出码为 `1`，修好后为 `0`。

## 总览

| 级别 | 编号 | 问题 | 证据 |
| --- | --- | --- | --- |
| **P0** | P0-1 | `major`/`minor`/`patch` 用 `Int64` 存，`9223372036854775808 ..= u64::MAX` 整段被拒（解析、格式化、`matches` 全部受影响） | 差分 1,488 例；`u64_range_test.pion` 3 个测试 FAIL |
| **P1** | P1-1 | `VersionReq.comparators` 是公开的可变 `Array`，但 `matches` 读的是解析时预算的区间缓存，push 或改写后结果错误 | `cache_coherence_test.pion` 4 个测试 FAIL |
| **P1** | P1-2 | `Version.pre`/`Version.build` 可以赋值，但 `pre_len`/`build_len` 缓存不跟着变，`to_string`、`compare`、`matches` 结果错误，甚至输出非法的 `1.2.0-` | `cache_coherence_test.pion` 3 个测试 FAIL |
| **P1** | P1-3 | Red 阶段移植时把上游断言 `exceeds u64::MAX` 改成了 `Int64::MAX`，违反 AGENTS.md §1.1「严禁弱化上游测试」；README 写的「100% compliance / exact diagnostic messages」不成立 | `version_test.pion:82` 对照上游 `tests/test_version.rs:58` |
| P2 | P2-1 | 错误信息里引用字符时没有按 Rust `char::escape_debug` 转义（`\u{1}`、`\u{7f}`、`\u{ad}`、`\u{301}`、`\u{200b}`、`\u{2028}`、`\u{feff}`、`\u{a0}` 等） | 差分 1,071 例；`p2_error_quotes_char_like_rust_debug` FAIL |
| P2 | P2-2 | 溢出错误文案写的是 `exceeds Int64::MAX`，上游是 `exceeds u64::MAX` | 差分 777 例；`p2_overflow_error_message_says_u64` FAIL |
| P2 | P2-3 | `Version::equals` 忽略 build，`Version::hash` 却混入 build，违反 Eq/Hash 契约；默认的 `compare` 是 `cmp_precedence` 语义，和 Rust `Ord` 不同 | `p2_equals_hash_contract`、`p2_default_compare_matches_rust_ord` FAIL |
| P2 | P2-4 | API 缺口：无法用一组 `Comparator` 构造 `VersionReq`（上游有 `FromIterator` 和公开结构体字面量）；没有 `cmp_precedence`、`EMPTY`/`STAR` 常量、`Debug` 格式和 serde | 代码审阅 |
| P2 | P2-5 | 性能弱项：32 个 comparator 的复杂 req 解析只有 Rust 的 **0.58x**，「解析 + matches」只有 **0.34x**；长 prerelease 解析 0.82–0.84x | §4 |
| P2 | P2-6 | `bench/` 公平性：Rust 依赖没锁版本（`semver = "1"`，也没提交 lockfile）；语料偏向快路径（req 最多 2 个 comparator，版本只取 500 条，没有 prerelease 密集 / 复杂 req / 脏输入）；排序算法不同 | §5 |

**已用证据确认正确、没有找到反例的部分**（下面有数字）：`390a500` 引入的预编译 O(1) 区间加单 major prerelease 过滤器，在 `Int64` 值域内跟上游**逐位一致**（2.96 亿次穷举 `matches` 加 8.1 万次随机 `matches`）。此外，解析语法（除 P0/P2 列出的情况）、`Prerelease`/`BuildMetadata` 校验、`+001` 与 `+1` 的全序、32 个 comparator 上限、NUL/TAB/多字节字符引用、长输入的线性复杂度，都和上游一致。

---

## 1. 差分模糊测试（`tools/gen_corpus.py` + `src/main.pion` ↔ `oracle_rust`）

语料共 166,458 条，种子 `20261123`，可以用 `AUDIT_SEED`/`AUDIT_SCALE` 调整。每条输入都以 UTF-8 hex 编码，所以 NUL、空白和多字节字符都能原样传入。两边对每条输入输出一行，逐字节比较。

```
cases: 166458 (BuildMetadata::new=3030, Comparator::parse=16597, Comparator::matches=10000,
               VersionReq::matches=81072, Ord/cmp_precedence/Eq=20000, Prerelease::new=3030,
               VersionReq::parse=16597, Version::parse=16132)
mismatches: 3336
```

| API | 根因桶 | 不一致数 |
| --- | --- | ---: |
| `Version::parse` | u64 值域被拒（P0-1） | 120 |
| `VersionReq::parse` | u64 值域被拒（P0-1） | 448 |
| `Comparator::parse` | u64 值域被拒（P0-1） | 418 |
| `VersionReq::matches` | u64 值域被拒（P0-1） | 502 |
| `Version`/`VersionReq`/`Comparator::parse` | 溢出文案（P2-2） | 268 + 303 + 206 |
| `Version`/`VersionReq`/`Comparator::parse` | 字符转义（P2-1） | 358 + 380 + 333 |
| `Prerelease::new` / `BuildMetadata::new` / `Comparator::matches` / `Ord`+`cmp_precedence`+`Eq` | — | **0** |
| `VersionReq::matches`（`Int64` 值域内） | — | **0** |

典型反例（完整列表在 `$AUDIT_OUT/diff_report.txt`）：

```
input: '9223372036854775808.0.0'                       (Version::parse)
  pion: err|value of major version number exceeds Int64::MAX
  rust: ok|9223372036854775808.0.0||
input: '^9223372036854775806.0.0' | '9223372036854775808.0.0'   (VersionReq::matches)
  pion: verr|value of major version number exceeds Int64::MAX
  rust: 0
input: '1.2.3\x7f'                                       (VersionReq::parse)
  pion: err|expected comma after patch version number, found '<0x7f 原始字节>'
  rust: err|expected comma after patch version number, found '\u{7f}'
input: '18446744073709551616.0.0'
  pion: err|value of major version number exceeds Int64::MAX
  rust: err|value of major version number exceeds u64::MAX
```

## 2. 预编译区间 / prerelease 过滤器专项（`tools/gen_matrix.py`，`matrix` 模式）

这是本次红队的重点攻击面，结论是**没有找到反例**。

| 矩阵 | comparator 值域 | 版本值域 | req 数 | 版本数 | `matches` 次数 | 结果 |
| --- | --- | --- | ---: | ---: | ---: | --- |
| small | 8 种 op × 全部形状（`M`、`M.m`、`M.*`、`M.m.*`、`M.m.p[-pre]`），数字 {0,1}，pre {"", `0`, `a`}；全部单个 comparator、全部有序二元组，外加 20 万个随机三元组 | {0,1,2}³ × pre {"", `0`, `a`, `b`, `a.0`} | 283,232 | 135 | 38,236,320 | 逐字节一致 `9c5021d9…` |
| max | 同上，数字换成 {0, `Int64::MAX-1`, `Int64::MAX`} | {0,1,`MAX-1`,`MAX`}³ × 5 种 pre | 806,440 | 320 | 258,060,800 | 逐字节一致 `162965a4…` |

已覆盖的情况：多个不同 major 的 prerelease comparator（`pre_only_major` 退化为 −1）、空区间（`>1.0.0, <1.0.1`、`<0.0.0`、`<0.0.0-0`）、`=1.0.0-alpha, >=1.0.0-alpha`、`^0.0.0-alpha`、`~0.0.0-alpha`、`1.*`/`0.*`/`0.0.*`、`<1.0.0-0`、`>=1.0.0-0, <2.0.0-0`，以及 `Int64::MAX` 上 `major+1`/`minor+1` 的饱和分支。这些情况在 `error_api_test.pion::control_prerelease_intersections` 里也作为 control 断言写了一遍。

**修 P0-1 时必须注意**：改成 `UInt64` 以后，`build_version_req` 里的 `max_i64` 哨兵和 `cmaj + 1L` 之类的饱和判断（`eval.pion` 中的 `Op::Greater` 分支和 `Op::Less` 分支的 `cmaj - 1L`）要整体换成 `u64::MAX`。修完重新跑 `run_audit.sh`：max 矩阵设 `MATRIX_NUMS="0,18446744073709551614,18446744073709551615"`，P0 测试里的 `^18446744073709551615.0.0`、`~0.18446744073709551615` 已经覆盖了上溢边界。

## 3. 测试清单（`pionc test --json packages/semver/audit`，当前 9/23 PASS）

断言写的都是**上游的正确行为**：发现没修时 FAIL，修好后自动 PASS。`control_*` 是对照项，当前应该 PASS。

| 文件 | 测试 | 当前 |
| --- | --- | --- |
| `u64_range_test.pion` | `p0_u64_version_parse_roundtrip`、`p0_u64_req_and_comparator_parse_roundtrip`、`p0_u64_matches_no_overflow_at_major_plus_one` | FAIL |
| | `p2_overflow_error_message_says_u64` | FAIL |
| | `control_int64_max_still_works` | PASS |
| `cache_coherence_test.pion` | `p1_req_push_comparator_is_honoured`、`p1_req_assign_comparator_is_honoured`、`p1_req_built_from_star_plus_comparators`、`p1_req_replace_prerelease_comparator` | FAIL |
| | `p1_version_pre_assignment_is_honoured`、`p1_version_build_assignment_is_honoured`、`p1_version_clear_pre_is_honoured` | FAIL |
| | `control_req_replace_comparator_slow_path_is_live`、`control_parsed_req_unmodified_is_correct` | PASS |
| `error_api_test.pion` | `p2_error_quotes_char_like_rust_debug`、`p2_equals_hash_contract`、`p2_default_compare_matches_rust_ord` | FAIL |
| | `control_error_quotes_already_matching`、`control_compare_full_and_equals_exact`、`control_prerelease_intersections` | PASS |
| `dos_test.pion` | `control_10k_segment_prerelease_roundtrip_and_order`、`control_100kb_single_identifier`、`control_33_comparators_rejected_32_accepted` | PASS |

### P1-1 复现（`VersionReq` 缓存失效）

```pion
let req = parse_req(">=1.0.0")          // 预算区间 [1.0.0, MAX]
req.comparators.push(parse_comparator("<0.5.0"))
req.to_string()                          // ">=1.0.0, <0.5.0"
req.matches(parse_version("1.2.0"))      // Pion: true    dtolnay: false

let r = VersionReq::star()               // 目前唯一能用代码拼 req 的途径
r.comparators.push(parse_comparator("=2.0.0"))
r.matches(parse_version("1.0.0"))        // Pion: true（缓存仍然是 "*"）  dtolnay: false
```

影响：依赖策略、黑名单这类用代码拼出来的 req 会放行任何版本，这个影响和安全相关。修法有两种（二选一）：把 `comparators` 设为私有，再提供只读访问和 `VersionReq::from_comparators`；或者让 `matches` 不读缓存，比如在可变访问时作废缓存，或者按 `comparators.length()` 和内容指纹校验缓存。

### P1-2 复现（`Version` 缓存失效）

```pion
let mut v = parse_version("1.2.0")
v.pre = Prerelease::new("alpha")         // 上游文档里的惯用写法
v.to_string()                            // Pion: "1.2.0"    dtolnay: "1.2.0-alpha"
let mut w = parse_version("1.2.0-alpha")
w.pre = Prerelease::empty()
w.to_string()                            // Pion: "1.2.0-"（非法 SemVer）  dtolnay: "1.2.0"
```

## 4. DoS 与性能（`tools/gen_perf.py`，用 `scripts/bench_compare.py` 跑，warmup 1、5 轮严格交替，stdout SHA-256 一致）

| 场景 | Pion 中位数 (ms) | Rust 中位数 (ms) | 相对 Rust | RSS Pion / Rust |
| --- | ---: | ---: | ---: | --- |
| `long_pre_parse`：200 个版本，各含约 1 万段 prerelease 和 5 千段 build，×5 | 137.1 | 114.6 | 0.84x | 24.1 / 24.3 MiB |
| `scale_10k`：10 KB prerelease ×2000 | 34.4 | 33.7 | 0.98x | 1.8 / 2.0 MiB |
| `scale_100k`：100 KB ×200 | 35.0 | 29.1 | 0.83x | 2.2 / 2.2 MiB |
| `scale_1m`：1 MB ×20 | 34.6 | 28.2 | 0.82x | 5.7 / 4.8 MiB |
| `long_pre_cmp`：400 个约 5 千段的 prerelease 两两全序比较 ×20 | 513.1 | 574.1 | **1.12x** | 12.5 / 11.4 MiB |
| `req32_parse`：2 万条 32-comparator req，解析加格式化 ×3 | 246.3 | 143.9 | **0.58x** | 16.3 / 15.5 MiB |
| `req32_match_release`：解析加 `matches(1.5.5)` ×3 | 195.5 | 66.3 | **0.34x** | 16.3 / 15.5 MiB |
| `req32_match_pre`：解析加 `matches(1.5.5-alpha.3)` ×3 | 192.7 | 65.4 | **0.34x** | 16.3 / 15.5 MiB |
| `dirty_version`：10 万条脏输入 ×10 | 81.6 | 117.6 | **1.44x** | 11.2 / 10.6 MiB |
| `dirty_req`：10 万条脏输入 ×10 | 114.0 | 114.5 | 1.00x | 11.2 / 10.6 MiB |

- **复杂度**：总字节数固定（20 MB）时，10 KB、100 KB、1 MB 三档单标识符耗时持平（34.4 / 35.0 / 34.6 ms），说明是 O(N)，没有 O(n²)。1 万段 prerelease 能正确往返并排序，100 KB 数字标识符比较也正确（`dos_test.pion`）。
- **弱项**：复杂 req 的解析是瓶颈。`req32_match_*` 的耗时几乎全花在解析上（`matches` 本身是 O(1) 快路径），比 Rust 慢 2.9 倍。原因推测是每个 `Comparator` 的 `Prerelease::{ raw }` 以及 `Option[Int64]` 装箱和 RC 开销，Rust 用的是栈上 SSO `Identifier`。长 prerelease 解析慢 16–18%。
- **优势**：长 prerelease 全序比较和脏输入的拒绝路径比 Rust 快。

## 5. `bench/` 公平性审查

1. **依赖没锁版本**：`bench/rust_semver/Cargo.toml` 写的是 `semver = "1"`，也没提交 `Cargo.lock`。今天解析到的是 1.0.28，上游一发新版本，基准对象就跟着变了。应改成 `=1.0.28`。
2. **语料偏向快路径**：Bench 2 的 req 最多 2 个 comparator，版本只取前 500 条，其中约 22% 带 prerelease。`390a500` 的 O(1) 区间优化正好是针对这份语料做的。复杂 req（§4 的 0.58x / 0.34x）、prerelease 密集和脏输入都不在榜单里，所以 README 写的「0.79x–0.94x」不能代表最坏情况。建议把 §4 的场景并入 `BENCHMARKS.md`。
3. **排序算法不同**：Bench 1 里 Rust 用的是 `slice::sort`（稳定的 driftsort），Pion 是手写的三数取中快排加插入排序。因为是全序，输出一致，但两边不是同一种算法，测出的差距里混有算法差异，需要在报告里注明。
4. 两边都把读文件、进程启动算进计时（同机同输入），这一点是公平的；SHA-256 校验也确实做了。

## 6. 修复建议（按优先级）

1. P0-1 / P2-2 / P1-3：数字字段改为 `UInt64`，文案改为 `u64::MAX`，恢复上游的原始断言；`eval.pion` 里的哨兵按 §2 的说明同步修改。
2. P1-1 / P1-2：缓存字段和公开可变字段不能同时存在。要么把字段私有化并提供 getter、`with_pre`、`with_build`、`from_comparators`，要么让读取路径校验缓存。
3. P2-1：`quote_char_at` 改为实现 `char::escape_debug`：`is_grapheme_extended` 和 `!is_printable` 的字符转成 `\u{..}`，`"` 不转义。
4. P2-3：`hash` 和 `equals` 要配套；建议把 `compare`/`equals` 对齐 Rust 的 `Ord`/`Eq`（含 build），另外提供 `cmp_precedence`。
5. P2-5 / P2-6：优化 comparator 解析里的分配；锁定 bench 依赖版本，并补充对抗性语料。
