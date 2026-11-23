# Pion 包 Lean 4 证明红队审计（RT-lean-proofs）

- 审计对象：`AFK-surf/pion-packages` `origin/main` = `88c3a38f`，43 个带 `proofs/` 的包，CheckAxioms 列出的 **1,160 条定理**（另有 909 条辅助 lemma/私有定理不计入）。
- 工具链：`pionc 0.1.0`（`~/.pion/bin`）、Lean `v4.36.0-rc2`、Aeneas `1dc8ad31`、PionLean 取自 `/private/tmp/pion-lean-ref`（`ab48538`）。
- 复现：`audit/lean_proofs_audit/run_audit.sh [--probes] [--mutations]`，所有实验只在 `/private/tmp/rt-lean-audit-*` 副本上进行，仓库内 `packages/**`、`index/**`、根目录零改动。

## 0. 结论（不粉饰）

| 指标 | 数值 |
|---|---|
| 定理总数 | 1,160 |
| **A 级**（真实高价值生产不变量） | **93（8.0%）** |
| B 级（有一定价值的局部守卫/代数律） | 368（31.7%） |
| **C 级（凑数/注水）** | **699（60.3%）** |
| 其中 C1 常量单点求值 / C2 复述一行定义 / C3 拆碎推论 / C4 语言算术重述 / C5 过约束前提 | 151 / 237 / 293 / 10 / 13（5 条同时属两类） |
| 全仓有效率（A+B） | **39.7%**；只算 A：**8.0%** |
| 17/43 个包 **A 级为 0**，包括 crypto、regex、effect、json5、websocket、crdt | |
| `#verify` 函数覆盖的源码 | 6,576 / 187,228 行 = **3.5%**；784 个 `#verify` 函数中 359 个（46%）函数体只有一行，38 个是零参常量函数 |
| 正向变异（在 `#verify` 函数里注 bug） | **5/5 被证明门禁拦下**（effect 那一例单测全绿、只有证明拦住） |
| 逃逸变异（在真正的生产核心里注致命 bug） | **6/6 证明门禁仍全绿 PASS**；其中 4/6 连单测也全绿 |
| Lean 模型 vs Pion 原生语义 | 41 个溢出/负数/越界/截断/陷阱边界点 **逐字节一致**，未找到 P0 |
| 证明前提把可达的溢出输入排除掉（C5） | 2 个实锤：base64 长度溢出（≥512 MiB 输入直接 panic）、crdt 删除区间 `clock+len` 回绕（恶意 update 让删除失效） |

一句话：**这批证明没有作假（无 sorry/axiom/native_decide，模型与原生一致），但六成是为了凑「每包 24 条」写的单测级/复述级定理，真正兜住生产风险的只有 8%，且全部集中在小型纯算术辅助函数上；ChaCha20/Poly1305/Ed25519 主循环、正则 NFA/DFA、TimerHeap/Scheduler、倒排索引、JSON5 状态机都在证明之外，注入致命 bug 后门禁照样 24/24 全绿。**

## 1. 方法

1. `scan.py` 静态扫描（秒级、只读）：解析全部 `proofs/**/*.lean`，以 CheckAxioms 的 `#print axioms` 集合为准提取 1,160 条定理及其前提、结论、证明行数、所引用的 `#verify` 函数；扫描禁用关键字；解析 43 个 `run_proofs.sh` 的门禁逻辑；解析 `src/*.pion` 的 `#verify` 项、行数与包内生产调用点；给出 C1/C3 等启发式标记。
2. 人工分级 `manual_grades.tsv`：**1,160 条逐条读了定理陈述并对照目标函数体分级**；12 个核心包（crypto、regex、effect、fts、json5、url、time、http1、websocket、base64、flate、crdt，共 342 条）另外通读了证明与生产调用点。启发式与人工结论的分歧很大（启发式把 132 条 C 判成「可能 A/B」），所以总表一律以人工分级为准。
3. 分级口径（严格）：
   - **A**：非平凡逻辑的全称性质，单测无法穷举，且对应真实生产风险（溢出安全、完整编解码双射、日期/十进制完整算术 spec、校验函数的安全完备性……）。有限小域（≤ 6 万点）可被单测穷举的性质最多给 B。
   - **B**：对多分支辅助函数有意义的值域/互斥/单调/代数律，作用面限于孤立小函数。
   - **C1** 固定输入或零参函数的 `rfl/decide`，包括对 ≤ 8 个枚举值的穷举；**C2** 把一行函数体或一个 `if` 分支换个写法重说；**C3** 同一性质换参数/换镜像/由同文件 spec 直接推出的推论，或只证「不失败」而不说结果的 totality；**C4** 只依赖 Int/BitVec 代数、不说明包内逻辑；**C5** 前提比生产调用点实际保证的更强，正好把可达的错误输入排除。
   - 目标是**包内无调用的私有 `#verify` 死函数**的定理一律降为 C（如 decimal `u96_cmp`、uuid `crockford_*`）。

## 2. 维度 1：43 包含金量总表

（「在用」列按委托方给出的核心在用包标注；C 子类允许重叠。完整逐条明细在 `results/theorems.csv`，核心 12 包逐条表见附录。）

| 包 | 在用(委托方指定) | 定理 | A | B | C (C1/C2/C3/C4/C5) | 有效率 A+B | A 率 | #verify fn (单行/零参常量/包内无调用) | #verify LOC / src LOC | 建议 |
|---|:-:|---:|---:|---:|---|---:|---:|---|---|---|
| asn1 |  | 24 | 0 | 8 | 16 (5/7/4/0/0) | 33% | 0% | 30 (22/0/11) | 140 / 3904 (3.6%) | 降级：仅留 B，C 全删，不再要求 Lean |
| base64 | ✔ | 20 | 1 | 4 | 15 (5/4/0/1/7) | 25% | 5% | 13 (4/0/0) | 99 / 709 (14.0%) | 保留 A+B，删 C；修长度溢出后重证 |
| bson |  | 24 | 1 | 5 | 18 (3/6/9/0/0) | 25% | 4% | 13 (4/0/0) | 126 / 3551 (3.5%) | 保留 A+B，删 C |
| cbor |  | 22 | 1 | 5 | 16 (10/3/3/0/0) | 27% | 5% | 10 (0/0/0) | 192 / 3279 (5.9%) | 保留 A+B，删 C |
| cel |  | 24 | 5 | 6 | 13 (0/6/7/0/0) | 46% | 21% | 18 (10/0/0) | 120 / 7581 (1.6%) | 保留 A+B，删 C |
| crdt | ✔ | 29 | 0 | 5 | 24 (3/4/13/1/6) | 17% | 0% | 20 (11/0/1) | 109 / 4721 (2.3%) | 降级；先修 `clock+len` 回绕再谈证明 |
| cron |  | 21 | 11 | 4 | 6 (3/2/1/0/0) | 71% | 52% | 19 (1/0/4) | 342 / 2146 (15.9%) | 保留（全仓最佳之一），删 3 条 C1 |
| crypto | ✔ | 24 | 0 | 12 | 12 (0/3/8/1/0) | 50% | 0% | 15 (11/0/0) | 112 / 5703 (2.0%) | 保留 B，删 C；补 ChaCha 四分之一轮 / Poly1305 limb 算术才算 A |
| csp |  | 24 | 0 | 10 | 14 (6/5/3/0/0) | 42% | 0% | 16 (8/0/0) | 108 / 1904 (5.7%) | 保留 B，删 C |
| decimal |  | 46 | 12 | 13 | 21 (1/4/16/0/0) | 54% | 26% | 42 (17/1/16) | 510 / 3716 (13.7%) | 保留 A+B，删 C（含死函数 `u96_cmp` 4 条） |
| dns |  | 27 | 0 | 8 | 19 (2/6/11/0/0) | 30% | 0% | 31 (23/2/4) | 152 / 4374 (3.5%) | 降级 |
| effect | ✔ | 24 | 0 | 10 | 14 (2/10/2/0/0) | 42% | 0% | 20 (16/6/3) | 72 / 2564 (2.8%) | 保留 B，删 C；TimerHeap/Scheduler 本体值得补证 |
| email |  | 24 | 2 | 9 | 13 (2/7/4/0/0) | 46% | 8% | 16 (6/0/0) | 104 / 5300 (2.0%) | 保留 A+B，删 C |
| flate | ✔ | 19 | 1 | 5 | 13 (4/7/2/0/0) | 32% | 5% | 13 (8/1/0) | 79 / 3225 (2.5%) | 保留 A+B，删 C |
| fts | ✔ | 24 | 1 | 11 | 12 (2/7/3/0/0) | 50% | 4% | 15 (8/0/0) | 105 / 1644 (6.4%) | 保留 A+B，删 C |
| git |  | 22 | 1 | 7 | 14 (4/6/4/0/0) | 36% | 5% | 19 (6/0/1) | 148 / 4265 (3.5%) | 保留 A+B，删 C |
| graph |  | 29 | 5 | 6 | 18 (1/8/9/0/0) | 38% | 17% | 18 (15/0/2) | 68 / 4235 (1.6%) | 保留 A+B，删 C |
| hcl |  | 24 | 0 | 9 | 15 (3/4/8/0/0) | 38% | 0% | 14 (7/2/0) | 147 / 8520 (1.7%) | 降级 |
| http1 | ✔ | 49 | 3 | 18 | 28 (3/10/15/0/0) | 43% | 6% | 22 (5/0/0) | 210 / 2708 (7.8%) | 保留 A+B，删 C |
| http2 |  | 26 | 3 | 7 | 16 (3/9/4/0/0) | 38% | 12% | 28 (18/0/0) | 166 / 3667 (4.5%) | 保留 A+B，删 C |
| http_cache |  | 24 | 2 | 11 | 11 (3/4/4/0/0) | 54% | 8% | 15 (2/0/1) | 126 / 2915 (4.3%) | 保留 A+B，删 C |
| ical |  | 22 | 2 | 7 | 13 (4/5/4/0/0) | 41% | 9% | 11 (4/0/0) | 82 / 3951 (2.1%) | 保留 A+B，删 C |
| jq |  | 22 | 0 | 8 | 14 (1/8/5/0/0) | 36% | 0% | 14 (8/0/0) | 78 / 12132 (0.6%) | 降级 |
| json5 | ✔ | 24 | 0 | 8 | 16 (3/6/7/0/0) | 33% | 0% | 17 (12/0/0) | 79 / 4858 (1.6%) | 降级；解析器本体在证明之外 |
| jsonpath |  | 24 | 1 | 9 | 14 (2/8/4/0/0) | 42% | 4% | 13 (4/0/0) | 84 / 6149 (1.4%) | 保留 A+B，删 C |
| jwt |  | 37 | 3 | 11 | 23 (5/4/11/3/0) | 38% | 8% | 26 (10/0/6) | 184 / 2848 (6.5%) | 保留 A+B，删 C |
| mime |  | 22 | 0 | 10 | 12 (2/6/4/0/0) | 45% | 0% | 16 (8/0/0) | 114 / 3876 (2.9%) | 保留 B，删 C |
| mqtt |  | 27 | 0 | 13 | 14 (3/3/8/0/0) | 48% | 0% | 13 (6/0/1) | 134 / 4627 (2.9%) | 保留 B，删 C |
| msgpack |  | 22 | 0 | 5 | 17 (7/7/3/0/0) | 23% | 0% | 14 (3/2/2) | 182 / 2841 (6.4%) | 降级 |
| protobuf |  | 24 | 4 | 7 | 13 (4/1/8/0/0) | 46% | 17% | 15 (7/1/1) | 96 / 6423 (1.5%) | 保留 A+B，删 C |
| qrcode |  | 22 | 0 | 8 | 14 (2/10/2/0/0) | 36% | 0% | 15 (6/0/2) | 138 / 3014 (4.6%) | 降级 |
| regex | ✔ | 24 | 0 | 9 | 15 (2/8/5/0/0) | 38% | 0% | 15 (5/0/0) | 109 / 7765 (1.4%) | 降级；NFA/DFA/PikeVM 均在证明之外 |
| resp |  | 24 | 1 | 9 | 14 (4/5/5/0/0) | 42% | 4% | 12 (4/0/1) | 99 / 2568 (3.9%) | 保留 A+B，删 C |
| semver |  | 32 | 5 | 14 | 13 (0/2/11/0/0) | 59% | 16% | 13 (2/0/0) | 296 / 2087 (14.2%) | 保留 A+B，删 C |
| ssh |  | 20 | 2 | 4 | 14 (5/1/7/1/0) | 30% | 10% | 9 (3/1/1) | 77 / 3824 (2.0%) | 保留 A+B，删 C |
| svg |  | 24 | 0 | 9 | 15 (1/9/5/0/0) | 38% | 0% | 16 (12/0/1) | 72 / 5785 (1.2%) | 降级 |
| tar |  | 34 | 6 | 6 | 22 (8/4/10/0/0) | 35% | 18% | 32 (19/14/3) | 315 / 3515 (9.0%) | 保留 A+B，删 C |
| time | ✔ | 47 | 11 | 11 | 25 (10/0/15/0/0) | 47% | 23% | 22 (5/3/3) | 245 / 5931 (4.1%) | 保留 A+B，删 C |
| url | ✔ | 24 | 2 | 10 | 12 (1/8/3/0/0) | 50% | 8% | 13 (3/0/1) | 163 / 7593 (2.1%) | 保留 A+B，删 C |
| uuid |  | 55 | 5 | 11 | 39 (5/7/27/0/0) | 29% | 9% | 42 (20/4/29) | 389 / 4103 (9.5%) | 保留 A+B，删 C（ULID 8 条 1 行复用、死函数 crockford 6 条） |
| wasm |  | 24 | 0 | 8 | 16 (9/2/5/0/0) | 33% | 0% | 20 (7/0/1) | 154 / 8847 (1.7%) | 降级 |
| websocket | ✔ | 34 | 0 | 12 | 22 (3/5/11/3/0) | 35% | 0% | 16 (4/0/0) | 143 / 1866 (7.7%) | 保留 B，删 C；完整 UTF-8 DFA 正确性才是 A |
| zip |  | 22 | 2 | 6 | 14 (5/6/3/0/0) | 36% | 9% | 13 (5/1/0) | 108 / 1994 (5.4%) | 保留 A+B，删 C |
| **合计 43 包** | 12 | **1160** | **93** | **368** | **699** (151/237/293/10/13) | **39.7%** | **8.0%** | 784 (359/38/95) | 6576 / 187228 (3.5%) | |

