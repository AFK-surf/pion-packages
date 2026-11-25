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

- **Compliance & unit tests**: **23/23 PASS** (`wire_test.pion`, `packets_test.pion`, `decoder_test.pion`, `topic_trie_test.pion`, `session_test.pion`).
- **Red-team adversarial suite**: **37/37 PASS** (`pionc test --json --only-pkg packages/mqtt/audit`: 25/25 defect tests + 12/12 control tests).

## Formal Verification (Lean 4)

Production pure kernels in `src/wire.pion` are annotated with `#verify` and extracted directly to Lean 4 via `pionc extract-lean` (**3 types**, **13 functions**, **0 externals**):

- **Annotated types**: `ProtocolVersion`, `QoS`, `PacketType`, `MqttLimits`.
- **Annotated hot-path functions**: `MqttLimits::default`, `qos_to_int`, `qos_from_int_opt`, `packet_type_to_int`, `packet_type_from_int_opt`, `vbi_encoded_len`, `vbi_decode_2`, `vbi_decode_3`, `vbi_decode_4`, `fixed_header_flags_err_code`, `is_mqtt_forbidden_ascii`, `is_utf8_cont_byte`, `is_mqtt_c1_control_2b`.
- **Machine-checked proofs** (`proofs/MqttProofs/VbiAndCodec.lean`, `proofs/MqttProofs/FlagsAndUtf8.lean`): **27 theorems**, **0 `sorry` / `admit` / `axiom` / `bv_decide` / `native_decide`**, verified by `proofs/CheckAxioms.lean` to depend solely on standard Lean axioms (`[propext, Classical.choice, Quot.sound]`):
  - `MqttLimits::default` strict positivity, `QoS` (`0..2`) and `PacketType` (`1..15`) exact roundtrip & domain bijections.
  - OASIS §1.5.5 VBI byte-length exact 4-tier partition (`0`, `[0, 127]`, `[128, 16383]`, `[16384, 2097151]`, `[2097152, 268435455]`), monotonicity, exact bit-assembly formulas for 2/3/4-byte decoders, canonical range preservation, and pairwise disjointness of canonical tiers.
  - OASIS §2.1.3 fixed-header reserved-flag validation across all 15 control packet types (out-of-range rejection, `PUBLISH` `QoS=3` and `QoS=0 ∧ DUP=1` rejection, exact `PUBLISH` validity iff, `0x02` requirement for `PUBREL`/`SUBSCRIBE`/`UNSUBSCRIBE`, `0x00` requirement for the remaining 11 types, total error-code range `[0, 3]`).
  - OASIS §1.5.4 & RFC 3629 UTF-8 byte classifiers: forbidden ASCII C0/DEL exact iff & printable `[32, 126]` safety, continuation byte `[0x80, 0xBF]` exact iff & ASCII disjointness, and 2-byte C1 control (`U+0080..U+009F`) exact iff & continuation soundness.
- **Differential cross-check**: `proofs/EvalDiff.lean` checks **40 cases** against native Pion execution via `diff -u` (0 differences).

```sh
packages/mqtt/proofs/run_proofs.sh
```

### 4-Mode `wasm_smoke` Verification

All four modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) run with an isolated clean `PION_CACHE_DIR`, exit `0`, and emit byte-identical stdout SHA-256 (`171f20e34f0ce46aa0f50856a730786be53d1899d527983a8e1da196c638933e`):

```sh
pionc run packages/mqtt/wasm_smoke
pionc run --release packages/mqtt/wasm_smoke
pionc run --target wasm32 packages/mqtt/wasm_smoke
pionc run --target wasm32 --release packages/mqtt/wasm_smoke
```

## Head-to-Head Benchmarks (`Linux x86_64`, `warmup=1`, `rounds=5`)

Run via `sh packages/mqtt/bench/run_bench.sh` using `scripts/bench_compare.py` (strictly interleaved rounds, mandatory byte-for-byte stdout SHA-256 verification) against:
- **Go**: `github.com/eclipse/paho.golang/packets v0.23.0` (`go.sum` locked, `-mod=readonly`)
- **Rust**: `rumqttc 0.25.1` (`Cargo.lock` locked, `--release --locked`)

