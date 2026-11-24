# 红队审计报告：Pion `packages/diff`（`281f5c1`） vs Rust `imara-diff v0.2.0`

- 被审对象：`origin/feat/opt-diff` @ `281f5c1`（`perf(diff): optimize interner, histogram, myers, and unified formatting`），只读，未改 `src/**`、原有测试或仓库根文件。
- 参照实现：crates.io `imara-diff = "=0.2.0"`（`harness/rust_oracle`，`--release`，`lto = true`，`codegen-units = 1`）。所有“期望值”都由这个真实 Rust 程序在同一输入上打印出来，没有手写期望。
- 机器：Apple M5 Max (Darwin arm64)，Darwin arm64（Apple M5 Max，18 核），跟 README 基准同一平台。**跑基准时机器负载 39–48**（别的会话在用），所以下面的倍率是严格交替测出来的相对值，绝对毫秒数有噪声。

## 一键复现

```sh
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
pionc test packages/diff/audit            # 18 个测试：13 个 p0_/p1_/p2_ 预期 FAIL（就是证据），5 个 ok_ 对照组预期 PASS
sh packages/diff/audit/run_audit.sh       # 构建 + 用 oracle 重新推一遍期望值 + 测试 + 5000 组差分 fuzz + merge3 对照 + 探针 + 对抗基准（约 3 分钟）
sh packages/diff/audit/run_audit.sh --quick   # 不跑基准，每族 200 组
```

结果写到 `/tmp/diff-redteam`（可传入其他目录），worktree 保持干净。

| 文件 | 作用 |
| --- | --- |
| `src/redteam_test.pion` | `pionc test packages/diff/audit` 的测试，由 `gen_redteam_tests.py` 从 oracle 生成（`run_audit.sh` 第 2 步会重新生成并逐字节比对） |
| `harness/rust_oracle` | 真实 `imara-diff 0.2.0`：`cases` / `bench` / `multi`（`InternedInput::update_after` 复用） |
| `harness/pion_runner` | 同一输出格式的 Pion 端：`cases` / `bench` / `multi` / `merge` |
| `fuzz.py` | 差分 fuzz：5 族 × 1000 组 × {Histogram, Myers} × {后处理 hunks `P`、原始 hunks `R`、Pion 非窗口 `diff_slices` 的 `S`、unified ctx 0/1/3/25}，并给 unified 不一致做归因 |
| `shrink.py` | 行级 delta-debugging 缩小器 |
| `merge_fuzz.py` | `merge3` vs `git merge-file -p`（imara-diff 没有三方合并） |
| `gen_adversarial.py` / `gen_hash_flood.py` / `bench_adversarial.sh` | 对抗语料与 `scripts/bench_compare.py` 头对头基准（`--warmup 1 --rounds 5`，强制 SHA-256 一致） |

> 偏离任务书的地方：任务书写的是 `audit/tests/redteam_test.pion`，但 `pionc 0.1.0` 只收集包根目录和 `src/` 里的 `*_test.pion`。实测放在 `tests/` 时 `pionc test packages/diff/audit` 一个审计测试都不跑，所以文件放在 `audit/src/redteam_test.pion`。另外确认过：`pionc test packages/diff`（136/136）、`sh scripts/verify.sh packages/diff`、全仓 `pionc test`（2716/2716）都不会扫进 `audit/`，结果不受影响。

## 总览

