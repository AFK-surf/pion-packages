#!/bin/sh
# Red-team differential + native-vs-wasm32 run for packages/dns.
# pion (native --release, wasm32 --release on Node) vs Go miekg/dns v1.1.63
# vs Rust hickory-proto =0.24.2. Everything is built/written under
# $RT_DIR (default /private/tmp/rt-dns); the repository tree stays clean.
set -eu
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RT_DIR=${RT_DIR:-/private/tmp/rt-dns}
BIN="$RT_DIR/bin"; CASES="$RT_DIR/cases"; OUT="$RT_DIR/out"
MUTANTS=${MUTANTS:-6000}
mkdir -p "$BIN" "$CASES" "$OUT"

echo "==> cases (mutants=$MUTANTS)"
python3 "$HERE/gen_cases.py" "$CASES" --mutants "$MUTANTS"

echo "==> build pion driver (native + wasm32, --release)"
pionc build --release -o "$BIN/pion_driver" "$HERE/pion_driver"
pionc build --release --target wasm32 -o "$BIN/pion_driver.wasm" "$HERE/pion_driver"

echo "==> build Go miekg/dns driver"
rm -rf "$RT_DIR/go-proj" && mkdir -p "$RT_DIR/go-proj"
cp "$HERE/go/go.mod" "$HERE/go/go.sum" "$HERE/go/main.go" "$RT_DIR/go-proj/"
(cd "$RT_DIR/go-proj" && GOCACHE="$RT_DIR/gocache" GOFLAGS=-mod=mod go build -o "$BIN/go_driver" .)

echo "==> build Rust hickory-proto driver (--release, --locked)"
rm -rf "$RT_DIR/rust-proj" && mkdir -p "$RT_DIR/rust-proj"
cp -R "$HERE/rust/Cargo.toml" "$HERE/rust/Cargo.lock" "$HERE/rust/src" "$RT_DIR/rust-proj/"
CARGO_TARGET_DIR="$RT_DIR/rust-target" cargo build --release --locked --manifest-path "$RT_DIR/rust-proj/Cargo.toml"
cp "$RT_DIR/rust-target/release/dns-audit-diff-rust" "$BIN/rust_driver"

WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
for m in msg name ip6 tcp doh; do
  "$BIN/pion_driver" "$m" "$CASES/$m.tsv" > "$OUT/pion_native_$m.txt"
  node "$WASM_RT" "$BIN/pion_driver.wasm" "$m" "$CASES/$m.tsv" > "$OUT/pion_wasm_$m.txt"
done
for m in msg name ip6; do
  "$BIN/go_driver" "$m" "$CASES/$m.tsv" > "$OUT/go_$m.txt"
  "$BIN/rust_driver" "$m" "$CASES/$m.tsv" > "$OUT/rust_$m.txt"
done

python3 "$HERE/compare.py" "$OUT" "$CASES"
