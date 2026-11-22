#!/bin/sh
# Build the three differential drivers into $OUT (default: $TMPDIR/pion-yaml-audit). Nothing is written to the repo.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="${OUT:-${TMPDIR:-/tmp}/pion-yaml-audit}"
export PATH="${HOME}/.pion/bin:${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/go/bin:${PATH}"
mkdir -p "$OUT/go_src" "$OUT/rust_src/src"
pionc build --release -o "$OUT/pion_driver" "$HERE/pion_driver"
cp "$HERE/rust_driver/Cargo.toml" "$OUT/rust_src/Cargo.toml"
cp "$HERE/rust_driver/src/main.rs" "$OUT/rust_src/src/main.rs"
CARGO_TARGET_DIR="$OUT/rust_target" cargo build -q --release --manifest-path "$OUT/rust_src/Cargo.toml"
cp "$OUT/rust_target/release/rust_yaml_audit_driver" "$OUT/rust_driver"
cp "$HERE/go_driver/go.mod" "$HERE/go_driver/main.go" "$OUT/go_src/"
(cd "$OUT/go_src" && go mod tidy >/dev/null 2>&1 && go build -o "$OUT/go_driver" .)
echo "$OUT"
