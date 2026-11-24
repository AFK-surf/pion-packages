# RT-mqtt 红队审计报告：`packages/mqtt` @ `c850403`

- 审计对象：`origin/feat/pkg-mqtt` `c850403e0763d72ca904ff82110d8d9256192e26` 的 `packages/mqtt/src/**`（只读，本分支只新增 `packages/mqtt/audit/**`）
- 对照：OASIS MQTT 3.1.1 / 5.0 规范；Go `github.com/eclipse/paho.golang/packets v0.23.0`（只支持 5.0）；Rust `rumqttc 0.25.1`（`mqttbytes::v4` 与 `v5`）
- 工具链：`pionc 0.1.0`（`AFK-surf/pion@79d1fbd`，arm64_apple）、go 1.27.3、cargo 1.100.0；Apple M5 Max (Darwin arm64)
- 复现：`sh packages/mqtt/audit/run_audit.sh`（产物和缓存都放在 `/tmp/rt-mqtt-*`，跑完工作区仍干净）

## 0. 结论

| 级别 | 数量 | 一句话 |
| --- | ---: | --- |
| **P0** | 3 | 客户端 `Session` 不用 CONNACK 下发的 Server Keep Alive（合规 broker 会定时踢掉空闲客户端）；同一批数据里后面的包出错时，QoS 2 消息会永久丢失（exactly-once 被破坏）；服务端对从未用过的 Packet ID 回 PUBREC，就能把客户端的 QoS>0 发送永久堵死 |
| **P1** | 13 | `Session` 状态机几乎不校验收到的包（CONNACK 之前就投递 PUBLISH、重复 CONNACK 会清空 in-flight、ACK 类型和 QoS 对不上也接受、Session Present 与 Clean Start 冲突、Topic Alias 上下限）；CONNACK 下发的能力约束（Maximum QoS / Retain Available / Maximum Packet Size / Topic Alias Maximum）出站都不执行；`StreamDecoder::feed` 直接持有调用方的缓冲区，调用方复用读缓冲时数据会被悄悄改坏；`publish` 会改调用方传入的 `Properties`；`TopicTrie::remove` 从不回收条目，订阅反复增删时内存无界增长（1M 次增删、0 条存活订阅，RSS 301 MiB） |
| **P2** | 10 | v5 各 ACK / CONNACK / AUTH / DISCONNECT 和 v3.1.1 CONNACK 的 Reason Code 不校验（`is_valid_reason_code` 写了但没有任何地方调用）；编码器用 `& 0xFF` 截断 reason code（256 会编成 0x00 Success）；v5 UNSUBACK 编码和解码不对称；Shared Subscription 加 No Local 不拒绝；有 Authentication Data 没有 Authentication Method 不拒绝；v3.1.1 下把 `$share/...` 按 5.0 语义拒绝；Trie 把 `$share/g/a` 和 `a` 当成同一个槽；入站不执行自己声明的 Receive Maximum；服务端发来的 PINGREQ 会被应答 |

**编解码层（wire codec）很扎实**：12,130 条差分向量里，Pion 在 MUST 级标签上符合 **6590/6600**（剩下 10 条见 P2-5/6/7），Go paho 是 1532/4759，Rust rumqttc 是 2995/6600；三方都是 0 panic。4 模式（native/wasm32 × dbg/rel）的判定流逐字节一致，0 trap。DoS 类攻击（1 字节滴入加粘包、声明 256 MiB 长度、属性数量炸弹、3.2 万层 topic）都没有打穿。**问题集中在 `session.pion`（Sans-IO 状态机）和 `trie.pion` 的生命周期管理。**

基准公平性：W1/W2/W2b 能复现，结论可信；**W3「Pion 比 Rust 快 1.32 倍」不成立**：两边对比的都是照着 Pion 算法手写的 trie，不是上游库，而 Rust 基线用的是标准库默认的 SipHash。换成和 Pion 运行时 Map 同类、带种子且抗 HashDoS 的 foldhash 之后，Rust 是 128 ms，Pion 是 188 ms，Rust 快 1.47 倍（见 §5）。