| 级别 | 编号 | 指控 | 关键证据 |
| --- | --- | --- | --- |
| **P0** | P0-1 | `intern_lines_windowed(margin=21)` 让 `diff_lines`/`unified_diff`/`merge3` 的结果跟 imara 不同，`hit_pre \|\| hit_suf` 回退没兜住 | 4 个失败测试；window 族 1000 组中，窗口路径 `diff_lines` 不一致的有 13 组（H）/ 14 组（M），而同一批输入的非窗口 `diff_slices` 只有 0 组 / 1 组不一致；20 万行真实形状文件的 unified 输出把 hunk 放错位置，尾部上下文从 3 行截成 1 行 |
| **P0** | P0-2 | `context >= 21` 时 `margin == ctx`，没有余量：尾部上下文被截短，unified 跟 Pion 自己的 `diff_lines` 也对不上 | 失败测试 `p0_unified_ctx25_trailing_context_truncated`；fuzz 中 558 次 unified 输出在 hunks 一致的情况下仍和 `diff_lines` 自相矛盾 |
| **P0** | P0-3 | 行哈希无种子、可逆：可以构造全 32 位碰撞，触发 HashDoS，插入退化成二次复杂度 | 1.44 MB 输入：Pion **2459 ms** vs imara **17.4 ms**（**141×**；另一轮 3833 vs 16 ms，235×）；对照组（同大小普通行）1.02× |
| **P1** | P1-1 | Myers 不是 imara 的忠实移植（3 处有意偏离），Histogram 的 >63 回退路径也跟着偏 | 3 个失败测试；`MR` 不一致：small 52、code 195、repeat 611 组（每族 1000 组）；Histogram `HR` 133/1000 |
| **P1** | P1-2 | README 写的 “100% byte-for-byte identical unified diff output” 只在那 3 个基准输入上成立 | 空侧头 `-0,0` vs `-1,0`、`\ No newline at end of file`，5000 组里 4413 组至少有一个 ctx 的 unified 输出不同 |
| **P1** | P1-3 | 性能弱项：边缘回退要算两遍（0.59×）、超长单行（0.52×）、没有 interner 复用（0.62×）、Myers 全量重写或分散修改（0.72×）、峰值 RSS 更高 | 见基准表 |
| **P2** | P2-1 | imara 首个 hunk 的上下文怪癖（imara 自己的 bug，Pion 的输出更正确），但字节上不一致 | `p2_unified_first_hunk_context_imara_quirk` |
| **P2** | P2-2 | `merge3` 的语义跟 `git merge-file` 不同（相邻编辑静默合并），并且继承了 P0-1 | 1000 组：55 组 Pion 判 clean 而 git 判冲突 |
| **P2** | P2-3 | API 能力缺口：没有 `MyersMinimal`、`InternedInput` 增量复用、通用 `TokenSource`、可插拔 `SliderHeuristic`/`UnifiedDiffPrinter` | 源码对比 |

此外有一节**反证**：Pion 明显赢 imara 的场景，如实列出，不隐瞒。

---

## P0-1 窗口化 interner 改变了 diff 结果，回退检查没兜住

**根因（源码级）。** `diff_lines` 和 `unified_diff` 先用字节级前后缀把文件裁成“中段 + 两侧各 21 行”的窗口（`src/lib.pion:134`、`src/unified.pion:75`），然后**只在窗口内**跑 `IndentHeuristic`。只有当最终 hunk 正好落在窗口第 0 行或最后一行时，才回退到全量重算（`src/lib.pion:155-156`、`src/unified.pion:95-96`）。但 imara 的打分函数 `Indents::at_token`（`imara-diff/src/slider_heuristic.rs:160-190`）会向上、向下各扫最多 `MAX_BLANKS = 20` 行空行，扫到序列边界时返回 `(token_idx, BLANK)`；`token_idx == tokens.len()` 时算作 `at_eof`，再加 `END_OF_FILE_PENALTY = 21`。在窗口里，“窗口边界”被当成了“文件边界”：

- 候选切分点离窗口起点不到 20 行、而且中间全是空行时，`prev_indent` 本该是窗口外那一行的缩进，窗口里算成了 `BLANK`；
- 靠近窗口尾部时，同样被当成 EOF 打分。

于是启发式在窗口内选中了另一个切分点。这个点**没碰到**第 0 行或最后一行，所以 `hit_pre || hit_suf` 不会触发，结果就静默地和 imara 不一样了。这类输入的触发条件是：变更旁边有 ≥20 行的空行（或纯空白行）连续段，并且这段空行跨过了窗口边界。

**证据 1：最小反例（25 行，Histogram 和 Myers 都中）**

```text
before = "    if x {\n    }\n" + "\n" * 23
after  = "    }\n" + "\n" * 22
imara diff_lines         : 0-1:0-0 23-24:22-22
Pion  diff_lines         : 0-1:0-0 22-23:21-21      <-- 窗口路径
Pion  diff_slices (全量) : 0-1:0-0 23-24:22-22      <-- Pion 自己的非窗口路径跟 imara 一致
```

