#!/bin/sh
# One-shot red-team audit for packages/zip (RT-zip).
#   sh packages/zip/audit/run_audit.sh [all|build|unit|vectors|fuzz|paths|writer|modes|dos|prof]
# Artifacts go to $AUDIT_OUT (default /private/tmp/pion-zip-audit: the real path of /tmp on macOS, because the
# wasm32 runner resolves symlinks). Nothing is written inside the repository.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-zip-audit}
BIN="$AUDIT_OUT/bin"
SECTION=${1:-all}
export FUZZ_N=${FUZZ_N:-6000}
export AUDIT_OUT
mkdir -p "$BIN"

build() {
  echo "==> build: Pion native (release) + Go 1.27 archive/zip + Rust zip =2.2.3 (locked) -> $BIN"
  pionc fmt --check "$AUDIT_DIR" || exit 1
  pionc check --json "$AUDIT_DIR" || exit 1
  pionc build --release -o "$BIN/pion_audit" "$AUDIT_DIR" || exit 1
  (cd "$AUDIT_DIR/diff/go" && GOCACHE="$AUDIT_OUT/gocache" go build -o "$BIN/go_audit" .) || exit 1
  rm -rf "$AUDIT_OUT/rust-proj" && mkdir -p "$AUDIT_OUT/rust-proj"
  cp -R "$AUDIT_DIR/diff/rust/Cargo.toml" "$AUDIT_DIR/diff/rust/Cargo.lock" "$AUDIT_DIR/diff/rust/src" "$AUDIT_OUT/rust-proj/"
  CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked \
    --manifest-path "$AUDIT_OUT/rust-proj/Cargo.toml" || exit 1
  cp "$AUDIT_OUT/rust-target/release/zip-audit-rust" "$BIN/rust_audit"
  go version; rustc --version; python3 --version; node --version; pionc --version
}

unit() {
  echo "==> unit: redteam_test.pion (redteam_* FAIL while the defect exists; control_* must PASS)"
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit.json" 2> "$AUDIT_OUT/unit.stderr"
  python3 - "$AUDIT_OUT/unit.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
bad = 0
for t in d['tests']:
    if t['pkg'] != 'zip_audit':
        continue
    kind = 'RED ' if t['name'].startswith('redteam_') else 'CTRL'
    print(f"  {kind} {'PASS' if t['ok'] else 'FAIL'}  {t['name']}")
    bad += kind == 'CTRL' and not t['ok']
up = [t for t in d['tests'] if t['pkg'] != 'zip_audit']
print(f"  upstream zip+flate tests: {sum(t['ok'] for t in up)}/{len(up)} pass")
sys.exit(1 if bad else 0)
PY
  rc=$?
  grep "pion panic" "$AUDIT_OUT/unit.stderr" | sed 's/^/    /'
  return $rc
}

writer() {
  echo "==> writer: Pion ZipWriter archives verified by Go / Rust / Python"
  python3 "$AUDIT_DIR/difftest.py" writer
}

prof() {
  echo "==> prof: W1 (decompress+CRC) / W2 (Deflate L6 write) cost breakdown, Pion vs Go, 5 iterations"
  python3 "$ROOT_DIR/packages/zip/bench/gen_corpus.py" "$AUDIT_OUT/bench" >/dev/null || exit 1
  for k in 1 2 3; do
    echo "  -- round $k: pion"; "$BIN/pion_audit" prof "$AUDIT_OUT/bench/mixed_28mb.zip" "$AUDIT_OUT/bench/mixed_28mb.bundle" 5 | sed 's/^/     /'
    echo "  -- round $k: go";   "$BIN/go_audit" prof "$AUDIT_OUT/bench/mixed_28mb.zip" | sed 's/^/     /'
  done
  python3 - "$AUDIT_OUT/bench/mixed_28mb.bundle" <<'PY'
import struct, sys, zlib
b = open(sys.argv[1], 'rb').read(); n = struct.unpack_from('<I', b)[0]; p = 4; tot = 0
for _ in range(n):
    l = struct.unpack_from('<H', b, p)[0]; p += 2 + l
    d = struct.unpack_from('<I', b, p)[0]; p += 4
    c = zlib.compressobj(6, zlib.DEFLATED, -15); tot += len(c.compress(b[p:p + d]) + c.flush()); p += d
print("  zlib (C) L6 compressed bytes, same 200 payloads: %d" % tot)
PY
  echo "  bench/rust lockfile tracked in git? $(cd "$ROOT_DIR" && git ls-files packages/zip/bench/rust | grep -c Cargo.lock) (0 = transitive deps float)"
}

rc=0
case "$SECTION" in
  build) build ;;
  unit) unit || rc=1 ;;
  vectors|fuzz|paths|dos) python3 "$AUDIT_DIR/difftest.py" "$SECTION" || rc=1 ;;
  modes) python3 "$AUDIT_DIR/difftest.py" modes || rc=1 ;;
  writer) writer ;;
  prof) prof ;;
  all)
    build
    unit || rc=1
    writer
    # vectors/fuzz exit 1 when a Pion crash is observed: that is the expected red-team result here
    python3 "$AUDIT_DIR/difftest.py" vectors || echo "  (vectors: Pion crash reproduced)"
    python3 "$AUDIT_DIR/difftest.py" paths
    python3 "$AUDIT_DIR/difftest.py" fuzz || echo "  (fuzz: Pion crash reproduced)"
    python3 "$AUDIT_DIR/difftest.py" modes || rc=1
    python3 "$AUDIT_DIR/difftest.py" dos
    prof
    ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
cd "$ROOT_DIR" && if [ -n "$(git status --porcelain --ignored)" ]; then
  git status --porcelain --ignored | grep -v '^?? packages/zip/audit/$' | grep . && { echo "worktree NOT clean"; rc=1; }
fi
exit $rc
