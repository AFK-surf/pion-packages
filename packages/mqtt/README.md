# `mqtt` (`v0.1.0`)

100% pure Pion, zero-dependency, `World`-free **Sans-IO MQTT 3.1.1 & MQTT 5.0** protocol stack — full wire codec for all 15 control packets and all 27 MQTT 5.0 properties, incremental streaming decoder, `O(depth)` level-indexed `TopicTrie[T]` router, and Sans-IO client session state machine. Compiles and runs identically on Native and `wasm32`.

## Features

- **Dual-Version Wire Codec (`src/wire.pion`, `src/properties.pion`, `src/packet.pion`)**:
  - Full **MQTT 3.1.1 (`V311`)** and **MQTT 5.0 (`V5`)** support across all **15 Control Packets**: `CONNECT`, `CONNACK`, `PUBLISH`, `PUBACK`, `PUBREC`, `PUBREL`, `PUBCOMP`, `SUBSCRIBE`, `SUBACK`, `UNSUBSCRIBE`, `UNSUBACK`, `PINGREQ`, `PINGRESP`, `DISCONNECT`, and `AUTH` (v5.0 only; strictly rejected in v3.1.1).
  - Strict fixed-header reserved flag validation (`PUBREL`/`SUBSCRIBE`/`UNSUBSCRIBE` = `0x02`, `PUBLISH` `QoS=3` rejected, `QoS=0` with `DUP=1` rejected).
  - Strict OASIS §1.5.5 Variable Byte Integer (VBI, 1–4 bytes) validation: rejects >4-byte encodings (`MalformedVbi`) and non-canonical/overlong encodings such as `[0x80, 0x00]` (`NonCanonicalVbi`).
  - Strict RFC 3629 UTF-8 + OASIS MQTT §1.5.4 string validation: rejects UTF-16 surrogates (`U+D800..U+DFFF`), `U+0000`, C0 controls (`U+0001..U+001F`), and DEL/C1 controls (`U+007F..U+009F`), while permitting `U+FEFF` BOM.
  - All **27 MQTT 5.0 Properties** with per-packet context validation, value range checks (rejecting `0` for `Receive Maximum`, `Topic Alias`, `Maximum Packet Size`, `Subscription Identifier`), multiple `User Property` and `Subscription Identifier` preservation, duplicate single-value property rejection (`DuplicateProperty`), and `MqttLimits` DoS protection (`max_packet_size`, `max_topic_len`, `max_properties`, `max_subscriptions`, `max_inflight`).
- **Streaming Incremental Decoder (`src/decoder.pion`)**:
  - `StreamDecoder` handles arbitrary fragmentation (down to 1-byte drip) and sticky multi-packet buffers with a zero-copy single-chunk fast path and O(1) amortized buffer compaction.
  - Enforces `max_packet_size` before allocating payload buffers.
- **Topic Validation & `TopicTrie[T]` Router (`src/topic.pion`, `src/trie.pion`)**:
  - Strict OASIS §4.7 `validate_topic_name`, `validate_topic_filter`, zero-allocation `topic_matches`, and MQTT 5.0 §4.8.2 `parse_shared_subscription` (`$share/{ShareName}/{filter}`).
  - Enforces OASIS §4.7.2 `$` isolation: topics starting with `$` (e.g. `$SYS/broker/load`) never match top-level `#` or `+/...` wildcards.
  - Arena-backed iterative `TopicTrie[T]` with generation-stamped `O(1)` key deduplication, insertion, removal, and `O(depth)` routing immune to backtracking DoS.
- **Sans-IO Client Session State Machine (`src/session.pion`)**:
  - Pure Sans-IO (`connect`, `publish`, `subscribe`, `unsubscribe`, `disconnect`, `feed`, `poll_transmit`, `tick`, `on_transport_disconnected`) — zero socket or clock dependencies.
  - Complete QoS 0 / QoS 1 (`PUBLISH` → `PUBACK`) / QoS 2 (`PUBLISH` → `PUBREC` → `PUBREL` → `PUBCOMP`) bidirectional flows with Packet ID `1..65535` allocation & recycling, inbound QoS 2 deduplication, `Receive Maximum` flow control, reconnect `DUP=1` retransmission, bidirectional Topic Alias mapping (cleared on disconnect), and Keepalive `PINGREQ`/`PINGRESP` driver.