测试：`p0_window_blank_suffix_histogram`、`p0_window_blank_suffix_myers`。

**证据 2：前缀侧**（`p0_window_blank_prefix_histogram`）：在 22 行空行后面删掉 3 行，imara 给 `20-23:20-20`，Pion 给 `21-24:21-21`；unified ctx=3 的头部和正文也随之不同。

**证据 3：真实形状的大文件（`gen_adversarial.py` 生成的 `edge_blank`，200,041 行）。** 改了第一行 `// v1 -> // v2`，同时在一段 40 行的空行里多加 1 行：

```text
imara:  @@ -100036,6 +100036,7 @@   （3 行前文 + 插入 + 3 行后文）
Pion :  @@ -100018,4 +100018,5 @@   （hunk 往上挪了 18 行，后文只剩 1 行）
```

hunk 滑进了被裁掉的后缀里，unified 的尾部上下文也就被窗口长度 `before_len = mid_b`（`src/unified.pion:130`）截断了。缩小版写进了测试 `p0_window_header_edit_plus_blank_run_unified`。在“只改首行 + 连续段内增删一行”的形状上枚举，连续段为空行或纯空格行的 1200 个变体中 **600 个**跟 imara 不同；连续段为非空白行（`    }`、`}`、`x`）的 1800 个变体全部一致，其中 900 个是靠全量回退才对上的。

**证据 4：fuzz 归因。** `window` 族（1000 组，前后各 15–45 行公共代码，夹着空行段）：`HP` 13、`MP` 14 不一致，但同一批输入上 `HS` = 0、`MS` = 1（非窗口路径）。所以 Histogram 的 13 组差异全部、Myers 的至少 13 组差异，都纯粹来自窗口化。`merge3` 内部调用的就是 `diff_lines`（`src/merge3.pion:108-109`），所以三方合并也继承了这个问题。

## P0-2 `context >= 21` 时 unified 的上下文被截短，并且跟自己的 `diff_lines` 矛盾

`unified_diff` 把 `margin` 设成 `max(ctx, 21)`。当 `ctx >= 21` 时，保护行数正好等于上下文行数，一点余量都没有。只要字节级后缀起点落在 hunk 之前（slider 滑进后缀区，很常见），尾部上下文就会少一行，有时 hunk 位置也不一样。

```text
p0_unified_ctx25_trailing_context_truncated（28 行输入）
imara : @@ -1,28 +1,28 @@ ...（后文到第 28 行）
Pion  : @@ -1,27 +1,27 @@ ...（少了最后一行上下文 " a"）
```

同一输入上，Pion 的 `diff_lines`、unified ctx=1/3 都和 imara 一致，只有 ctx=25 错了。fuzz 中 hunks 一致但 unified 不一致、并且无法用任何格式约定解释的（`unified-inconsistent-with-own-diff_lines`）共 **558 次**（window 337、repeat 191、code 28、small 2），绝大多数在 ctx=25，少数在 ctx=3（window 族，属于 P0-1）。

## P0-3 HashDoS：无种子 FNV 行哈希可被批量碰撞，复杂度退化成二次

`intern_before_window` / `intern_after_window`（`src/intern.pion:192`、`:308`）用固定初值 `0x811C9DC5` 的 FNV-1a，按 4 字节小端字计算，再接一个开放寻址、线性探测的表。FNV 的乘法在 mod 2^32 下可逆：任取第一个字 `w0`，都能解出第二个字 `w1`，使 9 字节行 `w0 w1 \n` 的哈希**完全相同**（不只低位相同）。`gen_hash_flood.py` 只保留可打印 ASCII 的解，所以输入是合法 UTF-8，imara 的 `&str` API 也能吃。脚本还带一个 Python 模型，自检 1000 行确实同哈希 `0x914b17a1`。哈希全相同时，每插入一个新行都要线性探测并逐字节比较之前的所有同哈希行，总代价 O(n²)。imara 用 `hashbrown` + `foldhash`，不受影响。