12 个核心在用包：342 条，A 19（5.6%）、B 115、C 208，有效率 39.2%，**比非核心包更低**（非核心 A 9.0%）。

### 2.1 凑数的结构性证据

- **配额写进了门禁**：18 个包恰好 24 条，8 个 `run_proofs.sh` 写死 `THM_COUNT -lt 24`，7 个写死 `-ne 24`（bson、csp、hcl、http_cache、protobuf、resp、url）——后者意味着**删掉一条水定理门禁就会失败**。恰好 24 条的 18 个包 A 率只有 4.4%；不受配额约束、自然写到 32–55 条的 decimal/time/semver/tar/uuid/cron 贡献了全部 A 的 54%（50/93）。
- **为凑配额而造靶子**：effect 把 6 个优先级常量拆成零参 `#verify` 函数（`priority_asked/shown/detail` 包内无调用点，`sched_lane_admits` 本身仍写死 `20/0/-10`），再证 `priority_strict_hierarchy`；url 新增无人调用的 `Ipv4Addr::to_u32` 来证「往返」；decimal 的 `u96_cmp`、uuid 的 `crockford_val*`/`hex_char_*` 是**无调用的私有死函数**却各挂 4–6 条定理。全仓 784 个 `#verify` 函数里 95 个在包内没有生产调用点（其中 8 个私有死函数），60 个根本没有定理引用。
- **同一 hex 解码器被各包复制后重复证明**：`hex_val / hex_nibble / oid_hex_val …` 的「值域 + 大小写不敏感」在 crypto、regex、bson、cel、crdt、dns、git、hcl、http1、jq、mime、resp、svg、uuid 共 14 个包里各证一遍（≈ 28 条）。
- **spec + 3 条推论**：time、semver、uuid、decimal、bson 普遍先证一条完整 spec，再追加 refl/antisymm/trans 三条一两行就能从 spec 推出的推论（这部分占 C3 的大头）；uuid 的 8 条 ULID 比较定理证明全是 1 行复用 UUID 版本。
- 证明长度：A 中位 48 行、B 16 行、C 6 行；C 级定理的证明多数就是 `unfold; simp`/`decide`。

### 2.2 典型例子（委托方点名的 4 条全部坐实）

| 定理 | 级别 | 原因 |
|---|---|---|
| `effect.priority_strict_hierarchy` | C1 | 六个零参常量 30>20>10>5>0>-10；其中三个常量无调用点 |
| `json5.splitmix64_zero_nonzero` | C1 | `splitmix64 0 ≠ 0` 单点求值 |
| `fts.fold_greek_final_sigma` | C1 | `fold_greek_cyrillic 962 = 963` |
| `json5.pointer_escape_unescape_tilde` | C1 | 两个固定输入 |
| `crypto.cc_rotl32_12/8/7_inverse` | C3 | 同一条旋转互逆律拆成 4 个固定位移 |
| `crypto.chacha20_aead_lengths_exact` | C2 | 函数体就是 `n == 32`/`n == 12`/`n >= 16` |
| `effect.queue_*`、`fiber_shielded_never_cut` | C2 | 复述 `cap < 0 \|\| len < cap`、`interrupted && shield == 0` |
| `json5.hash_ensure_nonzero_ne_zero` | C2 | 函数体 `if h == 0 { 1 } else { h }` |
| `crypto.fe_add_comm` | C4 | 10 次 `Int64` 加法交换律，对域约化一字未提 |
| `crdt.delete_item_merge_covers_both` | C5 | 见 §4.3 |
| A 级代表 | A | `fts.snippet_win_end_rt3_safe`（RT-3 溢出）、`cron.is_leap_year_spec`（位运算闰年 ≡ 公历规则，全 Int32）、`cel.i64_add_overflows_iff`、`decimal.aligned_add_96_*`、`time.to_epoch_days_spec`、`tar.validate_extract_path_bytes_sound`、`git.delta_copy_range_ok_sound`、`zip.in_range64_iff`、`semver.matches_release_total_no_overflow` |

## 3. 维度 2：覆盖面与双面变异实测

### 3.1 覆盖率

- `#verify` 函数总行数 6,576 / 生产源码 187,228 行 = **3.5%**（逐包见总表；最低 jq 0.6%，最高 cron 15.9%）。
- 被证明的几乎都是从生产代码里「抽出来」的 1–10 行辅助函数：46% 的 `#verify` 函数只有一行函数体。没有任何包的主数据结构、主循环或解析器状态机在 `#verify` 内。

### 3.2 双面变异（`mutate.py`，5 个在用包，副本在 `/private/tmp/rt-lean-audit-mut`）

每个变异都在包副本上同时跑 `pionc test --json` 和包自己的 `proofs/run_proofs.sh`（live `pionc extract-lean` → `lake build` → CheckAxioms → EvalDiff → 原生对拍）。基线 5/5 两者都 PASS。

| 编号 | 类型 | 注入的 bug | 单元测试 | 证明门禁 |
|---|---|---|---|---|
| crypto-pos-rotl | 正向 | `#verify cc_rotl32`：右移位数 `32-n → 31-n` | FAIL 71/76 | **FAIL**（`AeadHkdfHex.lean:61`） |
| effect-pos-parent | 正向 | `#verify heap_parent`：`(i-1)/2 → i/2` | **PASS 19/19** | **FAIL**（`SchedulerAndSync.lean:77/96/118`）← 证明比单测强的唯一实例 |
| regex-pos-intersect | 正向 | `#verify char_range_intersect`：下界取 max 改 min | FAIL 22/23 | **FAIL** |
| fts-pos-winend | 正向 | `#verify snippet_win_end`：窗口多 1 | FAIL 22/23 | **FAIL** |
| json5-pos-surrogate | 正向 | `#verify decode_surrogate_pair`：低代理偏移差 1 | FAIL 241/242 | **FAIL** |
| crypto-neg-qround | 逃逸 | ChaCha20 块函数第一个列四分之一轮 rotl 16→15（所有密钥的密文都错） | FAIL 72/76 | **PASS 24/24** |
| crypto-neg-ctleak | 逃逸 | `constant_time_eq` 加首字节数据相关提前返回（计时侧信道，结果不变） | **PASS 76/76** | **PASS 24/24** |
| effect-neg-pop | 逃逸 | `TimerHeap::pop` 下沉忽略右孩子 | **PASS 19/19** | **PASS 24/24** |
| regex-neg-pike-eol | 逃逸 | PikeVM `eval_look`：`(?m)$` 不再匹配 `\n` 前 | **PASS 23/23** | **PASS 24/24** |
| fts-neg-filter | 逃逸 | `Index::search` 标签过滤只比 key 不比 value（过滤绕过） | FAIL 20/23 | **PASS 24/24** |
| json5-neg-escape | 逃逸 | 字符串转义 `\n` 解码成 CR | **PASS 242/242** | **PASS 24/24** |

三个「两道门都没拦住」的逃逸 bug 用 `probes/escape/run_escape_demos.sh` 复现为真实错误：

```
effect-timer-order    orig  fired: 5 10 15 20 25 30 35 40 45 50
effect-timer-order    mut   fired: 5 15 20 30 35 40 25 45 10 50      ← 定时器乱序
regex-multiline-cap   orig  is_match("ab\ncd") = true  captures group1 = [0,2)
regex-multiline-cap   mut   is_match("ab\ncd") = true  captures = None ← DFA 与 PikeVM 结果互相矛盾
json5-newline-escape  orig  {k:"a\nb"}
json5-newline-escape  mut   {k:"a\rb"}
```

结论：
- 正向 5/5 说明门禁对**被证明的那几行**是真敏感的，不是摆设。
- 逃逸 6/6 说明**证明对 96.5% 的生产代码零保护**。regex 一例最典型：证明了 DFA 侧的 `dfa_look_holds`，而 PikeVM 侧语义相同的 `eval_look` 是另一份未证明的拷贝；crypto 的 `ct_diff_acc` 定理给人「常数时间已验证」的印象，但常数时间这一性质本身从未被陈述，`constant_time_eq` 可以随意加提前返回。

## 4. 维度 3：提取链路与语义健全性

### 4.1 作弊/后门扫描（全 43 包）

| 检查 | 结果 |
|---|---|
| `sorry`/`admit`/`axiom` 声明/`unsafe`/`implemented_by`/`native_decide`/`bv_decide`/`opaque`/`extern` | 0（只有 cron 3 处 `decide +kernel`，内核求值，健全） |
| CheckAxioms 集合 vs 定理集合 | 1,160 条 `#print axioms` 全部对应真实定理，无幽灵名、无重复；另有 283 条**未加 `private` 的辅助定理**（cron 62、decimal 70……）不在 CheckAxioms，只能通过依赖它的主定理间接检查 |
| `#verify_opaque`（在 Lean 里生成为 `axiom`） | 全仓 0 处；但 15 个 `run_proofs.sh`（bson、crypto、csp、effect、email、fts、hcl、http_cache、json5、jsonpath、protobuf、regex、resp、svg、url）用**黑名单**（只 grep `sorryAx/ofReduceBool/trustCompiler`）检查公理，一旦有人引入 `#verify_opaque`，生成的 `FunsExternal.lean` 里的 `axiom` 不会被这 15 个门禁发现；其余 28 个用 `propext/Classical.choice/Quot.sound` 白名单，是对的 |
| 是否现场提取 | 43/43 都现场跑 `pionc extract-lean`，没有读静态产物 |
| 模块是否全部被构建 | 43/43 的子模块都被根模块 import |

