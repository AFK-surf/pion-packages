# `packages/crdt` 红队审计报告（vs 官方 Node.js `yjs` / Rust `yrs`）

- 审计对象：`AFK-surf/pion-packages` `origin/main` `7a40e8f`，`packages/crdt/src/**`（未改动任何源码与原有测试）。
- 参照实现：Node.js `yjs@13.6.33`（`lib0` 随附，`node v24.22.2`）；Rust `yrs =0.28.2`（`cargo build --release`，`lto=thin`，`OffsetKind::Utf16`，与 JS 索引一致）。`y-octo =0.3.0` 已锁进 `rust/Cargo.lock`，本轮未单独出数。
- 机器：`Darwin arm64`（Apple M5 Max (Darwin arm64)）。**跑 bench 时同机还有别的会话在跑审计，load average ≈ 42**，绝对毫秒数有噪声；三个实现严格交替轮转，倍率可比。
- 一键复现：`sh packages/crdt/audit/run_audit.sh`（`SECTIONS="tests fuzz yrs malformed size bench"`、`SEEDS`、`ROUNDS` 可调；产物只写 `~/.cache/pion-crdt-audit` 与 `$AUDIT_OUT`）。

## 0. 总览

| 级别 | 编号 | 指控 | 证据（全部可复现） |
| --- | --- | --- | --- |
| **P0** | P0-1 | 收到**远端删除**后，本地下一次编辑**改错字符**（search marker 失效） | `p0_1_*` 失败；fuzz `ops-ascii` 6/60、`ops-unicode` 4/60 与 yjs 状态不一致，清掉 marker 后（`+nm`）0/60 |
| **P0** | P0-2 | 在 emoji 中间插入（JS/yjs 合法的 UTF-16 下标）后，**Pion 副本之间永不收敛** | `p0_2_*` 失败；fuzz `ops-emoji` 60/60 失败，其中 39 个是 Pion 自己的副本互不一致 |
| **P0** | P0-3 | 解码官方 yjs 拆分代理对的 update 结果与 yjs/yrs 不同 | `p0_3_*` 失败；`shuffle-emoji` 60/60 与 yjs 不一致，yrs 在同样 120 个乱序投递脚本上与 yjs **120/120 一致** |
| **P0** | P0-4 | **任何 `Y.XmlFragment` / `Y.XmlElement` 文档（y-prosemirror、Tiptap、BlockNote…）整包被拒** | `p0_4_*` 失败：`INVALID_CONTENT_REF` |
| **P0** | P0-5 | **15 字节的恶意 update 让进程 abort**（`Int` 32 位溢出 → 越界 panic） | `run_audit.sh` [4] `str_len_2p31`：`pion panic: index -2147483636 out of bounds`；yjs、yrs 都返回错误 |
| P1 | P1-1 | 重新编码时把 `Y.XmlText`（ref 6）改写成 `Y.Text`（ref 2）：用 Pion 做中继/持久化会改坏所有下游的类型 | `p1_1_*` 失败（字节 `06`→`02`） |
| P1 | P1-2 | 子文档（`ContentDoc`，ref 9）整包被拒 | `p1_2_*` 失败 |
| P1 | P1-3 | **没有 GC**：删掉的文本以明文继续随 update 发给所有对端（隐私泄露），update 体积是 yjs 的 4.4 倍 | `p1_3_*` 失败；automerge-paper：yjs 223,414 B / yrs 223,411 B / **Pion 990,662 B** |
| P1 | P1-4/5 | `YText::format` 不是 yjs 语义：区间重叠时尾部丢属性，嵌套时不恢复外层的值 | `p1_4_*`、`p1_5_*` 失败；fuzz `format+nm` 12/60 连**纯文本**都和 yjs 不一致 |
| P1 | P1-6 | 恶意深度嵌套的 `Any`（200k 层，400 KB）→ **SIGSEGV**（yjs 抛可捕获的 RangeError；yrs 同样 SIGABRT） | [4] `deep_any_200k` |
| P1 | P1-7 | 性能：**连续输入是 O(n²)**，20 万次追加比 yrs 慢 **26 倍**（yjs 也比它快 4.6 倍）；远端 apply 比 yrs 慢 1.9 倍 | 见 §3 |
| P1 | P1-8 | 功能缺口：没有 XML 类型、UndoManager、observe/事件/事务 origin、Awareness、Update v2、Subdocs、Snapshot、RelativePosition、`toDelta`/`applyDelta`/`insert(…, attrs)`/`insertEmbed` | §2 列了 grep 证据 |
| P2 | P2-1 | 重新编码 `Any` 对象时按字母序排 key，破坏 JS 的 key 顺序（yrs 也会重排，所以只算“不如 yjs”） | `p2_1_*` |
| P2 | P2-2 | pending 队列每重投一次就多存一份（200 次 → 200 份；yjs 合并成 1 份），重传下内存无上限 | `p2_2_*` |
| P2 | P2-3 | 接受非法 UTF-8（yjs、yrs 都拒绝），UTF-16 长度算错，后面那个 struct 被悄悄变成 GC | `p2_3_*` |
| P2 | P2-4 | 长度 2^53-1 的 GC 块被截成 32 位 `Int`，时钟回绕到 2^64-1，后面的插入丢失（yjs：时钟 2^53，文本 `"x"`） | `p2_4_*` |
| P2 | P2-5 | 现有 `BENCHMARKS.md` 只和 yjs 比；yjs 版本没锁；stdout 用 `upd_ge=1` 把 update 体积差藏了起来 | `packages/crdt/bench/bench_node_text.mjs:70`、`BENCHMARKS.md:246` |

