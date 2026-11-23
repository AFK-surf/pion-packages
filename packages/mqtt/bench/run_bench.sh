#!/bin/sh
# Head-to-head objective benchmark runner for packages/mqtt:
# Pion Native (--release) vs Go github.com/eclipse/paho.golang/packets v0.23.0 vs Rust rumqttc 0.25.1 (--release --locked).
# All build artifacts and corpora are isolated in /tmp/w12-mqtt-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$BENCH_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
OUT_DIR="/tmp/w12-mqtt-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic MQTT v5 & v3.1.1 corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_corpus.py" "$OUT_DIR"

V5_ALL15="$OUT_DIR/v5_all15.bin"
V5_14="$OUT_DIR/v5_14.bin"
V4_STREAM="$OUT_DIR/v311_all14.bin"
V5_BYTES=$(($(wc -c < "$V5_ALL15" | tr -d ' ') * 1000))
MIXED_BYTES=$(($(wc -c < "$V5_14" | tr -d ' ') * 500 + $(wc -c < "$V4_STREAM" | tr -d ' ') * 500))

echo "==> Building Pion Native benchmark (--release)"
PION_CACHE_DIR="$OUT_DIR/pion-cache" pionc build --release -o "$BIN_DIR/pion_mqtt_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Go github.com/eclipse/paho.golang/packets v0.23.0 benchmark (-mod=readonly)"
rm -rf "$OUT_DIR/go-proj"
mkdir -p "$OUT_DIR/go-proj"
cp "$BENCH_DIR/go/go.mod" "$BENCH_DIR/go/go.sum" "$BENCH_DIR/go/main.go" "$OUT_DIR/go-proj/"
(cd "$OUT_DIR/go-proj" && go build -mod=readonly -o "$BIN_DIR/go_mqtt_bench" .)

echo "==> Building Rust rumqttc 0.25.1 benchmark (--release --locked)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/Cargo.lock" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked --quiet \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/mqtt_bench" "$BIN_DIR/rust_mqtt_bench"

echo ""
echo "=== W1: 200,000 MQTT 5.0 PUBLISH (Properties + User Properties + QoS 1) Encode + Stream Decode ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: 200k MQTT 5.0 PUBLISH (Props + UserProps + QoS 1) Encode+Decode" \
  --impl "pion=$BIN_DIR/pion_mqtt_bench w1" \
  --impl "go_paho_v0.23=$BIN_DIR/go_mqtt_bench w1" \
  --impl "rust_rumqttc_0.25=$BIN_DIR/rust_mqtt_bench w1" \
  --baseline rust_rumqttc_0.25 \
  --warmup 1 --rounds 5 --ops 200000 \
  --md-out "$OUT_DIR/w1.md" --json-out "$OUT_DIR/w1.json"

echo ""
echo "=== W2: 500,000 Mixed MQTT 3.1.1 + 5.0 Control Packets Stream Decode (137B chunks) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: 500k Mixed MQTT 3.1.1 + 5.0 Control Packets Stream Decode (Pion vs Rust rumqttc)" \
  --impl "pion=$BIN_DIR/pion_mqtt_bench w2 $V5_14 $V4_STREAM" \
  --impl "rust_rumqttc_0.25=$BIN_DIR/rust_mqtt_bench w2 $V5_14 $V4_STREAM" \
  --baseline rust_rumqttc_0.25 \
  --warmup 1 --rounds 5 --ops 500000 --bytes "$MIXED_BYTES" \
  --md-out "$OUT_DIR/w2.md" --json-out "$OUT_DIR/w2.json"

echo ""
echo "=== W2b: 500,000 MQTT 5.0 All 15 Control Packets (incl. AUTH) Stream Decode (Pion vs Go paho) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2b: 500k MQTT 5.0 All 15 Control Packets incl. AUTH (Pion vs Go paho)" \
  --impl "pion=$BIN_DIR/pion_mqtt_bench w2_v5 $V5_ALL15" \
  --impl "go_paho_v0.23=$BIN_DIR/go_mqtt_bench w2_v5 $V5_ALL15" \
  --baseline go_paho_v0.23 \
  --warmup 1 --rounds 5 --ops 500000 --bytes "$V5_BYTES" \
  --md-out "$OUT_DIR/w2_v5.md" --json-out "$OUT_DIR/w2_v5.json"

echo ""
echo "=== W3: TopicTrie Routing (10,000 Wildcard Subs x 100,000 IoT Publishes) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: TopicTrie Routing (10k Wildcard Subs x 100k IoT Publishes)" \
  --impl "pion=$BIN_DIR/pion_mqtt_bench w3" \
  --impl "go_trie=$BIN_DIR/go_mqtt_bench w3" \
  --impl "rust_trie=$BIN_DIR/rust_mqtt_bench w3" \
  --baseline rust_trie \
  --warmup 1 --rounds 5 --ops 100000 \
  --md-out "$OUT_DIR/w3.md" --json-out "$OUT_DIR/w3.json"