`p0_`/`p1_`/`p2_` 共 25 个测试**当前全部 FAIL**，12 个 `control_` 测试**全部 PASS**（`pionc test --json --only-pkg packages/mqtt/audit`：37 total / 12 passed / 25 failed / 0 unexpected）。原有的 `sh scripts/verify.sh packages/mqtt` 仍是 19/19 PASS。

## 1. P0

### P0-1 不使用 Server Keep Alive（`p0_server_keep_alive_from_connack_ignored`）
- 位置：`src/session.pion:636-640` `Session::tick` 固定用 `self.config.keep_alive_secs`；`Session::feed` 的 ConnAck 分支（`:428`）没有读 `server_keep_alive`。
- 规范：[MQTT-3.2.2-21]：如果服务端在 CONNACK 里带了 Server Keep Alive，客户端 **MUST** 用这个值替换自己的 Keep Alive。
- 复现：客户端配置 60 s，CONNACK 下发 `Server Keep Alive = 10`。到 t = 10.5 s 时 `tick()` 不发 PINGREQ。
- 影响：broker 用 1.5 × 10 s 判定超时，连接空闲时会被周期性断开。对端完全合规就会触发，云 IoT broker 下调 keepalive 很常见。

### P0-2 后面的包出错时 QoS 2 消息丢失（`p0_qos2_message_lost_when_later_packet_in_chunk_errors`）
- 位置：`Session::feed`（`src/session.pion:455-520`）在循环里先产生副作用（`inbound_qos2.set(pid)`、把 PUBREC 放进 tx 队列），再把事件放进局部 `events`。之后同一批数据里任何一个包 `return Err(...)`（例如 `:465` 的 UnknownTopicAlias），整个 `events` 数组都会被丢掉。
- 复现：一个 TCP 段里依次是 `PUBLISH QoS2 pid=1 "M1"` 和一个引用未知 Topic Alias 的 PUBLISH。`feed` 返回 Err，应用收不到 M1。断线重连（Session Present = 1）后，broker 按规范重发 DUP=1 的 PUBLISH，这时 `inbound_qos2` 里已经有 pid 1，消息被当成重复包吞掉。**M1 一次也没有投递，exactly-once 变成 at-most-zero。**
- 前提：对端发出了一个会让会话层报错的包（未知 alias、QoS>0 却没有 pid 等）。只要有一个协议错误，就会让本该 exactly-once 的消息永久丢失。

### P0-3 幽灵 PUBREC 堵死流控（`p0_phantom_pubrec_wedges_flow_control`）
- 位置：`src/session.pion:528-535`。收到 PUBREC 时，无论这个 pid 在不在 in-flight 里都执行 `outbound_inflight.set(r.packet_id, Qos2PubRel(..))`，而且不进入 `outbound_order`，所以永远不会被重传或清理。
- 复现：CONNACK 下发 `Receive Maximum = 10`，服务端随后发 10 个 pid 为 1000..1009 的 PUBREC。此后 `inflight_count() == 10`，`publish(QoS1)` 返回 `FlowControlExceeded`。只有收到 Session Present = 0 的 CONNACK 才会恢复（`run_audit.sh` 的 `phantom` 探针同样复现）。
- 影响：恶意或有 bug 的服务端、或者中间代理，只用十几个字节就能让客户端在整个会话期间无法发送 QoS>0 消息。每个 PUBREC 还会触发一个 PUBREL 回包，可以被用来放大流量。

## 2. P1

