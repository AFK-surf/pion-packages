#!/bin/sh
# Red-team audit runner for packages/http_cache (origin/feat/pkg-http-cache @ 124e712).
# Usage: sh packages/http_cache/audit/run_audit.sh [all|unit|compare|fuzz|dos|bench]
# All build products live in $RT_WORK (default /tmp/rt_http_cache_work); the worktree stays clean.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
WORK="${RT_WORK:-/tmp/rt_http_cache_work}"
export PATH="${HOME:-}/.cargo/bin:/opt/homebrew/bin:${PATH:-}"
PIONC="${PIONC:-}"
if [ -z "$PIONC" ]; then
  if command -v pionc >/dev/null 2>&1; then PIONC=$(command -v pionc); else PIONC="${HOME}/.pion/bin/pionc"; fi
fi
mkdir -p "$WORK"
MODE="${1:-all}"
FAIL=0

json_last() { tail -n 1; }

run_unit() {
  echo "=== UNIT: control (must PASS) ==="
  "$PIONC" test --json --only-pkg --filter control "$AUDIT_DIR" 2>/dev/null | json_last > "$WORK/control.json" || true
  python3 - "$WORK/control.json" <<'PY' || FAIL=1
import json, sys
d = json.load(open(sys.argv[1]))
for t in d["tests"]:
    print(("  PASS  " if t["ok"] else "  FAIL  ") + t["name"])
bad = [t for t in d["tests"] if not t["ok"]]
print(f"control: {d['passed']}/{d['total']} pass")
sys.exit(1 if bad or d["total"] == 0 else 0)
PY
  echo "=== UNIT: redteam (each FAIL = finding reproduced; PASS = fixed) ==="
  "$PIONC" test --json --only-pkg --filter redteam "$AUDIT_DIR" 2>"$WORK/redteam.stderr" | json_last > "$WORK/redteam.json" || true
  python3 - "$WORK/redteam.json" "$WORK/redteam.stderr" <<'PY' || FAIL=1
import json, re, sys
d = json.load(open(sys.argv[1]))
msgs = {}
for line in open(sys.argv[2], errors="replace"):
    m = re.search(r"redteam_test\.pion:(\d+): (.*)", line)
    if m:
        tag = m.group(2).split(":")[0]
        msgs.setdefault(tag, m.group(2).strip())
rep = 0
for t in d["tests"]:
    sev = t["name"].split("_")[1].upper()
    if t["ok"]:
        print(f"  FIXED       [{sev}] {t['name']}")
    else:
        rep += 1
        print(f"  REPRODUCED  [{sev}] {t['name']}")
for k in sorted(msgs):
    print("      " + msgs[k][:220])
print(f"redteam: {rep}/{d['total']} findings reproduced")
sys.exit(0)
PY
}

run_compare() {
  echo "=== COMPARE: Pion http_cache vs Rust http-cache-semantics 3.0.0 ==="
  python3 "$AUDIT_DIR/diff/gen_cases.py" "$WORK/diff_corpus.txt"
  rm -rf "$WORK/rust-diff"; mkdir -p "$WORK/rust-diff"
  cp -R "$AUDIT_DIR/diff/rust/Cargo.toml" "$AUDIT_DIR/diff/rust/src" "$WORK/rust-diff/"
  (cd "$WORK/rust-diff" && CARGO_TARGET_DIR="$WORK/rust-target" cargo build --release --offline -q 2>/dev/null \
    || CARGO_TARGET_DIR="$WORK/rust-target" cargo build --release -q)
  "$PIONC" build --release -o "$WORK/pion_diff" "$AUDIT_DIR/diff/pion" >/dev/null
  "$WORK/pion_diff" "$WORK/diff_corpus.txt" > "$WORK/diff_pion.out"
  "$WORK/rust-target/release/rt-http-cache-diff-rust" "$WORK/diff_corpus.txt" > "$WORK/diff_rust.out"
  python3 "$AUDIT_DIR/diff/compare.py" "$WORK/diff_corpus.txt" "$WORK/diff_pion.out" "$WORK/diff_rust.out" || FAIL=1
}