**Pion 做得好、如实记下的地方**（这些攻击没有打穿）：纯 ASCII/CJK 的远端整合与乱序投递（`shuffle` 60/60 与 yjs 一致）、`merge_updates`/`diff_update`（60/60）、清掉 marker 后的多端 ASCII/CJK 收敛（120/120）、深 2 万层的嵌套类型删除（yjs 自己栈溢出，Pion 正常）、u53 边界 client id、100 万个 delete 区间不挂；本地编辑型 benchmark（W1、tombstone、真实 trace）比 yrs（每次操作一个事务）和 yjs 都快。

## 1. 正确性 / 互操作铁证

`pionc test --json -p crdt_redteam_audit packages/crdt/audit` → `total=16 passed=3 failed=13`。3 个 `control_*` 对照测试通过（证明夹具和 delta 辅助函数本身是对的），13 个证据测试全部失败。说明：`pionc test` 只认包根目录下的 `*_test.pion`，所以测试文件放在 `audit/redteam_test.pion`，没有放 `audit/tests/`。

### P0-1 远端删除后 search marker 失效 → 本地编辑打到错误的字符
```
A: "0123456789abc" → 同步给 B；B 在末尾追加 "XYZ" → 同步给 A；A 删除 [10,12) "ab" → 只把 delete set 同步给 B
B: "0123456789cXYZ"，执行 delete(12,1)（删 "Y"）
yjs = yrs = "0123456789cXZ"        Pion = "0123456789XYZ"（删掉的是 "c"）
```
根因：只有整合**新的远端 struct** 时才会清 marker（`src/doc.pion:421` `parent.markers.clear()`），而 `apply_delete_set_to_doc`（`src/encoding.pion:902`）→ `delete_item` 只把 `parent.length` 减掉，不动 marker；`find_insert_pos` 往回走时仍然相信过期的 `marker.index`。真实协作里“对端删了点东西，我接着打字”是最常见的路径，结果是悄悄地错删、错插，而且这个错操作会被广播出去。
fuzz 证明这是 ASCII/CJK 场景下唯一的根因：`ops-ascii` 6/60、`ops-unicode` 4/60 失败，加上 `+nm`（harness 在每次本地操作前清空 marker）后两个模式都是 0/60。

### P0-2 / P0-3 UTF-16 代理对被拆分
yjs 的 `ContentString.splice` 在代理对中间切开时，两半各换成 U+FFFD；Pion 的 `utf16_to_byte_offset`（`src/store.pion:31`）会**越过**整个 4 字节序列，`content_split`（`src/store.pion:357`）于是得到左半 = 整个 emoji、`len=1`：长度和内容对不上。
```
A: "😀ab" → B；A.insert(1,"z")，B 并发 insert(3,"Q")；双向全量同步
yjs = yrs = "�z�aQb"（两边一致）    Pion: A="😀zabQ"  B="😀zaQb"  ← 不收敛
```
`ops-emoji` 60/60 失败（39 个 Pion 自己副本之间不一致，21 个与 yjs 不同），`shuffle-emoji`（把 yjs 产生的 update 打乱顺序投给 Pion）60/60 失败；yrs 跑同样的 120 个脚本与 yjs 120/120 一致。emoji 修饰符、肤色、ZWJ 旗帜这类文本在真实聊天/文档里都很常见。