| 语料（`bench_compare.py`，SHA 一致） | Pion 中位数 | imara 中位数 | 倍率 |
| --- | ---: | ---: | ---: |
| `hashflood`（80,000 行互相碰撞，1.44 MB） | **2458.9 ms** | 17.4 ms | **0.01×（慢 141 倍）** |
| `hashctrl`（同大小普通行） | 18.9 ms | 19.2 ms | 1.02× |

规模扩展（单次运行）：2 万行 0.17 s → 4 万行 0.86 s → 8 万行 2.92 s。行数翻倍，时间约 ×4，符合二次复杂度。只要 `diff` 处理的是不可信输入（代码评审服务、同步服务），用 1–2 MB 的文件就能把一次 diff 拖到秒级以上。

## P1-1 Myers 不是 imara 的忠实移植；Histogram 的回退路径跟着偏

逐行对比源码，有 3 处有意偏离（下面提到的 imara 写法，按 imara 自己的逻辑看也像 bug，但“逐字节一致”的承诺要求照搬）：

| 位置 | imara-diff 0.2.0 | Pion `281f5c1` |
| --- | --- | --- |
| 奇偶判断 | `myers.rs:102` `let is_odd = (file2.len() - file2.len()) & 1 != 0;`（恒为 false） | `src/myers.pion:284` `((len2 - len1) & 1) != 0` |
| common 行裁剪窗口 | `myers/preprocess.rs:132` `start = if pos > 100 { 100 } else { 0 }` | `src/myers.pion:57` `pos - window` |
| common 行裁剪开关 | 始终启用（`preprocess.rs:113`） | `src/myers.pion:702` 只在 `!minimal && (b_len >= 64 \|\| a_len >= 64)` 时启用 |

| fuzz 族（每族 1000 组） | `MR`（原始 Myers） | `MP`（后处理后） | `HR`（原始 Histogram） |
| --- | ---: | ---: | ---: |
| small | 52 | 4 | 0 |
| code | 195 | 7 | 0 |
| eol | 35 | 26 | 0 |
| repeat | **611** | 65 | **133** |

最小反例（`p1_myers_postprocessed_small`，7 行）：`before = "c\n}\nc\nc\na\n}\na\n"`，`after = "a\n}\nc\na\na\n}\nc\na\n"`，imara Myers 给 `0-1:0-1 3-4:3-4 6-6:6-7`，Pion 给 `0-1:0-1 3-4:3-3 5-5:4-5 6-6:6-7`（多出一个 hunk）。另有 `p1_myers_raw_small`、`p1_myers_raw_mixed`。Histogram 在出现次数 >63 时回退到 Myers，所以 `p1_histogram_myers_fallback_raw`（192 行 x/y/空行）也不一致。

## P1-2 unified 输出不是 “100% byte-for-byte identical”

hunks 完全一致时仍有两类字节差异，`fuzz.py` 用 imara 格式化器的 Python 复刻（会先断言复刻输出 == imara 真实输出）逐条归因：

| 原因 | imara | Pion | 次数（5000 组 × 2 算法 × 4 个 ctx） |
| --- | --- | --- | ---: |
| `gnu-zero-len-header`：某侧长度为 0 的头 | `@@ -6,1 +6,0 @@`、空文件 `@@ -1,0 +1,1 @@` | `@@ -6,1 +5,0 @@`、`@@ -0,0 +1,1 @@`（`src/unified.pion:46`） | 7,939（另有 968 次与 no-newline 叠加） |
| `no-newline-marker`：文件末尾没有换行 | 只补一个裸 `\n` | 加 `\ No newline at end of file` | 3,865（另有 968 + 160 次与其他原因叠加） |

测试：`p1_unified_empty_before_header`、`p1_unified_ctx0_pure_insertion_header`、`p1_unified_no_newline_marker`。Pion 的写法符合 GNU 约定，可以说“更标准”，但它**不是** README 承诺的 imara 逐字节一致。`context = 0` 且 hunk 是纯插入或纯删除时，**每一组**都中。

## P1-3 性能 / 内存对抗基准