### 4.2 Lean 模型 vs Pion 原生语义（P-SEM，`probes/run_probes.sh`）

在一个探针包里对 41 个边界点同时跑原生二进制和 `pionc extract-lean` 生成的 Lean 模型：移位 `≥ 位宽`/负数、`/` `%` 除零与 `MIN/-1`、负数除法与取余符号、`Int32`/`Int64` 加乘回绕、`-MIN`、`Int64→Int`/`UInt→Int`/`UInt64→Int` 截断与重解释、`Int→Byte→Int`、`Array::make(-5)`、UTF-8 `String.length`、`Bytes` 越界。**41/41 输出逐字节一致**（原生陷阱 ↔ Lean `fail`）。`--release` 下陷阱同样保留。**未构造出「Lean 证明通过而原生结果不同」的反例，不定 P0。**

需要写进规则的语义边界：
- 运行时检查**只在 `#verify` 函数里生成**。同样的 `3 << 40`、`7 / 0` 放在普通函数里原生得到 `768`、`0`（ARM64 按位宽取模、`sdiv` 除零得 0；x86_64 除零会 SIGFPE），与 Lean 模型不同。编译器用 `E_VERIFY_UNVERIFIED_CALLEE` 禁止 `#verify` 调未验证函数，所以目前不构成漏洞，但**证明结论绝不能外推到复制出去的非 `#verify` 版本**（regex `eval_look` 就是这种复制）。
- 原生「对拍」在 41/43 个包里比较的是两边各自对照写死期望值打印的 `PASS/FAIL` 字符串，不是两边算出来的值（只有 cron、uuid 打印值）；期望值写错时两边会一起错。
- **EvalDiff 盲区**：43 个 EvalDiff 没有一个测陷阱/失败分支（全部用 `reducesTo 期望值`）；22/43 不含任何 `INT_MAX/INT_MIN/2^32-1` 级极值；asn1、cbor、http2、ssh 连负数输入都没有。

### 4.3 C5 实锤：证明前提挡掉的正是会出错的输入

| 探针 | 定理前提 | 生产实际 | 原生实测 |
|---|---|---|---|
| P-B64 | `b64_encoded_len_nopad_spec`/`b64_length_roundtrip` 要求 `n ≤ 536870910`；`hex_len_roundtrip` 要求 `n ≤ 2^30-1`；`b32_encoded_len_*` 要求 `n ≤ 10^9` | `encode_with` 直接传 `data.length()`，无任何上限检查 | `encoded_len(536870912,false) = -715827882`；`encode_no_pad(512 MiB)` → `panic: negative bytes length`；`encoded_len(1610612736,true) = -2^31`；`hex_encoded_len(2^30) = -2^31` |
| P-CRDT | `delete_item_contains_iff`、`delete_item_merge_sound/covers_both`、`item_last_id_spec` 都假设 `clock + len < 2^64` | `read_delete_set` 从网络 update 读任意 `var_uint` clock/len，直接 `ds.add`，不查回绕 | `DeleteItem{2^64-2, 4}` 不包含 `2^64-1`；`merge({10,5},{12,2^64-6})` 丢掉第二段，`DeleteSet.is_deleted` 对已删除 clock 返回 false |

这两处都是**生产 bug**（base64：大输入崩溃；crdt：恶意 update 使删除静默失效），证明恰好把它们定义到了定理之外。

### 4.4 门禁本身的工程缺陷

- **不可从零复现**：15 个脚本（bson、crypto、csp、effect、email、fts、hcl、http_cache、json5、jsonpath、protobuf、regex、resp、svg、url）在空 `LEAN_WORK` 下第 1 步就 `ERROR: PionLean reference missing`（它们找 `/private/tmp/pion-lean-ref/PionLean`，该目录不存在，PionLean 实际在 `lean/PionLean`），只是因为共享目录里恰好已有一份才能跑；PionLean 与 `pionc` 都不随仓库固定版本（只有 Aeneas 固定在 `1dc8ad31`）。
- **共享工作区竞态**：30 个脚本默认用同一个 `/private/tmp/pion-lean-shared/proj`，每次运行都覆盖其中的 `lakefile.lean`、`CheckAxioms.lean`、`EvalDiff.lean`。两个包并发跑时 A 的 CheckAxioms 可能被 B 覆盖后再执行，存在**假 PASS** 的可能（审计期间该目录的 lakefile 正被别的会话改写）。

## 5. 维度 4：反凑数门禁标准与去留建议

### 5.1 立即废除

1. 「每包 24 条」配额，以及 15 个脚本里写死的 `-lt 24`/`-ne 24`。改为：门禁只检查「CheckAxioms 集合 == 文件中全部非 private 定理集合」和白名单公理。
2. 以定理条数作为任何进度/验收指标。

### 5.2 硬性禁用清单（CI 可自动拦截，`scan.py` 已实现大部分检测）

| 禁止 | 判定 |
|---|---|
| C1 零参/固定输入求值、≤ 8 值枚举穷举 | 无任何量化的值参数；或只量化有限小枚举 → 改写成 `pionc test` |
| C2 复述一行定义 | 目标函数体一行、结论是该表达式的等价改写 |
| C3 拆碎推论 | 归一化数字后与同包另一定理同形；或能由同文件 spec 用 ≤ 3 行推出；或只证 `∃ r, f x = ok r` 的 totality |
| C4 语言算术重述 | 结论不依赖包内任何分支/常量 |
| C5 逃避前提 | 每条带范围前提的定理必须在注释里给出生产调用点的守卫位置（文件:行）；给不出就算 C5 |
| 死靶 | 目标函数在包内无生产调用点且非公开 API |
| 新增零参 `#verify` 常量函数、为证明而拆出的一行包装 | 直接拒收 |

### 5.3 新增门禁

1. **变异杀伤门禁**（核心）：对每个 `#verify` 函数自动生成算子变异（`+1/-1`、比较符翻转、掩码/位移常量 ±1、分支交换），要求每条定理至少独占杀死一个变异，否则视为凑数；整体要求 `#verify` 函数变异杀伤率 ≥ 90%。`mutate.py` 是该门禁的雏形。
2. 公理白名单（`propext/Classical.choice/Quot.sound`）统一到全部 43 个脚本，并扫描生成的 `FunsExternal.lean`。
3. 固定 `pionc` 与 PionLean 版本（写进 `proofs/` 或仓库根），每个包用独立的 `LEAN_WORK`，禁止共享目录。
4. EvalDiff 必须包含陷阱/失败分支、`MIN/MAX/0/-1` 和每个带前提定理的前提边界外一点；原生对拍改为打印值后 `diff`。

### 5.4 在当前 `extract-lean` 子集下哪些值得证

子集支持整数/位运算（带 `#verify` 陷阱）、结构体、枚举、`Array/FixedArray/Bytes` 值语义、循环与递归；不支持闭包、字符串方法（除 `length`）、`Array::sort`、浮点。据此：

- **值得写（已证明能出 A）**：带溢出风险的整数核（checked/saturating 加减、96/128 位多字算术、varint/zigzag/LEB128/VBI、长度计算）、日历/时间完整 spec 与往返、位打包双射、守护内存/路径安全的校验函数（tar 路径、git delta 区间、zip `in_range64`）、排序比较器的完整全序（含 trans，fts 的 `hit_tiebreak_cmp` 恰恰缺 trans）。
- **值得补、目前缺的高价值目标**（都在子集内）：ChaCha20 四分之一轮/块函数对 RFC 8439 规格、Poly1305 limb 进位、Ed25519 `fe_mul` 约化上界；`TimerHeap::push/pop` 的堆序不变量（上面的逃逸 bug 就会被拦住）；`DeleteSet` 合并在**不加回绕前提**时的正确性（会直接逼出 crdt bug）；base64 编码长度**在全 `Int` 域**的正确性（会逼出溢出 bug）；把 regex 的 `eval_look` 与 `dfa_look_holds` 合成一个 `#verify` 函数，让 DFA/PikeVM 共享同一条证明。
- **不值得写**：枚举编码往返、零参常量、`Limits::default` 字段值、一行谓词的 iff、ASCII 字符类（用表驱动单测即可）。按总表「降级」一栏的 11 个包（asn1、crdt、dns、hcl、jq、json5、msgpack、qrcode、regex、svg、wasm）当前没有任何 A 级定理且有效率 ≤ 38%，建议**删除全部 C 级、只留 B，不再要求每包 Lean**，等确有上述高价值目标时再立项。

### 5.5 量化去留

- 可直接删除：**699 条 C**（其中 151 条 C1 应迁成单测）；保留 461 条 A+B。
- 删除后门禁需要同步：去掉 `-lt/-ne 24`，否则 15 个包会因「不足 24 条」失败。
- 需要先修生产 bug 再重证：base64 长度溢出、crdt `clock+len` 回绕。

## 6. 产物与复现

| 文件 | 内容 |
|---|---|
| `run_audit.sh` | 一键：静态扫描；`--probes` 语义/C5 探针；`--mutations` 双面变异 |
| `scan.py` | 定理清单、CheckAxioms 对账、禁用词、门禁解析、`#verify` 覆盖率与调用点、C1/C2/C3 启发式 + 人工分级汇总 |
| `manual_grades.tsv` | 1,160 条人工分级与理由 |
| `mutate.py` + `mutations.json` | 双面变异实验 |
| `probes/run_probes.sh` | P-SEM（41 点原生 vs Lean）、P-NV、P-B64、P-CRDT |
| `probes/escape/run_escape_demos.sh` | 3 个双门逃逸 bug 的行为复现 |
| `gen_tables.py` | 从 `theorems.csv` 生成逐条表 |
| `results/` | 本次运行的 `theorems.csv`（1,160 行）、`packages.csv`、`verify_fns.csv`、`summary.json`、`mutation_results.json` |

审计限制：非核心 31 包的分级基于逐条读定理陈述与目标函数体，没有逐条读证明脚本；「在用」只按委托方名单标注，未调查下游仓库；变异实验只覆盖 5 个包各 1 个正向、1–2 个逃逸变异，不是完整变异测试。

## 附录：12 个核心包逐条分级（文件:行号）

#### crypto — 24 条：A 0 / B 12 / C 12

