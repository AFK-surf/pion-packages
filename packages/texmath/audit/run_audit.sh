#!/bin/sh
# Red-team audit of Pion `texmath` against the real npm `katex`.
#
# One command runs everything:
#   sh packages/texmath/audit/run_audit.sh
#
# Environment:
#   KATEX_PATH      existing node_modules/katex to use (default: npm-install katex@$KATEX_VERSION into a temp dir)
#   KATEX_VERSION   npm version spec when installing (default: latest)
#   AUDIT_OUT       directory to keep raw outputs (default: a temp dir that is removed at exit)
#   SKIP_BENCH=1    skip the benchmarks (sections 6-7)
#   DOS_TIMEOUT     seconds per DoS probe (default 10); DOS_RSS_CAP_MIB (default 4096)
#
# Exit status: 0 when no defect was found, 1 when any evidence of a defect was produced.
# Nothing is written inside the repository.
set -u

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
export PATH="$HOME/.pion/bin:$PATH"
PIONC_BIN="${PIONC:-$(command -v pionc)}"

if [ -n "${AUDIT_OUT:-}" ]; then
  WORK="$AUDIT_OUT"
  mkdir -p "$WORK"
else
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/texmath-audit.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT
fi
FOUND=0

section() { printf '\n==================== %s ====================\n' "$1"; }

section "0. Environment"
if [ -z "${KATEX_PATH:-}" ]; then
  echo "installing katex@${KATEX_VERSION:-latest} into $WORK/katex ..."
  mkdir -p "$WORK/katex"
  (cd "$WORK/katex" && npm init -y >/dev/null 2>&1 && npm install --no-audit --no-fund "katex@${KATEX_VERSION:-latest}" >/dev/null 2>&1) || {
    echo "FAIL: npm install katex failed" >&2
    exit 2
  }
  KATEX_PATH="$WORK/katex/node_modules/katex"
fi
export KATEX_PATH
echo "katex  : $(node -e 'console.log(require(process.env.KATEX_PATH).version)') ($KATEX_PATH)"
echo "node   : $(node --version)"
echo "pionc  : $("$PIONC_BIN" --version)"
echo "host   : $(uname -sm) $(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
echo "texmath: $(git -C "$ROOT_DIR" rev-parse --short HEAD)"

"$PIONC_BIN" build --release "$AUDIT_DIR/diff_driver" -o "$WORK/diffdrv" || exit 2
"$PIONC_BIN" build --release "$PKG_DIR/bench/pion_bench" -o "$WORK/pbench" || exit 2

section "1. Evidence test suite (pionc test packages/texmath/audit)"
"$PIONC_BIN" test --json -p texmath_redteam "$AUDIT_DIR" >"$WORK/tests.json" 2>"$WORK/tests.stderr"
python3 - "$WORK/tests.json" <<'EOF'
import json, sys
from collections import Counter
d = json.load(open(sys.argv[1]))
tests = [t for t in d.get("tests", []) if t["pkg"] == "texmath_redteam"]
fail = [t["name"] for t in tests if not t["ok"]]
by = Counter(n.split(":")[0] for n in fail)
tot = Counter(t["name"].split(":")[0] for t in tests)
print(f"texmath_redteam: {len(tests)} tests, {len(tests) - len(fail)} pass, {len(fail)} FAIL (each failure = KaTeX-vs-Pion defect)")
for k in sorted(tot):
    print(f"  {k:12} {by.get(k, 0):4} / {tot[k]:4} failing")
for n in fail:
    print("  FAIL", n)
sys.exit(1 if fail else 0)
EOF
[ $? -ne 0 ] && FOUND=1
echo "(assertion messages with KaTeX vs Pion output: $WORK/tests.stderr)"

