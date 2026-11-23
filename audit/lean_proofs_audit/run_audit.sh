#!/usr/bin/env bash
# One-shot reproduction of the Lean-proof red-team audit (REPORT.md).
#
#   audit/lean_proofs_audit/run_audit.sh                 # static scan only (seconds, read-only)
#   audit/lean_proofs_audit/run_audit.sh --probes        # + semantic / C5 probes (minutes)
#   audit/lean_proofs_audit/run_audit.sh --mutations     # + two-sided mutation runs (~1-2 h)
#
# Environment:
#   OUT        output dir for the scan (default: mktemp under /private/tmp)
#   LEAN_WORK  isolated Lean workspace for probes/mutations (default /private/tmp/rt-lean-audit-work);
#              it is seeded from /private/tmp/pion-lean-ref/lean (PionLean) and a copy of the
#              shared Aeneas build, and is never /private/tmp/pion-lean-shared.
# Nothing is written inside the repository.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${OUT:-$(mktemp -d /private/tmp/rt-lean-audit-scan.XXXXXX)}"
LEAN_WORK="${LEAN_WORK:-/private/tmp/rt-lean-audit-work}"
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$PATH"

if [ "$LEAN_WORK" = "/private/tmp/pion-lean-shared" ]; then
  echo "refusing to use the shared Lean workspace" >&2; exit 2
fi

echo "=== [1] static scan: theorem inventory, CheckAxioms sets, forbidden tokens, run_proofs.sh gates,"
echo "        #verify coverage, C1-C5 heuristics + manual grades -> $OUT"
python3 -I "$HERE/scan.py" --repo "$REPO" --out "$OUT" --grades "$HERE/manual_grades.tsv"
echo
cat "$OUT/summary.md"

seed_lean_work() {
  if [ ! -d "$LEAN_WORK/proj/PionLean" ]; then
    mkdir -p "$LEAN_WORK/proj/.deps"
    cp -R /private/tmp/pion-lean-ref/lean/PionLean "$LEAN_WORK/proj/PionLean"
    cp /private/tmp/pion-lean-ref/lean/PionLean.lean "$LEAN_WORK/proj/PionLean.lean"
  fi
  if [ ! -d "$LEAN_WORK/aeneas/backends/lean" ]; then
    cp -R /private/tmp/pion-lean-shared/aeneas "$LEAN_WORK/aeneas"   # read-only copy of the prebuilt Aeneas
  fi
  ln -sfn "$LEAN_WORK/aeneas/backends/lean" "$LEAN_WORK/proj/.deps/aeneas"
}

for arg in "$@"; do
  case "$arg" in
    --probes)
      seed_lean_work
      echo "=== [2] semantic + C5 probes"
      bash "$HERE/probes/run_probes.sh" "$REPO" "$LEAN_WORK" ;;
    --mutations)
      seed_lean_work
      echo "=== [3] two-sided mutation experiments (copies under /private/tmp/rt-lean-audit-mut)"
      python3 -I "$HERE/mutate.py" --repo "$REPO" --lean-work "$LEAN_WORK" --mut-root /private/tmp/rt-lean-audit-mut ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done
echo "scan output: $OUT"