| # | 定理 | 位置 | 级别 | 依据 |
|---:|---|---|---|---|
| 1 | `cc_rotl32_zero` | `packages/crypto/proofs/CryptoProofs/AeadHkdfHex.lean:88` | **C3** | rotl of 0 |
| 2 | `cc_rotl32_16_involutive` | `packages/crypto/proofs/CryptoProofs/AeadHkdfHex.lean:95` | **B** | rotation inverse (one instance of the general law) |
| 3 | `cc_rotl32_12_inverse` | `packages/crypto/proofs/CryptoProofs/AeadHkdfHex.lean:103` | **C3** | same law as rotl16, fixed shift 12/20 |
| 4 | `cc_rotl32_8_inverse` | `packages/crypto/proofs/CryptoProofs/AeadHkdfHex.lean:111` | **C3** | same law, fixed shift 8/24 |
| 5 | `cc_rotl32_7_inverse` | `packages/crypto/proofs/CryptoProofs/AeadHkdfHex.lean:119` | **C3** | same law, fixed shift 7/25 |
| 6 | `chacha20_aead_lengths_exact` | `packages/crypto/proofs/CryptoProofs/AeadHkdfHex.lean:127` | **C2** | body is n == 32 / n == 12 / n >= 16 |
| 7 | `hkdf_sha256_valid_len_exact` | `packages/crypto/proofs/CryptoProofs/AeadHkdfHex.lean:137` | **C2** | body is len >= 0 && len <= 255*32 |
| 8 | `hkdf_sha256_blocks_counter_safe` | `packages/crypto/proofs/CryptoProofs/AeadHkdfHex.lean:147` | **B** | ceil-div lands in [1,255]: counter byte never wraps |
| 9 | `hkdf_sha512_valid_len_exact` | `packages/crypto/proofs/CryptoProofs/AeadHkdfHex.lean:163` | **C2** | body is len >= 0 && len <= 255*64 |
| 10 | `hkdf_sha512_blocks_counter_safe` | `packages/crypto/proofs/CryptoProofs/AeadHkdfHex.lean:173` | **C3** | copy of the SHA-256 theorem with 64 |
| 11 | `hex_nibble_val_bounds` | `packages/crypto/proofs/CryptoProofs/AeadHkdfHex.lean:189` | **B** | 4-branch classifier exact iff |
| 12 | `hex_nibble_val_case_insensitive` | `packages/crypto/proofs/CryptoProofs/AeadHkdfHex.lean:234` | **B** | A-F vs a-f |
| 13 | `ct_diff_acc_zero_iff` | `packages/crypto/proofs/CryptoProofs/ConstantTimeAndCurve.lean:77` | **B** | OR-latch zero iff equal; 1-line body but used by constant_time_eq |
| 14 | `ct_diff_acc_monotone_nonzero` | `packages/crypto/proofs/CryptoProofs/ConstantTimeAndCurve.lean:92` | **B** | latch can never clear |
| 15 | `fe_cmov_flag_zero` | `packages/crypto/proofs/CryptoProofs/ConstantTimeAndCurve.lean:109` | **B** | branch-free select correctness for flag 0 over all Fe |
| 16 | `fe_cmov_flag_one` | `packages/crypto/proofs/CryptoProofs/ConstantTimeAndCurve.lean:116` | **B** | branch-free select correctness for flag 1 over all Fe |
| 17 | `fe_cmov_same_invariant` | `packages/crypto/proofs/CryptoProofs/ConstantTimeAndCurve.lean:123` | **C3** | corollary of the mask algebra (a^m&0) |
| 18 | `fe_cswap_pair_zero` | `packages/crypto/proofs/CryptoProofs/ConstantTimeAndCurve.lean:130` | **B** | ladder cswap swap=0 |
| 19 | `fe_cswap_pair_one` | `packages/crypto/proofs/CryptoProofs/ConstantTimeAndCurve.lean:143` | **B** | ladder cswap swap=1 |
| 20 | `fe_cswap_pair_involutive` | `packages/crypto/proofs/CryptoProofs/ConstantTimeAndCurve.lean:150` | **C3** | two-line corollary of the two cswap theorems |
| 21 | `fe_add_comm` | `packages/crypto/proofs/CryptoProofs/ConstantTimeAndCurve.lean:157` | **C4** | ten Int64 wrapping-add commutativity facts; says nothing about field reduction |
| 22 | `x25519_clamp_low_byte_cofactor8` | `packages/crypto/proofs/CryptoProofs/ConstantTimeAndCurve.lean:166` | **B** | RFC 7748 clamp |
| 23 | `x25519_clamp_high_byte_range` | `packages/crypto/proofs/CryptoProofs/ConstantTimeAndCurve.lean:186` | **B** | RFC 7748 clamp |
| 24 | `x25519_clamp_idempotent_all` | `packages/crypto/proofs/CryptoProofs/ConstantTimeAndCurve.lean:207` | **C3** | bitmask idempotence of b&248 / (b&127)\|64 |

#### regex — 24 条：A 0 / B 9 / C 15

| # | 定理 | 位置 | 级别 | 依据 |
|---:|---|---|---|---|
| 1 | `dfa_mode_exclusive` | `packages/regex/proofs/RegexProofs/AutomataAndCaptures.lean:33` | **C2** | two 1-arm matches on a 3-variant enum |
| 2 | `dfa_look_word_ascii_complement` | `packages/regex/proofs/RegexProofs/AutomataAndCaptures.lean:38` | **C2** | `!=` vs `==` on two Bools |
| 3 | `dfa_look_word_unicode_complement` | `packages/regex/proofs/RegexProofs/AutomataAndCaptures.lean:48` | **C3** | same as ascii |
| 4 | `dfa_look_end_text_implies_end_line` | `packages/regex/proofs/RegexProofs/AutomataAndCaptures.lean:58` | **C2** | `at_eoi` vs `at_eoi \|\| next_is_nl` |
| 5 | `dfa_look_end_line_iff` | `packages/regex/proofs/RegexProofs/AutomataAndCaptures.lean:67` | **C2** | restates match arm |
| 6 | `reverse_look_kind_involutive` | `packages/regex/proofs/RegexProofs/AutomataAndCaptures.lean:73` | **C1** | finite 8-variant enum, exhaustively unit-testable |
| 7 | `reverse_look_preserves_word_boundary` | `packages/regex/proofs/RegexProofs/AutomataAndCaptures.lean:79` | **C1** | finite 8-variant enum |
| 8 | `onepass_can_compile_iff` | `packages/regex/proofs/RegexProofs/AutomataAndCaptures.lean:88` | **C2** | restates the conjunction |
| 9 | `onepass_mask_add_slot_oob` | `packages/regex/proofs/RegexProofs/AutomataAndCaptures.lean:106` | **C2** | restates else branch |
| 10 | `onepass_mask_add_slot_idempotent` | `packages/regex/proofs/RegexProofs/AutomataAndCaptures.lean:122` | **B** | OR-bit idempotence of the slot mask |
| 11 | `captures_slot_valid_bounds` | `packages/regex/proofs/RegexProofs/AutomataAndCaptures.lean:157` | **B** | slot index 2i+1 in bounds of slots |
| 12 | `captures_slot_valid_neg` | `packages/regex/proofs/RegexProofs/AutomataAndCaptures.lean:185` | **C2** | restates `idx >= 0` |
| 13 | `char_range_le_refl` | `packages/regex/proofs/RegexProofs/RangesAndSyntax.lean:28` | **C3** | follows from total |
| 14 | `char_range_le_antisymm` | `packages/regex/proofs/RegexProofs/RangesAndSyntax.lean:35` | **B** | sort-order law |
| 15 | `char_range_le_trans` | `packages/regex/proofs/RegexProofs/RangesAndSyntax.lean:48` | **B** | sort-order law |
| 16 | `char_range_le_total` | `packages/regex/proofs/RegexProofs/RangesAndSyntax.lean:57` | **B** | sort-order law |
| 17 | `char_range_intersect_comm` | `packages/regex/proofs/RegexProofs/RangesAndSyntax.lean:63` | **C3** | min/max commutativity |
| 18 | `char_range_intersect_idem` | `packages/regex/proofs/RegexProofs/RangesAndSyntax.lean:76` | **C3** | min/max idempotence |
| 19 | `char_range_intersect_mem_iff` | `packages/regex/proofs/RegexProofs/RangesAndSyntax.lean:82` | **B** | exact set-intersection semantics |
| 20 | `is_utf8_cont_byte_iff` | `packages/regex/proofs/RegexProofs/RangesAndSyntax.lean:96` | **B** | mask semantics over the byte range |
| 21 | `utf8_lead_len_bounds` | `packages/regex/proofs/RegexProofs/RangesAndSyntax.lean:175` | **C2** | four constant branches 1..4 |
| 22 | `hex_val_bounds` | `packages/regex/proofs/RegexProofs/RangesAndSyntax.lean:205` | **B** | classifier range (duplicate of crypto/mime/... hex helpers) |
| 23 | `hex_val_case_insensitive` | `packages/regex/proofs/RegexProofs/RangesAndSyntax.lean:238` | **C3** | duplicate of crypto hex_nibble_val_case_insensitive |
| 24 | `regex_ws_meta_disjoint` | `packages/regex/proofs/RegexProofs/RangesAndSyntax.lean:274` | **B** | disjoint byte sets |

#### effect — 24 条：A 0 / B 10 / C 14

| # | 定理 | 位置 | 级别 | 依据 |
|---:|---|---|---|---|
| 1 | `rng_init_state_nonzero_u32` | `packages/effect/proofs/EffectProofs/RuntimeAndDeque.lean:112` | **B** | xorshift seed never 0 |
| 2 | `rng_step_u32_bounds` | `packages/effect/proofs/EffectProofs/RuntimeAndDeque.lean:170` | **C2** | result is literally `... & 0xFFFFFFFF` |
| 3 | `rng_step_u32_zero_fixed` | `packages/effect/proofs/EffectProofs/RuntimeAndDeque.lean:177` | **C1** | closed evaluation |
| 4 | `rng_below_val_le_one` | `packages/effect/proofs/EffectProofs/RuntimeAndDeque.lean:183` | **C2** | restates `if n <= 1 { return 0 }` |
| 5 | `rng_below_val_bounds` | `packages/effect/proofs/EffectProofs/RuntimeAndDeque.lean:192` | **B** | modulo result in [0,n) for draw >= 0 |
| 6 | `ring_next_cap_grows` | `packages/effect/proofs/EffectProofs/RuntimeAndDeque.lean:221` | **B** | no overflow for cap < 2^30 |
| 7 | `ring_slot_add_bounds` | `packages/effect/proofs/EffectProofs/RuntimeAndDeque.lean:239` | **B** | in-bounds index |
| 8 | `ring_slot_prev_bounds` | `packages/effect/proofs/EffectProofs/RuntimeAndDeque.lean:252` | **B** | in-bounds index |
| 9 | `ring_slot_prev_add_one_inv` | `packages/effect/proofs/EffectProofs/RuntimeAndDeque.lean:268` | **B** | push_front/pop_front index inverse |
| 10 | `timer_before_irrefl` | `packages/effect/proofs/EffectProofs/RuntimeAndDeque.lean:311` | **B** | strict order law |
| 11 | `timer_before_asymm` | `packages/effect/proofs/EffectProofs/RuntimeAndDeque.lean:317` | **C3** | follows from irrefl + trans |
| 12 | `timer_before_trans` | `packages/effect/proofs/EffectProofs/RuntimeAndDeque.lean:335` | **B** | strict order law |
| 13 | `heap_parent_lt` | `packages/effect/proofs/EffectProofs/SchedulerAndSync.lean:67` | **B** | heap index decreases |
| 14 | `heap_left_parent_inv` | `packages/effect/proofs/EffectProofs/SchedulerAndSync.lean:81` | **B** | child/parent inverse for i < 2^30 |
| 15 | `heap_right_parent_inv` | `packages/effect/proofs/EffectProofs/SchedulerAndSync.lean:101` | **C3** | same as left with +1 |
| 16 | `queue_unbounded_always_has_room` | `packages/effect/proofs/EffectProofs/SchedulerAndSync.lean:123` | **C2** | body `cap < 0 \|\| len < cap` |
| 17 | `queue_bounded_has_room_iff` | `packages/effect/proofs/EffectProofs/SchedulerAndSync.lean:131` | **C2** | same body, other disjunct |
| 18 | `queue_shutdown_rejects_offer` | `packages/effect/proofs/EffectProofs/SchedulerAndSync.lean:139` | **C2** | body `!shut && ...` |
| 19 | `priority_strict_hierarchy` | `packages/effect/proofs/EffectProofs/SchedulerAndSync.lean:144` | **C1** | 6 zero-arg constants; 3 of them (asked/shown/detail) have no production caller and sched_lane_admits hard-codes 20/0/-10 |
| 20 | `sched_lane_focused_urgent_room` | `packages/effect/proofs/EffectProofs/SchedulerAndSync.lean:159` | **C2** | restates first if-branch |
| 21 | `sched_lane_background_serialized` | `packages/effect/proofs/EffectProofs/SchedulerAndSync.lean:173` | **C2** | restates third branch with has_bg_running=true |
| 22 | `sched_lane_idle_yields` | `packages/effect/proofs/EffectProofs/SchedulerAndSync.lean:192` | **C2** | restates else-branch |
| 23 | `sched_non_idle_never_preempted` | `packages/effect/proofs/EffectProofs/SchedulerAndSync.lean:217` | **C2** | body `eff_p <= -10 && ...` |
| 24 | `fiber_shielded_never_cut` | `packages/effect/proofs/EffectProofs/SchedulerAndSync.lean:227` | **C2** | body `interrupted && shield == 0` |