section "2. Differential MathML: targeted attack corpus (audit/cases_targeted.txt)"
"$WORK/diffdrv" "$AUDIT_DIR/cases_targeted.txt" >"$WORK/targeted.pion"
node "$AUDIT_DIR/katex_diff.mjs" "$AUDIT_DIR/cases_targeted.txt" >"$WORK/targeted.katex" 2>/dev/null
python3 "$AUDIT_DIR/diff_compare.py" "$AUDIT_DIR/cases_targeted.txt" "$WORK/targeted.katex" "$WORK/targeted.pion" >"$WORK/targeted.diff"
[ $? -ne 0 ] && FOUND=1
tail -1 "$WORK/targeted.diff"
echo "(per-case diff: $WORK/targeted.diff)"

section "3. Differential MathML: KaTeX's own screenshotter corpus (audit/corpus_katex_screenshotter.txt)"
"$WORK/diffdrv" "$AUDIT_DIR/corpus_katex_screenshotter.txt" >"$WORK/ss.pion"
node "$AUDIT_DIR/katex_diff.mjs" "$AUDIT_DIR/corpus_katex_screenshotter.txt" >"$WORK/ss.katex" 2>/dev/null
python3 "$AUDIT_DIR/diff_compare.py" "$AUDIT_DIR/corpus_katex_screenshotter.txt" "$WORK/ss.katex" "$WORK/ss.pion" >"$WORK/ss.diff"
[ $? -ne 0 ] && FOUND=1
tail -1 "$WORK/ss.diff"
echo "Pion 'Undefined control sequence / No such environment' on KaTeX-valid input, by command:"
grep -A2 'PION_REJECTS_VALID' "$WORK/ss.diff" | grep '  pion' | sed 's/.*: //' | sort | uniq -c | sort -rn | head -40

section "4. Layout height/depth vs KaTeX HTML tree (audit/cases_layout.txt, tolerance 0.005em)"
"$WORK/diffdrv" "$AUDIT_DIR/cases_layout.txt" layout >"$WORK/layout.pion"
node "$AUDIT_DIR/katex_layout.mjs" "$AUDIT_DIR/cases_layout.txt" >"$WORK/layout.katex"
python3 - "$AUDIT_DIR/cases_layout.txt" "$WORK/layout.katex" "$WORK/layout.pion" <<'EOF'
import sys
cases = [l for l in open(sys.argv[1]).read().split("\n") if len(l) >= 2]
k = open(sys.argv[2]).read().split("\n"); p = open(sys.argv[3]).read().split("\n")
bad = 0
print(f"{'formula':48} {'katex h/d':>14} {'pion h/d':>14} {'dh':>7} {'dd':>7}")
for c, a, b in zip(cases, k, p):
    if not (a.startswith("OK") and b.startswith("OK")):
        print(f"{c[:48]:48} {a} | {b}"); bad += 1; continue
    _, kh, kd = a.split(); _, ph, pd = b.split()
    dh, dd = float(ph) - float(kh), float(pd) - float(kd)
    if abs(dh) > 0.005 or abs(dd) > 0.005:
        bad += 1
        print(f"{c[:48]:48} {kh:>6}/{kd:<7} {ph:>6}/{pd:<7} {dh:+7.3f} {dd:+7.3f}")
print(f"SUMMARY layout mismatches: {bad} / {len(cases)}")
sys.exit(1 if bad else 0)
EOF
[ $? -ne 0 ] && FOUND=1

section "5. DoS / crash probes (each input in its own process; killed at timeout or RSS cap)"
python3 "$AUDIT_DIR/dos_probe.py" "$WORK/diffdrv" "$AUDIT_DIR/katex_diff.mjs" "$KATEX_PATH" \
  --timeout "${DOS_TIMEOUT:-10}" --rss-cap-mib "${DOS_RSS_CAP_MIB:-4096}" | tee "$WORK/dos.txt"
if grep -E '\| pion +\| (CRASH|TIMEOUT|RSS>CAP)' "$WORK/dos.txt" >/dev/null; then FOUND=1; fi