| ID | 测试 | 根因 / 位置 | 规范 |
| --- | --- | --- | --- |
| P1-1 | `p1_publish_before_connack_is_delivered` | `feed` 不检查 `self.st`，`Connecting` 状态下照样投递 PUBLISH | [MQTT-3.2.0-1]：服务端发其他包之前 MUST 先发 CONNACK |
| P1-2 | `p1_duplicate_connack_wipes_inflight_messages` | 已经 `Connected` 时再收到 CONNACK（Session Present = 0），`:439` 的 else 分支会清空 in-flight / used_pids，不产生任何事件 | [MQTT-3.2.0-2]：服务端 MUST NOT 发第二个 CONNACK；这里 in-flight 消息被悄悄丢掉 |
| P1-3 | `p1_puback_completes_qos2_publish` | `:523` PubAck 分支不看 in-flight 条目的类型，QoS 2 发布收到 PUBACK 也算完成 | §4.3.3 QoS 2 必须走 PUBREC/PUBREL/PUBCOMP |
| P1-4 | `p1_pubrec_for_qos1_publish_emits_pubrel` | `:528` 对 QoS 1 的条目收到 PUBREC 也改成 QoS2PubRel 状态并发出 PUBREL | 同上（协议错误） |
| P1-5 | `p1_session_present_with_clean_start_accepted` | ConnAck 分支没有和 `clean_start` 对比 | [MQTT-3.2.2-4]：客户端没有会话状态却收到 Session Present = 1，MUST 断开连接 |
| P1-6 | `p1_inbound_topic_alias_above_client_maximum_accepted` | `:461` 收到 alias 直接存，没有和 `config.topic_alias_maximum`（默认 0）比较 | §3.3.2.3.4 / [MQTT-3.3.2-11] |
| P1-7 | `p1_outbound_topic_alias_without_server_permission` | `:206` 只在 `peer_topic_alias_maximum > 0` 时才检查上限，等于 0 时任何 alias 都放行 | §3.2.2.3.8 不带该属性即为 0 / [MQTT-3.3.2-9] |
| P1-8 | `p1_connack_maximum_qos_not_enforced` | CONNACK 里的 `maximum_qos` 读出来之后没有用 | [MQTT-3.2.2-11] |
| P1-9 | `p1_connack_retain_available_not_enforced` | 同上，`retain_available` | [MQTT-3.2.2-14] |
| P1-10 | `p1_connack_maximum_packet_size_not_enforced` | 同上，`maximum_packet_size`；客户端照样发出 1000 B 的包，而服务端只接受 64 B | [MQTT-3.2.2-15] |
| P1-11 | `p1_stream_decoder_aliases_caller_read_buffer` | `src/decoder.pion:58-59`：缓冲区为空时直接用 `self.buf = chunk` 持有调用方的 `Bytes`。Pion 的 `Bytes` 是可变的，传输层复用读缓冲（常见写法）时，半个包的前缀会在下一次 `feed` 拷贝之前被覆盖。复现结果：线上是 `a/b`，解码出来是 `xyb` | API 契约：没有说明 feed 之后调用方不能再改这块缓冲 |
| P1-12 | `p1_publish_mutates_caller_properties` | `:262` 的 `let stored_props = props` 只是别名（`Properties` 是引用语义的 `pub struct`），随后 `topic_alias = None` 直接改到了调用方的对象 | 调用方复用同一个 Properties 做下一次 alias 发布时会失败 |
| P1-13 | （`run_audit.sh` 的 `churn` 探针；公开 API 观测不到内存，所以没有写成单测） | `src/trie.pion:151-206`：`remove` 只把 id 从节点数组里 pop 掉，`entry_keys`/`entry_values` 只增不减，空节点也从不回收 | 订阅反复增删时内存无界增长：10 万次增删、0 存活订阅占 34 MiB；**100 万次占 301 MiB**，基本是线性增长，broker 场景下是 DoS 面 |

> P1 共 13 项：P1-1..12 各有一个当前 FAIL 的测试，P1-13 由 `churn` 探针给出证据。

## 3. P2

