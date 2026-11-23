#!/bin/sh
# Red-team audit of packages/json (feat/pkg-json @ 44160880): one command, Pion vs
# Rust serde_json =1.0.145 (arbitrary_precision + preserve_order, Cargo.lock, --locked),
# Node.js JSON + the RFC 8785 Appendix canonicalizer, nst/JSONTestSuite @ 1ef36fa.
#
#   sh packages/json/audit/run_audit.sh                  # every stage (~3 min on an Apple M-series)
#   sh packages/json/audit/run_audit.sh tests jcs        # selected stages only
#
# Stages: tests    pionc test packages/json/audit (p*_ FAIL = exhibit against the package; ctl_* must pass)
#         syntax   6,228 hand-written + generated + mutated documents: accept/reject and value tree vs serde_json
#         jsonts   all 318 JSONTestSuite test_parsing files (y_/n_/i_) vs serde_json
#         numbers  27,508 number literals (strtod torture, exact midpoints, 400..800 digits, 100k digits,
#                  i64/u64 edges) -> Int / Float bits / BigNum, vs Rust std (0-ULP) via serde_json raw numbers
#         numfmt   30,000 doubles: stringify_canonical vs ECMAScript Number::toString; stringify round trip
#         jcs      RFC 8785 examples + 3,000 random documents: stringify_canonical vs Node reference
#         ptr      RFC 6901 examples + 3,000 random (doc, pointer) pairs vs serde_json Value::pointer
#         rt       stringify / stringify_pretty / stringify_canonical re-parse and json_eq on every accepted doc
#         utf8     stringify_canonical on keys that are not UTF-8 (must not abort the process)
#         deep     20k / 100k / 1M nesting with raised max_depth: parse + 3 serializers + json_eq + drop
#         wasm     every differential output above from native dbg/rel + wasm32 dbg/rel: byte-identical
#         hashdos  40,000 parser-colliding keys vs 40,000 ordinary keys (same size/shape): time ratio
#         bench    head-to-head via scripts/bench_compare.py (SHA-256 gated; informational, never fails)
#
# Exit status: 0 only if every stage finds no defect. Everything is built and written under $OUT
# (default /private/tmp/rt-json-audit); the worktree stays clean.
set -u

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT="${OUT:-/private/tmp/rt-json-audit}"
export PATH="${HOME}/.pion/bin:${HOME}/.cargo/bin:/opt/homebrew/bin:${PATH}"
STAGES="${*:-tests syntax jsonts numbers numfmt jcs ptr rt utf8 deep wasm hashdos bench}"
RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
JTS_REV=1ef36fa01286573e846ac449e8683f8833c5b26a
B="$OUT/bin"
C="$OUT/cases"
R="$OUT/res"
mkdir -p "$B" "$C" "$R"
FAILED=""
fail() { FAILED="$FAILED $1"; }
want() { case " $STAGES " in *" $1 "*) return 0 ;; esac; return 1; }

echo "==> $(pionc --version 2>&1 | head -1); $(cargo --version); node $(node --version)"
echo "==> building drivers into $B"
pionc build --release -o "$B/pion_driver" "$AUDIT_DIR/driver" || exit 2
pionc build -o "$B/pion_driver_dbg" "$AUDIT_DIR/driver" || exit 2
pionc build --release --target wasm32 -o "$B/pion_driver.wasm" "$AUDIT_DIR/driver" || exit 2
pionc build --target wasm32 -o "$B/pion_driver_dbg.wasm" "$AUDIT_DIR/driver" || exit 2
CARGO_TARGET_DIR="$OUT/rust-target" cargo build -q --release --locked \
  --manifest-path "$AUDIT_DIR/oracle/rust/Cargo.toml" || exit 2
cp "$OUT/rust-target/release/json_audit_oracle" "$B/rust_oracle"

JTS="$OUT/JSONTestSuite"
if [ ! -d "$JTS/test_parsing" ]; then
  rm -rf "$JTS"
  if git init -q "$JTS" && git -C "$JTS" fetch -q --depth 1 https://github.com/nst/JSONTestSuite.git "$JTS_REV" &&
    git -C "$JTS" checkout -q FETCH_HEAD; then :; else
    echo "  !! could not fetch JSONTestSuite @ $JTS_REV"
    rm -rf "$JTS"
  fi
fi
if [ -d "$JTS/test_parsing" ]; then
  python3 "$AUDIT_DIR/tools/gen_cases.py" "$C" "$JTS/test_parsing" >/dev/null
