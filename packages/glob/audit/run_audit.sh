#!/bin/sh
# One-command red-team audit of packages/glob against real Rust globset/ignore and git.
#   sh packages/glob/audit/run_audit.sh           # everything (full benchmark, ~10 min)
#   sh packages/glob/audit/run_audit.sh --quick   # smaller benchmark (~3 min)
# All artifacts go to $AUDIT_OUT (default /tmp/pion-glob-audit); the worktree stays clean.
# Exit code: 0 if the audit ran to completion (the findings are in the output), 2 on tooling errors.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="${AUDIT_OUT:-/tmp/pion-glob-audit}"
QUICK=""
[ "${1:-}" = "--quick" ] && QUICK="--quick"
mkdir -p "$OUT"

echo "==> [1/6] build Pion driver and Rust oracle (globset 0.4.21, ignore 0.4.34)"
pionc build --release -o "$OUT/pion_driver" "$HERE/driver" || exit 2
CARGO_TARGET_DIR="$OUT/rust-target" cargo build --quiet --release --locked \
  --manifest-path "$HERE/oracle/Cargo.toml" || exit 2
cp "$OUT/rust-target/release/glob-audit-oracle" "$OUT/rust_oracle"
GLOBSET_SRC=$(ls -d "$HOME"/.cargo/registry/src/*/globset-0.4.21 | head -1)

echo "==> [2/6] red-team tests (every test is expected to FAIL until the defect is fixed)"
pionc test --json -p glob_audit "$HERE" 2>/dev/null | tail -1 | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("redteam tests: total=%d failed(evidence)=%d passed=%d" % (d["total"], d["failed"], d["passed"]))
for t in d["tests"]:
    print(("  FAIL " if not t["ok"] else "  pass ") + t["name"])
'

echo "==> [3/6] upstream globset vectors replayed on Pion"
python3 "$HERE/upstream_vectors.py" "$OUT/pion_driver" "$GLOBSET_SRC" "$HERE/../glob_test.pion" "$OUT/upstream"

echo "==> [4/6] differential matrix vs Rust globset/ignore and git check-ignore"
python3 "$HERE/differential.py" "$OUT/pion_driver" "$OUT/rust_oracle" "$OUT/diff"
echo "    details: $OUT/diff/diff_divergences.txt"

echo "==> [5/6] minimise multi-pattern GlobSet divergences"
python3 "$HERE/minimize_sets.py" "$OUT/pion_driver" "$OUT/rust_oracle" "$OUT/min"

echo "==> [6/6] adversarial benchmark (Pion vs Rust, stdout hash-checked)"
python3 "$HERE/adversarial_bench.py" "$OUT/pion_driver" "$OUT/rust_oracle" "$OUT/bench" $QUICK || exit 2
echo "    table: $OUT/bench/bench.md"
exit 0
