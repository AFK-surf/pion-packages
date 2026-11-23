#!/bin/sh
# One-shot red-team audit for packages/mime (Wave 10 RT-mime).
#   sh packages/mime/audit/run_audit.sh [all|build|unit|diff|perf]
# Requires: pionc (AFK-surf/pion c375cee+), go 1.27, cargo (mime 0.3.18 + infer 0.16.0 from the local registry
# cache, --offline), node (wasm32 runner), python3.
# All artifacts go to $AUDIT_OUT (default /private/tmp/rt-mime, the real path of /tmp on macOS because the wasm32
# runner resolves symlinks). Nothing is written inside the repository.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/rt-mime}
BIN="$AUDIT_OUT/bin"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
DIFF_N=${DIFF_N:-5000}
PROBE_MB=${PROBE_MB:-8}
mkdir -p "$BIN"
export AUDIT_OUT PROBE_MB PYTHONDONTWRITEBYTECODE=1

build() {
  echo "==> build: Pion harness (native debug/release, wasm32 debug/release), Go 1.27 stdlib, Rust mime+infer"
  pionc fmt --check "$AUDIT_DIR" || exit 1
  pionc check --json "$AUDIT_DIR" > /dev/null || { pionc check --json "$AUDIT_DIR"; exit 1; }
  pionc build -o "$BIN/pion_dbg" "$AUDIT_DIR" || exit 1
  pionc build --release -o "$BIN/pion_rel" "$AUDIT_DIR" || exit 1
  pionc build --target wasm32 -o "$BIN/pion_dbg.wasm" "$AUDIT_DIR" || exit 1
  pionc build --release --target wasm32 -o "$BIN/pion_rel.wasm" "$AUDIT_DIR" || exit 1
  rm -rf "$AUDIT_OUT/go" && cp -R "$AUDIT_DIR/go" "$AUDIT_OUT/go"
  (cd "$AUDIT_OUT/go" && GOFLAGS=-mod=mod go build -o "$BIN/go_audit" .) || exit 1
  rm -rf "$AUDIT_OUT/rust" && mkdir -p "$AUDIT_OUT/rust"
  cp -R "$AUDIT_DIR/rust/Cargo.toml" "$AUDIT_DIR/rust/Cargo.lock" "$AUDIT_DIR/rust/src" "$AUDIT_OUT/rust/"
  CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --offline \
    --manifest-path "$AUDIT_OUT/rust/Cargo.toml" || exit 1
  cp "$AUDIT_OUT/rust-target/release/mime-audit-rust" "$BIN/rust_audit"
  go version
  pionc --version 2>/dev/null || true
}

unit() {
  echo "==> unit: red-team Pion tests (redteam_* FAIL while a defect exists; control_* must PASS)"
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit.json" 2> "$AUDIT_OUT/unit.stderr"
  python3 - "$AUDIT_OUT/unit.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
bad_controls = 0
for t in d['tests']:
    if t['pkg'] != 'mime_audit':
        continue
    kind = 'RED ' if t['name'].startswith('redteam_') else 'CTRL'
    print(f"  {kind} {'PASS' if t['ok'] else 'FAIL'}  {t['name']}")
    if kind == 'CTRL' and not t['ok']:
        bad_controls += 1
up = [t for t in d['tests'] if t['pkg'] == 'mime']
print(f"  upstream mime tests: {sum(1 for t in up if t['ok'])}/{len(up)} pass")
sys.exit(1 if bad_controls else 0)
PY
  rc_u=$?
  grep "pion panic" "$AUDIT_OUT/unit.stderr" | sed 's/^.*redteam_test.pion:/    line /'
  return $rc_u
}

diff_() {
  echo "==> diff: ${DIFF_N}-case corpora per mode; 4-mode Pion identity + Pion vs Go 1.27 / Rust mime / infer"
  python3 -I "$AUDIT_DIR/diff.py" "$AUDIT_OUT/diff" "$BIN" --n "$DIFF_N"
}