## Public API Summary

```pion
// Wire & limits
pub enum ProtocolVersion { V311, V5 }
pub enum QoS { AtMostOnce, AtLeastOnce, ExactlyOnce }
pub val struct MqttLimits { max_packet_size, max_topic_len, max_properties, max_subscriptions, max_inflight }
pub fn encode_vbi(value : Int) -> Result[Bytes, MqttError]
pub fn decode_vbi(data : Bytes, offset : Int) -> Result[(Int, Int), MqttError]
pub fn validate_mqtt_utf8(s : String) -> Result[Unit, MqttError]
pub fn validate_fixed_header_flags(ptype : Int, flags : Int) -> Result[Unit, MqttError]

// Control packets & properties
pub struct Properties { ... } // all 27 MQTT 5.0 properties
pub fn encode_packet(packet : Packet, version : ProtocolVersion) -> Result[Bytes, MqttError]
pub fn decode_packet(data : Bytes, version : ProtocolVersion) -> Result[(Packet, Int), MqttError]
pub fn decode_packet_with_limits(data : Bytes, version : ProtocolVersion, limits : MqttLimits) -> Result[(Packet, Int), MqttError]

// Streaming decoder
pub fn StreamDecoder::new(version : ProtocolVersion, limits : MqttLimits) -> StreamDecoder
pub fn StreamDecoder::feed(self : StreamDecoder, chunk : Bytes) -> Unit
pub fn StreamDecoder::next_packet(self : StreamDecoder) -> Result[Option[Packet], MqttError]
pub fn StreamDecoder::drain(self : StreamDecoder) -> Result[Array[Packet], MqttError]

// Topic matching & Trie router
pub fn validate_topic_name(topic : String) -> Result[Unit, MqttError]
pub fn validate_topic_filter(filter : String) -> Result[Unit, MqttError]
pub fn parse_shared_subscription(filter : String) -> Result[Option[SharedSubscription], MqttError]
pub fn topic_matches(filter : String, topic : String) -> Bool
pub fn TopicTrie::new[T]() -> TopicTrie[T]
pub fn TopicTrie::insert_with_key[T](self : TopicTrie[T], filter : String, key : Int, value : T) -> Result[Unit, MqttError]
pub fn TopicTrie::remove[T](self : TopicTrie[T], filter : String, key : Int) -> Bool
pub fn TopicTrie::match_topic[T](self : TopicTrie[T], topic : String) -> Array[T]

// Sans-IO Session
pub fn Session::new(config : SessionConfig) -> Session
pub fn Session::connect(self : Session, now_ms : Int64) -> Result[Unit, MqttError]
pub fn Session::publish(self : Session, topic : String, payload : Bytes, qos : QoS, retain : Bool, props : Properties, now_ms : Int64) -> Result[Option[Int], MqttError]
pub fn Session::feed(self : Session, data : Bytes, now_ms : Int64) -> Result[Array[SessionEvent], MqttError]
pub fn Session::poll_transmit(self : Session) -> Bytes
pub fn Session::tick(self : Session, now_ms : Int64) -> Result[Unit, MqttError]
pub fn Session::on_transport_disconnected(self : Session) -> Unit
```

## Verification

```sh
sh scripts/verify.sh packages/mqtt
```

- **Compliance & unit tests**: **19/19 PASS** (`wire_test.pion`, `packets_test.pion`, `decoder_test.pion`, `topic_trie_test.pion`, `session_test.pion`).

### 4-Mode `wasm_smoke` Verification

All four modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) run with an isolated clean `PION_CACHE_DIR`, exit `0`, and emit byte-identical stdout SHA-256 (`171f20e34f0ce46aa0f50856a730786be53d1899d527983a8e1da196c638933e`):