else
  python3 "$AUDIT_DIR/tools/gen_cases.py" "$C" >/dev/null
  rm -f "$C/jsonts.hex"
fi
node_oracle() { node "$AUDIT_DIR/oracle/node/oracle.mjs" "$@"; }

if want tests; then
  echo
  echo "==> [tests] pionc test packages/json/audit (p*_ FAIL = exhibit; ctl_* = controls)"
  (cd "$AUDIT_DIR" && pionc test --json . >"$OUT/tests.json" 2>"$OUT/tests.stderr") || true
  python3 - "$OUT/tests.json" <<'PYEOF' || fail tests
import json, sys
d = json.load(open(sys.argv[1]))
mine = [t for t in d["tests"] if t["pkg"] == "json_redteam_audit"]
up = [t for t in d["tests"] if t["pkg"] == "json"]
ex = [t for t in mine if not t["name"].startswith("ctl")]
ctl = [t for t in mine if t["name"].startswith("ctl")]
print(f"  red-team: {sum(not t['ok'] for t in ex)}/{len(ex)} exhibits FAIL, "
      f"{sum(t['ok'] for t in ctl)}/{len(ctl)} controls pass; package's own tests: {sum(t['ok'] for t in up)}/{len(up)} pass")
for t in mine:
    print(("    FAIL " if not t["ok"] else "    pass ") + t["name"])
sys.exit(0 if all(t["ok"] for t in mine + up) and mine else 1)
PYEOF
  echo "  (assertion messages: $OUT/tests.stderr)"
fi

if want syntax; then
  echo
  echo "==> [syntax] RFC 8259 grammar / UTF-8 / surrogates / mutations vs serde_json"
  "$B/pion_driver" parse "$C/syntax.hex" >"$R/syntax_pion.txt"
  "$B/rust_oracle" parse "$C/syntax.hex" >"$R/syntax_rust.txt"
  python3 "$AUDIT_DIR/tools/compare.py" "$C/syntax.hex" pion="$R/syntax_pion.txt" serde="$R/syntax_rust.txt" --name syntax || fail syntax
fi

if want jsonts; then
  echo
  echo "==> [jsonts] nst/JSONTestSuite @ ${JTS_REV%????????????????????????????????} test_parsing (y_/n_/i_) vs serde_json"
  if [ -f "$C/jsonts.hex" ]; then
    "$B/pion_driver" parse "$C/jsonts.hex" >"$R/jsonts_pion.txt"
    "$B/rust_oracle" parse "$C/jsonts.hex" >"$R/jsonts_rust.txt"
    python3 "$AUDIT_DIR/tools/compare.py" "$C/jsonts.hex" pion="$R/jsonts_pion.txt" serde="$R/jsonts_rust.txt" --name jsonts || fail jsonts
    python3 - "$C/jsonts.hex" "$R/jsonts_pion.txt" <<'PYEOF' || fail jsonts
import sys
c = open(sys.argv[1]).read().split("\n"); p = open(sys.argv[2]).read().split("\n")
st = {"y": [0, 0], "n": [0, 0], "i": [0, 0]}
bad = []
for i, l in enumerate(c):
    if not l: continue
    name = l.split("\t")[1]; acc = not p[i].startswith("ERR")
    st[name[0]][0 if acc else 1] += 1
    if (name[0] == "y" and not acc) or (name[0] == "n" and acc): bad.append(name)
print(f"  y_: {st['y'][0]}/{sum(st['y'])} accepted, n_: {st['n'][1]}/{sum(st['n'])} rejected, "
      f"i_: {st['i'][0]} accepted / {st['i'][1]} rejected  {bad[:5]}")
sys.exit(1 if bad else 0)
PYEOF
  else
    echo "  SKIPPED (JSONTestSuite not available)"; fail jsonts-skipped
  fi
fi

if want numbers; then
  echo
  echo "==> [numbers] number model + 0-ULP parse vs Rust std / serde_json raw numbers"
  "$B/pion_driver" parse "$C/numparse.hex" >"$R/num_pion.txt"
  "$B/rust_oracle" parse "$C/numparse.hex" >"$R/num_rust.txt"
  python3 "$AUDIT_DIR/tools/compare.py" "$C/numparse.hex" pion="$R/num_pion.txt" rust="$R/num_rust.txt" --name numbers || fail numbers
fi

