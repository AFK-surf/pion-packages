#!/bin/sh
# One-command red-team audit of packages/cedar against official Rust `cedar-policy =4.15.0`.
#
#   sh packages/cedar/audit/run_audit.sh            # full gate (~2-3 min on an M-series Mac, defective tree)
#   sh packages/cedar/audit/run_audit.sh --quick    # smaller fuzz + DoS subset
#   sh packages/cedar/audit/run_audit.sh --bench    # also re-run the benchmark-fairness tables (not gated)
#
# Exit status: 0 = every gate passes (no known defect left), 1 = at least one defect reproduced,
#              2 = tooling error (missing toolchain, build failure).
# Gates: [2] red-team + control unit tests  [3] test expectations re-derived from cedar-policy
#        [4] differential corpus + seeded fuzz + formatter cross-validity  [5] 4-mode byte identity
#        [6] DoS / complexity / stack probes (4 modes)  [7] the audit left no files in the worktree
# All build products live under $AUDIT_OUT (default /private/tmp/rt-cedar-audit - the real path,
# the wasm32 runner does not follow the /tmp symlink) and its own PION_CACHE_DIR / CARGO_TARGET_DIR.
# Nothing under packages/cedar/audit needs to change for a fixed tree to reach exit 0.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
OUT="${AUDIT_OUT:-/private/tmp/rt-cedar-audit}"
NC="$OUT/pion-cache-native"
WC="$OUT/pion-cache-wasm"
QUICK=0
BENCH=0
for a in "$@"; do
  case "$a" in
    --quick) QUICK=1 ;;
    --bench) BENCH=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
FUZZ_N=5000
SEEDS="1 2 3"
DOSQ=""
if [ "$QUICK" -eq 1 ]; then FUZZ_N=1500; SEEDS="1"; DOSQ="--quick"; fi
mkdir -p "$OUT"
for t in pionc cargo python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }
done
STATUS_BEFORE=$(git -C "$REPO_ROOT" status --porcelain --ignored 2>/dev/null)
FAIL=""
gate() { # name exit-code
  if [ "$2" -ne 0 ]; then FAIL="$FAIL $1"; echo "  => GATE $1: FAIL"; else echo "  => GATE $1: pass"; fi
}

echo "==> [1/7] build: cedar-policy =4.15.0 oracle + DoS twin (cargo --locked), Pion driver/probes (debug + release)"
CARGO_TARGET_DIR="$OUT/cargo" cargo build -q --release --locked --manifest-path "$SCRIPT_DIR/rust/Cargo.toml" \
  --bin oracle --bin dos || exit 2
ORACLE="$OUT/cargo/release/oracle"
RDOS="$OUT/cargo/release/dos"
PION_CACHE_DIR="$NC" pionc build -o "$OUT/driver_dbg" "$SCRIPT_DIR/diff/pion_driver" >/dev/null || exit 2
PION_CACHE_DIR="$NC" pionc build --release -o "$OUT/driver_rel" "$SCRIPT_DIR/diff/pion_driver" >/dev/null || exit 2
PION_CACHE_DIR="$NC" pionc build -o "$OUT/dos_dbg" "$SCRIPT_DIR/dos/pion_dos" >/dev/null || exit 2
PION_CACHE_DIR="$NC" pionc build --release -o "$OUT/dos_rel" "$SCRIPT_DIR/dos/pion_dos" >/dev/null || exit 2

echo "==> [2/7] red-team unit tests (each FAILS while its defect exists) + control tests (must always pass)"
PION_CACHE_DIR="$NC" pionc test --json -p cedar_audit "$SCRIPT_DIR" 2>/dev/null | tail -1 > "$OUT/tests.json"
python3 -I - "$OUT/tests.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("  could not read pionc test output:", e); sys.exit(2)
red = [t for t in d["tests"] if not t["name"].startswith("control")]
ctl = [t for t in d["tests"] if t["name"].startswith("control")]
print("  red-team: %d/%d pass | control: %d/%d pass" % (sum(t["ok"] for t in red), len(red), sum(t["ok"] for t in ctl), len(ctl)))
for t in d["tests"]:
    if not t["ok"]:
        print("    FAIL " + t["name"])
sys.exit(0 if d["tests"] and all(t["ok"] for t in d["tests"]) else 1)
PY
gate unit-tests $?

echo "==> [3/7] self-consistency: every unit-test expectation re-derived from cedar-policy =4.15.0"
python3 -I "$SCRIPT_DIR/diff/test_expect.py" emit > "$OUT/te.cases" && "$ORACLE" "$OUT/te.cases" > "$OUT/te.rust" || exit 2
python3 -I "$SCRIPT_DIR/diff/test_expect.py" check "$OUT/te.cases" "$OUT/te.rust"
gate test-expectations $?

