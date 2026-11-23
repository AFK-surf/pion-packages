#!/bin/sh
# RT-crypto-v030: red-team audit of packages/crypto v0.3.0 (AES-128/256-GCM, P-256 SEC1 validation /
# decompression, P-256 ECDH). One command reproduces every piece of evidence in REPORT.md.
#
#   sh packages/crypto/audit_v030/run_audit.sh [all|build|tests|diff|ct|mutants|bench]
#
# Gates (exit 1 if any fails; a fix branch reruns this unchanged):
#   tests    control_* red-team unit tests (exact CryptoError kinds, inc_32 wrap KATs, ...) all PASS
#   diff     20k-vector Go 1.27 stdlib differential, byte-identical in native_dbg / native_rel /
#            wasm_dbg / wasm_rel (+ 4-mode stdout SHA-256 equal, 0 traps)
#   ct       release QBE SSA: AES / GHASH / scalar-mult branch-free and table-free
#   mutants  10 re-created bug classes must each be detected by the corpus or the control tests
#   bench    the repository's v0.3.0 benchmark rows must not be dominated by process start-up (P2-1)
#
# Needs: pionc ($HOME/.pion/bin, AFK-surf/pion@66d2b4b), node (wasm32 runtime), go >= 1.24, python3.
# Every artefact goes to /private/tmp/rt-crypto-v030-* (never into the git worktree).
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=${RT_OUT:-/private/tmp/rt-crypto-v030-out}
BIN="$OUT/bin"
WHAT=${1:-all}
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PION_CACHE_DIR=${PION_CACHE_DIR:-/private/tmp/rt-crypto-v030-cas}
export GOFLAGS=${GOFLAGS:--mod=mod}
export RT_ORACLE="$BIN/oracle_native_rel" RT_GO_ORACLE="$BIN/go_oracle"
mkdir -p "$BIN"
FAILED=""

step() { printf '\n==== %s ====\n' "$*"; }
gate() { # name, status
  if [ "$2" -eq 0 ]; then echo "GATE $1: PASS"; else echo "GATE $1: FAIL"; FAILED="$FAILED $1"; fi
}

build() {
  step "build: Go oracle (stdlib crypto/aes, crypto/cipher, crypto/ecdh, crypto/elliptic)"
  (cd "$AUDIT_DIR/go" && go build -o "$BIN/go_oracle" .)
  step "build: Pion oracle in 4 modes"
  pionc build -o "$BIN/oracle_native_dbg" "$AUDIT_DIR/oracle" > /dev/null
  pionc build --release -o "$BIN/oracle_native_rel" "$AUDIT_DIR/oracle" > /dev/null
  pionc build --target wasm32 -o "$BIN/oracle_wasm_dbg.wasm" "$AUDIT_DIR/oracle" > /dev/null
  pionc build --release --target wasm32 -o "$BIN/oracle_wasm_rel.wasm" "$AUDIT_DIR/oracle" > /dev/null
  ls -l "$BIN"
}

run_tests() {
  step "pionc fmt --check / check / test: audit_v030/tests (+ the package's own 76 tests)"
  pionc fmt --check "$AUDIT_DIR/tests/redteam_v030_test.pion" "$AUDIT_DIR/oracle/src/main.pion"
  pionc check --json "$AUDIT_DIR/tests" > "$OUT/check.json"
  set +e
  pionc test --json "$AUDIT_DIR/tests" > "$OUT/tests.json" 2> "$OUT/tests.stderr"
  set -e
  python3 - "$OUT/tests.json" "$OUT/tests.stderr" <<'EOF'
import json, re, sys
t = open(sys.argv[1]).read()
d = json.loads(t[t.find('{"ok"'):])
print(f"total={d['total']} passed={d['passed']} failed={d['failed']}")
bad = 0
for x in d["tests"]:
    if x["pkg"] == "crypto_v030_redteam" or not x["ok"]:
        print(("PASS " if x["ok"] else "FAIL ") + x["pkg"] + "::" + x["name"])
    bad += 0 if x["ok"] else 1
for m in re.finditer(r"_test\.pion:(\d+): (.*)", open(sys.argv[2]).read()):
    print(f"  line {m.group(1)}: {m.group(2)}")
sys.exit(1 if bad or d["failed"] else 0)
EOF
}