| ID | 测试 | 说明 |
| --- | --- | --- |
| P2-1 | `p2_v5_reason_codes_outside_defined_set_accepted` | `decode_ack_body`（`src/packet.pion:607`）、CONNACK（`:805`）、SUBACK v5（`:1032`）、UNSUBACK（`:1124`）、DISCONNECT、AUTH 都不检查 reason code 是否在允许集合里。`is_valid_reason_code`（`properties.pion:1010`）**写了但从没被调用**。差分结果：2209/2209 个越界码 Pion 和 paho 都接受，rumqttc 全部拒绝。[MQTT-3.4.2-1] 等规定发送方 MUST 使用表内的值 |
| P2-2 | `p2_connack_reserved_return_code_and_session_present_with_error` | v3.1.1 CONNACK 返回码 6..255 是保留值，却被接受；Session Present = 1 搭配失败码也被接受（v5 [MQTT-3.2.2-6]） |
| P2-3 | `p2_encoder_truncates_reason_code_to_byte` | `encode_ack_packet`（`:243`）和 SUBACK（`:483`）都用 `push_u8(v & 0xFF)`。reason code 传 256 会编成 0x00「Success」，0x180 会编成 0x80 |
| P2-4 | `p2_v5_unsuback_without_reason_codes_roundtrip_asymmetry` | 编码器允许 v5 UNSUBACK 不带 reason code，自己的解码器却会拒绝（`:1124` 之后） |
| P2-5 | `p2_shared_subscription_with_no_local_accepted` | [MQTT-3.8.3-4]：Shared Subscription 设置 No Local 是 Protocol Error；解码器接受，编码器也会生成 |
| P2-6 | `p2_connect_authentication_data_without_method_accepted` | §3.1.2.11.10 |
| P2-7 | `p2_v311_share_prefixed_filters_rejected` | `validate_topic_filter` 不区分协议版本，3.1.1 下合法的普通过滤器 `$share/g`、`$share//a`、`$share/+/a` 被拒（差分 8 条 `G.filter` 不一致都是这个原因） |
| P2-8 | `p2_trie_conflates_shared_and_plain_subscriptions` | `normalize_filter_for_trie` 去掉 `$share/{group}/` 前缀以后再索引，`remove("a", k)` 会删掉 `$share/g/a`。Trie 本身也不提供共享订阅「组内只投一个」的语义 |
| P2-9 | `p2_inbound_receive_maximum_not_enforced` | 客户端声明了 Receive Maximum = 2，服务端连发 3 个未确认的 QoS 2，客户端仍接受（应当以 0x93 断开） |
| P2-10 | `p2_server_pingreq_answered` | PINGREQ 只能由客户端发往服务端；`:586` 收到服务端发来的 PINGREQ 会回 PINGRESP，而不是当成协议错误 |

### 代码审查观察项（不判为缺陷，或者只能理论触发）
- **O-1 C0/C1 控制字符严格拒绝**（`wire.pion:325`）：U+0001..U+001F、U+007F..U+009F 在**所有**字符串字段一律拒绝（包括 reason string、user property、client id）。规范只说 SHOULD NOT / MAY 视为畸形包，所以这样做合规，但比 paho 和 rumqttc 都严。差分里有 64 × 5 个字段只有 Pion 拒绝。如果 broker 发来的 reason string 带 `\t` 或 `\n`，整条连接会被断开。建议非 topic 字段放宽，或做成可配置。
- **O-2 `max_properties = 256` 把 User Property 也算进去**：带 257 个 user property 的合法包会被拒绝（Go 和 Rust 都接受）。这是实现限额，合规，但应在 README 里写明。
- **O-3 Trie 去重代次计数器 `gen` 是 `Int`**：实测 Pion 的 `Int` 溢出会静默回绕。2³² 次匹配以后，过期的 `seen_gen[k] == gen` 会误把首次命中当成重复（只影响单次匹配，属于理论问题；按 50k msg/s 算约 1 天回绕一次）。
- **O-4 `StreamDecoder` 内存放大**：调用方 chunk 没消费完时，会按 `buf.length() * 2` 新分配，传 1 MiB chunk、剩 1 字节也会分配约 2 MiB。有上限（drain 完会释放），不算泄漏。