#### fts — 24 条：A 1 / B 11 / C 12

| # | 定理 | 位置 | 级别 | 依据 |
|---:|---|---|---|---|
| 1 | `snippet_normalize_ws_idempotent` | `packages/fts/proofs/FtsProofs/SnippetAndRanking.lean:43` | **B** | idempotence over all Int |
| 2 | `snippet_normalize_ws_ctrl` | `packages/fts/proofs/FtsProofs/SnippetAndRanking.lean:57` | **C2** | restates `c == 10 \|\| c == 13 \|\| c == 9` |
| 3 | `snippet_context_before_bounds` | `packages/fts/proofs/FtsProofs/SnippetAndRanking.lean:70` | **B** | range |
| 4 | `snippet_win_end_rt3_safe` | `packages/fts/proofs/FtsProofs/SnippetAndRanking.lean:101` | **A** | RT-3 overflow: window end never overflows/exceeds total for all Int32 |
| 5 | `snippet_range_gt_irrefl` | `packages/fts/proofs/FtsProofs/SnippetAndRanking.lean:128` | **B** | order law |
| 6 | `snippet_range_gt_asymm` | `packages/fts/proofs/FtsProofs/SnippetAndRanking.lean:134` | **C3** | follows from irrefl + trans |
| 7 | `snippet_range_gt_trans` | `packages/fts/proofs/FtsProofs/SnippetAndRanking.lean:152` | **B** | order law |
| 8 | `hit_tiebreak_cmp_refl` | `packages/fts/proofs/FtsProofs/SnippetAndRanking.lean:163` | **C3** | follows from zero_iff |
| 9 | `hit_tiebreak_cmp_antisymm` | `packages/fts/proofs/FtsProofs/SnippetAndRanking.lean:169` | **B** | comparator law (transitivity is NOT proven) |
| 10 | `hit_tiebreak_cmp_zero_iff` | `packages/fts/proofs/FtsProofs/SnippetAndRanking.lean:182` | **B** | comparator law |
| 11 | `hit_tiebreak_cmp_order_key_desc` | `packages/fts/proofs/FtsProofs/SnippetAndRanking.lean:199` | **C2** | restates first branch |
| 12 | `hit_tiebreak_cmp_doc_id_asc` | `packages/fts/proofs/FtsProofs/SnippetAndRanking.lean:206` | **C2** | restates third branch |
| 13 | `sanitize_scalar_valid` | `packages/fts/proofs/FtsProofs/Utf8AndTokenizer.lean:29` | **B** | output always a Unicode scalar |
| 14 | `sanitize_scalar_idempotent` | `packages/fts/proofs/FtsProofs/Utf8AndTokenizer.lean:47` | **C3** | follows from valid |
| 15 | `cp_utf8_len_bounds` | `packages/fts/proofs/FtsProofs/Utf8AndTokenizer.lean:66` | **C2** | four constant branches |
| 16 | `cp_utf8_len_surrogate` | `packages/fts/proofs/FtsProofs/Utf8AndTokenizer.lean:80` | **B** | surrogates encoded as U+FFFD length |
| 17 | `fold_ascii_cp_idempotent` | `packages/fts/proofs/FtsProofs/Utf8AndTokenizer.lean:97` | **B** | idempotence |
| 18 | `fold_greek_final_sigma` | `packages/fts/proofs/FtsProofs/Utf8AndTokenizer.lean:123` | **C1** | fixed input |
| 19 | `fold_greek_unassigned_3A2` | `packages/fts/proofs/FtsProofs/Utf8AndTokenizer.lean:129` | **C1** | fixed input |
| 20 | `fold_cyrillic_idempotent` | `packages/fts/proofs/FtsProofs/Utf8AndTokenizer.lean:135` | **B** | range + idempotence over Cyrillic block |
| 21 | `is_cjk_rt2_marks_excluded` | `packages/fts/proofs/FtsProofs/Utf8AndTokenizer.lean:229` | **C2** | restates the early-return branch |
| 22 | `is_cjk_ascii_disjoint` | `packages/fts/proofs/FtsProofs/Utf8AndTokenizer.lean:246` | **B** | disjoint classes |
| 23 | `camel_split_requires_upper` | `packages/fts/proofs/FtsProofs/Utf8AndTokenizer.lean:273` | **C2** | restates first conjunct |
| 24 | `camel_split_lower_to_upper` | `packages/fts/proofs/FtsProofs/Utf8AndTokenizer.lean:281` | **C2** | restates disjunct |

#### json5 — 24 条：A 0 / B 8 / C 16

| # | 定理 | 位置 | 级别 | 依据 |
|---:|---|---|---|---|
| 1 | `hash_ensure_nonzero_ne_zero` | `packages/json5/proofs/Json5Proofs/HashPointerAndSyntax.lean:29` | **C2** | body `if h == 0 { 1 } else { h }` |
| 2 | `hash_ensure_nonzero_idempotent` | `packages/json5/proofs/Json5Proofs/HashPointerAndSyntax.lean:37` | **C3** | corollary |
| 3 | `splitmix64_zero_nonzero` | `packages/json5/proofs/Json5Proofs/HashPointerAndSyntax.lean:45` | **C1** | fixed input 0 |
| 4 | `hash_needs_grow_guarantees_empty_slot` | `packages/json5/proofs/Json5Proofs/HashPointerAndSyntax.lean:58` | **B** | load-factor => probe terminates (len < 2^28) |
| 5 | `hash_needs_grow_full` | `packages/json5/proofs/Json5Proofs/HashPointerAndSyntax.lean:73` | **C3** | corollary of previous |
| 6 | `hash_next_slot_bounds` | `packages/json5/proofs/Json5Proofs/HashPointerAndSyntax.lean:86` | **B** | masked probe index in [0,mask] |
| 7 | `pointer_escape_unescape_tilde` | `packages/json5/proofs/Json5Proofs/HashPointerAndSyntax.lean:113` | **C1** | fixed inputs |
| 8 | `pointer_escape_unescape_slash` | `packages/json5/proofs/Json5Proofs/HashPointerAndSyntax.lean:119` | **C1** | fixed inputs |
| 9 | `pointer_unescape_roundtrip` | `packages/json5/proofs/Json5Proofs/HashPointerAndSyntax.lean:125` | **B** | RFC 6901 roundtrip |
| 10 | `json_needs_escape_ctrl` | `packages/json5/proofs/Json5Proofs/HashPointerAndSyntax.lean:136` | **C2** | restates `b < 0x20` |
| 11 | `json_needs_escape_printable_safe` | `packages/json5/proofs/Json5Proofs/HashPointerAndSyntax.lean:144` | **C2** | restates negation of body |
| 12 | `ascii_lut_flags_bounds` | `packages/json5/proofs/Json5Proofs/HashPointerAndSyntax.lean:164` | **B** | LUT value fits a Byte |
| 13 | `surrogate_ranges_disjoint` | `packages/json5/proofs/Json5Proofs/UnicodeAndUtf8.lean:75` | **C2** | two constant ranges |
| 14 | `decode_surrogate_pair_bounds` | `packages/json5/proofs/Json5Proofs/UnicodeAndUtf8.lean:88` | **B** | exact formula and supplementary-plane range |
| 15 | `decode_surrogate_pair_injective` | `packages/json5/proofs/Json5Proofs/UnicodeAndUtf8.lean:124` | **B** | injective on valid pairs |
| 16 | `pack_hex2_bounds` | `packages/json5/proofs/Json5Proofs/UnicodeAndUtf8.lean:144` | **B** | no overflow / byte range |
| 17 | `pack_hex4_bounds` | `packages/json5/proofs/Json5Proofs/UnicodeAndUtf8.lean:170` | **C3** | same as pack_hex2 with 4 nibbles |
| 18 | `is_unicode_j5_ws_non_ascii` | `packages/json5/proofs/Json5Proofs/UnicodeAndUtf8.lean:213` | **B** | no ASCII overlap |
| 19 | `is_unicode_j5_ws_line_seps` | `packages/json5/proofs/Json5Proofs/UnicodeAndUtf8.lean:238` | **C2** | restates three disjuncts |
| 20 | `utf8_valid_3byte_rejects_overlong` | `packages/json5/proofs/Json5Proofs/UnicodeAndUtf8.lean:249` | **C2** | restates `!(b0 == 0xE0 && b1 < 0xA0)` |
| 21 | `utf8_valid_3byte_rejects_surrogate` | `packages/json5/proofs/Json5Proofs/UnicodeAndUtf8.lean:258` | **C3** | restates `!(b0 == 0xED && b1 >= 0xA0)` |
| 22 | `utf8_valid_4byte_rejects_overlong` | `packages/json5/proofs/Json5Proofs/UnicodeAndUtf8.lean:267` | **C3** | restates `!(b0 == 0xF0 && b1 < 0x90)` |
| 23 | `utf8_valid_4byte_rejects_above_max` | `packages/json5/proofs/Json5Proofs/UnicodeAndUtf8.lean:276` | **C3** | restates `!(b0 == 0xF4 && b1 > 0x8F)` |
| 24 | `utf8_valid_3byte_requires_cont` | `packages/json5/proofs/Json5Proofs/UnicodeAndUtf8.lean:285` | **C3** | restates `is_utf8_cont(b1)` conjunct |

#### url — 24 条：A 2 / B 10 / C 12

| # | 定理 | 位置 | 级别 | 依据 |
|---:|---|---|---|---|
| 1 | `ipv4_u32_roundtrip` | `packages/url/proofs/UrlProofs/IpAddrs.lean:122` | **C2** | from_u32/to_u32 are a field wrap/unwrap; to_u32 has no production caller |
| 2 | `ipv4_new_exact_u32` | `packages/url/proofs/UrlProofs/IpAddrs.lean:127` | **B** | exact big-endian packing |
| 3 | `ipv4_new_octets_roundtrip` | `packages/url/proofs/UrlProofs/IpAddrs.lean:174` | **A** | bijection [0,255]^4 -> u32 (one direction) |
| 4 | `ipv4_octets_in_byte_range` | `packages/url/proofs/UrlProofs/IpAddrs.lean:209` | **C2** | every octet is `(... ) & 0xFF` |
| 5 | `ipv4_octets_new_roundtrip` | `packages/url/proofs/UrlProofs/IpAddrs.lean:225` | **A** | bijection over all 2^32 addresses (other direction) |
| 6 | `ipv4_eq_iff` | `packages/url/proofs/UrlProofs/IpAddrs.lean:267` | **C2** | body `self.bits == other.bits` |
| 7 | `ipv6_new_segments_in_u16_range` | `packages/url/proofs/UrlProofs/IpAddrs.lean:310` | **C2** | every field is `s & 0xFFFF` |
| 8 | `ipv6_new_idempotent_on_u16` | `packages/url/proofs/UrlProofs/IpAddrs.lean:323` | **B** | masking is identity on u16 |
| 9 | `ipv6_seg_exact` | `packages/url/proofs/UrlProofs/IpAddrs.lean:336` | **C2** | restates the 8-way if-chain |
| 10 | `ipv6_seg_new_bounds` | `packages/url/proofs/UrlProofs/IpAddrs.lean:344` | **C3** | corollary of the two above |
| 11 | `ipv6_eq_iff` | `packages/url/proofs/UrlProofs/IpAddrs.lean:361` | **C2** | 8-field conjunction == structural equality |
| 12 | `ipv6_eq_refl_symm` | `packages/url/proofs/UrlProofs/IpAddrs.lean:380` | **C3** | corollary of eq_iff |
| 13 | `puny_threshold_bounds` | `packages/url/proofs/UrlProofs/PunycodeAndPercent.lean:111` | **B** | RFC 3492 clamp |
| 14 | `puny_threshold_exact` | `packages/url/proofs/UrlProofs/PunycodeAndPercent.lean:135` | **C2** | restates the three branches |
| 15 | `puny_threshold_mono_k` | `packages/url/proofs/UrlProofs/PunycodeAndPercent.lean:160` | **B** | monotonic in k |
| 16 | `puny_encode_digit_ascii_range` | `packages/url/proofs/UrlProofs/PunycodeAndPercent.lean:178` | **C2** | restates both branches |
| 17 | `puny_digit_roundtrip` | `packages/url/proofs/UrlProofs/PunycodeAndPercent.lean:208` | **B** | encode/decode roundtrip on the 36 digits (exhaustively unit-testable) |
| 18 | `puny_decode_digit_case_insensitive` | `packages/url/proofs/UrlProofs/PunycodeAndPercent.lean:260` | **B** | case-insensitive decode |
| 19 | `puny_decode_digit_valid_iff` | `packages/url/proofs/UrlProofs/PunycodeAndPercent.lean:287` | **B** | exact classifier |
| 20 | `encode_set_mask_distinct_pow2` | `packages/url/proofs/UrlProofs/PunycodeAndPercent.lean:343` | **C1** | 7-variant enum, closed |
| 21 | `encode_byte_mask_controls_subset_all` | `packages/url/proofs/UrlProofs/PunycodeAndPercent.lean:418` | **B** | WHATWG set inclusion |
| 22 | `encode_byte_mask_hierarchy` | `packages/url/proofs/UrlProofs/PunycodeAndPercent.lean:464` | **B** | WHATWG set inclusion chain over 0..255 |
| 23 | `encode_byte_mask_ascii_alnum_safe` | `packages/url/proofs/UrlProofs/PunycodeAndPercent.lean:505` | **B** | alnum never encoded |
| 24 | `encode_byte_mask_c0_del_nonascii_always_encoded` | `packages/url/proofs/UrlProofs/PunycodeAndPercent.lean:523` | **C3** | overlaps controls_subset_all |