run_diff() {
  step "Go oracle corpus (deterministic ChaCha8 seed)"
  "$BIN/go_oracle" gen "$OUT/corpus.tsv" "$OUT/expected.out"
  step "4-mode differential vs Go (native_dbg / native_rel / wasm_dbg / wasm_rel)"
  rc=0
  for m in native_dbg native_rel; do
    "$BIN/oracle_$m" vectors "$OUT/corpus.tsv" > "$OUT/$m.out" || { echo "$m exited $? (trap?)"; rc=1; }
  done
  for m in wasm_dbg wasm_rel; do
    node "$WASM_RT" "$BIN/oracle_$m.wasm" vectors "$OUT/corpus.tsv" > "$OUT/$m.out" || { echo "$m exited $? (trap?)"; rc=1; }
  done
  python3 - "$OUT" <<'EOF' || rc=1
import collections, hashlib, os, sys
out = sys.argv[1]
want = open(os.path.join(out, "expected.out")).read().splitlines()
print(f"expected: {len(want)} lines  sha256={hashlib.sha256(open(os.path.join(out, 'expected.out'), 'rb').read()).hexdigest()}")
cats = collections.Counter(l.split("\t")[0].split("/")[0] + "/" + l.split("\t")[0].split("/")[1] for l in want)
print("corpus families:", ", ".join(f"{k}={v}" for k, v in sorted(cats.items())))
bad = 0
for m in ["native_dbg", "native_rel", "wasm_dbg", "wasm_rel"]:
    data = open(os.path.join(out, m + ".out"), "rb").read()
    got = data.decode(errors="replace").splitlines()
    diffs = [(w, g) for w, g in zip(want, got) if w != g]
    miss = abs(len(want) - len(got))
    print(f"  {m:10s}: {len(got):6d} lines  sha256={hashlib.sha256(data).hexdigest()}  mismatches={len(diffs)} missing={miss}")
    for w, g in diffs[:10]:
        print(f"      want {w[:150]}\n      got  {g[:150]}")
    bad += len(diffs) + miss
sys.exit(1 if bad else 0)
EOF
  return $rc
}

run_ct() {
  step "constant-time SSA gate (release QBE)"
  python3 "$AUDIT_DIR/ct_ssa_check_v030.py"
}

run_mutants() {
  step "mutation sensitivity (copies under /private/tmp/rt-crypto-v030-mut)"
  [ -f "$OUT/corpus.tsv" ] || "$BIN/go_oracle" gen "$OUT/corpus.tsv" "$OUT/expected.out"
  python3 "$AUDIT_DIR/mutants.py" "$OUT/corpus.tsv" "$OUT/expected.out"
}

run_bench() {
  step "benchmark reproduction + workload-sizing gate"
  python3 "$AUDIT_DIR/bench_check.py"
}

run_gate() { # name, function
  set +e
  ( set -e; "$2" )
  st=$?
  set -e
  gate "$1" "$st"
}

case "$WHAT" in
  build) build ;;
  tests) run_gate tests run_tests ;;
  diff) run_gate diff run_diff ;;
  ct) run_gate ct run_ct ;;
  mutants) run_gate mutants run_mutants ;;
  bench) run_gate bench run_bench ;;
  all)
    build
    run_gate tests run_tests
    run_gate diff run_diff
    run_gate ct run_ct
    run_gate mutants run_mutants
    run_gate bench run_bench
    ;;
  *) echo "usage: $0 [all|build|tests|diff|ct|mutants|bench]" >&2; exit 2 ;;
esac

step "summary (artefacts in $OUT)"
if [ -n "$FAILED" ]; then
  echo "FAILED gates:$FAILED  -> see REPORT.md"
  exit 1
fi
echo "all gates PASS"