### P0-4 / P1-1 / P1-2 线协议：XML 与子文档
- `read_raw_content` 的 ref 7（`src/encoding.pion:394`）只读了 typeRef。yjs 的 `readContentType` 遇到 `YXmlElement`(3)/`YXmlHook`(5) 还要再读一个 nodeName 字符串，于是解码错位 → `INVALID_CONTENT_REF`，**整个 update 被拒**（y-prosemirror、Tiptap、BlockNote、Hocuspocus 的文档全都是这种）。
- `int_to_type_ref`（`src/store.pion:295`）把 3..6 全映射成 `YTextRef`：`Y.XmlText` 重新编码后变成 `Y.Text`，`p1_1` 里字节 `06`→`02`。
- ref 9 `ContentDoc` 落到 `_ => INVALID_CONTENT_REF`（`src/encoding.pion:415`）。

### P1-3 没有 GC：已删内容泄露
```
insert "public " + "SECRET-PASSWORD-123"，再删掉 secret
yjs (gc=true) update = 25 B，不含 "SECRET"      Pion update 含明文 "SECRET-PASSWORD-123"
```
真实 trace（automerge-paper，259,778 次编辑）：`encodeStateAsUpdate` 体积 yjs 223,414 B、yrs 223,411 B、**Pion 990,662 B（4.4×）**。

### P1-4/5 富文本语义
`YText::format`（`src/doc.pion:860`）只是在 `index` 插 `key=val`、在 `index+len` 插 `key=null`，没有实现 yjs 的 `formatText`/`insertAttributes`/`minimizeAttributeChanges`：
- `abcdef` 全部加粗后再对 `[2,4)` 加粗 → yjs：`abcdef{bold}`；Pion：`abcd{bold} ef{}`。
- 外层 red、内层 blue → yjs：`ab red / cd blue / ef red`；Pion：`ef` 没有颜色。
- 本地插入时也不会像 yjs 那样跳过格式标记、补否定属性，fuzz `format+nm` 有 12/60 连纯文本的顺序都和 yjs 不同。

### P2 系列
见 §0 表格与测试注释；对应的失败信息由 `run_audit.sh` [1] 打出。

## 2. 功能缺口（vs yjs / yrs / y-octo）

`grep -ci` 统计 `src/*.pion`，下列关键词命中都是 0：`Xml`、`Undo`、`observe`、`Awareness`、`v2`、`Subdoc`、`Snapshot`、`gc`、`insert_embed`、`RelativePosition`/`sticky`、`transact`/`Transaction`。公开 API 只有：`Doc::{new,get_text,get_array,get_map,state_vector,encode_state_vector,encode_state_as_update(_from),apply_update}`、`YText::{insert,push,delete,format,len,to_string}`、`YArray::{insert,insert_range,push,insert_text/array/map,delete,get,get_*,len,to_array}`、`YMap::{set,set_*,get,get_*,delete,contains_key,len,keys,to_map}`、`merge_updates`、`diff_update`。另外：
- 没有 `toDelta`：读不出富文本属性和 embed，只能拿纯文本（本审计只好在测试里自己写了 `delta_string`）。
- 没有事务：每次操作就是一个独立 update，没有 origin、没有事件，也就没法接 y-websocket/y-protocols 的 awareness。
- 没有 Update v2：v2 字节按 v1 解析，“成功”但什么都没写进去（yjs v1 解码器对此也一样，所以只算缺口，不算 bug）。
- `YArray::to_array` 丢掉嵌套类型，`get` 对 `ContentJSON`（ref 2，旧版 yjs）返回 `None`。

## 3. 头对头性能（Pion vs Node `yjs` vs Rust `yrs --release`）

`scripts/bench_compare.py --warmup 1 --rounds 5`，三个实现**每一轮 stdout 的 SHA-256 都一致**。每次编辑一个事务（`yrs` 每次 `transact_mut()`，yjs 默认隐式事务），基线为 `rust_yrs`：

| 负载 | pion | node_yjs | rust_yrs | Pion vs yrs | 峰值 RSS（pion / yjs / yrs） |
| --- | ---: | ---: | ---: | ---: | --- |
| W1 原包负载 `text 20000×3` | 240.6 ms | 1612.1 ms | 3142.1 ms | **13.06×** | 10.1 / 102.5 / 5.5 MiB |
| 连续输入 `append 50k` | 74.3 ms | 161.7 ms | 30.4 ms | **0.41×** | 18.0 / 70.4 / 2.6 MiB |
| 连续输入 `append 100k` | 416.2 ms | 250.6 ms | 42.1 ms | **0.10×** | 34.0 / 80.5 / 2.6 MiB |
| 连续输入 `append 200k` | 1944.3 ms | 422.1 ms | 75.3 ms | **0.04×** | 66.8 / 102.7 / 2.8 MiB |
| 墓碑 `tombstone 50k`（隔字删除后随机插入 10k） | 1474.9 ms | 2009.1 ms | 2548.0 ms | 1.73× | 37.0 / 124.9 / 13.9 MiB |
| 真实 trace automerge-paper（259,778 次编辑） | 1781.3 ms | 5745.0 ms | 5036.5 ms | 2.83× | 94.3 / 157.9 / 17.3 MiB |
| 远端 apply：官方 yjs update ×20 | 132.7 ms | 363.4 ms | 69.4 ms | **0.52×** | 9.2 / 116.8 / 6.3 MiB |

