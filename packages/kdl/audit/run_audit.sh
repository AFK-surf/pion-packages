#!/bin/sh
# One-shot red-team audit for packages/kdl.
#   sh packages/kdl/audit/run_audit.sh
# Requires: pionc (PATH or $HOME/.pion/bin), node (wasm32 runner), cargo, python3, git.
# Oracles / references are pinned:
#   - Rust `kdl` 6.7.1 (+ kdl 4.7.1 for parse_v1) via oracle/rust/Cargo.lock (--locked)
#   - official KDL 2.0.0 spec test suite, kdl-org/kdl commit 6ceecd8 (tag 2.0.0), fetched into
#     $KDL_SPEC_DIR (CC-BY-SA, not vendored) and verified by the git tree hash of tests/test_cases.
# All artifacts go to $AUDIT_OUT (default: a fresh directory under /private/tmp, the real path of
# /tmp on macOS, because the wasm32 runner resolves symlinks). Nothing is written in the repository.
# Exit status: 0 = every check PASS; 1 = at least one defect (FAIL); 2 = harness/toolchain error.
set -u
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
TMP_BASE=/tmp
[ -d /private/tmp ] && TMP_BASE=/private/tmp
AUDIT_OUT=${AUDIT_OUT:-$(mktemp -d "$TMP_BASE/rt-kdl-audit.XXXXXX")}
mkdir -p "$AUDIT_OUT"
AUDIT_OUT=$(CDPATH= cd -- "$AUDIT_OUT" && pwd -P)
BIN="$AUDIT_OUT/bin"
WASM_RT="${PION_WASM_RT:-$HOME/.pion/share/pion/pion_wasm_rt.mjs}"
KDL_SPEC_DIR=${KDL_SPEC_DIR:-$TMP_BASE/rt-kdl-spec-6ceecd8}
SPEC_COMMIT=6ceecd85d6dd111ae8eb62bfeaca737662d073c8
SPEC_TREE=c24314580e7f05da7c2eacc221adc0a4edcd9f3f
export PION_CACHE_DIR=${PION_CACHE_DIR:-$AUDIT_OUT/pion-cache}
export AUDIT_DIR REPO_ROOT AUDIT_OUT BIN WASM_RT KDL_SPEC_DIR PYTHONDONTWRITEBYTECODE=1
rm -rf "$BIN" "$AUDIT_OUT/modes" "$AUDIT_OUT/corpus" && mkdir -p "$BIN" "$AUDIT_OUT/modes"

die() { echo "HARNESS ERROR: $*" >&2; exit 2; }
for t in pionc node cargo python3 git; do
  command -v "$t" > /dev/null 2>&1 || die "missing tool: $t"
done
[ -f "$WASM_RT" ] || die "missing wasm runtime $WASM_RT"

echo "==> toolchain: $(pionc --version) | node $(node --version) | $(cargo --version)"
echo "==> audit out: $AUDIT_OUT"

echo "==> [1/5] official KDL 2.0.0 test suite (kdl-org/kdl @ $SPEC_COMMIT) -> $KDL_SPEC_DIR"
if [ "$(git -C "$KDL_SPEC_DIR" rev-parse HEAD 2> /dev/null)" != "$SPEC_COMMIT" ]; then
  rm -rf "$KDL_SPEC_DIR"
  git init -q "$KDL_SPEC_DIR" &&
    git -C "$KDL_SPEC_DIR" fetch -q --depth 1 https://github.com/kdl-org/kdl.git "$SPEC_COMMIT" &&
    git -C "$KDL_SPEC_DIR" -c advice.detachedHead=false checkout -q FETCH_HEAD ||
    die "cannot fetch kdl-org/kdl $SPEC_COMMIT"
fi
[ "$(git -C "$KDL_SPEC_DIR" rev-parse HEAD:tests/test_cases)" = "$SPEC_TREE" ] ||
  die "official test suite tree hash mismatch"

echo "==> [2/5] pionc fmt --check / check (audit package)"
pionc fmt --check "$AUDIT_DIR" || die "pionc fmt --check failed"
pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" 2>&1 || { cat "$AUDIT_OUT/check.json"; die "pionc check failed"; }

echo "==> [3/5] build pinned Rust oracle (kdl 6.7.1 + v1, --locked)"
rm -rf "$AUDIT_OUT/rust-proj" && mkdir -p "$AUDIT_OUT/rust-proj"
cp -R "$AUDIT_DIR/oracle/rust/Cargo.toml" "$AUDIT_DIR/oracle/rust/Cargo.lock" "$AUDIT_DIR/oracle/rust/src" "$AUDIT_OUT/rust-proj/"
( CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --offline \
    --manifest-path "$AUDIT_OUT/rust-proj/Cargo.toml" 2> /dev/null ||
  CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked \
    --manifest-path "$AUDIT_OUT/rust-proj/Cargo.toml" ) || die "rust oracle build failed"
cp "$AUDIT_OUT/rust-target/release/kdl-audit-oracle-rust" "$BIN/rust_oracle"

echo "==> [4/5] build probe in 4 modes (serial: native_dbg, native_rel, wasm_dbg, wasm_rel)"
pionc build -o "$BIN/native_dbg" "$AUDIT_DIR" > "$AUDIT_OUT/build_native_dbg.log" 2>&1 || { cat "$AUDIT_OUT/build_native_dbg.log"; die "native debug build"; }
pionc build --release -o "$BIN/native_rel" "$AUDIT_DIR" > "$AUDIT_OUT/build_native_rel.log" 2>&1 || { cat "$AUDIT_OUT/build_native_rel.log"; die "native release build"; }
pionc build --target wasm32 -o "$BIN/wasm_dbg.wasm" "$AUDIT_DIR" > "$AUDIT_OUT/build_wasm_dbg.log" 2>&1 || { cat "$AUDIT_OUT/build_wasm_dbg.log"; die "wasm32 debug build"; }
pionc build --release --target wasm32 -o "$BIN/wasm_rel.wasm" "$AUDIT_DIR" > "$AUDIT_OUT/build_wasm_rel.log" 2>&1 || { cat "$AUDIT_OUT/build_wasm_rel.log"; die "wasm32 release build"; }

echo "==> [5/5] differential suites, query, API, DoS probes, 4-mode identity"
python3 -c 'import ast,sys; [ast.parse(open(f).read()) for f in sys.argv[1:]]' "$AUDIT_DIR/driver.py" "$AUDIT_DIR/cases.py" || die "driver does not parse"
python3 "$AUDIT_DIR/driver.py"
rc=$?
[ "$rc" -le 1 ] || rc=2
echo "==> artifacts kept in $AUDIT_OUT"
exit $rc
