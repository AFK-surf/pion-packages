#!/bin/sh
# One-command red-team audit of packages/cel against Go `github.com/google/cel-go v0.24.1`.
#   sh packages/cel/audit/run_audit.sh           # everything (~4-6 min on an M-series Mac)
#   sh packages/cel/audit/run_audit.sh --quick   # smaller fuzz + DoS subset (~1-2 min)
# All artifacts go to $AUDIT_OUT (default /private/tmp/rt-cel-audit: the *real* path, the wasm32
# runner does not follow the /tmp symlink) and to separate PION_CACHE_DIRs. The worktree stays clean.
# Exit code: 0 if the audit ran to completion (findings are in the output), 2 on tooling errors.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="${AUDIT_OUT:-/private/tmp/rt-cel-audit}"
NATIVE_CACHE="${OUT}/pion-cache-native"
WASM_CACHE="${OUT}/pion-cache-wasm"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1
FUZZ_N=5000
[ "$QUICK" -eq 1 ] && FUZZ_N=1000
mkdir -p "$OUT"

echo "==> [1/6] build Pion drivers (debug + --release) and Go cel-go v0.24.1 oracles"
PION_CACHE_DIR="$NATIVE_CACHE" pionc build -o "$OUT/pion_driver_dbg" "$HERE/diff/pion_driver" >/dev/null || exit 2
PION_CACHE_DIR="$NATIVE_CACHE" pionc build --release -o "$OUT/pion_driver_rel" "$HERE/diff/pion_driver" >/dev/null || exit 2
PION_CACHE_DIR="$NATIVE_CACHE" pionc build --release -o "$OUT/pion_dos" "$HERE/dos/pion_dos" >/dev/null || exit 2
(cd "$HERE/diff/go_oracle" && GOFLAGS=-mod=readonly go build -o "$OUT/go_oracle" .) || exit 2
(cd "$HERE/dos/go_dos" && GOFLAGS=-mod=readonly go build -o "$OUT/go_dos" .) || exit 2

echo "==> [2/6] red-team tests (red tests FAIL while the defect exists; control tests must pass)"
PION_CACHE_DIR="$NATIVE_CACHE" pionc test --json -p cel_audit "$HERE" 2>/dev/null | tail -1 | python3 -c '
import json, sys
d = json.load(sys.stdin)
red = [t for t in d["tests"] if not t["name"].startswith("control")]
ctl = [t for t in d["tests"] if t["name"].startswith("control")]
print("red-team: %d tests, %d FAIL (evidence), %d pass | control: %d/%d pass" % (
    len(red), sum(not t["ok"] for t in red), sum(t["ok"] for t in red),
    sum(t["ok"] for t in ctl), len(ctl)))
for t in d["tests"]:
    print(("  FAIL " if not t["ok"] else "  pass ") + t["name"])
'

echo "==> [3/6] differential vs cel-go v0.24.1 (curated red-team corpus + random fuzz, E=eval / C=check+eval)"
python3 "$HERE/diff/gen_cases.py" curated > "$OUT/curated.cases"
python3 "$HERE/diff/gen_cases.py" fuzz 1 "$FUZZ_N" > "$OUT/fuzz.cases"
for c in curated fuzz; do
  printf '  %-8s ' "$c"
  python3 "$HERE/diff/run_diff.py" "$OUT/pion_driver_dbg" "$OUT/go_oracle" "$OUT/$c.cases" "$OUT/$c" || exit 2
done
for c in curated fuzz; do
  echo "  --- root-cause buckets: $c (details: $OUT/$c.mismatch.txt)"
  python3 "$HERE/diff/classify.py" "$OUT/$c.mismatch.txt" --examples 1 | cut -c1-220 | sed 's/^/    /'
done

echo "==> [4/6] Pion build-mode consistency (reference: native debug; 4 modes, byte-identical transcripts)"
for c in curated fuzz; do
  python3 "$HERE/diff/cmp_builds.py" "$OUT/$c.cases" "$OUT/pion_driver_dbg" "$OUT/pion_driver_rel" "native-release" | sed 's/^/  /'
  PION_CACHE_DIR="$WASM_CACHE" python3 "$HERE/diff/cmp_builds.py" "$OUT/$c.cases" "$OUT/pion_driver_dbg" \
    "pionc run --target wasm32 $HERE/diff/pion_driver --" "wasm32-debug" | sed 's/^/  /'
  PION_CACHE_DIR="$WASM_CACHE" python3 "$HERE/diff/cmp_builds.py" "$OUT/$c.cases" "$OUT/pion_driver_dbg" \
    "pionc run --release --target wasm32 $HERE/diff/pion_driver --" "wasm32-release" | sed 's/^/  /'
done

echo "==> [5/6] DoS / limit-bypass probes (Pion native + wasm32 vs cel-go unlimited and cel.CostLimit(1e6))"
if [ "$QUICK" -eq 1 ]; then Q=--quick; else Q=; fi
PION_CACHE_DIR="$WASM_CACHE" python3 "$HERE/dos/run_dos.py" "$OUT/pion_dos" "$OUT/go_dos" "$HERE/dos/pion_dos" $Q

echo "==> [6/6] worktree cleanliness"
ROOT=$(cd "$HERE/../../.." && pwd)
if [ -z "$(git -C "$ROOT" status --porcelain --ignored)" ]; then echo "  git status --porcelain --ignored: clean"; else
  echo "  WARNING: worktree not clean:"; git -C "$ROOT" status --porcelain --ignored | sed 's/^/    /'; fi
exit 0