结论：
- **O(n²) 连续输入**：`try_merge_with_left` 每敲一个键都执行 `Content::Str(ls + rs)`（`src/doc.pion:300`），把整段合并后的字符串复制一遍。n 翻倍，耗时约 ×4.7–5.6；200k 时比 yrs 慢 26 倍、比 yjs 慢 4.6 倍，内存是 yrs 的 24 倍。长文档里“一直往下打字”正是编辑器最常见的负载。
- 远端整合（服务端/同步场景）比 yrs 慢 1.9 倍；体积多 4.4 倍（P1-3）也会直接放大网络和存储成本。
- 内存：所有负载里 Pion 的峰值 RSS 都是 yrs 的 1.4–24 倍。
- 如实记录：W1、墓碑、真实 trace 这三项 Pion 最快。yrs 在这三项上的慢主要来自每次操作一个事务、加上 `OffsetKind::Utf16` 的位置换算；没测 yrs 一个事务批量回放的数字。

## 4. 安全 / 鲁棒性（`node/fuzz_malformed.mjs`，16 个手工构造 + 300 个随机变异）

| 用例 | Pion | yjs | yrs |
| --- | --- | --- | --- |
| `str_len_2p31`（15 B：字符串长度 2^31-1） | **SIGABRT** `pion panic: index -2147483636 out of bounds` | 报错 | 报错 |
| `deep_any_200k`（`[[[…]]]` 20 万层） | **SIGSEGV** | 可捕获的 RangeError | SIGABRT |
| `deep_types_20k_then_delete_root` | ok | 栈溢出（RangeError） | ok |
| `invalid_utf8` | **接受**（P2-3） | 拒绝 | 拒绝 |
| `gc_len_2p53` | 时钟回绕到 2^64-1，`"x"` 丢失（P2-4） | ok | 时钟截断 |
| `client_count_2p62` | 报错 | 报错 | 报错，但 RSS 2 GiB |
| `pending_flood_5000` | 存了 5000 份 pending（P2-2） | 1 份 | — |
| 其余 11 个 + 300 个随机变异 | 无崩溃、无挂起 | — | — |

P0-5 根因：`Decoder::read_bytes`（`src/lib0.pion:701`）里的 `self.pos + len` 在 32 位 `Int` 下溢出成负数，越过了边界检查，随后 `slice` panic。只要服务端对不受信的 update 调 `apply_update`，任何对端都能用 15 个字节让它整个进程退出。`read_any`（`src/lib0.pion:768`）递归没有深度上限。

## 5. 复现命令

```sh
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
pionc test --json -p crdt_redteam_audit packages/crdt/audit      # 13 FAIL = 13 条证据，3 个 control PASS
sh packages/crdt/audit/run_audit.sh                               # 全部：tests fuzz yrs malformed size bench
SECTIONS=fuzz SEEDS=200 sh packages/crdt/audit/run_audit.sh       # 加大 fuzz
node packages/crdt/audit/node/minimize.mjs ~/.cache/pion-crdt-audit/bin/harness <失败脚本>   # 最小化
```

文件：
- `redteam_test.pion`：证据单测（夹具是官方 yjs 原样输出的 hex，生成器是 `node/gen_fixtures.mjs`）。
- `harness/`：Pion 脚本解释器；`node/interp.mjs`（yjs）和 `rust/src/bin/yrs_interp.rs`（yrs）用的是同一门脚本语言、输出同样的 stdout。
- `node/fuzz.mjs`、`node/check.mjs`、`node/minimize.mjs`：多端差分 fuzz、交叉解码校验和最小化工具。
- `node/fuzz_merge.mjs`：`merge_updates` / `diff_update` 差分。
- `node/fuzz_malformed.mjs`：畸形包。
- `bench/pion_bench`、`bench/node_bench.mjs`、`rust/src/bin/yrs_bench.rs`、`bench/make_update.mjs`：三语言基准。