全部通过 `scripts/bench_compare.py --warmup 1 --rounds 5`（严格交替、stdout SHA-256 一致），ctx=3，倍率 = imara 中位数 / Pion 中位数（<1 表示 Pion 更慢）。机器负载 39–48。

| 场景 | 说明 | Pion | imara | 倍率 | RSS Pion / imara |
| --- | --- | ---: | ---: | ---: | ---: |
| `hashflood` | P0-3 | 2458.9 ms | 17.4 ms | **0.01×** | 7.0 / 7.7 MiB |
| `minified` | 9 MB 单行 JSON，改 1 字节 | 78.5 ms | 41.2 ms | **0.52×** | 71.6 / 70.5 MiB |
| `edge_fallback` | 20 万行，首行改动 + `}` 段加 1 行，触发 `hit_suf` 全量重算 | 71.9 ms | 42.8 ms | **0.59×** | **33.3 / 21.2 MiB** |
| `edge_control` | 同一文件，普通行改动（不回退） | 38.0 ms | 42.5 ms | 1.12× | 19.1 / 21.2 MiB |
| `multi` | 1 个 before × 8 个 after，imara 用 `update_after` 复用，Pion 没有这类 API | 64.9 ms | 40.5 ms | **0.62×** | 17.6 / 15.3 MiB |
| `rewrite` Myers | 2 万行全量重写 | 26.4 ms | 19.0 ms | **0.72×** | 9.7 / 9.1 MiB |
| `scattered` Myers | 20 万行，每 50 行改 1 行 | 96.1 ms | 68.9 ms | **0.72×** | **40.2 / 25.8 MiB** |
| `rewrite` Histogram | 2 万行全量重写 | 16.6 ms | 16.3 ms | 0.98× | 7.8 / 5.9 MiB |
| `high_d` Myers / Histogram | 3 万行，300 种行，30% 重写 | 54.2 / 68.5 ms | 53.1 / 68.8 ms | 0.98× / 1.00× | 6.7 / 5.6 MiB |
| `scattered` Histogram | 两边都病态（约 2 s） | 1924 ms | 1951 ms | 1.01× | **28.7 / 19.0 MiB** |

`edge_fallback` 和 `edge_control` 是同一个文件：Pion 在回退路径上耗时是控制组的 **1.89×**（71.9 vs 38.0 ms），imara 两者都约 42.6 ms。这就是任务书怀疑的“边缘修改导致两遍计算”，已坐实。原包基准在同一时段重跑（`bench/run_bench.sh`）：10K Histogram **0.77×**、10K Myers **0.85×**、helix_syntax **0.96×**（README 宣称 1.01×；当时负载 ~47，仅供参考）。

**鲁棒性探针**（`run_audit.sh` 第 6 步，单次运行）：10 MB 无换行单行、20 万相同行（改 1 行 / 截半）、10 万交替行、空 vs 空、1000×`\n` vs 1000×`\r\n`、多字节 UTF-8，两边都没有崩溃，退出码都是 0。除“10 MB 无换行”只差 `\ No newline` 标记外，输出全部逐字节一致。10 MB 单行：Pion 43.9 ms，imara 25.1 ms。非 UTF-8 字节（`\xff\xfe`）Pion 可以正常处理。

## P2-1 imara 首个 hunk 上下文怪癖（imara 的 bug，Pion 的输出更正确）

imara 的 `UnifiedDiff::fmt` 初始 `pos = 0`。当首个 hunk 满足 `ctx < start <= 2*ctx` 时，它从第 1 行开始输出上下文，头部却写 `-(start-ctx+1)`，生成的补丁本身就不自洽。Pion 输出的是正确的 `start-ctx` 起点。`p2_unified_first_hunk_context_imara_quirk` 按 imara 的真实输出断言，用来证明“逐字节一致”不成立，**不作为 Pion 的缺陷**。fuzz 中出现 2,686 次（另有 160 次与 no-newline 叠加）。

## P2-2 `merge3` 跟 `git merge-file` 的语义不一致（imara 没有三方合并，以 git 为参照）

1000 组随机三方输入：890 组完全一致；**55 组 Pion 静默合并、git 判冲突**；3 组 Pion 判冲突、git 能干净合并；52 组两边都冲突但冲突区域或文本不同。根因有三：