## 4. 差分、DoS 与 4 模式证据

### 4.1 三方差分（`diff/gen_vectors.py` 生成 12,130 条，种子固定）
`vectors.bin` 的 sha256 为 `e5b7a103…`（每次运行都会打印）。标签含义：`accept` / `reject` / `incomplete` 是规范 MUST 级，`strict` 表示超出规范定义的取值集合，`either` 表示 MAY 或实现限额。完整表格见 `corpus/differential_summary.md`，Pion 与规范不符的 10 条见 `corpus/pion_vs_spec.tsv`，Pion 接受的 2461 条 `strict` 向量见 `corpus/pion_strict_accepts.tsv`。

| 覆盖面 | 向量数 | Pion | Go paho | Rust rumqttc |
| --- | ---: | --- | --- | --- |
| 固定头：16 种类型 × 16 种 flags × 2 个版本 | 512 | 508/508 | 39/254 | 131/508 |
| VBI / 剩余长度不匹配 / 截断 | 126 | 114/114 | 35/57 | 74/114 |
| UTF-8（码点扫描、代理项、超长编码、非字符、65535 B）× 5 个字段 | 1590 | 1046/1046 | 513/653 | 1004/1046 |
| 27 种属性 × 14 种上下文的允许性、未知属性、重复、取值域 | 2807 | 2803/2804 | 698/2804 | 713/2804 |
| Reason Code / 返回码 / CONNACK flags / v5 简写形式 | 3356 | 895/895（strict 接受 2461） | 114/373（strict 接受 2210） | 342/895（strict 接受 2） |
| CONNECT 语义（256 种 flags × 2、协议名/级别、Will） | 564 | 560/560 | 59/280 | 425/560 |
| SUBSCRIBE / UNSUBSCRIBE / 过滤器 / 选项 / 空列表 / pid 0 | 656 | 646/655 | 70/328 | 299/655 |
| PUBLISH topic / alias | 19 | 18/18 | 4/10 | 7/18 |
| 随机变异（位翻转、替换、插入删除并修正长度、类型互换） | 2500 | 0 panic | 0 panic | 0 panic |

这组差分也顺带暴露了参照实现的缺陷：rumqttc v5 不能解析 AUTH（`InvalidPacketType(15)`），也不接受 rem_len = 0 的 v5 DISCONNECT（`PayloadRequired`）；paho 基本不做语义校验。

### 4.2 DoS 探针（`run_audit.sh` 第 3 步，native --release，`/usr/bin/time -l`）

| 探针 | 结果 |
| --- | --- |
| 1 字节滴入加粘包，交替进行（1k → 100k 轮，共 327.5 万帧） | RSS 恒定 2160 KiB，`max_buffered` = 55 B（不到一帧），**无泄漏** |
| 5 字节头声明 256 MiB | Pion 立即报 `PacketTooLarge`（1.8 MiB）；**Go paho 预分配 `bytes.Buffer.Grow(268435455)`，RSS 262 MiB**；rumqttc 拒绝（5.5 MiB） |
| 10k / 40k / 160k 个属性（放宽 limits） | 解码耗时 1 / 4 / 16 ms，**线性，无 O(n²)**；默认 limits 在第 257 个属性时拒绝 |
| 5,000 / 32,000 层 topic，`+` 和 `#` 混合，Trie 加 `topic_matches` | 1 / 10 ms，native 和 wasm32 都没有栈溢出（遍历是迭代的） |
| Trie 增删 10 万 / 100 万次 | **34 MiB / 301 MiB，0 存活订阅（P1-13）** |
| 幽灵 PUBREC | `inflight=10`，发布被堵死（P0-3） |