#### time — 47 条：A 11 / B 11 / C 25

| # | 定理 | 位置 | 级别 | 依据 |
|---:|---|---|---|---|
| 1 | `is_leap_year_spec` | `packages/time/proofs/TimeProofs/Calendar.lean:30` | **B** | Gregorian rule vs spec over all Int32 (incl. negative) |
| 2 | `leap_year_1900` | `packages/time/proofs/TimeProofs/Calendar.lean:79` | **C1** | fixed input |
| 3 | `leap_year_2000` | `packages/time/proofs/TimeProofs/Calendar.lean:82` | **C1** | fixed input |
| 4 | `leap_year_2100` | `packages/time/proofs/TimeProofs/Calendar.lean:85` | **C1** | fixed input |
| 5 | `leap_year_2400` | `packages/time/proofs/TimeProofs/Calendar.lean:88` | **C1** | fixed input |
| 6 | `leap_year_zero` | `packages/time/proofs/TimeProofs/Calendar.lean:91` | **C1** | fixed input |
| 7 | `leap_year_neg400` | `packages/time/proofs/TimeProofs/Calendar.lean:94` | **C1** | fixed input |
| 8 | `leap_year_neg100` | `packages/time/proofs/TimeProofs/Calendar.lean:97` | **C1** | fixed input |
| 9 | `days_in_month_of_spec` | `packages/time/proofs/TimeProofs/Calendar.lean:102` | **B** | matches spec table, 28..31 |
| 10 | `days_in_month_of_feb` | `packages/time/proofs/TimeProofs/Calendar.lean:144` | **C3** | corollary of the spec |
| 11 | `to_epoch_days_spec` | `packages/time/proofs/TimeProofs/Calendar.lean:174` | **A** | full civil-date -> epoch-day correctness vs mathematical spec |
| 12 | `from_epoch_days_spec` | `packages/time/proofs/TimeProofs/Calendar.lean:552` | **A** | full epoch-day -> civil-date correctness vs spec |
| 13 | `from_epoch_days_out_of_range` | `packages/time/proofs/TimeProofs/Calendar.lean:716` | **B** | error branch total |
| 14 | `to_epoch_days_from_epoch_days` | `packages/time/proofs/TimeProofs/Calendar.lean:821` | **A** | roundtrip |
| 15 | `from_epoch_days_to_epoch_days` | `packages/time/proofs/TimeProofs/Calendar.lean:836` | **A** | roundtrip |
| 16 | `signed_duration_zero_valid` | `packages/time/proofs/TimeProofs/Duration.lean:54` | **C1** | zero-arg constant |
| 17 | `signed_duration_min_valid` | `packages/time/proofs/TimeProofs/Duration.lean:61` | **C1** | zero-arg constant |
| 18 | `signed_duration_max_valid` | `packages/time/proofs/TimeProofs/Duration.lean:68` | **C1** | zero-arg constant |
| 19 | `checked_add_i64_spec` | `packages/time/proofs/TimeProofs/Duration.lean:76` | **A** | exact overflow detection over all Int64 pairs |
| 20 | `checked_sub_i64_spec` | `packages/time/proofs/TimeProofs/Duration.lean:146` | **A** | exact overflow detection over all Int64 pairs |
| 21 | `signed_duration_new_sound` | `packages/time/proofs/TimeProofs/Duration.lean:273` | **A** | normalisation + range check over all (secs,nanos) |
| 22 | `signed_duration_checked_neg_sound` | `packages/time/proofs/TimeProofs/Duration.lean:373` | **A** | checked negation vs spec |
| 23 | `signed_duration_checked_add_sound` | `packages/time/proofs/TimeProofs/Duration.lean:404` | **A** | checked add vs spec (carry of nanos) |
| 24 | `signed_duration_checked_sub_sound` | `packages/time/proofs/TimeProofs/Duration.lean:521` | **A** | checked sub vs spec |
| 25 | `signed_duration_cmp_spec` | `packages/time/proofs/TimeProofs/Duration.lean:612` | **B** | comparator == order on total nanos |
| 26 | `signed_duration_cmp_refl` | `packages/time/proofs/TimeProofs/Duration.lean:647` | **C3** | corollary of cmp_spec |
| 27 | `signed_duration_cmp_antisymm` | `packages/time/proofs/TimeProofs/Duration.lean:651` | **C3** | corollary of cmp_spec |
| 28 | `signed_duration_cmp_trans_lt` | `packages/time/proofs/TimeProofs/Duration.lean:657` | **C3** | corollary of cmp_spec |
| 29 | `date_cmp_total` | `packages/time/proofs/TimeProofs/Order.lean:16` | **C3** | corollary of the if-chain |
| 30 | `date_cmp_refl` | `packages/time/proofs/TimeProofs/Order.lean:21` | **C3** | corollary |
| 31 | `date_cmp_lt_iff` | `packages/time/proofs/TimeProofs/Order.lean:24` | **B** | lexicographic spec |
| 32 | `date_cmp_eq_zero_iff` | `packages/time/proofs/TimeProofs/Order.lean:62` | **B** | comparator law |
| 33 | `date_cmp_antisymm` | `packages/time/proofs/TimeProofs/Order.lean:80` | **C3** | corollary of lt_iff |
| 34 | `date_cmp_trans_lt` | `packages/time/proofs/TimeProofs/Order.lean:120` | **C3** | corollary of lt_iff |
| 35 | `to_epoch_days_strict_mono` | `packages/time/proofs/TimeProofs/Order.lean:128` | **A** | order isomorphism date order <-> epoch-day order |
| 36 | `time_to_second_of_day_spec` | `packages/time/proofs/TimeProofs/Order.lean:148` | **B** | exact + range |
| 37 | `time_cmp_spec` | `packages/time/proofs/TimeProofs/Order.lean:167` | **B** | comparator spec |
| 38 | `time_cmp_refl` | `packages/time/proofs/TimeProofs/Order.lean:212` | **C3** | corollary of spec |
| 39 | `time_cmp_antisymm` | `packages/time/proofs/TimeProofs/Order.lean:215` | **C3** | corollary of spec |
| 40 | `time_cmp_trans_lt` | `packages/time/proofs/TimeProofs/Order.lean:220` | **C3** | corollary of spec |
| 41 | `timestamp_cmp_spec` | `packages/time/proofs/TimeProofs/Order.lean:235` | **B** | comparator spec |
| 42 | `timestamp_cmp_refl` | `packages/time/proofs/TimeProofs/Order.lean:269` | **C3** | corollary of spec |
| 43 | `timestamp_cmp_antisymm` | `packages/time/proofs/TimeProofs/Order.lean:272` | **C3** | corollary of spec |
| 44 | `timestamp_cmp_trans_lt` | `packages/time/proofs/TimeProofs/Order.lean:277` | **C3** | corollary of spec |
| 45 | `datetime_cmp_refl` | `packages/time/proofs/TimeProofs/Order.lean:286` | **C3** | corollary |
| 46 | `datetime_cmp_antisymm` | `packages/time/proofs/TimeProofs/Order.lean:292` | **B** | comparator law (no spec theorem for DateTime) |
| 47 | `datetime_cmp_trans_lt` | `packages/time/proofs/TimeProofs/Order.lean:309` | **B** | comparator law |

#### http1 — 49 条：A 3 / B 18 / C 28