1. `hunks_conflict`（`src/merge3.pion:87-100`）把“相邻但不重叠”的修改当成可以合并，git 和 diff3 会把它们判为冲突；
2. 用的是 Histogram + 缩进启发式，跟 git 默认的 Myers 对齐方式不同；
3. 内部调用 `diff_lines`，继承了 P0-1。

例子：`base = "a\n}\n}\n"`，`ours = "Z\n}\n}\n"`，`theirs = "a\nc\n}\n"`。git 报冲突，Pion 静默输出 `"Z\nc\n}\n"`。

## P2-3 API 能力缺口（对照 imara-diff 0.2.0 的公开 API）

| imara-diff 0.2.0 | Pion `packages/diff` |
| --- | --- |
| `Algorithm::{Histogram, Myers, MyersMinimal}` | `Algorithm` 只有 `Myers` / `Histogram`；minimal 只能通过 `myers_diff_range(..., minimal=true)` 这个底层函数调用 |
| `InternedInput::update_before/update_after`、`Interner::erase_tokens_after`、`Diff::compute_with` 复用缓冲 | 没有，每次都重新 intern 并分配（`multi` 基准 0.62×） |
| 泛型 `TokenSource`（`&str` 行、`&[u8]` 字节行、自定义字符或词 token） | 只有固定的行切分、`diff_slices(Array[String])`、`diff_tokens(Array[Int])` |
| 可插拔 `SliderHeuristic`、`NoSliderHeuristic`、`IndentLevel::for_line`（Unicode 字符） | 只有内置缩进启发式和 `postprocess_no_heuristic` |
| `UnifiedDiffPrinter` trait、`UnifiedDiffConfig`、`Diff::is_removed/is_added/count_*`、`Hunk` 迭代器 | 固定格式字符串，只能拿到 `DiffResult.hunks` |

## 反证：Pion 明显赢的地方（如实记录）

| 场景 | Pion | imara | 倍率 | 原因 |
| --- | ---: | ---: | ---: | --- |
| `repetitive`（3 万行 5 种行），Histogram / Myers | 40.9 / 37.4 ms | 2186 / 1797 ms | **53× / 48×** | imara `preprocess.rs:132` 的窗口写法让 `should_prune_common_line` 在 `pos > 100` 时扫 `[100, pos)`，退化成 O(n²)；Pion 改成了 `pos - 100` |
| `probe_alternating_100k` | 20–24 ms | 4.9–5.2 s | ~230× | 同上 |
| `million`（100 万行改 1 行） | 45.1 ms | 220.7 ms | **4.9×** | 字节级前后缀裁剪；RSS 55.6 vs 94.1 MiB |
| `edge_control` | 38.0 ms | 42.5 ms | 1.12× | 窗口化 interner 的正常收益 |

这些场景都不是 Pion 不如 imara 的证据。同时也说明：Pion 的速度优势有一部分来自**修掉了 imara 的 bug**，这跟“逐字节对齐 imara”的目标本身是冲突的（见 P1-1）。

## 已排查、未证实（不计入指控）

- **`occ` 打包位宽**（`gen` 27 位 / `index` 29 位 / `len` 7 位）：`len` 封顶 64，跟 imara 的 `MAX_CHAIN_LEN + 1` 一致；`gen` 每次 `histogram_diff_range` 都从新状态开始，要溢出需要单次 diff 里出现 >1.34 亿次 populate；`index` 要溢出需要 >5.37 亿行。按当前运行时（字符串分配尺寸经 `uint32` 截断）无法在本机构造实测输入，**只属于理论风险**。
- **`tok_span` 31 位偏移**：需要 ≥2 GiB 的单个字符串，同样无法实测，不计入。
- **rehash 正确性**：100 万唯一行（`million`，反复 rehash）和 8 万全碰撞行（`hashflood`）的输出都跟 imara 逐字节一致，没发现正确性问题。只有 P0-3 的性能问题。
- **CRLF、多字节 UTF-8、空文件、只有换行符的文件、末尾加换行**：hunks 全部一致（`ok_*` 对照测试通过）。