### 4.3 4 模式一致性（`corpus/4mode.txt`）
同一份 12,130 条判定流，加上 2 万次变异自检摘要和 3.2 万层深度探针，在 `native dbg` / `native --release` / `wasm32 dbg` / `wasm32 --release` 下 stdout 完全一致（diff_sha `c3db429a46be581c…`），0 trap，0 差异。

## 5. 基准公平性（`run_audit.sh` 第 5 步，本机复测，warmup 1 / rounds 5，按轮交替）

| 负载 | 复测 | README 声明 | 判定 |
| --- | --- | --- | --- |
| W1 v5 PUBLISH 编码 + 解码 | Pion 291 ms / paho 584 ms / rumqttc 85 ms | 296 / 611 / 83 | 能复现。rumqttc 的 API 要求传入自有 `String`，Rust 驱动每次迭代多做约 5 次 String 分配，这一点对 Pion **有利**，Rust 仍然快 3.4 倍；paho 写进复用的 `bytes.Buffer`，没有问题 |
| W2 混合流解码 | Pion 90 ms / rumqttc 26 ms | 98 / 30 | 能复现，公平（两边都在每个 137 B chunk 上拷贝一次） |
| W2b v5 全部 15 种包 | Pion 111 ms / paho 258 ms（2.31x） | 3.18x | 方向能复现，倍数因机器负载有波动。paho 的 `ReadPacket` 逐字节读固定头、每个包分配一个 `bytes.Buffer`，这就是它在 `paho/client.go` 里直接读 `net.Conn` 的真实用法，**公平** |
| W3 TopicTrie | Pion 188 / go_trie 280 / **rust_trie(SipHash) 245 / rust_trie(foldhash) 128 / rust_trie(FNV) 138** | Pion 比 Rust 快 1.32x | **不成立**。① `go_trie`/`rust_trie` 是照搬 Pion 算法手写的，不是 paho/rumqtt 的上游代码（rumqttc 是客户端，没有路由器；paho 的 `StandardRouter` 是线性扫描），所以 W3 只是同一算法的跨语言对比，不是和上游库的对比；② Rust 基线用的是标准库 SipHash-1-3。Pion 运行时 Map 用的是带种子的快速哈希（`pion_rt.c` 的 `pion_str_hash`），对等的 Rust 选择是 foldhash（同样带种子、抗 HashDoS），这时 Rust 比 Pion 快 **1.47 倍**。README 应改为如实写「W3 Pion 落后 1.47x（同类哈希器）」，或者同时列出两种哈希器的结果 |

SHA-256 输出一致性校验在所有变体上都通过（W3 `b7e0b1e8…`）。

## 6. 交付物

```
packages/mqtt/audit/
  pion.toml, src/main.pion         审计驱动（diff / drip / bigdecl / props / deep / churn / phantom / selftest）
  redteam_test.pion                25 个 p*_ 测试（当前 FAIL）+ 12 个 control_ 测试（PASS）
  run_audit.sh                     一键：构建 → 差分 → 4 模式 → DoS → 测试 → 基准 → verify.sh
  diff/gen_vectors.py              12,130 条带 OASIS 标签的向量生成器（种子固定）
  diff/compare.py                  三方结果与规范标签的汇总
  diff/go/                         paho.golang/packets v0.23.0 差分驱动（go.sum 锁定）
  diff/rust/                       rumqttc 0.25.1 差分驱动（Cargo.lock 锁定，--locked --offline）
  diff/rust_hasher_variant.py      W3 的 Rust 哈希器变体（siphash / foldhash / fnv）
  corpus/                          差分汇总、Pion 违规向量、strict 接受清单、4 模式结果
```

修复建议的优先顺序：P0-1/2/3，然后是 P1-1..5（`Session::feed` 按状态和 in-flight 类型做校验，事件先提交再处理下一个包，或者报错时连同已有事件一起返回），然后是 P1-6..10（把 CONNACK 能力存进 Session，在 `publish` 时检查），最后是 P1-11/12/13（`feed` 拷贝或在文档写明所有权转移、`Properties` 先 clone、Trie 回收条目）。
