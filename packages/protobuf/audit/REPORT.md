# 红队审计报告：Pion `packages/protobuf` @ `8df2404`（`feat/pkg-protobuf`）

对照实现：

- Go [`google.golang.org/protobuf`](https://pkg.go.dev/google.golang.org/protobuf) **v1.36.6**：`protowire`、`dynamicpb`、`protojson`。`.proto` 编译用 [`bufbuild/protocompile`](https://github.com/bufbuild/protocompile) **v0.14.1**，它的检查规则与 protoc 一致。
- Rust [`prost`](https://crates.io/crates/prost) **=0.13.5**（`--release`）。prost 没有动态反射，所以只参与线格式三方对拍。

环境：`tokyo-mac-studio-0`（Darwin arm64，`pionc 0.1.0` @ `AFK-surf/pion@8d110a3`，node 跑 wasm32），2026-11-23。整机同时有其他负载，时间请看同一轮交替运行得出的**倍率**，绝对值仅作参考。

## 一键复现

```sh
export PATH="$HOME/.pion/bin:$PATH"
sh packages/protobuf/audit/run_audit.sh          # 全量，约 2 分钟
QUICK=1 sh packages/protobuf/audit/run_audit.sh  # 跳过 250 KB 默认参数合并 DoS（单次约 13 s）
cd packages/protobuf && pionc test --json audit  # 只跑红队单测：31 个 redteam_* FAIL = 31 条证据，13 个 control_* PASS
```

构建产物、Go/Cargo 缓存、输入和日志全部写到 `$AUDIT_OUT`（默认 `/private/tmp/rt-protobuf`），不写进 git worktree。原有的 `pionc test packages/protobuf`（26 个测试）不受影响，仍然全部通过。

| 文件 | 作用 |
|---|---|
| `redteam_test.pion` | 31 个 `redteam_*`：按 Go/protoc 的实际行为写断言，FAIL 即证据。期望值全部由 `go/cmd/oracle` 实测得出，不是凭记忆写的。另有 13 个 `control_*`：Pion 扛住的攻击，必须保持绿色 |
| `probe/` · `go/cmd/oracle` · `rust/src/main.rs` | 三方差分探针，协议相同：`<mode> … <hex 行文件>`，每行输出 `OK …` 或 `ERR …`。模式有 `varint` / `tag` / `wire` / `dyn` / `dynall` / `canon` / `schema` / `schemahex` / `deep*` / `bench` |
| `diff_vectors.py` · `pbvec.py` | 212 个定向向量：A 线格式三方；B DynamicMessage 解码 + JSON + 重编码，对照 dynamicpb/protojson；C `.proto` 解析，对照 protocompile |
| `fuzz_diff.py` | 6,006 个线格式变异输入 + 2,000 个 `.proto` 变异输入（seed 20261123）。Native、Wasm32、Go 三方都跑：统计崩溃，逐行比 native 与 wasm32 输出，并把每个与 Go 的差异归到具体条目 |
| `gen_adversarial.py` · `oneshot.py` | 对抗负载（合并炸弹、大 schema、宽消息、5 万条 map、5 万未知字段）；单次运行计时，记录退出码 / 信号与峰值 RSS |
| `go/go.sum` · `rust/Cargo.lock` | 锁死对照实现的依赖，审计结果可逐字节复现（官方 `bench/` 缺这两个文件，见 F-16） |

---

## 结论速览

| 级别 | # | 指控 | 证据 / 倍率 |
|---|---|---|---|
| **P0** | F-1 | 类型名解析不按作用域：短名回退到全文件第一个同名类型，而且**同名 enum 优先于 message**，导致**静默用错描述符**解码 | `B.C.item` 被解成 `A.Item`；`Holder.status`（message）被当成别处的 enum，整条丢进 unknown；还能**绕过 UTF-8 校验与线格式校验**（fuzz 里 42 例 Go 拒绝、Pion 接受） |
| **P0** | F-2 | `.proto` 整数字面量：八进制按十进制读，溢出静默回绕 | `int32 a = 017;` 得到字段号 **17**（protoc 是 15）；`= 4294967297` 回绕成**字段 1**；`BIG = 4294967296` 回绕成 0。线格式与所有上游静默不兼容 |
| **P0** | F-3 | 同一单值子消息字段重复出现时，**合并是 O(N²)**；用**默认 `DecodeOptions`** 就能触发 CPU DoS | 250 KB 报文 **12.8–15.6 s**，Go 0.01–0.03 s（**约 500–1000 倍**）。40 KB 时 0.56 s，Go 0.011 s（0.02x） |
| **P0** | F-4 | 递归没有栈保护：调大 `max_depth` 后，解码约 5,000 层 **SIGSEGV**；**不设任何选项**，在内存里构造 25,000 层的 DynamicMessage 后释放就 **SIGSEGV**；Wasm32 上 500 层解码、1,000 层构造即 `RangeError` trap | Go 能解码并重编码 50,000 层（RecursionLimit 50,010）。README 写的“无栈溢出 / 无 Wasm32 trap”只在默认 `max_depth=100` 下成立 |
| **P1** | F-5 | Proto3 JSON 丢掉**显式存在（explicit presence）**的零值（proto3 `optional`、所有 proto2 字段，包括 `required`），`emit_defaults` 也形同虚设 | `optional int32 a = 0` 输出 `{}`，Go 输出 `{"a":0}`；`emit_defaults=true` 对空消息仍输出 `{}` |
| **P1** | F-6 | `map` 重复 key 没有 last-wins，JSON 出现重复键，重编码体积膨胀 | `{"k":1,"k":2}`；5 万条重复 key 重编码出 350,000 B，Go 是 7 B |
| **P1** | F-7 | 解析器拒绝真实世界的合法 `.proto`：消息内 `extend`、proto2 `group`、`edition = "2023"`，以及字符串里含 `}` 的聚合选项；`\x41` / `\101` 转义被读错 | protocompile 全部接受；json_name `"\x41\102"` 被解析成 `x41102` |
| **P1** | F-8 | `import` 只记录不解析：任何用到 well-known type（Timestamp / wrappers / Struct / Any…）的字段都**无法解码**，也没有 WKT 的 JSON 映射 | `ERR message not found: google.protobuf.Timestamp`；Go 输出 `"1970-01-01T00:00:01.000000005Z"` |
| **P1** | F-9 | proto2 `string` 也强制校验 UTF-8（上游只对 proto3 / editions VERIFY 校验），合法的 proto2 数据被整条拒绝 | `0a02e9ff`：Go 解码并原样重编码，Pion 报 `invalid UTF-8` |
| **P1** | F-10 | 每遇到一次消息类型字段，都要在整个 schema 里 DFS 查名（先找 enum 再找 message）：大 schema 的解码耗时随 schema 规模放大 | 4,000 个消息的 schema、80 KB 输入：**15.6 s**，Go 0.08 s；2,000 个消息时 3.39 s，Go 0.035 s（**0.01x**） |
| **P1** | F-11 | map 条目内 key/value 的 wire type 不对时，整条消息报错（Go 当作未知字段跳过，按默认值处理） | `0a080a016b1507000000`：Go 输出 `{"m":{"k":0}}`，Pion `ERR wire type mismatch` |
| P2 | F-12 | protoc 做的语义校验大多缺失（13 类） | 保留号 / 保留名被字段占用、重名字段、JSON 名冲突、proto3 首个枚举值非 0、proto3 `required` / `default`、未解析的类型、无 `allow_alias` 的别名、越界的默认值、两次 `package`、给 oneof 写不存在的选项、嵌套 ≥32 层，全部被接受 |
| P2 | F-13 | 不检查 proto2 `required` 字段 | Go 报 `required field R.a not set`，Pion 接受（fuzz 136 例） |
| P2 | F-14 | JSON 数字格式：`float` 按 binary64 位数输出；指数写法、map key 顺序、字段顺序都与 protojson 不同 | `0.1f` 输出 `0.10000000149011612`（Go `0.1`）；`1e+20` / `1e-07` / `4.94065645841247e-324`（Go `100000000000000000000` / `1e-7` / `5e-324`） |
| P2 | F-15 | README 宣称未知字段“无损往返”，实际不保留非最短 varint 的原始字节 | 未知字段 `92 00 01 62` 被重写成 `12 01 62`；Go 原样保留。消息语义相同 |
| P2 | F-16 | 官方 `bench/` 的公平性与可复现性：缺 `Cargo.lock` / `go.sum`；旗舰 API（DynamicMessage / JSON）完全没有基准 | 见“公平性”一节。补上动态 API 的头对头后 **Pion 反而领先** |

### 审过但没坐实的指控（如实记录）

- **线格式边界全部正确**（A 节 48 个向量，Pion 与 Go、prost 的判定逐一一致）。覆盖：varint `0/1/127/128/u32::MAX/i32::MIN（10 B）/i32 截断 5 B/i64::MIN/i64::MAX/u64::MAX`、第 10 字节为 `0x02`/`0x7f`、11 字节、截断、非最短编码；tag 为 0、`2^29-1`、`2^29`、19000–19999、高 32 位非零的 64 位 tag、wire type 6/7；group 嵌套、错配、孤立 EndGroup、未闭合 StartGroup、子消息长度内截断的 group；长度溢出、`u64::MAX` 长度。三处 `pion=rust≠go` 是因为 Go 的 `ConsumeTag` 本身不校验 wire type 和字段号上界（之后的 `Unmarshal` 会拒绝），不算 Pion 的错。
- **`bool` 高位**：`0x1_0000_0000` 解码为 `true`，同一个值作为 `int32` 截断为 0，与 Go 一致（`control_bool_high_bits_true`）。
- **double JSON 精度没有问题**：任务书说“`Float::to_string` 只有 15 位”，这在当前运行时**不成立**：`pion_double_to_str` 依次尝试 `%.15g`/`%.16g`/`%.17g`，直到能往返为止。`0.30000000000000004`、`1e-300`、`1.7976931348623157e+308`、`-0`、NaN、±Infinity 与 Go 数值一致，只有格式差异（F-14）。
- **float / double 位精确**：`-0.0`、次正规数、±Inf、quiet/signaling NaN 往返逐位一致。**Pion 比 Go 更好**：Go dynamicpb 会把 float32 signaling NaN `0x7f800001` 变成 quiet `0x7fc00001`，Pion 保留原位。
- **oneof / presence / 合并语义**：oneof 零值（`0`/`""`/`false`）会上线格式也会进 JSON；同一 arm 的子消息合并；切换 arm 清掉旧 arm；先 msg、后其他 arm、再 msg 只保留最后一次；子消息里的 repeated 字段拼接——全部与 Go 一致。
- **map 缺 key / 缺 value / value 在 key 前 / 条目内重复字段 / 条目内未知字段**：与 Go 一致。
- **packed**：空 packed、截断、fixed 长度不整除、packed 与 unpacked 交替、proto2 unpacked 字段收到 packed 数据：与 Go 一致。
- **proto2 closed enum**：原本怀疑“未知枚举值应进 unknown fields”，实测 **Go dynamicpb 与 Pion 一样**直接保留数值（`{"e":5}`），**撤回该指控**。
- **JSON 转义 / Base64 / int64 字符串化 / lowerCamelCase**（`foo_bar_baz`、`_foo`、`foo__bar`、`foo_1bar`、`a_b_C`、显式 `json_name`）：与 Go 一致。
- **深度炸弹（默认参数下）**：50,000 层 `.proto` 嵌套在 64 层干净拒绝；50,000 层 StartGroup 与 101 层子消息在默认 `max_depth=100` 下干净拒绝。默认上限 100 与 prost 相同，只是比 Go 的 10,000 严（`depth_101` 一项 Pion 与 prost 都拒绝、Go 接受，这是策略差异，不算缺陷）。
- **HashDoS 不适用**：DynamicMessage 用数组存字段和 map 条目，没有哈希表。5 万条不同 key 的 map 解码 + JSON 是线性的，**比 Go 快 3.0x**；10 万个未知字段线性。
- **宽消息**（16,000 个字段）解码：Pion 0.61 s，Go 0.86 s，没有差距。单消息 18,000 个字段的 schema 解析 Pion 0.57 s、Go 0.06 s（字段号去重是 O(N²)），只影响离线解析，归为 F-10 的附带项。
- **Fuzz**：6,006 个线格式变异输入、2,000 个 `.proto` 变异输入，Pion **0 次崩溃 / trap / 超时，native 与 wasm32 输出 0 处差异**。与 Go 的 584 处差异（判定不同或 JSON 值不同）全部归因到上表 F-1/5/6/8/9/11/13/14 和 N-3（默认深度），**没有无法解释的差异**。
- **DynamicMessage 头对头**（任务书要求补的 dynamicpb 对比）：Pion **领先**，解码 1.43x、解码 + JSON 1.94x、解码 + 重编码 1.72x，峰值 RSS 只有 Go 的 1/4–1/5（见第 6 节）。

---

## P0

### F-1 类型名解析不按作用域，静默用错描述符

根因：`resolve_nested_message` / `resolve_nested_enum`（`src/dynamic.pion:28-51`）只看**直接子类型**，找不到就交给 `schema_find_message` / `schema_find_enum`（`src/schema.pion:1057-1119`）。后者对全文件做 DFS，**短名**相等就返回第一个命中。所有 `Named` 字段在 `is_packable_scalar`、`expected_field_wire_type`、`read_scalar_value` 里都**先问“是不是 enum”**，再问 message。另外，解码出的 `DynamicMessage.message_name` 存的是 `desc.name`（短名，`src/dynamic.pion:784`），之后 `encode_dynamic` / `to_proto3_json` 用这个短名重新查找，又会查到别的类型。protoc 的规则是从最内层作用域逐层向外，按 C++ 的方式解析。

| 场景 | 输入 | Go / protoc | Pion |
|---|---|---|---|
| 外层作用域的同名类型 | `B.C.item : Item`，另有 `A.Item` | `{"c":{"item":{"name":"hi"}}}` | `{"c":{"item":{}}}`（按 `A.Item{int32 x}` 解，`name` 进了 unknown） |
| message 与别处的 enum 同名 | `Holder.status : Holder.Status(message)`，另有 `Other.Status(enum)` | `{"status":{"code":7}}` | `{}`（当成 enum，wire type 不匹配，整条进 unknown） |
| 解码嵌套类型本身 | `decode_dynamic(s, "B.Item", 0a026869)` | `{"name":"hi"}` / `0a026869` | JSON `{"x":"x"}`；`encode_dynamic` 报 `ENCERR value type mismatch` |

**安全影响**：用错描述符会让本该校验的内容不被校验。fuzz 中有 42 个输入 Go 拒绝而 Pion 接受，其中包括 `B.Item.name` 的非法 UTF-8 和 `Holder.status` 子消息里的非法线格式。证据：`redteam_scoped_name_resolution_picks_enclosing_scope`、`redteam_message_not_shadowed_by_unrelated_enum_of_same_name`、`redteam_decoded_submessage_reencodes_with_its_own_descriptor`，`diff_vectors` 的 `scope_*`。

### F-2 `.proto` 整数字面量：八进制和溢出

根因：`ProtoParser::read_int`（`src/schema.pion:204-249`）只认十进制和 `0x`；它在 `Int64` 上累加、不检查溢出，最后 `.to_int()` 截断。

| `.proto` | protocompile / protoc | Pion |
|---|---|---|
| `int32 a = 017;` | 字段号 15（与 `b = 15` 冲突，报错） | 字段号 **17**，接受 |
| `int32 a = 4294967297;` | 超过 536870911，报错 | 回绕为**字段 1**，接受 |
| `BIG = 4294967296;` / `2147483648` | 超出 int32 范围，报错 | 0 / −2147483648，接受 |
| `Z = 0x;` | 语法错误 | 0，接受 |

这类问题最危险的地方在于**静默**：schema 能通过，但字段号和其他实现不一样，结果是双方互相把对方的数据丢进 unknown 字段，或者解析成别的字段。证据：`redteam_octal_field_number_is_octal`、`redteam_field_number_overflow_rejected`、`redteam_enum_value_overflow_rejected`、`redteam_hex_literal_without_digits_rejected`。

### F-3 子消息合并 O(N²)，默认参数即可 DoS

根因：`decode_message_into` 对一个已经存在的子消息再做合并时（`src/dynamic.pion:490-504`，调用点在 `743-757`），会把旧消息的**全部字段和全部 unknown 字段逐个复制**到新数组，再继续解码。Protobuf 规范要求重复出现的单值消息字段做合并，所以 `Outer.inner` 出现 N 次、每次带一个 unknown 字段时，复制总量是 1+2+…+N。Go 是原地合并。

| 输入（单条记录） | Pion | Go dynamicpb | 倍率 |
|---|---:|---:|---:|
| `inner{99:1}` × 49,999，250 KB，**`decode_dynamic_default`** | **12.82 s**（另一次 15.58 s） | 0.01–0.03 s | 约 500–1000x |
| × 40,000（200 KB） | 8.59 s | 0.01 s | |
| × 20,000（100 KB） | 2.58 s | 0.01 s | |
| × 10,000（50 KB），bench_compare 中位数 | 559.6 ms | 11.0 ms | 0.02x |
| 对照组：`inner{x:7}` × 40,000（只有已知字段，没有 unknown） | 0.01 s | 0.01 s | 线性 |

49,999 次出现是 99,998 个字段，**刚好在默认 `max_fields = 100000` 以内**，所以默认参数挡不住。

### F-4 递归没有栈保护

| 探针 | 结果 |
|---|---|
| native `decode_dynamic`，`max_depth = n+10`，n = 4,000 | OK（但重编码报 `ENCERR depth 256`，见下） |
| native 同上，n = **5,000** / 50,000 | **SIGSEGV** |
| Go，`RecursionLimit = 50,010`，n = 50,000 | 解码并重编码 OK（138 MiB） |
| native，**不设任何选项**：用 `set_field` 构造 25,000 层的 DynamicMessage，`encode_dynamic` 返回 `ERR depth 256` 后释放 | **SIGSEGV**（释放时递归析构；20,000 层不崩） |
| native，50,000 层未知 group（`max_depth` 调大） | 解码 + 重编码 OK，**释放时 SIGSEGV** |
| wasm32 `decode_dynamic`，n = 300 / **500** | OK / **`RangeError: Maximum call stack size exceeded`** |
| wasm32 构造 1,000 层 DynamicMessage（无选项） | **trap** |
| wasm32 2,000 层未知 group | **trap** |

还有两个附带问题：(1) `encode_message_with_desc` 和 `write_json_message` 把深度**写死为 256**（`src/dynamic.pion:980`，`src/json.pion:259`），所以 `max_depth = 1000` 能解码的消息却无法重编码或转 JSON，前后不对称。(2) `DecodeOptions.max_depth` 没有安全上限：native 约 5,000、wasm32 约 500 就会崩溃。建议给 `max_depth` 设硬上限（参考 Go 的 10,000，前提是先把递归改成显式栈），并把析构也改成迭代，或改用 arena。

---

## P1

### F-5 Proto3 JSON 丢掉显式存在的零值，`emit_defaults` 无效

根因：`src/json.pion:271` 的判断是 `omit = !emit_defaults && oneof_index < 0 && is_default_proto3_value(v)`，**没看 label**，所以 proto3 `optional` 和所有 proto2 字段（包括 `required`）只要值为零就被省略。`emit_defaults` 只遍历 `msg.fields` 里已经存在的字段，从没出现在线格式上的字段永远不会输出。

| 用例 | Go protojson | Pion |
|---|---|---|
| proto3 `optional int32 a = 0; optional string b = ""` | `{"a":0,"b":""}` | `{}` |
| proto2 `optional int32 a = 0; optional bool b = false` | `{"a":0,"b":false}` | `{}` |
| proto2 `required int32 a = 0; optional bytes b = ""` | `{"a":0,"b":""}` | `{}` |
| `EmitUnpopulated` / `emit_defaults`，proto3 空消息 | `{"a":0,"b":"","c":[]}` | `{}` |

二进制重编码这一侧是对的（`28003200` 保留了零值），问题只出在 JSON。fuzz 中归到这一条的有 83 例。

### F-6 map 重复 key 没有 last-wins

根因：`src/dynamic.pion:624-643` 对每个 map 条目直接 `pairs.push`。

- JSON：`{"si":{"k":1,"k":2}}`，Go `{"si":{"k":2}}`。大多数 JSON 解析器会取最后一个值，但严格解析器会直接报错。
- message 类型的 value：Go 的 `{"1":{"y":2}}` 在 Pion 中变成两个条目。
- 重编码：50,000 条重复 key 的输入，Pion 输出 350,000 B，Go 输出 7 B。`get_map` 返回 5 万个元素。

### F-7 合法的真实世界 `.proto` 被拒

| 语法 | protocompile | Pion | 根因 |
|---|---|---|---|
| 消息内 `extend Foo { optional int32 bar = 100; }`（proto2 自定义选项的常见写法） | OK | `expected character` | `parse_message` 没有 `extend` 分支（顶层的 `extend` 被整块跳过，这一层没有） |
| `optional group Result = 1 { … }`、`repeated group` | OK | 报错 | 不支持 group 字段 |
| `edition = "2023";` | OK | `unexpected top-level keyword` | 不支持 editions |
| `option (my_opt) = { s: "}" };` | OK | 报错 | `read_option_value` 数花括号时把字符串里的 `}` 也算进去（`src/schema.pion:261-279`）。`service` 块走的是另一条会跳过字符串的路径，所以 gRPC 的 `google.api.http` 注解不受影响 |
| `[json_name = "\x41\102"]` | `AB` | `x41102` | `read_string_lit` 只认 `\n \r \t \\ \" \'` 这几种转义 |

对照组：`service` 中带 `stream`、`option`、空 `{}`、全限定或相对的类型，`extensions … [declaration = …]`、`reserved … to max`、`allow_alias`、负值或十六进制枚举，`"a" "b"` 字符串拼接，各类 `default` 数值（`-0x1F`、`-1.5e10`、`inf`、`-nan`、`u64::MAX`），以“字段名就是关键字”的写法，以上全部正确解析（C 节 SAME）。

### F-8 `import` 不解析，WKT 字段无法解码

`parse_schema` 只把 import 路径记进 `imports`，既没有加载文件的接口，也没有内置 WKT。只要消息里出现 `google.protobuf.Timestamp` / `Int64Value` / `Struct` 字段，`decode_dynamic` 就会返回 `message not found`，整条消息无法解码；字段不出现时没有影响。protojson 对 WKT 的特殊 JSON 映射（RFC 3339 时间、wrapper 拆包、Struct 转 JSON 对象）也完全没有实现。fuzz 中有 60 例。

### F-9 proto2 `string` 被强制校验 UTF-8

`DecodeOptions.strict_utf8` 默认为 `true`，并且不区分 syntax 一律生效（`src/wire.pion:538`）。protobuf-go 只对 proto3 和 editions 的 `utf8_validation = VERIFY` 做校验。所以历史上用 proto2 `string` 存 Latin-1 或二进制的数据，在 Go/C++ 中能正常往返，在 Pion 中整条消息被拒（fuzz 19 例）。

### F-10 每次字段出现都对整个 schema 做名字查找

每遇到一次消息类型的字段，`is_packable_scalar` → `resolve_nested_enum` 会在整个 schema 里 DFS 找 enum；找不到再由 `expected_field_wire_type` 和 `resolve_nested_message` 各做一遍 DFS 找 message。解析得到的结果从不缓存，描述符里也不存已解析好的引用。

| 2 万个 `Root.leaves` 元素（80 KB） | Pion | Go |
|---|---:|---:|
| schema 含 500 个消息 | 0.60 s | 0.02 s |
| 2,000 个消息（bench_compare 中位数） | 3,390 ms | 34.9 ms（**0.01x**） |
| 4,000 个消息 | 15.58 s | 0.08 s |

真实的大 schema（例如 googleapis 的某些单文件有上千个类型）会直接受影响。附带问题：`build_field_descriptor` 的字段号去重是 O(N²)，单消息 18,000 个字段的 schema 解析需要 0.57 s，Go 0.06 s。

### F-11 map 条目内 wire type 不对时整条消息报错

`read_scalar_value` 在 map 条目内部遇到 wire type 不符就返回错误（`src/dynamic.pion:579-616`）；而在普通字段上，同样的情况 Pion 会当作 unknown 字段处理（`:538-552`），两处行为不一致。Go 对两种情况都按 unknown 跳过，map 的 key/value 取默认值：`{"m":{"k":0}}`、`{"m":{"":7}}`。fuzz 中有 50 例。

---

## P2

- **F-12 缺少语义校验**：C 节有 25 项 DIFF，其中 20 项是“Pion 接受了非法的 `.proto`”。除去属于 F-2 的 5 项（八进制、字段号或枚举值溢出、`0x`），其余 15 项共 13 类：保留号或保留名被字段占用、重名字段、JSON 名冲突（`foo_bar` 与 `fooBar`）、proto3 首个枚举值非 0、proto3 `required` / `default`、未定义的类型 `Missing`、无 `allow_alias` 的别名、越界的默认值、两次 `package`、给 oneof 写不存在的选项，以及嵌套 ≥32 层（protocompile 上限 32，Pion 是 64，占 3 个向量）。另外 5 项是 Pion 拒绝合法 `.proto`，见 F-7。
- **F-13 proto2 `required` 不检查**：fuzz 中 136 例（Go `required field R.a not set`）。
- **F-14 JSON 数字格式**：`write_json_float`（`src/json.pion:75-90`）对 `float` 也按 binary64 输出，`0.1f` 变成 `0.10000000149011612`，`3.4028235e+38` 变成 `3.4028234663852886e+38`。按 float32 解析回去值不变，但输出与 protojson 不一致，文本也更长。double 的 `1e+20` / `1e-07` 写法与 Go 的 `100000000000000000000` / `1e-7` 不同；map key 按插入顺序而不是排序；字段按线格式顺序而不是声明顺序。以上都不影响 JSON 语义，但 canonical 字节对比会失败。
- **F-15 未知字段不是字节级无损**：README 说“lossless unknown field roundtrip”，实际 Pion 会把非最短 varint（`92 00`、`cb 00`）重写为最短形式（fuzz 3 例）；Go 原样保留。消息语义相同，影响签名或哈希这类需要字节一致的场景。

---

## Native vs Wasm32

- 6,006 个线格式输入 + 2,000 个 `.proto` 输入：两端输出**逐行完全一致**，0 次 trap。`pion_double_to_str` 在 native 端是 `%.15g…%.17g`，在 wasm32 端是 JS 的 `formatG`，fuzz 和 B 节的所有浮点向量结果一致，包括 `-0`、次正规数、`1e+21`。
- 差异只出现在**栈深度**：wasm32 的极限比 native 低约 10 倍（解码约 500 层 vs 约 5,000 层；构造后释放约 1,000 层 vs 约 25,000 层），见 F-4。默认 `max_depth = 100` 在两端都安全。

## 基准与公平性

### 补上的 DynamicMessage 头对头（Pion `decode_dynamic` vs Go `dynamicpb`，同一份 `.proto`、同一份输入，SHA-256 一致）

| 负载 | Pion 中位数 | Go 中位数 | Pion 倍率 | 峰值 RSS（Pion / Go） |
|---|---:|---:|---:|---:|
| 2,000 个 OTel span × 20：解码 | 189.1 ms | 270.6 ms | **1.43x** | 3.75 / 18.14 MiB |
| 同上：解码 + Proto3 JSON | 230.0 ms | 446.5 ms | **1.94x** | 3.88 / 16.97 MiB |
| 同上：解码 + 重编码 | 207.8 ms | 358.0 ms | **1.72x** | 3.83 / 17.22 MiB |
| 5 万条 map × 5：解码 + JSON | 70.5 ms | 211.7 ms | **3.00x** | 13.8 / 40.1 MiB |
| 5 万条 map × 5：解码 + 重编码 | 97.2 ms | 127.8 ms | **1.32x** | 14.6 / 26.9 MiB |
| merge_unknown_10000（F-3） | 559.6 ms | 11.0 ms | 0.02x | |
| bigschema_2000（F-10） | 3,390 ms | 34.9 ms | 0.01x | |

结论：在正常输入上，**Pion 的动态反射路径明显快于 Go dynamicpb**，这一点应该写进 README；落后只出现在 F-3 和 F-10 两种对抗输入上。

### 官方 `bench/` 复测（本机重跑，基线 rust）

| 负载 | Pion | Rust prost | Go | Pion 倍率 |
|---|---:|---:|---:|---:|
| decode_spans | 129.3 ms | 61.4 ms | 55.9 ms | 0.48x（README 0.47x） |
| encode_spans | 51.2 ms | 20.6 ms | 26.1 ms | 0.40x（README 0.43x） |
| packed_numeric | 28.6 ms | 25.5 ms | 24.1 ms | 0.89x（README 0.94x） |

README 的数字可以复现，误差在噪声以内。

### F-16 公平性和可复现性问题

1. **缺 `Cargo.lock` / `go.sum`**：`bench/rust` 只钉了 `prost = "=0.13.5"`，传递依赖（`bytes` 本次解析为 1.12.2 等）随时间漂移；`bench/go` 只有 `go.mod`，每次运行都要联网 `go mod tidy`。本审计的 `audit/rust/Cargo.lock` 和 `audit/go/go.sum` 已提交，构建时用 `--locked`。
2. **三方写法不对等，但方向对 Pion 有利**：Pion 和 Go 都是手写解码（`WireReader::slice_with_str` / `protowire.Consume*`），Rust 是 `#[derive(Message)]` 生成代码。各自都是最快的写法，基本公平。不过 Go 的手写 protowire 比 Go 用户实际常用的 `proto.Unmarshal` 生成代码路径更快，所以 0.47x 这个数对 Pion 偏严，并没有偏袒 Pion。
3. **旗舰 API 没有基准**：README 主推的 `decode_dynamic`、`to_proto3_json` 没有任何对比数据，而这恰恰是 Pion 领先的地方（见上表）。
4. **Span 0.43x–0.47x 的瓶颈**（来自代码阅读，**未做采样剖析**：本机 `sample` 在 100 ms 级别的短进程上没能挂上）：(a) `WireWriter::ensure_cap`、`write_raw_bytes`、`write_string_field`、`write_subwriter_field` 都是逐字节循环拷贝（`src/wire.pion:780-1013`），Rust 和 Go 这里是 `memcpy`；`write_string_field` 还要按 `code_unit_at` 逐个取字节。(b) 编码嵌套消息时先写进子 writer 再整体拷回（两遍）；prost 是先算 `encoded_len`，然后一遍写完。(c) 解码时每个 `string` 都要切片出一个新 `String`，每个 `bytes` 都要 `slice` 复制，同时还有 `Span` / `KeyValue` / `SpanEvent` 的堆分配和 `Array::push` 扩容。packed 数值负载用的是专门的快速路径（`read_packed_sint64` / `read_packed_double`），所以能到 0.89x。

---

## 修复建议（按优先级）

1. **F-1 / F-10**：`parse_schema` 之后加一次链接（link）：按 protoc 的作用域规则，把每个 `Named` 字段解析成唯一的全限定名，并区分 enum 和 message，结果存进 `FieldDescriptor`；`DynamicMessage.message_name` 改存 `full_name`。解码时直接用已解析的描述符（可以给 schema 建一个 `full_name → index` 表），F-10 随之消失。
2. **F-2**：重写 `read_int`：支持 `0` 开头的八进制，做 u64 溢出检查，并按用途检查范围（字段号 1..2^29-1、enum 在 int32 范围内）。
3. **F-3**：合并改成原地进行：fields 和 unknowns 直接复用已有数组，或者改用可变的 builder。
4. **F-4**：给 `max_depth` 设硬上限；编码、JSON 和析构都改为迭代，至少和解码使用同一个深度参数。
5. **F-5 / F-6 / F-11 / F-9**：JSON 根据 label / presence 决定是否省略；`emit_defaults` 遍历描述符而不是已有字段；map 做 last-wins；map 条目内 wire type 不符时跳过；只对 proto3 做 UTF-8 校验。
6. **F-7 / F-8 / F-12 / F-13**：补齐语法（消息内 `extend`、`group`、`edition`、字符串感知的聚合选项、完整的转义）；提供多文件 `parse_schemas` 并内置 WKT；补齐 protoc 的语义校验；加 `check_required` 选项。