if want numfmt; then
  echo
  echo "==> [numfmt] stringify_canonical vs ECMAScript Number::toString; stringify round trip"
  "$B/pion_driver" numfmt "$C/numfmt.txt" >"$R/nf_pion.txt"
  node_oracle numfmt "$C/numfmt.txt" >"$R/nf_node.txt"
  python3 - "$C/numfmt.txt" "$R/nf_pion.txt" "$R/nf_node.txt" <<'PYEOF' || fail numfmt
import sys
c, p, n = (open(f).read().split("\n") for f in sys.argv[1:])
fmt = rt = tot = 0; ex = []
for i, x in enumerate(c):
    if not x: continue
    tot += 1
    cp, pp, pb = p[i].split(" ")
    if cp != n[i]: fmt += 1; ex.append(f"{x}: pion {cp} node {n[i]}")
    if n[i] != "ERR" and pb != x: rt += 1; ex.append(f"{x}: stringify {pp} re-parses to {pb}")
print(f"  {tot - fmt}/{tot} canonical == Number::toString, {tot - rt}/{tot} bit-exact stringify round trips  {ex[:4]}")
sys.exit(1 if fmt or rt else 0)
PYEOF
fi

if want jcs; then
  echo
  echo "==> [jcs] RFC 8785 stringify_canonical vs Node JSON.parse + RFC 8785 Appendix canonicalizer"
  "$B/pion_driver" canon "$C/jcs.hex" >"$R/jcs_pion.txt"
  node_oracle canon "$C/jcs.hex" >"$R/jcs_node.txt"
  python3 "$AUDIT_DIR/tools/jcs_compare.py" "$C/jcs.hex" "$R/jcs_pion.txt" "$R/jcs_node.txt" --show 4 || fail jcs
fi

if want ptr; then
  echo
  echo "==> [ptr] RFC 6901 pointer vs serde_json Value::pointer"
  "$B/pion_driver" ptr "$C/ptr.txt" >"$R/ptr_pion.txt"
  "$B/rust_oracle" ptr "$C/ptr.txt" >"$R/ptr_rust.txt"
  python3 "$AUDIT_DIR/tools/compare.py" "$C/ptr.txt" pion="$R/ptr_pion.txt" serde="$R/ptr_rust.txt" --name ptr || fail ptr
fi

if want rt; then
  echo
  echo "==> [rt] serializer round trips on every accepted document"
  cat "$C/syntax.hex" "$C/jcs.hex" >"$C/rt.hex"
  "$B/pion_driver" rt "$C/rt.hex" >"$R/rt_pion.txt"
  sort "$R/rt_pion.txt" | uniq -c | sed 's/^/  /'
  if grep -q '^BAD' "$R/rt_pion.txt"; then fail rt; fi
fi

if want utf8; then
  echo
  echo "==> [utf8] serializers on object keys that are not UTF-8 (\"é\".slice(0, 1), lone 0xF0)"
  for m in pion_driver pion_driver_dbg; do
    "$B/$m" utf8 >"$R/utf8_$m.txt" 2>"$R/utf8_$m.err"
    rc=$?
    echo "  $m: exit $rc; $(tr '\n' ';' <"$R/utf8_$m.txt") $(head -c 120 "$R/utf8_$m.err")"
    [ $rc = 0 ] || fail "utf8-$m"
  done
fi

if want deep; then
  echo
  echo "==> [deep] deep nesting with raised max_depth in 4 build modes"
  for d in 20000 100000 1000000; do
    for k in a o; do
      for m in nrel ndbg wrel wdbg; do
        case $m in
          nrel) "$B/pion_driver" deep $k $d >"$R/deep.txt" 2>&1 ;;
          ndbg) "$B/pion_driver_dbg" deep $k $d >"$R/deep.txt" 2>&1 ;;
          wrel) node "$RT" "$B/pion_driver.wasm" deep $k $d >"$R/deep.txt" 2>&1 ;;
          wdbg) node "$RT" "$B/pion_driver_dbg.wasm" deep $k $d >"$R/deep.txt" 2>&1 ;;
        esac
        rc=$?
        if [ $rc != 0 ] || ! grep -q 'eq=true' "$R/deep.txt"; then
          echo "  $m $k $d: exit $rc $(head -c 160 "$R/deep.txt")"; fail "deep-$m-$k-$d"
        fi
      done
      echo "  $k $d: $(cat "$R/deep.txt") (4 modes checked)"
    done
  done
fi

