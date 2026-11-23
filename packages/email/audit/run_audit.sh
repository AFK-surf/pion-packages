#!/bin/sh
# One-shot red-team audit for packages/email.
#   sh packages/email/audit/run_audit.sh
# Requires: pionc (PATH or $HOME/.pion/bin), node (wasm32 runner), go >= 1.24, cargo, python3.
# Oracles are pinned: oracle/rust/Cargo.lock (mail-parser 0.9.4), oracle/go/go.sum (go-msgauth v0.7.0).
# All artifacts go to $AUDIT_OUT (default: a fresh directory under /private/tmp, the real path of /tmp
# on macOS, because the wasm32 runner resolves symlinks). Nothing is written inside the repository.
# Exit status: 0 = every check PASS; 1 = at least one defect (FAIL); 2 = harness/toolchain error.
set -u
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
TMP_BASE=/tmp
[ -d /private/tmp ] && TMP_BASE=/private/tmp
AUDIT_OUT=${AUDIT_OUT:-$(mktemp -d "$TMP_BASE/pion-email-audit.XXXXXX")}
mkdir -p "$AUDIT_OUT"
AUDIT_OUT=$(CDPATH= cd -- "$AUDIT_OUT" && pwd -P)
BIN="$AUDIT_OUT/bin"
WASM_RT="${PION_WASM_RT:-$HOME/.pion/share/pion/pion_wasm_rt.mjs}"
export AUDIT_DIR REPO_ROOT AUDIT_OUT BIN WASM_RT PYTHONDONTWRITEBYTECODE=1
rm -rf "$BIN" "$AUDIT_OUT/fx" "$AUDIT_OUT/modes" && mkdir -p "$BIN" "$AUDIT_OUT/fx" "$AUDIT_OUT/modes"

die() { echo "HARNESS ERROR: $*" >&2; exit 2; }
for t in pionc node go cargo python3; do
  command -v "$t" > /dev/null 2>&1 || die "missing tool: $t"
done
[ -f "$WASM_RT" ] || die "missing wasm runtime $WASM_RT"

echo "==> toolchain: $(pionc --version) | node $(node --version) | $(go version | cut -d' ' -f3) | $(cargo --version)"
echo "==> audit out: $AUDIT_OUT"

echo "==> [1/6] pionc fmt --check / check (audit package)"
pionc fmt --check "$AUDIT_DIR" || die "pionc fmt --check failed"
pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" 2>&1 || { cat "$AUDIT_OUT/check.json"; die "pionc check failed"; }

echo "==> [2/6] build pinned oracles (Rust mail-parser 0.9.4 --locked, Go net/mail + go-msgauth v0.7.0 -mod=readonly)"
rm -rf "$AUDIT_OUT/rust-proj" "$AUDIT_OUT/go-proj" && mkdir -p "$AUDIT_OUT/rust-proj" "$AUDIT_OUT/go-proj"
cp -R "$AUDIT_DIR/oracle/rust/Cargo.toml" "$AUDIT_DIR/oracle/rust/Cargo.lock" "$AUDIT_DIR/oracle/rust/src" "$AUDIT_OUT/rust-proj/"
( CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --offline \
    --manifest-path "$AUDIT_OUT/rust-proj/Cargo.toml" 2> /dev/null ||
  CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked \
    --manifest-path "$AUDIT_OUT/rust-proj/Cargo.toml" ) || die "rust oracle build failed"
cp "$AUDIT_OUT/rust-target/release/email-audit-oracle-rust" "$BIN/rust_oracle"
cp "$AUDIT_DIR/oracle/go/go.mod" "$AUDIT_DIR/oracle/go/go.sum" "$AUDIT_DIR/oracle/go/main.go" "$AUDIT_OUT/go-proj/"
( cd "$AUDIT_OUT/go-proj" && go build -mod=readonly -o "$BIN/go_oracle" . ) || die "go oracle build failed"
"$BIN/go_oracle" sign "$AUDIT_OUT/fx" || die "go oracle fixture signing failed"

echo "==> [3/6] build probe in 4 modes (serial: native_dbg, native_rel, wasm_dbg, wasm_rel)"
pionc build -o "$BIN/native_dbg" "$AUDIT_DIR" > "$AUDIT_OUT/build_native_dbg.log" 2>&1 || { cat "$AUDIT_OUT/build_native_dbg.log"; die "native debug build"; }
pionc build --release -o "$BIN/native_rel" "$AUDIT_DIR" > "$AUDIT_OUT/build_native_rel.log" 2>&1 || { cat "$AUDIT_OUT/build_native_rel.log"; die "native release build"; }
pionc build --target wasm32 -o "$BIN/wasm_dbg.wasm" "$AUDIT_DIR" > "$AUDIT_OUT/build_wasm_dbg.log" 2>&1 || { cat "$AUDIT_OUT/build_wasm_dbg.log"; die "wasm32 debug build"; }
pionc build --release --target wasm32 -o "$BIN/wasm_rel.wasm" "$AUDIT_DIR" > "$AUDIT_OUT/build_wasm_rel.log" 2>&1 || { cat "$AUDIT_OUT/build_wasm_rel.log"; die "wasm32 release build"; }

echo "==> [4/6] run red-team suite in 4 modes, go-msgauth cross-verification, oracle tables, DoS probes"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$AUDIT_DIR/driver.py" || die "driver.py does not parse"
python3 "$AUDIT_DIR/driver.py"
rc=$?
[ "$rc" -le 1 ] || rc=2
echo "==> artifacts kept in $AUDIT_OUT"
exit $rc