# bench <title> <bytes> <pion-args...> -- prints the pion and go rows and the Pion/Go median ratio.
bench() {
  title=$1; bytes=$2; shift 2
  tag=$(echo "$title" | tr -c 'a-zA-Z0-9\n' '_')
  python3 "$ROOT_DIR/scripts/bench_compare.py" --title "$title" \
    --impl "pion=$BIN/pion_rel $*" --impl "go_stdlib=$BIN/go_audit $*" --baseline go_stdlib \
    --warmup 1 --rounds 5 --bytes "$bytes" \
    --json-out "$AUDIT_OUT/perf/$tag.json" --md-out "$AUDIT_OUT/perf/$tag.md" > "$AUDIT_OUT/perf/$tag.log" 2>&1 \
    || { echo "  $title: bench_compare FAILED (see $AUDIT_OUT/perf/$tag.log)"; return 1; }
  python3 - "$AUDIT_OUT/perf/$tag.json" "$title" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rows = d.get("results") or d.get("impls") or d
def med(name):
    for r in rows:
        if r.get("name") == name:
            return r.get("median_ms") or r.get("median")
p, g = med("pion"), med("go_stdlib")
flag = "  <-- FAIL (>5x Go)" if p and g and p / g > 5 else ""
print(f"  {sys.argv[2]:<58} pion {p:9.1f} ms   go {g:8.1f} ms   pion/go {p / g:6.1f}x{flag}")
PY
}

perf() {
  echo "==> perf: adversarial probes (bench_compare.py, warmup 1, rounds 5, stdout SHA-256 checked)"
  mkdir -p "$AUDIT_OUT/perf"
  python3 -I "$AUDIT_DIR/perf_gen.py" "$AUDIT_OUT/perf" > /dev/null || exit 1
  P="$AUDIT_OUT/perf"
  A70=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  sz() { wc -c < "$1" | tr -d ' '; }
  bench "multipart ${PROBE_MB} MiB random body (typical case)" "$(sz "$P/bmh_random_$PROBE_MB.bin")" \
    mpfile "$A70" "$P/bmh_random_$PROBE_MB.bin"
  bench "multipart ${PROBE_MB} MiB near-miss (package's own red-team case)" "$(sz "$P/bmh_nearmiss_$PROBE_MB.bin")" \
    mpfile boundary1234567890X "$P/bmh_nearmiss_$PROBE_MB.bin"
  bench "multipart ${PROBE_MB} MiB Horspool worst case (boundary a*70)" "$(sz "$P/bmh_worst_$PROBE_MB.bin")" \
    mpfile "$A70" "$P/bmh_worst_$PROBE_MB.bin"
  bench "multipart 1000 tiny parts fan-out" "$(sz "$P/mp_fanout_1k.bin")" mpfile b "$P/mp_fanout_1k.bin"
  bench "multipart 64 parts x 60 KiB plain-param Content-Disposition" "$(sz "$P/mp_param_bomb.bin")" \
    mpfile b "$P/mp_param_bomb.bin"
  bench "multipart 64 parts x 60 KiB RFC 2231-param Content-Disposition" "$(sz "$P/mp_cont_bomb.bin")" \
    mpfile b "$P/mp_cont_bomb.bin"
  echo "  -- single-header scaling (parse only, mtn mode; user CPU seconds)"
  for f in hdr_params_4000 hdr_params_16000 hdr_cont_4000 hdr_cont_16000 hdr_sect_4000 hdr_sect_16000; do
    tp=$( { /usr/bin/time -p "$BIN/pion_rel" mtn "$P/$f.txt" > /dev/null; } 2>&1 | awk '/^user/{print $2}')
    tg=$( { /usr/bin/time -p "$BIN/go_audit" mtn "$P/$f.txt" > /dev/null; } 2>&1 | awk '/^user/{print $2}')
    printf "  %-18s %6s bytes  pion %6ss  go %6ss\n" "$f" "$(($(sz "$P/$f.txt") / 2))" "$tp" "$tg"
  done
  echo "  -- wasm32 (node) on the two worst probes"
  for f in "bmh_worst_$PROBE_MB.bin $A70" "mp_cont_bomb.bin b"; do
    set -- $f
    s0=$(python3 -c 'import time;print(time.time())')
    r=$(node "$WASM_RT" "$BIN/pion_rel.wasm" mpfile "$2" "$P/$1" 2>&1 | head -1)
    s1=$(python3 -c 'import time;print(time.time())')
    printf "  wasm32-release %-22s %-34s %6.2fs\n" "$1" "$r" "$(python3 -c "print($s1-$s0)")"
  done
}

rc=0
case "$SECTION" in
  build) build ;;
  unit) unit || rc=1 ;;
  diff) diff_ || rc=1 ;;
  perf) perf ;;
  all)
    build
    unit || rc=1
    diff_ || rc=1
    perf
    ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
cd "$ROOT_DIR" && git status --porcelain --ignored -- packages/mime | grep -v '^?? packages/mime/audit/$' && { echo "worktree NOT clean"; rc=1; }
exit $rc
