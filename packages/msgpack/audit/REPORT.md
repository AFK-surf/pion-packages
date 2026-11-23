# 红队审计报告：Pion `packages/msgpack` @ `ef53ce0`（`feat/pkg-msgpack`）

对照实现：Rust [`rmpv`](https://github.com/3Hren/msgpack-rust) **=1.3.1**（`--release`，与 `bench/rust` 相同）、Go [`vmihailenco/msgpack/v5`](https://github.com/vmihailenco/msgpack) **v5.4.1**（与 `bench/go` 相同）、MessagePack 规范（含 Timestamp ext `-1`）。
环境：`tokyo-mac-studio-0`（Darwin arm64，`pionc 0.1.0` = `AFK-surf/pion@bee7628`，node v24.22.2），2026-11-23。整机同时有其他负载，时间数字以同一轮交替运行的**倍率**为准。

## 一键复现

```sh
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
sh packages/msgpack/audit/run_audit.sh           # 全量，约 8 分钟（F-2 的 2 MiB 用例单个约 70 s）
QUICK=1 sh packages/msgpack/audit/run_audit.sh   # 跳过 262144 键 HashDoS 和 2 MiB 流
cd packages/msgpack && pionc test --json audit   # 只跑红队单测：5 个 redteam_* FAIL = 5 条铁证，6 个 control_* PASS
```

所有构建产物、输入和日志写到 `$AUDIT_OUT`（默认 `/private/tmp/pion-msgpack-audit-$USER`），不写进 git worktree。`pionc test packages/msgpack` 原有 27 个测试不受影响（全过）。

| 文件 | 作用 |
|---|---|
| `redteam_test.pion` · `src/lib.pion` | 5 个 `redteam_*`（FAIL 即铁证）+ 6 个 `control_*`（Pion 扛住的攻击，必须保持绿色） |
| `probe/` · `rust/src/main.rs` · `go/cmd/probe` | 三方差分探针，同一协议：`tree <opts> <hex 行文件>` → `OK <树> <重编码>` / `ERR <消息>`；另含 `bench` / `deep` / `bigenc` / `deepdrop` 模式 |
| `gen_vectors.py` · `diff_vectors.py` | 592 个定向向量（全部 256 个首字节完整/截断、整数各宽度边界、IEEE-754 位模式、Timestamp 32/64/96 与非规范容器、canonical、UTF-8、重复键、深度 63–129）三方差分 + Pion 4 模式逐字节一致 + canonical 自检 |
| `fuzz_diff.py` | 30,000 个结构化 + 变异输入（seed 1795）：Pion 4 模式 × 4 组选项、三方判定 / 树 / 重编码差分 |
| `gen_adversarial.py` | 对抗负载：HashDoS 碰撞键 map、`decode_prefix` 帧流、1M 整数/f32/f64 数组、含非 UTF-8 bin 的 1 MiB RPC 包、深度 100 ×1 万、1 万键 str map |
| `go/cmd/bench` · `rust` `bench` · `probe bench` | 对抗 benchmark 三方实现，stdout 逐字节一致（`scripts/bench_compare.py` 做 SHA-256 校验） |
| `go/cmd/bench_struct` | 公平性复核：地道 Go 写法（typed struct + msgpack tag）跑官方 workload 1/2，stdout 与官方 bench 逐字节一致 |
| `oneshot.py` | 单次运行计时、退出码 / 信号与峰值 RSS |

“Pion 4 模式”= native debug、native `--release`、wasm32 debug、wasm32 `--release`（后两者用 `node pion_wasm_rt.mjs` 实际运行）。

---

## 结论速览

| 级别 | # | 指控 | 证据倍率 / 现象 |
|---|---|---|---|
| **P0** | F-1 | `reject_duplicate_keys` 的“O(n) 哈希表”可被 **HashDoS 打成 O(n²)**：2.6 MB 报文吃掉 **21.7 s** CPU | 同报文 Go map / Rust HashSet 判重 0.049 s，**约 440 倍**；同尺寸随机键 Pion 0.022 s |
| **P0** | F-2 | `decode_prefix_at` 流式循环在 ≤ 2 MiB 缓冲上是 **O(N²)**：每帧把整块缓冲 `to_string()` 拷一遍 | 2 MiB / 52 万帧：**69.1 s**，Rust 0.044 s（**~1570 倍**）、Go 0.119 s；2.2 MiB 反而 0.052 s（性能悬崖） |
| **P1** | F-3 | `encode` 输出超过 2 GiB 时 32 位 `Int` 尺寸溢出，**进程直接 abort**（SIGABRT / wasm trap），不返回 `Err` | 1 MiB Bin 引用 ×2048：Pion 3 ms 内 `negative bytes length` 崩溃（RSS 仅 2.8 MiB）；rmpv 正常写出 2,147,493,891 B |
| **P1** | F-8 | “树解码硬上限 1024 层”在 **wasm32 上只剩 ~3% 栈余量**；native 下用户构造的深值在 ~51.5k 层析构就 SIGSEGV | node `--stack-size=950`（默认 984）下 `max_depth: 1024` 解码 1024 层 map 即 `RangeError: Maximum call stack size exceeded`；rmpv 10 万层构造+编码+析构正常 |
| **P1** | F-9 | 官方 benchmark 口径不公：Go 侧用最慢的 `any` 解码和 `map[string]any` + `SetSortMapKeys(true)` 编码；Rust 侧没用零拷贝 `read_value_ref` | 换成地道 Go typed struct：解码 Go **1.12x**、编码 Go **1.37x** 快于 Pion；Rust `read_value_ref`：RPC 树 1.14x、1M 整数/f32/f64 数组 **1.57–1.69x** 快于 Pion；深度 100 负载 Go 快 **1.97x** |
| P2 | F-4 | `decode` 把 `max_depth` 静默钳到 1024，`validate` 却照用户值；`validate` 一开 `reject_duplicate_keys` 又变成 1024；报错写 1024 不写用户给的值 | `max_depth: 2000`，1025 层：decode=Err、validate=Ok、validate+dup=Err（rmpv `read_value_with_max_depth(2000)` 与 Go 都接受） |
| P2 | F-5 | 默认 `max_depth` 128 与 rmpv 默认 1024 / Go 无上限不兼容 | 129 层普通数组：`decode_default` 拒绝，rmpv、Go 接受 |
| P2 | F-6 | 深度 ≥ 64（迭代路径）时 `DuplicateMapKey` 报的偏移错位（容器 key 记成了其最后一个标量的位置） | 同一 map：深度 0 报 offset 4，深度 64 报 69（应为 68） |
| P2 | F-7 | `encode` 接受 `Ext(-1, 3 字节)` 等非法 Timestamp 长度，产出的字节被 Pion 自己的默认解码器拒绝 | `c703ff000000` → `InvalidTimestamp`；encode/decode 不能往返 |

### 审过但没坐实的指控（如实记录）

- **≤ 2 MiB `data.to_string()` 快路径不会损坏字节，也不会误报/漏报 UTF-8**（任务书怀疑的“大 P0 雷”不成立）：Pion `String` 是字节串，`pion_bytes_to_str` 在 native（`pion_rt.c:1465`）和 wasm32（`pion_wasm_rt.mjs:870`）都是原样 `memcpy`，不做替换；UTF-8 校验在切片前按字节范围单独做。含非 UTF-8 `bin` + 合法 `str` 的混合包在 ≤ 2 MiB 与 > 2 MiB 两条路径解出完全相同的字符串，坏 `str` 的报错偏移也对（`control_le_2mib_to_string_fast_path_mixed_bin_str`，1 MiB `rpc_mixed_1m` 在 4 模式下结果一致）。这条路径真正的问题是性能（F-2）。
- **语义正确性很扎实**：592 个定向向量 + 30,000 个 fuzz 输入，三方差分 **0 个无法解释的差异**，Pion 4 模式 × 5 组选项 **0 个逐字节差异、0 次崩溃**；Pion 自己的 465 个重编码全部通过 `DecodeOptions::strict()`。所有差异都是 Pion 更严格且符合规范：
  - rmpv 把保留字节 **`0xC1` 解成 `nil`**（Rust 的 bug，72 例），Pion / Go 拒绝；
  - rmpv、Go 都**不校验 `str` 的 UTF-8**（overlong、代理对、`> U+10FFFF`、截断全部放行），Pion 按 RFC 3629 拒绝；
  - Go 接受 **`nsec ≥ 1e9` 的 Timestamp** 并悄悄归一化（`ts64(0,1e9)` → `t1.0`，`ts96(-1,1e9)` → `t0.0`），Pion 拒绝。
- **重复键判定与哈希一致**：`0x00` / `cc00` / `d000`、`Int(5)` / `UInt(5)`、fixstr / str8 同内容、ts32 / ts64 同时刻、`[1]` / `[cc01]` 都判重；`Float64(0.0)` vs `Float32(0.0)`、`+0.0` vs `-0.0`、payload 不同的 NaN、`str` vs `bin`、`-1` vs `UInt64::MAX` 都不判重；≤ 8 键线性路径与 > 8 键哈希路径结论完全一致（`eq ⇒ hash` 成立）。
- **深度 63/64/65/66、127/128/129、1023/1024 交界无差 1**：数组与 map 在 `decode` / `validate` / `decode_prefix` / dup 解码 / 重编码 / `msgpack_equals` 上结论一致（`control_depth_boundaries_consistent_around_64_and_1024`）。
- **IEEE-754**：全部特殊 f32 位模式（subnormal、±0、±Inf、quiet/signaling/负 NaN payload）往返逐位不变，wasm32 也不规范化 sNaN；`compact_floats` 只做无损收窄（`-0.0` → f32，`16777217.0` / `1e40` / `1e-40` / 低位 NaN payload 保持 f64，最小 subnormal 2^-149 正确收窄成 `ca00000001`）。
- **Timestamp**：32/64/96 位边界、`Int64::MIN..MAX`、全部非法长度（0/1/2/3/5/7/9/11/13/16）、`nsec ≥ 1e9` 都正确；`require_canonical` 拒绝非最短容器（ext8 装 4 字节、ext16 装 8 字节、ext32 装 12 字节、64 位装 32 位可表示值、96 位装 34 位可表示值）；`decode_timestamp: false` 保留原始 `Ext(-1, bytes)`。
- **`require_canonical`**：str8 装 ≤ 31 字节、bin16 装 ≤ 255、ext8 装 1/2/4/8/16、int8(5)、uint8(5)、int64(-1)、array16/map16 装 ≤ 15 项、嵌套内部的非最短编码全部拒绝；`encode_default` 产出 100% canonical。
- **长度炸弹 / 截断 / 尾随字节**：5 字节宣称 `0x7FFFFFFF` / `0xFFFFFFFF` 的 array32 / map32 / str32 / bin32 / ext32 都在分配前拒绝；10 万层 `validate` 正常。
- **编码非法值**：`Timestamp` 的 `nsec < 0` / `≥ 1e9`、ext type 超出 `-128..=127` 都返回 `Err`，不 panic（`control_encode_invalid_values_return_err`）。
- **基准里 Pion 领先的项也照实记**：1 MiB 混合 RPC 包、1 万键 str map 的普通解码 Pion 领先 rmpv `read_value` 与 Go；`require_canonical` 几乎零开销；dup 判重在 1 万个**正常**键上比 Go map 快 1.75x。

---

## P0

### F-1 `reject_duplicate_keys` HashDoS：O(n) 哈希表退化成 O(n²)

**根因**（`src/decode.pion`）：
- `mix64`（121–126 行）是**无种子**的 SplitMix64 终结器，这是一个可逆双射；`msgpack_key_hash` 对整数键直接 `mix64(u ^ 0x3030…30)`（133–139 行）。
- `KeyHashSet` 用线性探测（`key_hash_set_insert` 264–295 行），槽位 = `hash & mask`。

攻击者对任意想要的哈希值求逆即可得到键：`gen_adversarial.py` 让所有键的哈希低 24 位全为 0，于是每个新键都从同一个槽开始，沿着越来越长的簇线性探测（哈希高位不同，所以连 `msgpack_equals` 都不用调，纯探测就是 n²/2 次）。字符串键用的 FNV-1a 同样无种子，原理相同（本次只实测了整数键）。

| 键数 | 报文 | Pion dup（碰撞键） | Pion dup（随机键） | Go map 判重 | Rust HashSet 判重 |
|---:|---:|---:|---:|---:|---:|
| 16,384 | 164 KB | 0.089 s | 0.004 s | 0.213 s\* | 0.006 s |
| 65,535 | 655 KB | 1.274 s | 0.007 s | 0.011 s | 0.011 s |
| 131,072 | 1.3 MB | 5.214 s | 0.014 s | 0.018 s | 0.023 s |
| 262,144 | 2.6 MB | **21.716 s** | 0.022 s | 0.049 s | 0.049 s |

\* 首次运行含 Go 冷启动抖动。键数翻倍 → 时间 ×4，标准二次方。默认 `max_items` 允许单个 map 524,287 对（5.2 MB 报文），按趋势约 **87 s/报文**。rmpv / Go 本身不提供判重，表中是各自语言里地道的做法（Go 内置 map、Rust `std::collections::HashSet`，均为随机种子哈希），不受影响。README 里“O(n) hash-table duplicate map key rejection”的说法不成立。

### F-2 `decode_prefix_at` 流式解码 O(N²)

**根因**：`extract_utf8_str`（`src/decode.pion:43–58`）在缓冲 ≤ 2 MiB 时，第一次遇到 `str` 就 `dec.data.to_string()` 把**整块输入**拷成 `String` 缓存在 `Decoder` 上；而 `decode_prefix_at`（1314–1328 行）每次调用都 `make_decoder` 新建 `Decoder`，缓存随之作废。于是“按帧调用 `decode_prefix_at`”这个最自然的流式写法，每帧都要拷整块缓冲。

| 缓冲（4 字节帧 `{"k": n}`） | Pion `decode_prefix_at` 循环 | Pion `decode_all` | Go `Decoder.Decode` 循环 | Rust `read_value` 循环 |
|---:|---:|---:|---:|---:|
| 64 KiB | 0.090 s | 0.005 s | 0.007 s | 0.005 s |
| 256 KiB | 1.139 s | 0.009 s | 0.017 s | 0.007 s |
| 1 MiB | 16.425 s | 0.020 s | 0.063 s | 0.025 s |
| 2 MiB | **69.093 s** | 0.046 s | 0.119 s | 0.044 s |
| 2.125 MiB（> 2 MiB 阈值） | 0.052 s | 0.058 s | 0.110 s | 0.035 s |

`bench_compare.py` 同轮交替（256 KiB，SHA-256 一致）：Pion 1120.5 ms vs Rust 12.7 ms vs Go 21.3 ms（**0.02x**）。2 MiB 比 2.125 MiB 慢 1300 倍，是典型的性能悬崖。`decode_all` 没这个问题（只建一个 `Decoder`），但它把所有帧攒进一个数组，不适合真正的流（峰值 RSS 155 MiB vs `decode_prefix_at` 6 MiB）。同一机制也让 `validate()` 在 ≤ 2 MiB 输入上为“零树校验”白白拷贝整块输入。

---

## P1

### F-3 `encode` 输出 > 2 GiB：32 位尺寸溢出导致 abort

`encoded_size` / `encoded_size_iter`（`src/encode.pion:120–238`）用 32 位 `Int` 累加 `total`，`encode`（680 行）直接 `Bytes::new(total)`，没有任何溢出检查。值可以很便宜地构造出来：`Bytes` 是引用计数共享的，2048 个元素都引用同一个 1 MiB `Bin` 只占 1 MiB 内存。

| 构造 | Pion `encode_default` | rmpv `write_value_ref` |
|---|---|---|
| 1 MiB × 2047（2,146,445,310 B） | OK（0.76 s，RSS 2050 MiB） | OK |
| 1 MiB × 2048（2,147,493,891 B） | **SIGABRT**：`pion panic … negative bytes length`（3 ms，RSS 2.8 MiB） | OK |
| 1 MiB × 4097（4,296,036,360 B） | **SIGABRT**：总数回绕成 2 万字节，随后 `index 1069064 out of bounds` | OK |
| wasm32 release，1 MiB × 2048 | trap：`index out of bounds: idx=0, len=0` | — |

Pion 的 `Bytes` 装不下 > 2 GiB 是平台限制，但 API 签名是 `Result[Bytes, MsgpackError]`，正确行为应是返回错误而不是把整个进程带走（任何对不可信输入做聚合 / 转发再编码的服务都会被打崩）。4097 的回绕没有越界写（运行时有边界检查），所以是 DoS 而不是内存破坏。

### F-8 栈深度：wasm32 余量 ~3%，用户深值 ~51.5k 层析构崩溃

`max_safe_tree_depth = 1024`（`src/decode.pion:14`）的注释写明它是为了防止 Pion **递归 RC 析构**爆栈。实测：

- wasm32（debug / release 一样，node 默认 `--stack-size=984`）：数组链析构上限约 1,680 层，**map 链只有约 1,052 层**。在默认栈下 `max_depth: 1024` 解码 1024 层 map 刚好过，`--stack-size=950` 就 `RangeError: Maximum call stack size exceeded`（1024 层数组仍过）。嵌入到调用栈较深的 JS 宿主或栈更小的环境里，README 宣称安全的 1024 上限就会 trap。
- native：用户自己构造的深值在约 51,562 层（数组）析构时 SIGSEGV（`deep a 60000 128 encode`、`deep a 100000 128 equals` 都是 rc=139）；rmpv 在 10 万层构造 + `write_value` + 析构正常（100 万层才栈溢出），Go 无此问题。README 里“迭代 `encode` / `msgpack_equals`，10 万层 0 SIGSEGV”只对 `validate`（不建树）成立；`encode` / `msgpack_equals` 的迭代实现本身没问题，但值在超过 ~5 万层（wasm32 ~1–1.7 千层）时根本活不到析构之后。

### F-9 官方 benchmark 口径不公

`bench/go` 解码用 `msgpack.Unmarshal(&any)`（最慢的 `map[string]any` 装箱路径），编码用 `map[string]any` + `SetSortMapKeys(true)`（每条记录排序一次，而 Pion / Rust 直接按已排好的顺序写）；`bench/rust` 用 `read_value(&mut Cursor)` 拷贝解码，没用 rmpv 文档里的零拷贝 `read_value_ref`。`go/cmd/bench_struct` 用 typed struct 跑**同一份**语料 / 同一组记录，stdout 与官方逐字节一致：

| 负载（同轮交替，SHA-256 一致） | Pion | 地道对手 | 官方对手 |
|---|---:|---:|---:|
| W1 decode-rpc 80k 记录 | 64.9 ms | Go typed struct **58.2 ms（Go 快 1.12x）** | Go any 112.9 ms |
| W2 encode-rpc 50k 记录 | 33.5 ms | Go typed struct **24.3 ms（Go 快 1.37x）** | Go any + 排序 43.9 ms |
| W1 语料，通用树遍历 | 59.3 ms | Rust `read_value_ref` **52.0 ms（Rust 快 1.14x）** | Rust `read_value` 93.9 ms |

对抗负载（`bench_compare.py`，5 轮交替，SHA-256 一致；中位数）：

| 负载 | Pion | Pion `require_canonical` | rmpv `read_value` | rmpv `read_value_ref` | Go `any` |
|---|---:|---:|---:|---:|---:|
| 1 MiB 混合 RPC（非 UTF-8 bin + str）×20 | 75.4 ms | 74.0 ms | 83.2 ms | **45.2 ms** | 101.3 ms |
| 1M 整数数组 ×5 | 76.0 ms | 75.6 ms | **54.9 ms** | **48.3 ms** | 110.7 ms |
| 1M f32 数组 ×5 | 81.4 ms | 79.9 ms | **55.1 ms** | **48.5 ms** | 111.2 ms |
| 1M f64 数组 ×5 | 83.9 ms | 84.9 ms | **57.2 ms** | **49.5 ms** | 112.5 ms |
| 深度 100 × 1 万（> 64 迭代路径）×5 | 455.2 ms | 445.3 ms | 636.6 ms | 387.0 ms | **231.5 ms** |
| 1 万键 str map ×50 | 27.7 ms | 28.1 ms | 29.6 ms | **19.4 ms** | 49.2 ms |
| 1 万键 str map，判重 ×50 | **36.2 ms** | — | 111.9 ms† | — | 63.6 ms |
| 256 KiB / 65,536 帧流 ×1 | 1120.5 ms（`decode_all` 14.0 ms） | — | **12.7 ms** | — | 21.3 ms |

† Rust 判重用的是审计探针里的“树字符串指纹 + HashSet”，开销主要在格式化，不代表 Rust 的上限。

结论：Pion 落后于 rmpv（纯数值数组 1.4–1.7x）和 Go（深嵌套 1.97x、地道 struct 1.12–1.37x）；README 里“Pion 领先 Go 1.64x / 1.37x”的结论只在 Go 用 `any` 时成立。

---

## P2

- **F-4** `make_decoder`（`src/decode.pion:1271–1276`）把 `max_depth` 钳到 1024，报错 `MaxDepthExceeded(1024)` 而不是调用方的值；`validate_iter`（1357 行起）不钳，但 `reject_duplicate_keys: true` 时转去调 `decode`（1358–1363 行）又被钳。同一份输入、同一组选项，`decode` / `validate` / `validate`+dup 结论不同（`redteam_decode_honours_caller_max_depth_like_validate`、`redteam_validate_depth_independent_of_dup_flag`）。
- **F-5** 默认 `max_depth: 128`（`src/types.pion`）：129–1024 层的正常文档 rmpv 默认 `read_value`（`MAX_DEPTH = 1024`）和 Go 都能读，Pion 默认拒绝（`redteam_default_depth_compat_with_rmpv_1024`）。安全上偏保守可以接受，但应在 README 写明与上游默认不同。
- **F-6** `decode_iter` 在 map 帧里记录 `frame_key_pos[top] = start_pos`（`src/decode.pion:724`），`start_pos` 是**最后读到的那个标量**的位置；key 是容器时偏移就错了。深度 0 报 `offset 4`，同一 map 放在深度 64 报 69（应为 68）（`redteam_dup_key_offset_same_in_iterative_path`）。
- **F-7** `encoded_size` 不检查 `Ext(-1, …)` 的长度：`encode_default(Ext(-1, [0,0,0]))` 输出 `c703ff000000`，`decode_default` 报 `InvalidTimestamp`（`redteam_encode_rejects_or_roundtrips_ext_minus1`）。rmpv 原样往返；Pion 要么编码时报错，要么解码时在 `decode_timestamp: true` 下也保留非标准长度的 `Ext(-1)`。
- **观察（未单独出测）**：`decode_all` 每帧把 `dec.items` 清零（`src/decode.pion:1346`），`max_items` 只约束单帧，不约束整个流；`max_bytes` 只检查单个 str / bin / ext 的长度，不是总字节预算。README 未说明这两点语义。

---

## 4 模式一致性（native debug / release、wasm32 debug / release）

- 592 个定向向量 × 5 组选项（`-`、`ts0`、`canon`、`dup`、`compact`）、30,000 个 fuzz 输入 × 4 组选项：**0 个逐字节差异、0 次崩溃 / trap / OOM**。
- `wasm_smoke` debug / release 在 node 下 exit 0；`rpc_mixed_1m`、`deep100_x10k`、`strmap_10k` 三个大负载的 dup 解码结果 native 与 wasm32 一致。
- 唯一的模式差异是栈深度（F-8）和溢出时的报错文本（F-3：native `negative bytes length` / wasm32 `index out of bounds`，二者都是崩溃）。
