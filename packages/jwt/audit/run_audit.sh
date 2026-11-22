#!/bin/sh
# Red-team audit of packages/jwt: one command reproduces every piece of evidence in REPORT.md.
#
#   sh packages/jwt/audit/run_audit.sh [all|build|tests|diff|interop|wasm|probe|bench]
#
# Pion `packages/jwt` vs Rust jsonwebtoken 12.0.0 (+ RustCrypto sha2 0.11.1 / hmac 0.13.0 /
# base64 0.23.1, --release) vs Go golang-jwt/jwt/v5 v5.3.1 (+ Go stdlib crypto, base64).
# Needs: pionc ($HOME/.pion/bin), node (wasm32 runtime), cargo (crates cached or network),
# go, python3. Every build artefact and generated corpus goes to $AUDIT_OUT
# (default: ${TMPDIR:-/tmp}/pion-jwt-audit), never into the git worktree.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT=${AUDIT_OUT:-${TMPDIR:-/tmp}/pion-jwt-audit}
BIN="$OUT/bin"
WHAT=${1:-all}
ROUNDS=${BENCH_ROUNDS:-5}
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
mkdir -p "$BIN"

step() { printf '\n==== %s ====\n' "$*"; }

build() {
  step "build: pion oracle (native --release + wasm32)"
  pionc build --release -o "$BIN/oracle_pion" "$AUDIT_DIR/oracle"
  pionc build --release --target wasm32 -o "$BIN/oracle_pion.wasm" "$AUDIT_DIR/oracle"
  step "build: rust oracle (jsonwebtoken 12.0.0, --release)"
  CARGO_TARGET_DIR="$OUT/rust-target" cargo build --release --quiet \
    --manifest-path "$AUDIT_DIR/diff/rust/Cargo.toml"
  cp "$OUT/rust-target/release/oracle_rust" "$BIN/oracle_rust"
  step "build: go oracle (golang-jwt/jwt/v5 v5.3.1)"
  (cd "$AUDIT_DIR/diff/go" && go build -o "$BIN/oracle_go" .)
}

run_tests() {
  step "pionc test: audit/tests (p1_*/p2_* FAIL = evidence; control_* must PASS)"
  # pionc exits non-zero when a test fails; that is the expected outcome here.
  pionc test --json -p jwt_redteam_audit "$AUDIT_DIR/tests" > "$OUT/tests.json" 2> "$OUT/tests.stderr" || true
  python3 - "$OUT/tests.json" "$OUT/tests.stderr" <<'EOF'
import json, re, sys
t = open(sys.argv[1]).read()
d = json.loads(t[t.find('{"ok"'):])
why = {}
for m in re.finditer(r"_test\.pion:(\d+): (.*)", open(sys.argv[2]).read()):
    why.setdefault(m.group(2), m.group(1))
print(f"total={d['total']} passed={d['passed']} failed={d['failed']}")
bad_controls = 0
for x in d["tests"]:
    print(("PASS " if x["ok"] else "FAIL ") + x["name"])
    if not x["ok"] and x["name"].startswith("control_"):
        bad_controls += 1
print("assertion messages of failing tests:")
for msg, line in sorted(why.items(), key=lambda kv: int(kv[1])):
    print(f"  line {line}: {msg}")
if bad_controls:
    print(f"REGRESSION: {bad_controls} control test(s) failed")
    sys.exit(1)
EOF
}

run_diff() {
  step "crypto + base64url differential (270k vectors; must be byte-identical to RustCrypto)"
  python3 "$AUDIT_DIR/diff/gen_vectors.py" crypto "$OUT/crypto.tsv"
  for o in pion rust go; do "$BIN/oracle_$o" vectors "$OUT/crypto.tsv" > "$OUT/crypto.$o.out"; done
  python3 "$AUDIT_DIR/diff/compare.py" "$OUT/crypto.pion.out" "$OUT/crypto.rust.out" "$OUT/crypto.go.out" \
    --strict-prefix H --strict-prefix M --strict-prefix B64 --md "$OUT/crypto_diff.md"
  step "JWT attack corpus differential (verdicts: pion vs jsonwebtoken vs golang-jwt)"
  python3 "$AUDIT_DIR/diff/gen_vectors.py" jwt "$OUT/jwt.tsv"
  for o in pion rust go; do "$BIN/oracle_$o" vectors "$OUT/jwt.tsv" > "$OUT/jwt.$o.out"; done
  python3 "$AUDIT_DIR/diff/compare.py" "$OUT/jwt.pion.out" "$OUT/jwt.rust.out" "$OUT/jwt.go.out" --md "$OUT/jwt_diff.md"
}