### W1: 200,000 MQTT 5.0 `PUBLISH` (Properties + User Properties + QoS 1) Encode + Stream Decode

Stdout SHA-256 identical across all implementations and rounds: `938ea9a3ff656f3c22a3c5b3cfda9014748951abeb6533227583384a6fd415d1`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | vs `rust_rumqttc_0.25` |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion` | 179.052 | 178.472 | 194.274 | 895.26 | **0.43x** (14.39x faster than Go) |
| `go_paho_v0.23` | 2576.999 | 1872.314 | 2910.854 | 12885.00 | 0.03x |
| `rust_rumqttc_0.25` | 76.733 | 73.340 | 104.762 | 383.67 | 1.00x (baseline) |

### W2: 500,000 Mixed MQTT 3.1.1 + 5.0 Control Packets Stream Decode (137B chunks)

Stdout SHA-256 identical across all implementations and rounds: `43806b6c796e18ecce2235b7d43b0d89d7211f7150a568c3ef9161d83a580d37`.
*(Note: `rumqttc 0.25.1` returns `InvalidPacketType(15)` on MQTT 5.0 `AUTH` packets, so W2 tests the 14 shared packet types across v3.1.1 + v5.0, while W2b tests all 15 MQTT 5.0 packet types including `AUTH` against Go `paho.golang/packets v0.23.0`.)*

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | vs `rust_rumqttc_0.25` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 70.746 | 59.985 | 72.303 | 105.34 | 141.49 | **0.50x** |
| `rust_rumqttc_0.25` | 35.374 | 34.831 | 42.326 | 210.68 | 70.75 | 1.00x (baseline) |

### W2b: 500,000 MQTT 5.0 All 15 Control Packets (incl. `AUTH`) Stream Decode (137B chunks)

Stdout SHA-256 identical across all implementations and rounds: `24dd6070f01db72fafbce1d714493de9663626df44033ca1901a5c441820b6a6`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | vs `go_paho_v0.23` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **69.954** | 67.629 | 92.978 | **146.30** | **139.91** | **14.76x** |
| `go_paho_v0.23` | 1032.736 | 914.871 | 1291.234 | 9.91 | 2065.47 | 1.00x (baseline) |

### W3: TopicTrie Routing (10,000 Wildcard Subs × 100,000 IoT Publishes — Same-Algorithm Cross-Language Comparison)

*(Note: `go_trie` and `rust_trie` implement the same level-indexed Trie algorithm as Pion rather than upstream `paho`/`rumqttc` code — `rumqttc` is a client without a router and `paho`'s `StandardRouter` is a linear scan.)*

Stdout SHA-256 identical across all implementations and rounds: `b7e0b1e8964642f6c00124bedf6624f8ba43dbe74c6a2a766b032f5fa597298c`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | vs `rust_trie` |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion` | **129.225** | 126.628 | 135.091 | **1292.25** | **3.58x** (4.90x faster than Go) |
| `go_trie` | 633.218 | 586.341 | 724.875 | 6332.18 | 0.73x |
| `rust_trie` | 462.690 | 460.303 | 514.220 | 4626.89 | 1.00x (baseline) |

**Honest takeaways**:
- **Codec (W1/W2/W2b)**: Single-pass exact-capacity `StringBuilder` encoding, `String`-backed zero-boxing cursor decoding, 64-bit property bitmasks, and 4x-unrolled printable-ASCII MQTT UTF-8 validation deliver **3.66x** speedup on W1 (`655.5 -> 179.1 ms`), **3.06x** on W2 (`216.4 -> 70.7 ms`), and **4.37x** on W2b (`305.6 -> 70.0 ms`). Pion beats Go `paho.golang/packets v0.23.0` by **14.39x** on W1 and **14.76x** on W2b, and reaches **0.43x–0.50x** of Rust `rumqttc 0.25.1` while enforcing full OASIS UTF-8, property, and reason-code compliance.
- **TopicTrie (W3)**: Zero-allocation `/` level scanning, reusable traversal stacks, and dense generation-array deduplication speed up routing by **5.42x** (`700.7 -> 129.2 ms`), beating `rust_trie` by **3.58x** and `go_trie` by **4.90x**.