if want wasm; then
  echo
  echo "==> [wasm] differential outputs from 4 build modes must be byte-identical"
  run4() {
    tag=$1; shift
    "$B/pion_driver" "$@" >"$R/w_${tag}_nrel.txt" 2>/dev/null || echo "  native-release exit $? on $tag"
    "$B/pion_driver_dbg" "$@" >"$R/w_${tag}_ndbg.txt" 2>/dev/null || echo "  native-debug exit $? on $tag"
    node "$RT" "$B/pion_driver.wasm" "$@" >"$R/w_${tag}_wrel.txt" 2>/dev/null || echo "  wasm32-release exit $? on $tag"
    node "$RT" "$B/pion_driver_dbg.wasm" "$@" >"$R/w_${tag}_wdbg.txt" 2>/dev/null || echo "  wasm32-debug exit $? on $tag"
    n=$(wc -l <"$R/w_${tag}_nrel.txt" | tr -d ' ')
    u=$(shasum -a 256 "$R"/w_${tag}_*.txt | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
    if [ "$u" = 1 ] && [ "$n" -gt 0 ]; then
      echo "  $tag: 4/4 identical ($n lines, sha256 $(shasum -a 256 "$R/w_${tag}_nrel.txt" | cut -c1-16))"
    else
      echo "  $tag: DIFFERENT across modes"; shasum -a 256 "$R"/w_${tag}_*.txt; fail "wasm-$tag"
    fi
  }
  run4 syntax parse "$C/syntax.hex"
  run4 numbers parse "$C/numparse.hex"
  run4 numfmt numfmt "$C/numfmt.txt"
  run4 jcs canon "$C/jcs.hex"
  run4 ptr ptr "$C/ptr.txt"
  run4 rt rt "$C/rt.hex"
  [ -f "$C/jsonts.hex" ] && run4 jsonts parse "$C/jsonts.hex"
  run4 reject parse "$C/syntax.hex" reject
  run4 firstwins parse "$C/syntax.hex" firstwins
fi

if want hashdos || want bench; then
  if [ ! -f "$OUT/hash_evil.json" ]; then
    "$B/rust_oracle" hashgen 40000 "$OUT/hash_evil.json" "$OUT/hash_benign.json" | sed 's/^/  /'
  fi
fi

if want hashdos; then
  echo
  echo "==> [hashdos] parse + 40,000 lookups: parser-colliding keys vs ordinary keys (both $(wc -c <"$OUT/hash_evil.json" | tr -d ' ') B)"
  python3 - "$B/pion_driver" "$B/rust_oracle" "$OUT/hash_evil.json" "$OUT/hash_benign.json" <<'PYEOF' || fail hashdos
import subprocess, sys, time
pion, rust, evil, benign = sys.argv[1:]
def best(cmd):
    t = []
    for _ in range(3):
        s = time.perf_counter(); out = subprocess.run(cmd, capture_output=True, check=True).stdout; t.append(time.perf_counter() - s)
    return min(t), out
r = {}
for name, b in (("pion", pion), ("serde_json", rust)):
    te, oe = best([b, "adv", "wide", evil, "40000"]); tb, ob = best([b, "adv", "wide", benign, "40000"])
    assert oe == ob, (oe, ob)
    r[name] = te / tb
    print(f"  {name:11s} colliding {te*1000:8.1f} ms   ordinary {tb*1000:7.1f} ms   ratio {te/tb:6.1f}x")
sys.exit(1 if r["pion"] > 4 else 0)
PYEOF
fi

if want bench; then
  echo
  echo "==> [bench] head-to-head (informational; SHA-256 gated, warmup 1, 5 interleaved rounds)"
  bc() {
    title=$1; shift
    python3 "$ROOT_DIR/scripts/bench_compare.py" --title "$title" \
      --impl "pion=$B/pion_driver $*" --impl "rust_serde_json=$B/rust_oracle $*" \
      --baseline rust_serde_json --warmup 1 --rounds 5 --md-out "$OUT/bench.md" >/dev/null &&
      grep -E '^\| `|SHA' "$OUT/bench.md" | sed 's/^/  /'
  }
  bc "H1 parse + 40k lookups, 40k parser-colliding keys" adv wide "$OUT/hash_evil.json" 40000
  bc "H2 parse + 40k lookups, 40k ordinary keys" adv wide "$OUT/hash_benign.json" 40000
  bc "H3 without_keys(20k keys) on a 40k-key object" adv without "$OUT/hash_benign.json"
  echo "  W1/W2/W3 reproduction: sh packages/json/bench/run_bench.sh (see REPORT.md)"
fi

echo
if [ -n "$FAILED" ]; then
  echo "==> DEFECTS FOUND in stages:$FAILED"
  exit 1
fi
echo "==> no defect found"
exit 0
