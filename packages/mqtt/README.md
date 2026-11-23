# `mqtt` (`v0.1.0`)

100% pure Pion, zero-dependency, `World`-free **Sans-IO MQTT 3.1.1 & MQTT 5.0** protocol stack — full wire codec for all 15 control packets and all 27 MQTT 5.0 properties, incremental streaming decoder, `O(depth)` level-indexed `TopicTrie[T]` router, and Sans-IO client session state machine. Compiles and runs identically on Native and `wasm32`.

## Features

- **Dual-Version Wire Codec (`src/wire.pion`, `src/properties.pion`, `src/packet.pion`)**:
  - Full **MQTT 3.1.1 (`V311`)** and **MQTT 5.0 (`V5`)** support across all **15 Control Packets**: `CONNECT`, `CONNACK`, `PUBLISH`, `PUBACK`, `PUBREC`, `PUBREL`, `PUBCOMP`, `SUBSCRIBE`, `SUBACK`, `UNSUBSCRIBE`, `UNSUBACK`, `PINGREQ`, `PINGRESP`, `DISCONNECT`, and `AUTH` (v5.0 only; strictly rejected in v3.1.1).
  - Strict fixed-header reserved flag validation (`PUBREL`/`SUBSCRIBE`/`UNSUBSCRIBE` = `0x02`, `PUBLISH` `QoS=3` rejected, `QoS=0` with `DUP=1` rejected).
  - Strict OASIS §1.5.5 Variable Byte Integer (VBI, 1–4 bytes) validation: rejects >4-byte encodings (`MalformedVbi`) and non-canonical/overlong encodings such as `[0x80, 0x00]` (`NonCanonicalVbi`).
  - Strict RFC 3629 UTF-8 + OASIS MQTT §1.5.4 string validation: rejects UTF-16 surrogates (`U+D800..U+DFFF`), `U+0000`, C0 controls (`U+0001..U+001F`), and DEL/C1 controls (`U+007F..U+009F`), while permitting `U+FEFF` BOM.
  - All **27 MQTT 5.0 Properties** with per-packet context validation, value range checks (rejecting `0` for `Receive Maximum`, `Topic Alias`, `Maximum Packet Size`, `Subscription Identifier`), `Authentication Data` without `Authentication Method` rejection, full `is_valid_reason_code` validation on both encode and decode (no silent `& 0xFF` truncation), multiple `User Property` and `Subscription Identifier` preservation, duplicate single-value property rejection (`DuplicateProperty`), and `MqttLimits` DoS protection (`max_packet_size`, `max_topic_len`, `max_properties = 256` including `User Property` entries, `max_subscriptions`, `max_inflight`).
- **Streaming Incremental Decoder (`src/decoder.pion`)**:
  - `StreamDecoder` handles arbitrary fragmentation (down to 1-byte drip) and sticky multi-packet buffers, always copying incoming chunks into an internal owned buffer (safe against caller read-buffer reuse) with reusable buffer pooling and O(1) amortized compaction.
  - Enforces `max_packet_size` before allocating payload buffers.
- **Topic Validation & `TopicTrie[T]` Router (`src/topic.pion`, `src/trie.pion`)**:
  - Strict OASIS §4.7 `validate_topic_name`, version-aware `validate_topic_filter` / `validate_topic_filter_for_version` (`$share/...` treated as plain filters under v3.1.1 and validated as shared subscriptions under v5.0), zero-allocation `topic_matches`, and MQTT 5.0 §4.8.2 `parse_shared_subscription` (`$share/{ShareName}/{filter}`).
  - Enforces OASIS §4.7.2 `$` isolation: topics starting with `$` (e.g. `$SYS/broker/load`) never match top-level `#` or `+/...` wildcards.
  - Arena-backed iterative `TopicTrie[T]` with generation-stamped `O(1)` key deduplication, isolated `$share/{group}/{filter}` vs plain `{filter}` removal, free-list entry/node slot recycling and bottom-up empty-node pruning (1M insert/remove churn stays at `< 2 MiB` RSS), and `O(depth)` routing immune to backtracking DoS.
- **Sans-IO Client Session State Machine (`src/session.pion`)**:
  - Pure Sans-IO (`connect`, `publish`, `subscribe`, `unsubscribe`, `disconnect`, `feed`, `poll_transmit`, `tick`, `on_transport_disconnected`) — zero socket or clock dependencies.
  - Strict OASIS state-machine & capability enforcement: rejects pre-`CONNACK` packets, duplicate `CONNACK`, `Session Present = 1` with `Clean Start = 1`, server-sent `PINGREQ`, and mismatched/unknown `PUBACK`/`PUBREC`/`PUBCOMP`; enforces CONNACK `Server Keep Alive`, `Maximum QoS`, `Retain Available`, `Maximum Packet Size`, `Topic Alias Maximum`, and bidirectional `Receive Maximum`; atomic batch `feed()` prevents QoS 2 message loss on mid-batch errors; never mutates caller `Properties`.

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