run_fuzz() {
  echo "=== FUZZ: 50,000 deterministic iterations x {native,wasm32} x {debug,release} ==="
  ref=""
  for m in "" "--release" "--target wasm32" "--target wasm32 --release"; do
    set +e
    # shellcheck disable=SC2086
    /usr/bin/time -p "$PIONC" run $m "$AUDIT_DIR/fuzz" > "$WORK/fuzz.out" 2> "$WORK/fuzz.err"
    rc=$?
    set -e
    sha=$(shasum -a 256 "$WORK/fuzz.out" | cut -d' ' -f1)
    t=$(grep '^real' "$WORK/fuzz.err" | awk '{print $2}')
    echo "  [${m:-native debug}] exit=$rc real=${t}s stdout_sha256=$sha"
    sed 's/^/      /' "$WORK/fuzz.out"
    [ "$rc" -eq 0 ] || FAIL=1
    if [ -z "$ref" ]; then ref=$sha; elif [ "$sha" != "$ref" ]; then echo "  DIFF across modes"; FAIL=1; fi
  done
}

run_dos() {
  echo "=== DOS (default CacheLimits, native --release) ==="
  "$PIONC" build --release -o "$WORK/dos" "$AUDIT_DIR/dos" >/dev/null
  for m in vary_ua vary cc mem; do
    /usr/bin/time -l "$WORK/dos" "$m" 2> "$WORK/dos_$m.time"
    grep -E 'real|maximum resident set size' "$WORK/dos_$m.time" | sed 's/^ */      /'
  done
}

run_bench() {
  echo "=== BENCH: package's own run_bench.sh (claim: 1.34x) ==="
  sh "$PKG_DIR/bench/run_bench.sh" 2>&1 | sed -n '/^| Impl/,$p'
  echo "=== BENCH: same corpus, Rust http::Request/Response built once outside the loop ==="
  B=/tmp/pion-http-cache-bench
  rm -rf "$WORK/rust-bench-pre"; mkdir -p "$WORK/rust-bench-pre"
  cp -R "$PKG_DIR/bench/rust/Cargo.toml" "$PKG_DIR/bench/rust/src" "$WORK/rust-bench-pre/"
  python3 "$AUDIT_DIR/bench/make_rust_prebuilt.py" "$WORK/rust-bench-pre"
  (cd "$WORK/rust-bench-pre" && CARGO_TARGET_DIR="$WORK/rust-target-pre" cargo build --release -q)
  python3 "$ROOT_DIR/scripts/bench_compare.py" --title "rt: http_cache vs http-cache-semantics (prebuilt http objects)" \
    --impl "pion=$B/bin/pion_http_cache_bench $B/corpus.txt 5000" \
    --impl "rust_bench_as_shipped=$B/bin/rust_http_cache_bench $B/corpus.txt 5000" \
    --impl "rust_prebuilt_http_objects=$WORK/rust-target-pre/release/http-cache-bench-rust-pre $B/corpus.txt 5000" \
    --baseline rust_prebuilt_http_objects --warmup 1 --rounds 7 --ops 60000 \
    --md-out "$WORK/bench_prebuilt.md" 2>&1 | sed -n '/^| Impl/,$p'
}

case "$MODE" in
  unit) run_unit ;;
  compare) run_compare ;;
  fuzz) run_fuzz ;;
  dos) run_dos ;;
  bench) run_bench ;;
  all) run_unit; run_compare; run_fuzz; run_dos; run_bench ;;
  *) echo "usage: $0 [all|unit|compare|fuzz|dos|bench]" >&2; exit 2 ;;
esac

echo "=== worktree status ==="
git -C "$ROOT_DIR" status --porcelain --ignored | sed 's/^/  /'
exit $FAIL
