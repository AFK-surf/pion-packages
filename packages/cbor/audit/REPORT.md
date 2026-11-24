# 红队审计报告：Pion `packages/cbor` @ `60080f3`（`feat/opt-cbor`）

对照实现：Go [`fxamacker/cbor/v2`](https://github.com/fxamacker/cbor) **v2.9.0**（与 `bench/go` 相同）、Rust [`ciborium`](https://github.com/enarx/ciborium) **0.2.2**（`--release`）。
环境：Apple M5 Max (Darwin arm64，`pionc 0.1.0`），2026-11-23。整机同时有其他负载，时间数字以同一轮交替运行的**倍率**为准。

## 一键复现

```sh
export PATH="$HOME/.pion/bin:$PATH"
sh packages/cbor/audit/run_audit.sh             # 全量，约 10 分钟（第 5 节的二次方用例单个最长约 70 s）
QUICK=1 sh packages/cbor/audit/run_audit.sh     # 跳过第 5 节 131072 对的一次性 DoS 用例
cd packages/cbor && pionc test --json audit     # 只跑红队单测：13 个 redteam_* FAIL = 13 条铁证，5 个 control_* PASS
```

所有构建产物、输入和日志都写到 `$AUDIT_OUT`（默认 `/tmp/pion-cbor-audit-$USER`），不会写进 git worktree。`pionc test packages/cbor`（原有 209 个测试）不受影响。

| 文件 | 作用 |
|---|---|
| `redteam_test.pion` | 13 个 `redteam_*`（FAIL 即铁证，断言按原版 / RFC 行为写）+ 5 个 `control_*`（Pion 扛住的攻击，必须保持绿色） |
| `probe/` · `go/cmd/probe` · `rust/src/main.rs` | 三方差分探针，协议相同：`<mode> <hex 行文件>` → `OK <重编码>` / `ERR <消息>` |
| `gen_vectors.py` · `diff_vectors.py` | 126 个 RFC 8949 / CTAP2 定向向量及三方判定差分表 |
| `fuzz_diff.py` | 10,000 个变异输入（seed 8949）：崩溃会二分定位到具体输入，并做判定差分和重编码值差分 |
| `gen_adversarial.py` | 对抗负载：Shell 排序杀手键序、131072 对 map、64 MiB 串、1M 分片不定长串 |
| `go/cmd/bench` · `rust/src/bench.rs` · `probe bench` | 对抗 benchmark 三方实现，stdout 逐字节一致（`scripts/bench_compare.py` 做 SHA-256 校验） |
| `go/cmd/bench_{encode,decode}_struct` | 公平性复核：用地道的 Go 写法（typed struct）跑官方 workload，输出与官方 bench 逐字节一致 |
| `go/cmd/deepenc` · `oneshot.py` | 深层编码探针；单次运行计时、退出码 / 信号与峰值 RSS 统计 |

---

## 结论速览

| 级别 | # | 指控 | 证据倍率 / 现象 |
|---|---|---|---|
| **P0** | F-1 | `reject_duplicate_keys` 重复键检测是 **O(n²)**：640 KB 报文就能吃掉 **68–73 s** CPU | Go 0.04–0.25 s，**约 300–1800 倍** |
| **P0** | F-2 | Core Deterministic / CTAP2 **编码**用 Shell 原始 `n/2` 增量序列，**最坏 Θ(n²)** | 杀手键序：**15.5–55 s**，Go 0.07 s；随机键序也只有 Go 的 0.12–0.20x |
| **P1** | F-3 | 递归无栈保护：`max_depth` 不设上限，解码约 30k 层、编码 / 析构约 50k 层直接 **SIGSEGV** | Go 在 65,000 层（解码）/ 1,000,000 层（编码）都正常 |
| **P1** | F-5 | 没有“已消费字节数 / 解码首项”API，CBOR Sequence 和 WebAuthn `attestedCredentialData`（COSE_Key 后面跟 extensions）都解析不了 | Go `UnmarshalFirst`、ciborium `from_reader(&mut &[u8])` 都支持 |
| **P1** | F-9 | 官方 benchmark 口径不公：Go 侧故意用最慢的 `map[string]any` / `map[any]any` | 换成地道的 Go typed struct 后，Go 反超：编码 **1.59x**、解码 **1.21x** 快于 Pion |
| P2 | F-4 | 不校验 tag 0/1/2/3 的内容类型（RFC 8949 §3.4.1–3.4.3），strict 模式也不校验 | `c000` `c201` `c16161` `c380` `c06161`：Go 全部拒绝，Pion 全部接受 |
| P2 | F-6 | 重复键检测复用测试辅助函数 `cbor_equals`（所有 NaN 视为相等），payload 不同的 NaN 键被误判为重复 | `a2 f97e00 01 f97e01 02` 被 Pion 拒绝，Go 接受 |
| P2 | F-7 | Core Deterministic 不做 bignum 的 preferred serialization（§3.4.3），strict 解码把它当成 canonical | `Tag(2,h'01')` 编成 `c24101`，Go 编成 `01`；`c2420001` 也能过 strict |
| P2 | F-8 | strict 解码只认字节序：Pion **自己**的 CTAP2 canonical 输出会被 `DecodeOptions::strict()` 拒绝 | `a30af620f61818f6` → NonCanonicalEncoding |
| P2 | F-10 | 解码入口会无条件 `data.to_string()` 整份拷贝输入：大字节串的峰值 RSS 是 Rust 的 1.47x，速度是 Go 的 0.64x | 64 MiB bstr：193.8 MiB vs Rust 132.1 MiB |

### 审过但没坐实的指控（如实记录）

- **64 位整数极限没问题**：`Unsigned(UInt64)` / `Negative(UInt64)` 能无损表示 `2^64-1` 和 `-2^64`，与 Go、Rust 字节一致（`control_u64_and_neg_2pow64_lossless`）。任务书里“只用 Int64”的假设不成立。
- **不定长串**：嵌套不定长分片、跨 chunk 切断 UTF-8、chunk 类型错、奇数项 indef map、定长容器里的 break 都会被正确拒绝。**ciborium 0.2.2 反而会接受**嵌套不定长分片 `5f5f4101ffff` / `7f7f6161ffff`，这是 Rust 的 bug。1M 个 1 字节 chunk 拼接是线性的，与 Go 持平（0.96x），没有 O(N²)。
- **float**：f16 subnormal 往返、`-0.0`、preferred serialization（f64→f16/f32）与 Go、Rust 逐字节一致。NaN 统一成 `f97e00`，与 Go 默认的 `NaNConvert7e00` 一致。
- **长度炸弹 / 截断 / 保留 AI 28–30 / 非法 simple / 严格 UTF-8 / 尾随字节**：全部正确拒绝，也没有预分配（`count ≤ 剩余字节`，`cap ≤ 4096`）。
- **重复键默认行为**：任务书说“fxamacker 默认拒绝重复键”，实测**不成立**。v2.9.0 默认是 `DupMapKeyQuiet`，`a201010102` 会被接受（后值覆盖），只有 `DupMapKeyEnforcedAPF` 才拒绝。Pion 默认同样接受，这一项不算差距。`-0.0` 和 `+0.0` 作为键时，Go 判为重复而 Pion 不判；在 CBOR 数据模型里两者本就是不同的值，Pion 是对的。
- **10,000 个变异 fuzz**：Pion **0 次崩溃 / panic / 卡死**。剩下的判定差异全部是 F-4（tag 合法性）或 Go 的类型限制（Go 的 `map[any]any` 不支持 big.Int、数组、map 作为键），不算 Pion 的错。27 个重编码值差异全部来自 Go 的有损转换（tag 1 转成 `time.Time` 再丢 tag、`undefined` 变 `null`、bignum 降级、`±0` 合并），Pion 保真。
- **Pion 领先的对抗负载**（如实记录）：131072 个 f64 的扁平数组解码 1.53x Go；131072 个文本键的 map 解码 7.40x Go；64 MiB 文本串解码 1.17x Go。

---

## P0

### F-1 重复键检测 O(n²)，可被小报文打成 CPU DoS

`src/decode.pion` 里有两个重复键检测分支：indefinite map 一个，definite map 在 `reject_duplicate_keys && !require_canonical` 时一个。两处都对每个新键线性扫描 `pairs[0..i)`，并调用 `cbor_equals`：

```text
src/decode.pion  (indef map)      while j < pairs.length() { if cbor_equals(pk, k) ... }
src/decode.pion  (definite map)   } else if dec.reject_duplicate_keys { while j < pairs.length() ...
```

元素上限是默认的 `max_elements = 131072`（与 fxamacker 的 `MaxMapPairs` 相同），因此单个约 640 KB 的合法报文就要做约 8.6×10⁹ 次比较。fxamacker 用哈希表，是 O(n)。

| 输入（`gen_adversarial.py`） | Pion | Go `DupMapKeyEnforcedAPF` | 倍率 |
|---|---:|---:|---:|
| `map_131072_uint_random.cbor`（655,085 B，definite） | **72.692 s** | 0.247 s | ~294x |
| `map_131072_uint_indef.cbor`（655,082 B，indefinite） | **67.938 s** | 0.037 s | ~1836x |
| `map_16384_uint_random`（bench_compare 中位数） | 526.8 ms | 14.5 ms | 0.03x |
| `map_16384_uint_indef`（bench_compare 中位数） | 567.0 ms | 15.5 ms | 0.03x |

复现：`$AUDIT_OUT/bin/pion_probe bench dupdec $AUDIT_OUT/adv/map_131072_uint_random.cbor 1`（见 `run_audit.sh` 第 5、6 节）。

影响：README 把 `reject_duplicate_keys` 宣传为安全选项（对标 fxamacker 的 DupMapKey）。WebAuthn / COSE 服务端打开它以后，单个 640 KB 请求就能让一个核满载 70 s。`DecodeOptions::strict()` 处理 definite map 时走的是线性的 canonical 顺序比较，不受影响，但 strict 同时禁掉了 indefinite 和非最短编码，不能替代“只拒绝重复键”这个配置。

### F-2 确定性 / CTAP2 编码排序是 Θ(n²) 的 Shell 排序

`src/encode.pion` 里的 `sort_fast_indices`（n > 16 的快路径）和 `sort_encoded_keys`（慢路径，CTAP2 **总是**走这里）都用 Shell 原始增量 `gap = n/2, n/4, …, 1`。当 n 是 2 的幂，并且偶数槽位放较大的一半键、奇数槽位放较小的一半时，`gap ≥ 2` 的所有轮次都不会让奇偶位交换，最后一轮 `gap=1` 就退化成 Θ(n²) 的插入排序。键序生成见 `gen_adversarial.py: shell_killer_order`。这只是普通的 map 插入顺序，比如解码后原样转写，或者上游按某种规律生成 map。

| 输入（131072 对，约 0.65–0.79 MB） | Pion | Go | Rust |
|---|---:|---:|---:|
| uint 键，杀手序，`enc_det` | **15.547 s** | 0.071 s | 0.220 s |
| uint 键，杀手序，`enc_ctap2` | **41.147 s** | 0.068 s | 0.028 s |
| bstr 键，杀手序，`enc_det`（慢路径） | **55.092 s** | 0.079 s | 0.027 s |
| bstr 键，杀手序，`enc_ctap2` | **40.695 s** | 0.081 s | 0.028 s |
| uint 键，**随机序**，`enc_det`（bench_compare） | 317.5 ms（0.20x） | 63.8 ms | 46.0 ms |
| text 键，**随机序**，`enc_det`（bench_compare） | 657.0 ms（0.12x） | 76.5 ms | 46.5 ms |

16384 对的杀手序 bench_compare 结果：Pion 只有 Go 的 0.04–0.15x（SHA-256 一致）。三方输出的编码字节完全一致（`bytes=655085` / `786437`），说明结果本身没错，只是慢。

另外，慢路径会对每个键先算一遍 size，再编码到单独的 `Bytes`，然后 `to_string()` 再拷贝一次；比较用的是 String 比较。所以即使不碰最坏情况，大 map 也比 Go / Rust 慢 5–8 倍。

---

## P1

### F-3 递归没有栈保护：深嵌套直接 SIGSEGV

- **解码**：`DecodeOptions.max_depth` 不做范围校验（fxamacker 把 `MaxNestedLevels` 限制在 [4, 65535]，超出会在 `DecMode()` 时报错）。设成 65535 后，`decode_item` 递归在约 30k 层 map / 约 40k 层 array 时爆掉原生栈，进程被 **SIGSEGV** 杀掉，没有 `Err`。
- **编码**：`encode` / `encoded_size` / `find_invalid_simple` 都是无深度限制的递归，没有任何选项可以限制深度。50,000 层的值能编码成功，但进程随后在值析构时 SIGSEGV（`OK len=50001` 之后 rc=-11）；100,000 层时编码本身就会崩溃。

| 场景 | Pion | Go |
|---|---|---|
| 解码 `[[[…]]]` 20k / 30k / 40k / 65k 层（max_depth=65535） | OK / OK / **SIGSEGV** / **SIGSEGV** | 全部 OK |
| 解码 `{0:{0:…}}` 20k / 30k / 40k / 65k 层 | OK / **SIGSEGV** / **SIGSEGV** / **SIGSEGV** | — |
| 编码 n 层嵌套数组 10k / 50k / 100k / 1M | OK / **SIGSEGV（析构）** / **SIGSEGV** / **SIGSEGV** | 全部 OK（1M 层 0.375 s） |

默认 `max_depth = 32` 时不受影响（与 Go 默认相同）。但这个旋钮是公开的、可调的，调大以后得到的是进程崩溃而不是错误。编码侧没有任何旋钮，任何由程序构造的深层值都能让进程崩溃。复现见 `run_audit.sh` 第 4 节。

### F-5 缺“已消费长度”API，WebAuthn authData 无法正确解析

公开 API 只有 `decode / decode_default / validate / encode / encode_default / to_diagnostic`（`grep -n '^pub fn' src/*.pion`）。`allow_trailing_bytes: true` 只能拿到第一项，拿不到它的结束位置。现有测试 `roundtrip_cbor_sequence_with_allow_trailing` 也只验证了第一项。

WebAuthn §6.5.1 的 `attestedCredentialData` 是 `aaguid ‖ credIdLen ‖ credId ‖ credentialPublicKey(COSE_Key, CBOR) ‖ extensions(CBOR)`，必须知道 COSE_Key 占多少字节，才能接着解析 extensions。唯一的变通办法是“重编码第一项，用编码长度当作已消费长度”，而这在输入不是 preferred serialization 时是错的：

```text
redteam_reencode_workaround_cannot_recover_item_length
  输入 5f4101ff 02：第一项占 4 字节，重编码 4101 只有 2 字节 → FAIL
```

对照：fxamacker 有 `UnmarshalFirst(data) (rest, err)`、`DiagnoseFirst`、`Decoder` 流（`NewDecoder(r).Decode`）；ciborium 的 `from_reader(&mut &[u8])` 会推进切片。Pion 也没有流式 `Decoder` / `Encoder`（不能从 reader 增量读取，也不能写 RFC 8742 CBOR Sequence），没有 typed struct 编解码，也没有 tag 注册（`TagSet`）、`IndefLength` 单独禁止、`UTF8DecodeInvalid`、`NaN/Inf` 转换策略等 fxamacker 的 `DecOptions` / `EncOptions` 旋钮。

### F-9 官方 benchmark 的对比口径对 Go 不公

`bench/go/cmd/bench_encode` 每条记录新建 4 个 `map[string]any` / `map[int64]any`，再走反射编码，每次都要对键编码并排序；`bench_decode` 解码到 `map[any]any`，需要对每个键做哈希并装箱。这两者是 fxamacker 最慢的使用方式。WebAuthn / COSE 在 Go 里的地道写法是 typed struct（`keyasint`），fxamacker 会缓存字段的编码和排序。

我用 typed struct 重写了 Go 侧（`go/cmd/bench_encode_struct`、`go/cmd/bench_decode_struct`），stdout 与官方 bench **逐字节一致**（SHA-256 `b14fb8d5…` / `3e192925…`），在同一轮交替运行：

| Workload | Pion | Go struct（地道写法） | Go `map any`（官方 bench 用的写法） |
|---|---:|---:|---:|
| 1. 确定性编码 50k 条（ns/op） | 1639.6（**0.63x**） | **1032.3**（1.00x） | 2535.1（0.41x） |
| 2. 解码 + 遍历 80k 条（MB/s） | 214.7（**0.83x**） | **259.4**（1.00x） | 144.4（0.56x） |

所以“优化后在 WebAuthn + Telemetry 语料上双线反超 Go”只在“Go 用 `map any`”的口径下成立。按同一任务的地道 Go 写法，**Pion 编码慢 1.59x、解码慢 1.21x**。Pion 唯一稳定的领先项是峰值 RSS（1.8 MiB vs 11.7 MiB）。另外，官方 Go 解码基准用的是全局 `cbor.Unmarshal`（默认 DecMode），这一点没有问题。

---

## P2

### F-4 tag 0/1/2/3 内容合法性不校验（`redteam_tag*`，6 个 FAIL）

RFC 8949 §3.4.1：tag 0 只能包 RFC 3339 文本串。§3.4.2：tag 1 只能包整数或浮点数。§3.4.3：tag 2/3 只能包字节串。fxamacker 解码到 `any` 时全部拒绝；Pion 默认模式和 strict 模式都接受（ciborium 也接受）。

| 输入 | Go 的报错 | Pion |
|---|---|---|
| `c000` | tag number 0 must be followed by text string, got positive integer | OK |
| `c06161` | cannot set a for time.Time: parsing time "a" … | OK |
| `c16161` | tag number 1 must be followed by integer or floating-point number … | OK |
| `c201` / `c26161` / `c380` | tag number 2 or 3 must be followed by byte string … | OK |

10,000 次变异 fuzz 里有 49 条判定差异属于这一类。

### F-6 NaN 键被误判为重复（`redteam_dup_nan_*`，2 个 FAIL）

`cbor_equals` 的注释明确写着 “Treat all NaNs as equal for **structural test comparison**”，但 decode 的重复键检测直接复用了它。`a2 f97e00 01 f97e01 02`、`a2 f97e00 01 fb7ff8000000000001 02` 的两个键编码不同、payload 不同，是两个不同的数据项。Pion 在 `reject_duplicate_keys` 下拒绝它们，Go `DupMapKeyEnforcedAPF` 接受。fuzz 的 dup 模式里另有 5 条同类差异。

### F-7 Core Deterministic 不做 bignum preferred serialization（`redteam_*bignum*`，3 个 FAIL）

RFC 8949 §3.4.3 规定：能用 major type 0/1 表示的整数，preferred serialization 必须那样编码，bignum 字节串也不能带前导 0；§4.2.1 规定 Core Deterministic 必须使用 preferred serialization。实测 `encode(Tag(2, h'01'), deterministic())` 输出 `c24101`（Go CoreDet 输出 `01`），而 `DecodeOptions::strict()` 接受 `c24101` 和 `c2420001`。

### F-8 strict 解码无法验证 CTAP2 canonical（`redteam_strict_accepts_own_ctap2_output`，FAIL）

`require_canonical` 的键序比较固定用 `cmp_slice_lex`（RFC 8949 的字节序）。CTAP2 / RFC 7049 §3.9 是“先比长度，再比字节”。只要键长不一样，两种顺序就会分歧，例如 `{10, -1, 24}` 按 CTAP2 是 `0a, 20, 1818`，按字节序是 `0a, 1818, 20`。结果是 Pion 自己 `EncodeOptions::ctap2()` 的输出 `a30af620f61818f6` 会被 `DecodeOptions::strict()` 判为 NonCanonicalEncoding。fxamacker 不校验键序，所以这一项不是相对 Go 的退步，而是 README 中 “CTAP2 + strict canonical decode validation” 这一卖点自相矛盾。

### F-10 解码入口整份拷贝输入

`decode()` 第一步就是 `data_str: data.to_string()`，不管输入里有没有文本串，都整份拷贝一次（用于给 Text 切片）。64 MiB 字节串解码 ×3：

| | 中位数 | 峰值 RSS |
|---|---:|---:|
| Pion | 63.9 ms（0.64x Go） | 193.8 MiB（3.0 × 输入） |
| Go | 40.9 ms | 262.7 MiB |
| Rust | 43.8 ms | **132.1 MiB**（2.06 × 输入） |

64 MiB 文本串时 Pion 领先 Go（1.17x），原因是这次拷贝被文本切片复用了；字节串负载则白付一次拷贝。

---

## 方法与口径说明

- **差分判定**以 accept/reject 为准；值差分用 Core Deterministic 重编码后逐字节比较。Go 侧解码到 `any` 会带来已知的有损转换（time、big.Int、map 键类型限制），这类差异都已逐条归因，没有计入 Pion 的指控。
- **benchmark**：`scripts/bench_compare.py --warmup 1 --rounds 5`，严格交替轮转，所有表格的 stdout SHA-256 都一致。对抗 bench 的时间包含一次解码（三方相同）。Rust 没有重复键选项，所以不参加 `dupdec`。ciborium 没有 canonical 模式，Rust 侧按编码字节对键排序（CTAP2 先比长度），输出与 Go、Pion 逐字节一致。
- **单次 DoS 用例**（第 5 节）用的是 `oneshot.py` 的墙钟时间，超时 300 s。同机有其他负载，倍率比绝对时间更可信。