- **Compliance & unit tests**: **22/22 PASS** (`wire_test.pion`, `packets_test.pion`, `decoder_test.pion`, `topic_trie_test.pion`, `session_test.pion`).
- **Red-team adversarial suite**: **37/37 PASS** (`pionc test --json --only-pkg packages/mqtt/audit`: 25/25 defect tests + 12/12 control tests).

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
| `pion` | 334.738 | 329.079 | 346.464 | 1673.69 | **2.09 MiB** | **0.30x** (2.19x faster than Go) |
| `go_paho_v0.23` | 731.590 | 729.070 | 769.549 | 3657.95 | 18.39 MiB | 0.14x |
| `rust_rumqttc_0.25` | 99.373 | 97.410 | 122.183 | 496.86 | 5.67 MiB | 1.00x (baseline) |

### W2: 500,000 Mixed MQTT 3.1.1 + 5.0 Control Packets Stream Decode (137B chunks)

Stdout SHA-256 identical across all implementations and rounds: `43806b6c796e18ecce2235b7d43b0d89d7211f7150a568c3ef9161d83a580d37`.
*(Note: `rumqttc 0.25.1` returns `InvalidPacketType(15)` on MQTT 5.0 `AUTH` packets, so W2 tests the 14 shared packet types across v3.1.1 + v5.0, while W2b tests all 15 MQTT 5.0 packet types including `AUTH` against Go `paho.golang/packets v0.23.0`.)*

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | vs `rust_rumqttc_0.25` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 101.253 | 96.911 | 125.585 | 202.51 | **2.16 MiB** | 0.44x |
| `rust_rumqttc_0.25` | 44.190 | 30.371 | 60.718 | 88.38 | 5.72 MiB | 1.00x (baseline) |

### W2b: 500,000 MQTT 5.0 All 15 Control Packets (incl. `AUTH`) Stream Decode (137B chunks)

Stdout SHA-256 identical across all implementations and rounds: `24dd6070f01db72fafbce1d714493de9663626df44033ca1901a5c441820b6a6`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | vs `go_paho_v0.23` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **140.293** | 133.876 | 150.471 | **280.59** | **2.14 MiB** | **2.87x** |
| `go_paho_v0.23` | 402.232 | 385.956 | 447.819 | 804.46 | 18.28 MiB | 1.00x (baseline) |

### W3: TopicTrie Routing (10,000 Wildcard Subs × 100,000 IoT Publishes — Same-Algorithm Cross-Language Comparison)

*(Note: `go_trie` and `rust_trie_*` implement the same level-indexed Trie algorithm as Pion rather than upstream `paho`/`rumqttc` code — `rumqttc` is a client without a router and `paho`'s `StandardRouter` is a linear scan. Because Pion's runtime `Map` uses a seeded fast string hash (`pion_str_hash`), we report Rust with both standard `SipHash-1-3` and seeded HashDoS-resistant `foldhash`, plus `FNV`.)*

Stdout SHA-256 identical across all implementations and rounds: `b7e0b1e8964642f6c00124bedf6624f8ba43dbe74c6a2a766b032f5fa597298c`.

| Implementation | Hasher | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | vs `rust_trie_siphash` | vs `rust_trie_foldhash` |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | runtime seeded fast hash | 238.851 | 224.283 | 265.019 | 2388.52 | **3.83 MiB** | **1.23x** (1.49x faster than Go) | **0.64x** (1.57x slower) |
| `go_trie` | Go runtime map hash | 355.923 | 344.632 | 436.290 | 3559.23 | 13.12 MiB | 0.83x | 0.43x |
| `rust_trie_siphash` | `std` SipHash-1-3 | 294.326 | 286.106 | 324.732 | 2943.26 | 6.39 MiB | 1.00x (baseline) | 0.52x |
| `rust_trie_foldhash` | `foldhash` (seeded) | **151.683** | 149.105 | 206.588 | **1516.83** | 6.39 MiB | 1.94x | 1.00x (peer baseline) |
| `rust_trie_fnv` | FNV-1a (unseeded) | 169.125 | 161.383 | 231.446 | 1691.25 | 6.39 MiB | 1.74x | 0.90x |

**Honest takeaways**:
- **Codec (W1/W2/W2b)**: Pion beats Go `paho.golang/packets v0.23.0` by **2.19x** on W1 and **2.87x** on W2b while using **~8.5–9x less memory** (`2.1 MiB` vs `18.3–18.4 MiB`). Rust `rumqttc 0.25.1` is **~2.3–3.4x faster** than Pion on raw wire encode/decode (W1/W2) thanks to zero-copy `bytes::Bytes` slicing and fewer per-string validation checks, while Pion enforces full OASIS UTF-8, property, and reason-code compliance with **~2.7x lower RSS** (`2.1 MiB` vs `5.7 MiB`).
- **TopicTrie (W3, same-algorithm comparison)**: Pion beats Go (`1.49x`) and Rust `std` SipHash (`1.23x`) with the lowest RSS (`3.83 MiB` vs `6.39 MiB` / `13.12 MiB`), but **trails Rust `foldhash` by 1.57x** (`238.9 ms` vs `151.7 ms`) when Rust uses a comparable seeded fast hasher.