echo "==> [4/7] differential vs cedar-policy =4.15.0 (curated red-team corpus, seeded fuzz, formatter cross-validity)"
python3 -I "$SCRIPT_DIR/diff/gen_cases.py" > "$OUT/curated.cases" || exit 2
CORPORA="curated"
for s in $SEEDS; do
  python3 -I "$SCRIPT_DIR/diff/gen_fuzz.py" "$s" "$FUZZ_N" > "$OUT/fuzz$s.cases" || exit 2
  CORPORA="$CORPORA fuzz$s"
done
DIFF_RC=0
for c in $CORPORA; do
  "$ORACLE" "$OUT/$c.cases" > "$OUT/$c.rust" || exit 2
  "$OUT/driver_dbg" "$OUT/$c.cases" > "$OUT/$c.pion" || exit 2
  python3 -I "$SCRIPT_DIR/diff/compare.py" "$OUT/$c.rust" "$OUT/$c.pion" --label "$c" --details "$OUT/$c.mismatch.txt" || DIFF_RC=1
  "$OUT/driver_dbg" --fmt "$OUT/$c.cases" > "$OUT/$c.fmt" || exit 2
  python3 -I "$SCRIPT_DIR/diff/xfmt.py" "$OUT/$c.cases" "$OUT/$c.fmt" > "$OUT/$c.xfmt.cases" || exit 2
  "$ORACLE" "$OUT/$c.xfmt.cases" > "$OUT/$c.xfmt.rust" || exit 2
  python3 -I "$SCRIPT_DIR/diff/xfmt_compare.py" "$OUT/$c.rust" "$OUT/$c.xfmt.rust" --details "$OUT/$c.xfmt.mismatch.txt" || DIFF_RC=1
done
echo "  (per-case details: $OUT/<corpus>.mismatch.txt, $OUT/<corpus>.xfmt.mismatch.txt)"
gate differential $DIFF_RC

echo "==> [5/7] 4-mode byte identity of the differential transcripts (native dbg/rel, wasm32 dbg/rel)"
MODE_RC=0
for c in $CORPORA; do
  "$OUT/driver_rel" "$OUT/$c.cases" > "$OUT/$c.nr" || MODE_RC=1
  PION_CACHE_DIR="$WC" pionc run --target wasm32 "$SCRIPT_DIR/diff/pion_driver" -- "$OUT/$c.cases" > "$OUT/$c.wd" 2>"$OUT/$c.wd.err" || MODE_RC=1
  PION_CACHE_DIR="$WC" pionc run --release --target wasm32 "$SCRIPT_DIR/diff/pion_driver" -- "$OUT/$c.cases" > "$OUT/$c.wr" 2>"$OUT/$c.wr.err" || MODE_RC=1
  python3 -I - "$OUT" "$c" <<'PY' || MODE_RC=1
import hashlib, sys
out, c = sys.argv[1], sys.argv[2]
h = {m: hashlib.sha256(open("%s/%s.%s" % (out, c, ext), "rb").read()).hexdigest()
     for m, ext in (("native-dbg", "pion"), ("native-rel", "nr"), ("wasm-dbg", "wd"), ("wasm-rel", "wr"))}
same = len(set(h.values())) == 1
print("  %-8s %s  %s" % (c, "identical" if same else "DIFFER", "  ".join("%s=%s" % (m, v[:12]) for m, v in h.items())))
sys.exit(0 if same else 1)
PY
done
gate four-mode $MODE_RC

echo "==> [6/7] DoS / complexity / stack-depth probes (Pion native + wasm32 vs cedar-policy)"
PION_CACHE_DIR="$WC" python3 -I "$SCRIPT_DIR/dos/run_dos.py" "$OUT/dos_rel" "$OUT/dos_dbg" "$RDOS" "$SCRIPT_DIR/dos/pion_dos" $DOSQ
gate dos $?

if [ "$BENCH" -eq 1 ]; then
  echo "==> [bench] benchmark-fairness tables (informational, SHA-256 enforced by bench_compare.py)"
  AUDIT_OUT="$OUT" sh "$SCRIPT_DIR/bench_fair/run_bench_fair.sh" || echo "  bench run failed (not gated)"
fi

echo "==> [7/7] worktree cleanliness (the audit must not create files in the repository)"
STATUS_AFTER=$(git -C "$REPO_ROOT" status --porcelain --ignored 2>/dev/null)
if [ "$STATUS_BEFORE" = "$STATUS_AFTER" ]; then
  [ -z "$STATUS_AFTER" ] && echo "  git status --porcelain --ignored: clean" || echo "  unchanged by the audit (pre-existing local changes kept)"
  gate worktree 0
else
  echo "  the audit run changed the worktree:"; printf '%s\n' "$STATUS_AFTER" | sed 's/^/    /'
  gate worktree 1
fi

if [ -n "$FAIL" ]; then
  echo "RESULT: DEFECTS REPRODUCED - failing gates:$FAIL (see packages/cedar/audit/REPORT.md)"
  exit 1
fi
echo "RESULT: all gates pass"
exit 0