| # | 定理 | 位置 | 级别 | 依据 |
|---:|---|---|---|---|
| 1 | `is_tchar_byte_rejects_ctl_sp_nonascii` | `packages/http1/proofs/Http1Proofs/CharClass.lean:8` | **B** | RFC 9110 token class excludes CTL/SP/non-ASCII |
| 2 | `is_tchar_byte_accepts_alnum` | `packages/http1/proofs/Http1Proofs/CharClass.lean:19` | **B** | token class includes alnum |
| 3 | `is_uri_byte_spec` | `packages/http1/proofs/Http1Proofs/CharClass.lean:30` | **C2** | body `b >= 33 && b <= 126` |
| 4 | `is_header_val_byte_spec` | `packages/http1/proofs/Http1Proofs/CharClass.lean:37` | **C2** | restates body |
| 5 | `is_crlf_or_nul_byte_spec` | `packages/http1/proofs/Http1Proofs/CharClass.lean:55` | **C2** | restates body |
| 6 | `is_header_val_byte_rejects_crlf_nul` | `packages/http1/proofs/Http1Proofs/CharClass.lean:70` | **B** | cross-function: header values can never carry CR/LF/NUL (smuggling) |
| 7 | `is_tchar_byte_rejects_crlf_nul` | `packages/http1/proofs/Http1Proofs/CharClass.lean:80` | **C3** | same cross-check for tchar |
| 8 | `is_uri_byte_rejects_crlf_nul` | `packages/http1/proofs/Http1Proofs/CharClass.lean:88` | **C3** | same cross-check for URI |
| 9 | `ascii_lower_byte_spec` | `packages/http1/proofs/Http1Proofs/CharClass.lean:98` | **C2** | restates body |
| 10 | `ascii_lower_byte_idempotent` | `packages/http1/proofs/Http1Proofs/CharClass.lean:116` | **C3** | corollary |
| 11 | `hex_digit_value_spec` | `packages/http1/proofs/Http1Proofs/CharClass.lean:126` | **B** | exact 4-branch spec |
| 12 | `hex_digit_value_bounds` | `packages/http1/proofs/Http1Proofs/CharClass.lean:166` | **C3** | corollary of spec |
| 13 | `hex_digit_value_case_insensitive` | `packages/http1/proofs/Http1Proofs/CharClass.lean:175` | **B** | cross-function composition |
| 14 | `is_host_byte_rejects_ctl_sp_nonascii` | `packages/http1/proofs/Http1Proofs/CharClass.lean:186` | **C3** | same shape as tchar theorem |
| 15 | `limits_default_positive` | `packages/http1/proofs/Http1Proofs/Core.lean:115` | **C1** | zero-arg constant record |
| 16 | `version_eq_iff` | `packages/http1/proofs/Http1Proofs/Framing.lean:8` | **C2** | 2-variant enum equality |
| 17 | `is_bodyless_status_spec` | `packages/http1/proofs/Http1Proofs/Framing.lean:13` | **C2** | restates body |
| 18 | `effective_response_framing_bodyless` | `packages/http1/proofs/Http1Proofs/Framing.lean:31` | **B** | RFC 9112 6.3 bodyless statuses force no body |
| 19 | `effective_response_framing_body_allowed` | `packages/http1/proofs/Http1Proofs/Framing.lean:39` | **C3** | complement branch |
| 20 | `te_coding_step_rejects_after_chunked` | `packages/http1/proofs/Http1Proofs/Framing.lean:47` | **B** | chunked must be the final coding (smuggling) |
| 21 | `te_coding_step_rejects_unknown` | `packages/http1/proofs/Http1Proofs/Framing.lean:53` | **C3** | other branch |
| 22 | `check_framing_cl_rejects_after_te` | `packages/http1/proofs/Http1Proofs/Framing.lean:62` | **B** | CL after TE rejected (smuggling) |
| 23 | `check_framing_cl_rejects_duplicate` | `packages/http1/proofs/Http1Proofs/Framing.lean:67` | **C3** | branch |
| 24 | `check_framing_cl_rejects_negative` | `packages/http1/proofs/Http1Proofs/Framing.lean:72` | **C3** | branch |
| 25 | `check_framing_cl_accepts_valid` | `packages/http1/proofs/Http1Proofs/Framing.lean:79` | **C3** | branch |
| 26 | `check_framing_te_rejects_after_cl` | `packages/http1/proofs/Http1Proofs/Framing.lean:87` | **C3** | mirror of cl_rejects_after_te |
| 27 | `check_framing_te_rejects_http10` | `packages/http1/proofs/Http1Proofs/Framing.lean:92` | **B** | TE on HTTP/1.0 rejected |
| 28 | `check_framing_te_rejects_neg_state` | `packages/http1/proofs/Http1Proofs/Framing.lean:98` | **C3** | branch |
| 29 | `check_framing_te_accepts_valid` | `packages/http1/proofs/Http1Proofs/Framing.lean:105` | **C3** | branch |
| 30 | `check_framing_host_rejects_duplicate` | `packages/http1/proofs/Http1Proofs/Framing.lean:112` | **B** | duplicate Host rejected |
| 31 | `check_framing_host_rejects_invalid` | `packages/http1/proofs/Http1Proofs/Framing.lean:120` | **C3** | branch |
| 32 | `check_framing_host_accepts_first` | `packages/http1/proofs/Http1Proofs/Framing.lean:126` | **C1** | fixed input |
| 33 | `framing_init_inv` | `packages/http1/proofs/Http1Proofs/Framing.lean:137` | **C1** | closed fact about the initial state |
| 34 | `check_framing_cl_preserves_inv` | `packages/http1/proofs/Http1Proofs/Framing.lean:141` | **B** | framing invariant preservation |
| 35 | `check_framing_te_preserves_inv` | `packages/http1/proofs/Http1Proofs/Framing.lean:161` | **B** | framing invariant preservation |
| 36 | `check_framing_host_preserves_inv` | `packages/http1/proofs/Http1Proofs/Framing.lean:173` | **B** | framing invariant preservation |
| 37 | `check_framing_finalize_http11_requires_host` | `packages/http1/proofs/Http1Proofs/Framing.lean:191` | **B** | HTTP/1.1 requires Host |
| 38 | `check_framing_finalize_request_te_requires_chunked` | `packages/http1/proofs/Http1Proofs/Framing.lean:199` | **B** | request TE must end in chunked |
| 39 | `check_framing_finalize_cl_nonneg` | `packages/http1/proofs/Http1Proofs/Framing.lean:211` | **B** | CL framing => CL >= 0 and no TE (uses invariant) |
| 40 | `parse_http_minor_spec` | `packages/http1/proofs/Http1Proofs/Numeric.lean:9` | **C2** | restates 3 branches |
| 41 | `parse_status_digits_ok` | `packages/http1/proofs/Http1Proofs/Numeric.lean:35` | **B** | exact 3-digit parse |
| 42 | `parse_status_digits_rejects_nondigit` | `packages/http1/proofs/Http1Proofs/Numeric.lean:76` | **C3** | complement |
| 43 | `is_valid_encode_status_spec` | `packages/http1/proofs/Http1Proofs/Numeric.lean:91` | **C2** | restates body |
| 44 | `u63_decimal_step_ok` | `packages/http1/proofs/Http1Proofs/Numeric.lean:99` | **A** | overflow-checked decimal accumulate exact for all Int64 |
| 45 | `u63_decimal_step_rejects_overflow_or_invalid` | `packages/http1/proofs/Http1Proofs/Numeric.lean:152` | **A** | exact overflow rejection (with _ok: complete characterisation) |
| 46 | `chunk_size_hex_step_rejects_too_many_digits` | `packages/http1/proofs/Http1Proofs/Numeric.lean:276` | **C2** | restates first branch |
| 47 | `chunk_size_hex_step_ok` | `packages/http1/proofs/Http1Proofs/Numeric.lean:289` | **A** | overflow-checked hex accumulate exact |
| 48 | `chunk_size_hex_step_rejects_overflow` | `packages/http1/proofs/Http1Proofs/Numeric.lean:332` | **B** | sufficient (not exact) overflow condition |
| 49 | `chunk_size_check_limit_spec` | `packages/http1/proofs/Http1Proofs/Numeric.lean:355` | **C2** | restates 3 branches |

#### websocket — 34 条：A 0 / B 12 / C 22

| # | 定理 | 位置 | 级别 | 依据 |
|---:|---|---|---|---|
| 1 | `mask_byte_xor_involutive` | `packages/websocket/proofs/WebsocketProofs/FrameMask.lean:8` | **B** | RFC 6455 masking is an involution |
| 2 | `mask_byte_xor_zero` | `packages/websocket/proofs/WebsocketProofs/FrameMask.lean:21` | **C3** | xor 0 |
| 3 | `mask_byte_xor_comm` | `packages/websocket/proofs/WebsocketProofs/FrameMask.lean:31` | **C4** | xor commutativity |
| 4 | `mask_key_byte_bounds` | `packages/websocket/proofs/WebsocketProofs/FrameMask.lean:54` | **B** | byte range |
| 5 | `mask_key_byte_periodic` | `packages/websocket/proofs/WebsocketProofs/FrameMask.lean:89` | **B** | period 4 (holds across Int32 wrap) |
| 6 | `encoded_ext_len_spec` | `packages/websocket/proofs/WebsocketProofs/FrameMask.lean:110` | **C2** | restates 3 branches |
| 7 | `encoded_header_len_bounds` | `packages/websocket/proofs/WebsocketProofs/FrameMask.lean:133` | **B** | header length 2..14 |
| 8 | `is_minimal_len16_spec` | `packages/websocket/proofs/WebsocketProofs/FrameMask.lean:147` | **C2** | restates body |
| 9 | `check_ext_len64_rejects_msb` | `packages/websocket/proofs/WebsocketProofs/FrameMask.lean:153` | **B** | RFC 6455 5.2 MSB must be 0 |
| 10 | `check_ext_len64_rejects_nonminimal` | `packages/websocket/proofs/WebsocketProofs/FrameMask.lean:160` | **C3** | branch |
| 11 | `check_ext_len64_rejects_too_large` | `packages/websocket/proofs/WebsocketProofs/FrameMask.lean:170` | **B** | frame size limit (DoS) |
| 12 | `check_ext_len64_accepts_valid` | `packages/websocket/proofs/WebsocketProofs/FrameMask.lean:184` | **C3** | branch |
| 13 | `clamp_i64_to_i32_max_spec` | `packages/websocket/proofs/WebsocketProofs/FrameMask.lean:198` | **C2** | min(n, MAX) |
| 14 | `frame_total_bytes_exact` | `packages/websocket/proofs/WebsocketProofs/FrameMask.lean:216` | **C4** | Int32 -> Int64 widening sum is exact |
| 15 | `frag_sum_i64_exact` | `packages/websocket/proofs/WebsocketProofs/FrameMask.lean:240` | **C4** | Int32 -> Int64 widening sum is exact |
| 16 | `opcode_roundtrip` | `packages/websocket/proofs/WebsocketProofs/Protocol.lean:8` | **C1** | 6-variant enum |
| 17 | `opcode_from_int_sound` | `packages/websocket/proofs/WebsocketProofs/Protocol.lean:13` | **B** | decode sound over all Int32 |
| 18 | `opcode_from_int_rejects_reserved` | `packages/websocket/proofs/WebsocketProofs/Protocol.lean:26` | **C3** | complement of the match |
| 19 | `is_control_opcode_iff_ge8` | `packages/websocket/proofs/WebsocketProofs/Protocol.lean:39` | **C1** | 6-variant enum |
| 20 | `check_role_mask_spec` | `packages/websocket/proofs/WebsocketProofs/Protocol.lean:44` | **C1** | four fixed inputs |
| 21 | `check_control_frame_spec` | `packages/websocket/proofs/WebsocketProofs/Protocol.lean:52` | **C2** | restates branches |
| 22 | `is_valid_close_code_spec` | `packages/websocket/proofs/WebsocketProofs/Protocol.lean:71` | **C2** | restates body |
| 23 | `is_valid_close_code_rejects_forbidden` | `packages/websocket/proofs/WebsocketProofs/Protocol.lean:91` | **C3** | corollary |
| 24 | `utf8_dfa_sticky_error` | `packages/websocket/proofs/WebsocketProofs/Utf8.lean:8` | **B** | error state is absorbing |
| 25 | `utf8_dfa_ascii_accept` | `packages/websocket/proofs/WebsocketProofs/Utf8.lean:15` | **B** | ASCII from state 0 |
| 26 | `utf8_dfa_rejects_lone_continuation` | `packages/websocket/proofs/WebsocketProofs/Utf8.lean:26` | **C3** | single DFA cell family |
| 27 | `utf8_dfa_rejects_overlong_c0_c1` | `packages/websocket/proofs/WebsocketProofs/Utf8.lean:36` | **C3** | single DFA cell family |
| 28 | `utf8_dfa_rejects_above_f4` | `packages/websocket/proofs/WebsocketProofs/Utf8.lean:46` | **C3** | single DFA cell family |
| 29 | `utf8_dfa_rejects_overlong_e0` | `packages/websocket/proofs/WebsocketProofs/Utf8.lean:56` | **B** | 2-step overlong rejection |
| 30 | `utf8_dfa_rejects_surrogate_ed` | `packages/websocket/proofs/WebsocketProofs/Utf8.lean:72` | **C3** | same shape as e0 |
| 31 | `utf8_dfa_rejects_overlong_f0` | `packages/websocket/proofs/WebsocketProofs/Utf8.lean:89` | **C3** | same shape as e0 |
| 32 | `utf8_dfa_rejects_above_10ffff_f4` | `packages/websocket/proofs/WebsocketProofs/Utf8.lean:107` | **C3** | same shape as e0 |
| 33 | `utf8_dfa_accepts_valid_2byte` | `packages/websocket/proofs/WebsocketProofs/Utf8.lean:127` | **B** | 2-byte acceptance |
| 34 | `utf8_dfa_state_bounds` | `packages/websocket/proofs/WebsocketProofs/Utf8.lean:198` | **B** | state stays in [-1,7] for all inputs |

#### base64 — 20 条：A 1 / B 4 / C 15