if [ "${SKIP_BENCH:-0}" != "1" ]; then
  section "6. Benchmarks (scripts/bench_compare.py, --warmup 1 --rounds 5, SHA-256 checked)"
  BC="python3 $ROOT_DIR/scripts/bench_compare.py --warmup 1 --rounds 5 --baseline node-katex"
  KB="node $PKG_DIR/bench/katex_bench.mjs"

  echo "--- 6a. Upstream corpus, native (reproduces the README claim)"
  $BC --title "bench/corpus.txt x20, native" --ops 10000 \
    --impl "node-katex=$KB $PKG_DIR/bench/corpus.txt 20" \
    --impl "pion-native=$WORK/pbench $PKG_DIR/bench/corpus.txt 20" 2>&1 | grep -E '^\||SHA|FAIL'

  echo "--- 6b. Same corpus, Pion wasm32 (the browser target) vs KaTeX JS on the same Node"
  if "$PIONC_BIN" build --release --target wasm32 "$PKG_DIR/bench/pion_bench" -o "$WORK/pbench.wasm" >/dev/null 2>&1; then
    RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
    # pion_wasm_rt truncates piped stdout at 65536 bytes (see REPORT.md), so go through a file.
    $BC --title "bench/corpus.txt x20, wasm32" --ops 10000 \
      --impl "node-katex=$KB $PKG_DIR/bench/corpus.txt 20" \
      --impl "pion-wasm32=sh -c 'node $RT $WORK/pbench.wasm $PKG_DIR/bench/corpus.txt 20 > $WORK/wasm.out && cat $WORK/wasm.out'" 2>&1 | grep -E '^\||SHA|FAIL'
    echo "piped-stdout truncation check (bytes, native vs wasm32 through a pipe):"
    printf '  native %s / wasm32 %s\n' "$("$WORK/pbench" "$PKG_DIR/bench/corpus.txt" 1 | wc -c | tr -d ' ')" \
      "$(node "$RT" "$WORK/pbench.wasm" "$PKG_DIR/bench/corpus.txt" 1 | wc -c | tr -d ' ')"
  else
    echo "wasm32 build failed"
    FOUND=1
  fi

  echo "--- 6c. KaTeX's own screenshotter corpus: can the Pion bench even run it?"
  "$WORK/pbench" "$AUDIT_DIR/corpus_katex_screenshotter.txt" 1 >/dev/null 2>"$WORK/ss_bench.err"
  echo "pion bench exit=$? : $(head -1 "$WORK/ss_bench.err")"
  node "$PKG_DIR/bench/katex_bench.mjs" "$AUDIT_DIR/corpus_katex_screenshotter.txt" 1 >/dev/null 2>"$WORK/ss_kbench.err"
  echo "katex bench exit=$? : $(grep -m1 'ParseError' "$WORK/ss_kbench.err" | cut -c1-120) (only on the corpus' deliberate error entry, #124)"

  section "7. Stress shapes (identical output required by bench_compare)"
  python3 - "$WORK" <<'EOF'
import sys
w = sys.argv[1]
open(f"{w}/long.txt", "w").write("I " + "x+" * 200000 + "x\n")
open(f"{w}/matrix.txt", "w").write("D \\begin{pmatrix}" + "\\\\".join(["&".join(["a_{ij}"] * 200)] * 200) + "\\end{pmatrix}\n")
open(f"{w}/nest.txt", "w").write("I " + "\\frac{" * 500 + "x" + "}{y}" * 500 + "\n")
EOF
  for shape in long matrix nest; do
    $BC --title "stress: $shape" --ops 1 \
      --impl "node-katex=$KB $WORK/$shape.txt 1" \
      --impl "pion-native=$WORK/pbench $WORK/$shape.txt 1" 2>&1 | grep -E '^\| `|FAIL'
  done
fi

section "SUMMARY"
if [ "$FOUND" -ne 0 ]; then
  echo "DEFECTS FOUND: Pion texmath diverges from / is weaker than real KaTeX (see sections above and audit/REPORT.md)."
  exit 1
fi
echo "no divergence found"
exit 0