```sh
pionc run packages/mqtt/wasm_smoke
pionc run --release packages/mqtt/wasm_smoke
pionc run --target wasm32 packages/mqtt/wasm_smoke
pionc run --target wasm32 --release packages/mqtt/wasm_smoke
```

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`)

Run via `sh packages/mqtt/bench/run_bench.sh` using `scripts/bench_compare.py` (strictly interleaved rounds, mandatory byte-for-byte stdout SHA-256 verification) against:
- **Go**: `github.com/eclipse/paho.golang/packets v0.23.0` (`go.sum` locked, `-mod=readonly`)
- **Rust**: `rumqttc 0.25.1` (`Cargo.lock` locked, `--release --locked`)

### W1: 200,000 MQTT 5.0 `PUBLISH` (Properties + User Properties + QoS 1) Encode + Stream Decode

Stdout SHA-256 identical across all implementations and rounds: `938ea9a3ff656f3c22a3c5b3cfda9014748951abeb6533227583384a6fd415d1`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | vs `rust_rumqttc_0.25` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 296.346 | 292.141 | 356.731 | 1481.73 | **2.11 MiB** | **0.28x** (2.06x faster than Go) |
| `go_paho_v0.23` | 610.639 | 599.986 | 682.210 | 3053.19 | 19.11 MiB | 0.14x |
| `rust_rumqttc_0.25` | 83.215 | 80.810 | 202.784 | 416.08 | 5.67 MiB | 1.00x (baseline) |

### W2: 500,000 Mixed MQTT 3.1.1 + 5.0 Control Packets Stream Decode (137B chunks)

Stdout SHA-256 identical across all implementations and rounds: `43806b6c796e18ecce2235b7d43b0d89d7211f7150a568c3ef9161d83a580d37`.
*(Note: `rumqttc 0.25.1` returns `InvalidPacketType(15)` on MQTT 5.0 `AUTH` packets, so W2 tests the 14 shared packet types across v3.1.1 + v5.0, while W2b tests all 15 MQTT 5.0 packet types including `AUTH` against Go `paho.golang/packets v0.23.0`.)*

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | vs `rust_rumqttc_0.25` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 98.011 | 95.174 | 143.824 | 76.04 | 196.02 | **2.12 MiB** | 0.30x |
| `rust_rumqttc_0.25` | 29.695 | 27.990 | 32.586 | 250.97 | 59.39 | 5.69 MiB | 1.00x (baseline) |

### W2b: 500,000 MQTT 5.0 All 15 Control Packets (incl. `AUTH`) Stream Decode (137B chunks)

Stdout SHA-256 identical across all implementations and rounds: `24dd6070f01db72fafbce1d714493de9663626df44033ca1901a5c441820b6a6`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | vs `go_paho_v0.23` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **126.439** | 118.782 | 141.451 | **80.94** | **252.88** | **2.12 MiB** | **3.18x** |
| `go_paho_v0.23` | 401.452 | 349.965 | 415.651 | 25.49 | 802.90 | 20.84 MiB | 1.00x (baseline) |

### W3: TopicTrie Routing (10,000 Wildcard Subs × 100,000 IoT Publishes)

Stdout SHA-256 identical across all implementations and rounds: `b7e0b1e8964642f6c00124bedf6624f8ba43dbe74c6a2a766b032f5fa597298c`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | vs `rust_trie` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **189.556** | 188.942 | 202.256 | **1895.56** | **3.64 MiB** | **1.32x** (1.62x faster than Go) |
| `go_trie` | 307.596 | 294.664 | 320.134 | 3075.96 | 12.72 MiB | 0.81x |
| `rust_trie` | 250.624 | 245.389 | 252.126 | 2506.24 | 6.38 MiB | 1.00x (baseline) |

**Honest takeaways**:
- Pion beats Go `paho.golang/packets v0.23.0` by **2.06x** on W1 and **3.18x** on W2b while using **9–10x less memory** (`2.1 MiB` vs `19–21 MiB`), and beats both Rust (`1.32x`) and Go (`1.62x`) on W3 `TopicTrie` routing with the lowest RSS (`3.64 MiB`).
- Rust `rumqttc 0.25.1` is ~`3.3–3.5x` faster on raw wire encode/decode (W1/W2) thanks to zero-copy `bytes::Bytes` slicing and skipping strict OASIS §1.5.4 control-character / duplicate-property checks on every string, while Pion enforces strict OASIS compliance on every packet and keeps RSS ~`2.7x` lower (`2.1 MiB` vs `5.7 MiB`).