| # | 定理 | 位置 | 级别 | 依据 |
|---:|---|---|---|---|
| 1 | `b32_tail_roundtrip` | `packages/base64/proofs/Base64Proofs/Base32.lean:8` | **C1** | 5 fixed values |
| 2 | `b32_tail_bytes_rejects_invalid` | `packages/base64/proofs/Base64Proofs/Base32.lean:15` | **C1** | fixed inputs |
| 3 | `b32_encoded_len_pad_div8` | `packages/base64/proofs/Base64Proofs/Base32.lean:22` | **C5** | n <= 1e9 hides (n/5+1)*8 overflow above 1342177275 |
| 4 | `b32_encoded_len_nopad_roundtrip` | `packages/base64/proofs/Base64Proofs/Base32.lean:60` | **C5** | n <= 1e9 hides the same overflow |
| 5 | `b32_spare_mask_spec` | `packages/base64/proofs/Base64Proofs/Base32.lean:153` | **C1** | fixed inputs |
| 6 | `b32_spare_mask_canonical_zero` | `packages/base64/proofs/Base64Proofs/Base32.lean:163` | **C4** | pure BitVec shift/mask fact; mentions no package function |
| 7 | `b64_pack3_bounds` | `packages/base64/proofs/Base64Proofs/BitPack.lean:27` | **B** | 24-bit range |
| 8 | `b64_pack3_pack4_roundtrip` | `packages/base64/proofs/Base64Proofs/BitPack.lean:57` | **A** | bit-pack roundtrip over all byte triples |
| 9 | `b64_pack4_neg_if_invalid` | `packages/base64/proofs/Base64Proofs/BitPack.lean:172` | **B** | -1 sentinel propagates to a negative pack |
| 10 | `hex_len_roundtrip` | `packages/base64/proofs/Base64Proofs/BitPack.lean:204` | **C5** | n <= 2^30-1 hides hex_encoded_len n*2 overflow at n >= 2^30 |
| 11 | `hex_decoded_len_rejects_odd` | `packages/base64/proofs/Base64Proofs/BitPack.lean:244` | **C2** | restates body |
| 12 | `hex_pack_byte_roundtrip` | `packages/base64/proofs/Base64Proofs/BitPack.lean:263` | **B** | 256 values |
| 13 | `hex_pack_byte_neg_if_invalid` | `packages/base64/proofs/Base64Proofs/BitPack.lean:314` | **B** | sentinel propagation |
| 14 | `b64_encoded_len_pad_spec` | `packages/base64/proofs/Base64Proofs/Core.lean:117` | **C2+C5** | restates formula; n <= 536870910 hides the Int32 overflow for n >= 1610612734 |
| 15 | `b64_encoded_len_nopad_spec` | `packages/base64/proofs/Base64Proofs/Core.lean:134` | **C2+C5** | restates formula; n <= 536870910 hides the n*4 overflow at n >= 536870912 (probe P-B64) |
| 16 | `b64_decoded_len_rejects_mod1` | `packages/base64/proofs/Base64Proofs/Core.lean:151` | **C2** | restates branch |
| 17 | `b64_length_roundtrip` | `packages/base64/proofs/Base64Proofs/Core.lean:160` | **C5** | roundtrip only for n <= 536870910; encode of a >=512 MiB Bytes overflows encoded_len |
| 18 | `b64_expected_pad_completes_group` | `packages/base64/proofs/Base64Proofs/Core.lean:193` | **C1** | 3 fixed values |
| 19 | `b64_tail_canonical_mask_spec` | `packages/base64/proofs/Base64Proofs/Core.lean:198` | **C1** | fixed inputs |
| 20 | `b64_encoded_len_mono` | `packages/base64/proofs/Base64Proofs/Core.lean:205` | **C5** | monotone only below the overflow point |

#### flate — 19 条：A 1 / B 5 / C 13

| # | 定理 | 位置 | 级别 | 依据 |
|---:|---|---|---|---|
| 1 | `is_valid_level_spec` | `packages/flate/proofs/FlateProofs/Core.lean:88` | **C2** | restates body |
| 2 | `decompress_limits_default_spec` | `packages/flate/proofs/FlateProofs/Core.lean:93` | **C1** | zero-arg constant |
| 3 | `decompress_limits_new_spec` | `packages/flate/proofs/FlateProofs/Core.lean:100` | **C2** | identity record constructor |
| 4 | `is_valid_btype_spec` | `packages/flate/proofs/FlateProofs/Core.lean:105` | **C2** | restates body |
| 5 | `is_valid_stored_nlen_spec` | `packages/flate/proofs/FlateProofs/Core.lean:110` | **C2** | xor symmetry of `(slen ^ nlen) == 0xFFFF` |
| 6 | `huff_direct_entry_roundtrip` | `packages/flate/proofs/FlateProofs/HuffmanChecksum.lean:37` | **A** | table-entry pack/unpack roundtrip (decoder relies on it) |
| 7 | `huff_subtable_entry_roundtrip` | `packages/flate/proofs/FlateProofs/HuffmanChecksum.lean:132` | **B** | same for subtable entries |
| 8 | `huff_direct_subtable_disjoint` | `packages/flate/proofs/FlateProofs/HuffmanChecksum.lean:228` | **B** | tag bit distinguishes entries |
| 9 | `bit_reverse_zero_bits` | `packages/flate/proofs/FlateProofs/HuffmanChecksum.lean:242` | **C2** | 0-iteration loop case; the real reversal property is not proven |
| 10 | `adler32_pack_roundtrip` | `packages/flate/proofs/FlateProofs/HuffmanChecksum.lean:258` | **B** | pack/unpack |
| 11 | `adler32_pack_injective` | `packages/flate/proofs/FlateProofs/HuffmanChecksum.lean:334` | **C3** | corollary |
| 12 | `crc32_byte_poly_ieee_vectors` | `packages/flate/proofs/FlateProofs/HuffmanChecksum.lean:368` | **C1** | 4 test vectors; loop correctness not proven |
| 13 | `zlib_flevel_spec` | `packages/flate/proofs/FlateProofs/Zlib.lean:20` | **C2** | restates 4 branches |
| 14 | `zlib_flevel_bounds` | `packages/flate/proofs/FlateProofs/Zlib.lean:49` | **C3** | corollary |
| 15 | `zlib_compute_flg_fcheck` | `packages/flate/proofs/FlateProofs/Zlib.lean:62` | **B** | RFC 1950 FCHECK (finite 256x4 domain) |
| 16 | `zlib_encoder_decoder_duality` | `packages/flate/proofs/FlateProofs/Zlib.lean:121` | **B** | encoder header always accepted by decoder |
| 17 | `zlib_check_header_rejects_bad_fcheck` | `packages/flate/proofs/FlateProofs/Zlib.lean:149` | **C2** | restates first branch |
| 18 | `zlib_check_header_rejects_bad_cm_and_cinfo` | `packages/flate/proofs/FlateProofs/Zlib.lean:173` | **C1** | fixed inputs |
| 19 | `zlib_standard_headers_valid` | `packages/flate/proofs/FlateProofs/Zlib.lean:206` | **C1** | fixed inputs |

#### crdt — 29 条：A 0 / B 5 / C 24

| # | 定理 | 位置 | 级别 | 依据 |
|---:|---|---|---|---|
| 1 | `id_eq_iff` | `packages/crdt/proofs/CrdtProofs/Core.lean:71` | **C2** | 2-field conjunction == structural equality |
| 2 | `id_eq_refl` | `packages/crdt/proofs/CrdtProofs/Core.lean:79` | **C3** | corollary |
| 3 | `id_eq_symm` | `packages/crdt/proofs/CrdtProofs/Core.lean:84` | **C3** | corollary |
| 4 | `opt_id_eq_iff` | `packages/crdt/proofs/CrdtProofs/Core.lean:99` | **B** | Option lifting correct |
| 5 | `id_cmp_trichotomy` | `packages/crdt/proofs/CrdtProofs/Core.lean:117` | **C2** | DEAD: Id::cmp has no production caller |
| 6 | `id_cmp_eq_zero_iff` | `packages/crdt/proofs/CrdtProofs/Core.lean:124` | **C3** | DEAD target |
| 7 | `id_cmp_antisymm` | `packages/crdt/proofs/CrdtProofs/Core.lean:149` | **C3** | DEAD target |
| 8 | `id_cmp_trans` | `packages/crdt/proofs/CrdtProofs/Core.lean:158` | **C3** | DEAD target |
| 9 | `yata_same_origin_strict_order` | `packages/crdt/proofs/CrdtProofs/Core.lean:185` | **C4** | body is `lhs < rhs` on UInt64: order laws of `<` |
| 10 | `type_ref_roundtrip` | `packages/crdt/proofs/CrdtProofs/Store.lean:8` | **C1** | 3-variant enum |
| 11 | `type_ref_to_int_range` | `packages/crdt/proofs/CrdtProofs/Store.lean:13` | **C1** | 3-variant enum |
| 12 | `int_to_type_ref_injective_on_valid` | `packages/crdt/proofs/CrdtProofs/Store.lean:18` | **C1** | 3 values |
| 13 | `item_last_id_spec` | `packages/crdt/proofs/CrdtProofs/Store.lean:54` | **C5** | clock+len < 2^64 assumed; Item ids/lengths come from the wire unchecked |
| 14 | `item_last_id_singleton` | `packages/crdt/proofs/CrdtProofs/Store.lean:73` | **C3** | branch |
| 15 | `delete_item_contains_iff` | `packages/crdt/proofs/CrdtProofs/Store.lean:79` | **C2+C5** | restates body; hypothesis clock+len < 2^64 excludes wire-reachable wrap (read_delete_set never checks it) |
| 16 | `delete_item_contains_empty` | `packages/crdt/proofs/CrdtProofs/Store.lean:88` | **C3** | corollary |
| 17 | `delete_item_can_merge_iff` | `packages/crdt/proofs/CrdtProofs/Store.lean:107` | **C2+C5** | restates body; same unchecked wrap excluded by hypothesis |
| 18 | `delete_item_merge_sound` | `packages/crdt/proofs/CrdtProofs/Store.lean:116` | **C5** | only proven for clock+len < 2^64; decoder accepts any UInt64 clock/len from the wire |
| 19 | `delete_item_merge_covers_both` | `packages/crdt/proofs/CrdtProofs/Store.lean:138` | **C5** | the strongest crdt theorem, but its no-wrap hypotheses exclude exactly the attacker-reachable inputs (see probe P-CRDT) |
| 20 | `delete_item_merge_idempotent` | `packages/crdt/proofs/CrdtProofs/Store.lean:157` | **C3+C5** | corollary; same excluded wrap |
| 21 | `encode_item_info_ref_id` | `packages/crdt/proofs/CrdtProofs/Wire.lean:49` | **B** | info byte field roundtrip |
| 22 | `encode_item_info_has_origin` | `packages/crdt/proofs/CrdtProofs/Wire.lean:65` | **C3** | same roundtrip split per flag |
| 23 | `encode_item_info_has_right_origin` | `packages/crdt/proofs/CrdtProofs/Wire.lean:81` | **C3** | same roundtrip split per flag |
| 24 | `encode_item_info_has_parent_sub` | `packages/crdt/proofs/CrdtProofs/Wire.lean:97` | **C3** | same roundtrip split per flag |
| 25 | `encode_item_info_cant_copy_parent` | `packages/crdt/proofs/CrdtProofs/Wire.lean:113` | **C3** | composition of the two flag theorems |
| 26 | `encode_item_info_bounds` | `packages/crdt/proofs/CrdtProofs/Wire.lean:126` | **B** | fits a byte |
| 27 | `hex_nibble_roundtrip` | `packages/crdt/proofs/CrdtProofs/Wire.lean:155` | **B** | 16 values |
| 28 | `parse_hex_nibble_case_insensitive` | `packages/crdt/proofs/CrdtProofs/Wire.lean:194` | **C3** | duplicate of the hex helpers in other packages |
| 29 | `parse_hex_nibble_range` | `packages/crdt/proofs/CrdtProofs/Wire.lean:225` | **B** | range (duplicate helper) |