run_interop() {
  step "interop: Pion-signed -> Rust/Go verify, Rust/Go-signed -> Pion verify"
  { "$BIN/oracle_pion" sign; "$BIN/oracle_rust" sign; "$BIN/oracle_go" sign; } > "$OUT/interop.tsv"
  for o in pion rust go; do "$BIN/oracle_$o" vectors "$OUT/interop.tsv" > "$OUT/interop.$o.out"; done
  python3 "$AUDIT_DIR/diff/compare.py" "$OUT/interop.pion.out" "$OUT/interop.rust.out" "$OUT/interop.go.out" --md "$OUT/interop_diff.md"
  echo "payloads Pion's serializer produced for non-finite / signed-zero floats:"
  grep 'pion_sign/float/' "$OUT/interop.tsv" | while IFS="$(printf '\t')" read -r _op label _alg _key thex; do
    python3 -c 'import base64,sys; t=bytes.fromhex(sys.argv[2]).split(b"."); print("  %-28s %s" % (sys.argv[1], base64.urlsafe_b64decode(t[1]+b"="*(-len(t[1])%4)).decode()))' "$label" "$thex"
  done
}

run_wasm() {
  step "wasm32 differential: the same corpora through node + pion_wasm_rt.mjs must match native"
  for f in crypto jwt interop; do
    [ -f "$OUT/$f.tsv" ] || { echo "missing $OUT/$f.tsv (run diff/interop first)"; exit 1; }
    node "$WASM_RT" "$BIN/oracle_pion.wasm" vectors "$OUT/$f.tsv" > "$OUT/$f.wasm.out"
    if cmp -s "$OUT/$f.wasm.out" "$OUT/$f.pion.out"; then
      echo "$f: wasm32 == native ($(wc -l < "$OUT/$f.pion.out" | tr -d ' ') lines)"
    else
      echo "$f: wasm32 DIFFERS from native"; diff "$OUT/$f.pion.out" "$OUT/$f.wasm.out" | head -20; exit 1
    fi
  done
}

probe_one() {
  # $1 = label, rest = command; prints exit status (139 = SIGSEGV, 1 under node = RangeError)
  label=$1; shift
  set +e
  "$@" > "$OUT/probe.out" 2>&1
  rc=$?
  set -e
  printf '  %-44s rc=%-3s %s\n' "$label" "$rc" "$(head -c 90 "$OUT/probe.out" | tr '\n' ' ')"
}

run_probe() {
  step "probe: recursion depth (no hard cap) -> native SIGSEGV / wasm32 RangeError"
  for n in 1000 50000 80000 200000; do
    probe_one "native json_parse nest=$n max_depth=1e9" "$BIN/oracle_pion" deep $n 1000000000
  done
  for n in 1000 100000; do
    probe_one "native decode() nest=$n max_json_depth=1e9" "$BIN/oracle_pion" deepjwt $n 1000000000
  done
  probe_one "native decode() nest=200000 default depth" "$BIN/oracle_pion" deepjwt 200000 32
  for n in 1500 2000 3000; do
    probe_one "wasm32 json_parse nest=$n max_depth=1e9" node "$WASM_RT" "$BIN/oracle_pion.wasm" deep $n 1000000000
  done
  probe_one "wasm32 decode() nest=4000 max_json_depth=1e9" node "$WASM_RT" "$BIN/oracle_pion.wasm" deepjwt 4000 1000000000
  probe_one "wasm32 decode() nest=4000 default depth" node "$WASM_RT" "$BIN/oracle_pion.wasm" deepjwt 4000 32
}

run_bench() {
  step "adversarial-shape benchmarks (bench_compare.py, --warmup 1 --rounds $ROUNDS, stdout SHA-256 checked)"
  python3 "$AUDIT_DIR/diff/gen_adv_bench.py" "$OUT/adv" > /dev/null
  for f in "$OUT"/adv/adv_*.tsv; do
    name=$(basename "$f" .tsv)
    case "$name" in
      *deep_nesting*) iters=100 ;;
      *baseline*) iters=1000 ;;
      *) iters=400 ;;
    esac
    ntok=$(wc -l < "$f" | tr -d ' ')
    for mode in bench parse; do
      python3 "$ROOT_DIR/scripts/bench_compare.py" \
        --title "jwt audit: $mode $name ($ntok tokens x $iters)" \
        --impl "pion=$BIN/oracle_pion $mode $f $iters" \
        --impl "rust_jsonwebtoken=$BIN/oracle_rust $mode $f $iters" \
        --impl "go_golang_jwt=$BIN/oracle_go $mode $f $iters" \
        --baseline rust_jsonwebtoken --warmup 1 --rounds "$ROUNDS" --ops $((ntok * iters)) \
        --md-out "$OUT/bench_${mode}_${name}.md" --json-out "$OUT/bench_${mode}_${name}.json"
    done
  done
}

case "$WHAT" in
  build) build ;;
  tests) run_tests ;;
  diff) run_diff ;;
  interop) run_interop ;;
  wasm) run_wasm ;;
  probe) run_probe ;;
  bench) run_bench ;;
  all)
    build
    run_tests
    run_diff
    run_interop
    run_wasm
    run_probe
    run_bench
    ;;
  *) echo "usage: $0 [all|build|tests|diff|interop|wasm|probe|bench]" >&2; exit 2 ;;
esac
step "done (artefacts in $OUT)"
