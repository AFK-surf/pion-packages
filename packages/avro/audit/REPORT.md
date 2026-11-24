# 红队审计报告：Pion `packages/avro` v0.1.0 @ `79be97f`（`feat/pkg-avro`）

对照基准：Apache Avro **1.11.1** 规范（Java 参考实现的行为作为规范歧义处的裁决）、Go [`github.com/hamba/avro/v2`](https://github.com/hamba/avro) **v2.28.0**（与 `bench/go` 相同，`go.sum` 锁定、`-mod=readonly`）。
环境：Apple M5 Max (Darwin arm64，`pionc 0.1.0` / `AFK-surf/pion@66d2b4b`，Go 1.27.3，Node 24），2026-11-24。整机同时有其他负载，计时以同一轮的**倍率**为准。

## 一键复现

```sh
export PATH="$HOME/.pion/bin:$PATH"
sh packages/avro/audit/run_audit.sh              # 全量，约 1.5–2 分钟（含 4 GB 的 wasm32 OOM 探针与 bench 重跑）
QUICK=1 sh packages/avro/audit/run_audit.sh      # 2,000 个 fuzz 用例，跳过 wasm32 OOM 探针和 bench
cd packages/avro && pionc test --json audit      # 只跑红队单测：16 个 redteam_* FAIL = 16 条铁证，9 个 control_* PASS
```

退出码：红队单测全绿、hamba 差分没有 `FINDING` 桶、所有 DoS / 崩溃探针都在阈值内、4 模一致、worktree 干净时才是 0。当前 **exit 1，7 道闸门失败**。修复分支不改 `audit/` 一个字节即可重跑。所有构建产物、输入和日志写到 `$AUDIT_OUT`（默认 `/private/tmp/rt-avro-audit-$USER`），不进 git worktree；`pionc test packages/avro`（原有 16 个测试）不受影响。

| 文件 | 作用 |
|---|---|
| `redteam_test.pion` | 16 个 `redteam_*`（FAIL 即铁证，断言按规范 / Java / hamba 行为写）+ 9 个 `control_*`（Pion 扛住的攻击，必须保持绿色） |
| `src/lib.pion` | 单测辅助：hex、varint、OCF 头 / 块构造 |
| `probe/`（Pion）· `go/main.go`（hamba） | 同协议差分探针：`S`（解析 + PCF + CRC-64-AVRO）、`D`（二进制解码）、`R`（演进解析），输出按 schema 规范化的文本；另有 OCF / 深递归 / 4 模 `smoke` 模式 |
| `diff_oracle.py` | 53 个手写规范用例 + N 个随机 schema / 合法与变异数据 / 随机演进（seed 1111），按 `FINDING` / `spec-ambiguity` / `pion-stricter` / `hamba-deviation` 分桶 |
| `gen_ocf.py` · `measure.py` | 对抗 `.avro` 生成（元素放大、deflate 炸弹、超大 enum 头）；单次运行的退出码 / 信号 / 墙钟 / 峰值 RSS |

---

## 结论速览

| 级别 | # | 指控 | 证据 |
|---|---|---|---|
| **P0** | F-03 | `max_elements` 是**每个 OCF 块**的预算（每块新建 `BinReader`，`elements` 清零），文件级只数记录条数；`read_ocf` 又没有流式 API，全部物化 | **1,493 B → 64,000,000 个值、494 MiB**（放大约 35 万倍，随块数线性）；wasm32 下 **11.8 KB 文件直接 `WebAssembly.Memory.grow` trap**（3.97 GB） |
| **P0** | F-11 | enum 符号去重是 O(n²)，schema 来自**不可信的 OCF 头**，且 enum 符号不计入 `max_schema_types` | 默认限额下 1.6 MB 文件头（16 万符号）吃 **22–24 s** CPU，Go 0.02 s；头部上限是 64 MiB，外推可达小时级 |
| **P1** | F-01 | 演进解析用**全限定名**匹配 record / enum / fixed；规范是**非限定名** | `a.X → b.X`、`a.E → b.E`、`a.F → b.F` 全部 `ResolutionError`；hamba 与规范都接受 |
| **P1** | F-02 | `write_ocf` 把 **Parsing Canonical Form** 写进 `avro.schema` | 所有 Pion 写的 `.avro` 丢掉 `logicalType` / `default` / `aliases` / `doc`；Go 读回来 `timestamp-millis → int64`、`decimal → []uint8` |
| **P1** | F-12 | 递归解码 / 跳过 / schema 解析无栈保护；`max_depth` 默认 64 太紧、调大又不安全 | 默认值下 **33 节点**链表即被拒（Go 解 100 万节点）；`max_depth=1e6` 时原生 **30,000 节点（60 KB 输入）SIGSEGV**、wasm32 **700 节点（1.4 KB）`RangeError`** |
| P2 | F-04 | `long → float` 提升先转 `Double` 再转 binary32，**两次舍入** | `2^60+2^36+1` 得 `0x5d800000`，Java / Go 是 `0x5d800001` |
| P2 | F-05 | `float → double` 提升保留信号 NaN | `0x7f800001 → 0x7ff0000020000000`（sNaN），参考实现都是 `0x7ff8000020000000`；随机差分中 12 例 |
| P2 | F-06 | 不支持对象形式的命名引用 `{"type":"F"}` | Java 1.11.1 / hamba 都接受 |
| P2 | F-07 | reader 字段别名与 writer 的同名字段冲突时，后出现的 writer 字段覆盖前者 | writer `[b=1, a=2]`、reader `b aliases [a]` → 静默返回 2 |
| P2 | F-08 | Avro JSON 的 `double` 往返失败 | `-0.0 → "-0" → +0.0`；`NaN → nan`（不是合法 JSON，`decode_json` 自己都读不回） |
| P2 | F-09 | `decode_json` 保留 map 重复键，随后二进制编码出重复键 map | `{"a":1,"a":2}` → 2 个条目；Java / Go 只保留 1 个 |
| P2 | F-10 | 默认限额拒绝合法数据 / schema | 1,500 列 nullable 表（4,501 个 arena 节点 > 4,096）、100 万行以上的 OCF、空 union `[]` 全部被拒 |
| P2 | F-13 | `decode_json` 的 record 字段查找是对 JSON 对象的线性扫描，O(字段数 × 键数) | 1,000 字段 × 20 万垃圾键（2.3 MB）1.5 s |
| P2 | F-14 | 文档 / 测试口径：README 的“~2.2x–2.6x faster than both dynamic paths”不成立；包内只有 16 个测试，谈不上“移植上游测试套件” | W3 typed struct 只比 `go_hamba_any` 快 1.85x |

### 审过但没坐实的指控（如实记录）

- **PCF + CRC-64-AVRO**：10,054 个用例里，双方都接受的 2,735 个 schema 有 **2,724 个 PCF 与指纹逐字节一致**。剩下 11 个全是 hamba 的问题：hamba 把 `logicalType` 留在 PCF 里（规范 [STRIP] 要求剥掉，Java `SchemaNormalization` 也剥），以及 hamba 把显式 `"namespace": ""` 当成继承外层命名空间。Pion 在这两点上是对的。
- **命名空间 / 名字校验**：`""` 清空外层命名空间、带点名字覆盖 `namespace`、非限定引用回退到空命名空间（Java 语义）、非法名字、重复定义、未定义引用、嵌套 union、union 重复类型、enum 默认值不在符号表、union 默认值不匹配第一个分支：全部正确。hamba 反而接受重复 enum 符号、重复字段名、负 `size`、名为 `int` 的 fixed。
- **ZigZag / varint / float**：`Int32` / `Int64` 极值、10 字节 varint 第 10 字节 > 1、11 字节 varint、> 32 位的 int、截断，全部正确；float/double 的 `-0.0`、NaN payload、次正规数、`FLT_MAX` 进位溢出到 `inf`、ties-to-even，4 模逐字节一致（`probe smoke`）。
- **块编码**：负块计数 + `byte_size`、`Int64::MIN` 块计数、超大长度 / 计数（不预分配）、负长度、非法 UTF-8、非 0/1 的 boolean：全部拒绝且无大分配。
- **OCF 头 / 块**：错魔数、缺 `avro.schema`、未知 codec、错 sync、截断块、计数 0 / 负 / 2^40、`byte_size` 2^40、块内尾随字节：全部拒绝（`control_ocf_header_and_block_validation`）。
- **deflate 炸弹**：510 KB → 512 MiB 被 `max_bytes` 挡住，峰值 RSS 104 MiB（hamba 1,234 MiB 才报错）。
- **演进**：字段重排、跳过嵌套负块计数的 writer 字段、复杂默认值（record / array / bytes）、record / 字段别名、enum 默认值回退、writer union → 非 union 的惰性报错，全部正确。跳过递归字段也受 `max_depth` 约束（`control_skip_depth_is_bounded`）。
- **差分里 Pion 更严格或 hamba 有 bug 的部分**（不计为 Pion 缺陷）：Pion 校验 UTF-8（hamba 不校验）、负块 `byte_size` 超出剩余输入即拒、varint 多余位即拒；hamba 把 EOF 读成零值、解析递归 schema 时栈溢出（`fatal error: stack overflow`，差分里因此跳过 72 个递归用例）、带 `null` 默认值的 reader 字段解不出来、合成 union 报 “union type must be unique”。
- **规范歧义**：writer `int` → reader `["long","int"]`，Pion 取精确分支 `int`（Java `bestBranch` 同），hamba 取第一个可提升分支 `long`（规范字面）。名为 `a.int` 的类型：Pion 拒（规范字面），Java / hamba 收。
- **4 模一致性**：`packages/avro/wasm_smoke` 在 native dbg / rel、wasm32 dbg / rel 下 SHA-256 都是 README 声称的 `8b2b98db…50ec1f`；审计探针的 `smoke` 摘要也 4 模一致。4 模**不一致**的只有资源上限：栈深（F-12）和 32 位内存（F-03）。

---

## P0

### F-03 OCF 元素放大：`max_elements` 只管单个块，`read_ocf` 全量物化

**根因**：`src/ocf.pion:322-332` 每个块新建 `BinReader::new(..., limits)`，`elements` 从 0 开始；`src/binary.pion:543` 的预算因此是“每块 100 万元素”。文件级只有 `ocf.pion:293` 的 `total_records ≤ max_elements`，数的是**记录条数**不是元素。`read_ocf` / `read_ocf_resolved` 把整份文件解码到 `Array[AvroValue]` 才返回，没有逐块 / 逐记录的流式 API。

**最小复现**（`gen_ocf.py`）：schema `{"type":"array","items":"null"}`，每块 1 条记录 = `lng(1000000) 00`（4 字节），一个块 23 字节。

| 输入 | Pion `read_ocf`（默认 limits） | Go hamba 全量保留 | Go hamba 流式 |
|---|---|---|---|
| `amp_8`（261 B） | 8,000,000 值，65.5 MiB | — | — |
| `amp_32`（789 B） | 32,000,000 值，249.2 MiB | — | — |
| `amp_64`（1,493 B） | 64,000,000 值，**494.2 MiB**，1.6–3.4 s | 1,184 MiB | 64–65 MiB |
| `amp_deflate_64`（1,624 B） | 494.4 MiB | — | — |
| `amp_512`（11.8 KB），**wasm32 --release** | **`RangeError: WebAssembly.Memory.grow(): Unable to grow instance memory`**，3.97 GB | — | — |

单测 `redteam_ocf_max_elements_is_per_file_not_per_block`：`max_elements = 1000` 时 4 个块各 1,000 个元素全部放行。hamba 全量保留同样会爆，但它有流式解码器，调用方可以逐条处理；Pion 唯一的入口就是全量物化，而 README 把 `AvroLimits` 宣传为 DoS 防护。

**修复方向**：`elements` 预算按文件累计（或另设 `max_total_elements`）；提供逐块 / 逐记录迭代的 OCF reader。

### F-11 OCF 头里的 enum 符号去重 O(n²)

**根因**：`src/schema.pion:610-616` 对每个符号线性扫描已收集的符号；符号不占 `max_schema_types`（只数 arena 节点），也没有独立上限。`ocf.pion:253` 用默认 limits 解析文件里的 `avro.schema`，该值最大可到 `max_bytes` = 64 MiB。演进时 `resolve.pion:267-282` 的 writer × reader 符号映射也是 O(w·r)。

| enum 符号数（文件头大小） | Pion | Go hamba |
|---|---|---|
| 20,000（189 KB） | 0.28–0.30 s | 0.01 s |
| 40,000（389 KB） | 1.26–1.79 s | 0.01–0.02 s |
| 80,000（789 KB） | 5.63–6.34 s | 0.02–0.03 s |
| 160,000（1.6 MB） | **22.1–24.1 s** | — |

**修复方向**：用哈希集合去重（record 字段名、union 分支去重同理），并给符号数设上限。

## P1

### F-01 演进解析按全限定名匹配命名类型

Avro 1.11.1 “Schema Resolution”：*both schemas are records with the same (unqualified) name*；enum、fixed 同理。`src/resolve.pion:44-56 names_match` 只比 `w_name == r_name` 或 reader 别名，`match_score`（`:82-87`）和 `pc_compile`（`:242`、`:249`、`:303`）都用它。hamba `checkSchemaName` 比较的是 `Name()`（非限定名）。

后果：把类型挪到另一个命名空间（常见的包重命名）后，所有旧数据在 Pion 里都读不出来，除非 reader 给每个类型补上全限定别名。单测 `redteam_resolve_{record,enum,fixed}_unqualified_name_match`，差分 `res:unqualified-*`。

### F-02 `write_ocf` 写入 PCF，丢失逻辑类型等元数据

`src/ocf.pion:125`：`meta_entries.push(("avro.schema", canonical_form(schema).to_bytes()))`。PCF 按定义剥掉 `logicalType`、`default`、`aliases`、`doc`、`order`。Java `DataFileWriter` 和 hamba 写的是完整 schema。包里也没有“完整 schema 转 JSON”的序列化器。

实测（`run_audit.sh` 4f）：Pion 写 `at: timestamp-millis`、`id: uuid`、`amt: decimal(9,2)`，Go 读到的 `avro.schema` 是 `{"name":"Ev","type":"record","fields":[{"name":"at","type":"long"},{"name":"id","type":"string"},{"name":"amt","type":"bytes"}]}`，`at` 变成 `int64`、`amt` 变成 `[]uint8`。单测 `redteam_write_ocf_keeps_logical_types`。

### F-12 递归无栈保护；默认 `max_depth` 太紧，调大又会崩

`decode_datum_from`（`binary.pion:471`）、`skip_datum_from`（`:632`）、`exec_resolve`（`resolve.pion:367`）、`sb_parse_node`（`schema.pion:389`）、`jp_parse_value`（`json.pion:293`）都是直接递归，`max_depth` 是唯一护栏，没有上限也不按目标平台调整。

- 默认 `max_depth = 64`（`value.pion:54`），链表 `Node{v, next:[null,Node]}` 每个节点占 2 层（record + union），**第 33 个节点就被拒**（`redteam_default_depth_allows_100_node_recursive_list`）；Go hamba 解 1,000,000 个节点（1.5 GB RSS）正常。
- 调大 `max_depth` 后，原生 `--release` 在 25,000 节点通过、**30,000 节点（60 KB 输入）SIGSEGV**；`deep_schema` 10 万层同样 SIGSEGV。
- wasm32（Node 默认栈）400 节点通过、**700 节点（1.4 KB 输入）`RangeError: Maximum call stack size exceeded`**，原生却能过：同一配置在 4 个模式下表现不同。

**修复方向**：显式栈（或迭代 + 尾部链表展开）；或者按平台给 `max_depth` 设硬上限，并把默认值提到能覆盖常见递归数据的水平。

## P2

- **F-04** `resolve.pion:433-437`：`double_to_float32_bits(v.to_double())`。`v` 超过 2^53 时先舍入到 double，再舍入到 float，ties-to-even 落到错误的一边。`redteam_long_to_float_single_rounding`；差分 `res:long-to-float-double-rounding`。
- **F-05** `value.pion:205-209`：`float32_bits_to_double` 的 NaN 分支直接把 payload 左移 29 位，不置 quiet 位。`redteam_float_to_double_quiets_snan`；随机差分 12 例。
- **F-06** `schema.pion:779`：对象里的 `type` 只认原始类型和 `array/map/fixed/enum/record/error`，其余报 “unknown schema type”。Java 1.11.1 `Schema.parse` 末尾的分支（“For unions with self reference”）会按名字查找。`redteam_object_form_named_reference`。
- **F-07** `resolve.pion:318-343`：按 writer 字段找第一个“名字或别名”匹配的 reader 字段，两个 writer 字段可以映射到同一个 slot，后者覆盖前者（`:558`）。Java `applyAliases` 会把 writer `a` 改名为 `b` 后因重复字段报错；无论哪种处理，都不该静默返回别名那一列。`redteam_alias_does_not_override_exact_field`。
- **F-08** `json.pion:626-633` 用 `Double::to_string` 输出 `nan` / `inf` / `-0`；`jp_parse_number` 把 `-0` 当整数 0（`:262-285`），`Double` 分支 `JInt(v) → v.to_double()`（`:793`）丢掉符号。Java `JsonEncoder` 写 `"NaN"` / `"Infinity"`，`JsonDecoder` 能读回。`redteam_json_negative_zero_roundtrip`、`redteam_json_nan_infinity_roundtrip`。
- **F-09** `json.pion:858-876`：map 条目原样追加，不去重。`redteam_json_map_duplicate_keys_collapse`。
- **F-10** 默认限额过紧：`max_schema_types = 4096` 数的是 arena 节点（每个原始类型叶子、每个 `Ref` 都算），1,500 列 `["null","string"]` 就超（`redteam_default_schema_limit_allows_1500_nullable_fields`）；`read_ocf` 的 `total_records ≤ max_elements`（100 万）让普通的百万行文件读不了（`redteam_read_ocf_default_allows_more_than_1m_rows`）；`schema.pion:444-446` 拒绝 `[]`，Java / hamba 都接受（`redteam_empty_union_schema_accepted`）。
- **F-13** `json.pion:884-898`：每个 record 字段对 JSON 对象做一次 `json_obj_get` 线性扫描。1,000 字段 × 20 万垃圾键（2.3 MB）耗时 1.54 s。属于温和的二次方，记 P2。
- **F-14** 文档 / 测试：见下文 bench 一节。另外 `bytes → string` 提升会校验 UTF-8（`resolve.pion:454-462`），Java 不校验；差分里 39 例记为 `pion-stricter`，不算缺陷，但升级路径上可能拒收历史数据，建议在 README 写明。

---

## Bench 公平性（`packages/avro/bench/`，本机重跑，`--warmup 1 --rounds 5`，SHA-256 由 `scripts/bench_compare.py` 校验）

| Workload | README 中 Pion / `go_hamba_any` | 本次重跑（两轮） | README 中 `go_hamba_struct` / any | 本次重跑（两轮） |
|---|---|---|---|---|
| W1 二进制编解码往返 | 0.87x | 0.79x / 0.80x | 2.29x | 2.23x / 2.05x |
| W2 演进批量解码 | 0.95x | 1.04x / 1.01x | 2.20x | 2.18x / 2.24x |
| W3 OCF deflate 读写 | 0.81x | 0.69x / 0.73x | 1.85x | 1.80x / 1.78x |

三个 workload 的 stdout SHA-256 都与 README 一致（`f2ea3fe5…`、`75f2b111…`、`5ba2533c…`），双向互通校验（指纹、5 万条二进制、OCF）都通过。

结论：**方法学公平**。Pion 动态 `AvroValue` 对 Go 动态 `map[string]any` 是同口径；typed struct 列也如实列出，没有藏掉 Pion 落后 2x 以上的事实。整机有负载，绝对毫秒数比 README 慢 20–50%，但倍率在噪声范围内。需要更正的是：

1. README 写 typed struct “~2.2x–2.6x faster than both dynamic paths”。按 README 自己的表，W3 typed struct 只比 `go_hamba_any` 快 **1.85x**，比 Pion 快 2.30x，所以这句只对 Pion 成立。
2. 吞吐列在 W1 / W3 都用 W2 的 Go 编码输入大小（2,607,112 B）做分母。各实现口径一致，不影响倍率，但 MB/s 不是真实处理字节数。
3. 包内只有 16 个测试（`schema_test` / `binary_json_test` / `resolve_ocf_test`），远不是 Apache Avro 上游的 spec / interop 测试套件（如 `TestSchemaNormalization` 全部向量、`TestSchemaCompatibility`、`TestResolvingGrammarGenerator`、`TestDataFile` 等）。AGENTS.md §1.1 要求的“完整移植上游测试”没有做到，F-01 / F-02 / F-04 / F-06 这类问题正是上游测试会抓到的。

---

## 差分统计（`run_audit.sh` 第 2 节，10,054 个用例，seed 1111）

- 一致：9,678 / 9,982（另有 72 个递归 schema 因 hamba 会栈溢出而跳过）；304 个分歧分成 38 个桶。
- `FINDING` 桶：F-01 ×3、F-04、F-05（随机 12 例）、F-06、F-10（`[]`）。
- `spec-ambiguity`：union 分支偏好（手写 1 例 + 随机 5 例）、`a.int`、JSON 重复键。
- `pion-stricter`：UTF-8（117 例）、负块 `byte_size`（14 例）、varint 多余位（12 例）。
- `hamba-deviation`：其余全部，逐桶附原因（见 `diff.txt`）。
