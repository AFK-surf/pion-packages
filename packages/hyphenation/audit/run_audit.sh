#!/bin/sh
# One-shot red-team audit: packages/hyphenation (Pion) vs Rust hyphenation =0.8.4 (+ hyphenation_commons).
#   sh packages/hyphenation/audit/run_audit.sh            # full run
#   QUICK=1 sh packages/hyphenation/audit/run_audit.sh    # smaller DoS sizes, skip the fairness bench
#   HUGE=1 ...                                            # also the 2 x 1.1 GB max_input_bytes wrap probe (~3.3 GB RSS)
# Everything generated goes to $AUDIT_TMP (default /private/tmp/redteam-hyph); the repo stays clean.
set -u
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
export AUDIT_TMP="${AUDIT_TMP:-/private/tmp/redteam-hyph}"
T="$AUDIT_TMP"
B="$T/bin"
mkdir -p "$B"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
QUICK="${QUICK:-0}"
HUGE="${HUGE:-0}"
S="$AUDIT_DIR/scripts"
step() { printf '\n==================== %s ====================\n' "$*"; }

step "0. toolchain"
pionc --version; cargo --version; node --version; python3 --version
echo "pion-packages HEAD: $(git -C "$ROOT_DIR" rev-parse --short HEAD)  hyphenation src last commit: $(git -C "$ROOT_DIR" log -1 --format=%h -- packages/hyphenation/src)"

step "1. build Pion probe (native debug/release, wasm32 debug/release) and the Rust oracle"
pionc build -o "$B/pion_probe_debug" "$AUDIT_DIR/probe" || exit 1
pionc build --release -o "$B/pion_probe" "$AUDIT_DIR/probe" || exit 1
pionc build --target wasm32 -o "$B/pion_probe_debug.wasm" "$AUDIT_DIR/probe" || exit 1
pionc build --release --target wasm32 -o "$B/pion_probe_release.wasm" "$AUDIT_DIR/probe" || exit 1
CARGO_TARGET_DIR="$T/rust-target" cargo build --release -q --locked --manifest-path "$AUDIT_DIR/rust/Cargo.toml" || exit 1
cp "$T/rust-target/release/oracle" "$B/oracle"

step "2. pionc test (red-team evidence; p1_/p2_ FAILURES ARE EXPECTED = evidence, control_ must pass)"
(cd "$AUDIT_DIR" && pionc fmt --check . && pionc fmt --check probe && pionc check --json . | tail -c 200 && echo)
(cd "$AUDIT_DIR" && pionc test --json -p hyphenation_audit . > "$T/redteam.json" 2> "$T/redteam.stderr")
python3 - "$T/redteam.json" << 'PYEOF'
import json, sys, collections
d = json.load(open(sys.argv[1]))
c = collections.Counter()
for t in d["tests"]:
    c[(t["name"].split("_")[0], t["ok"])] += 1
print(f"total={d['total']} passed={d['passed']} failed={d['failed']}")
for lvl in ("p0", "p1", "p2", "control"):
    print(f"  {lvl:8s} fail={c[(lvl, False)]:3d} pass={c[(lvl, True)]:3d}")
for t in d["tests"]:
    if not t["ok"]:
        print("  FAIL", t["name"])
bad = [t["name"] for t in d["tests"] if t["name"].startswith("control") and not t["ok"]]
if bad:
    print("  !! CONTROL FAILURES:", bad)
PYEOF
grep "pion panic" "$T/redteam.stderr" | sed 's#^.*redteam_test.pion:#  redteam_test.pion:#' | cut -c1-260
echo "package's own suite:"; pionc test --json "$PKG_DIR" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"  total={d['total']} passed={d['passed']} failed={d['failed']}\")"

step "3. English differential vs Rust (568k records, 15 classes) + split/hyphenate invariants"
python3 "$S/diff.py" --show 3 --json "$T/diff.json"

step "4. 80-language UTF-8 differential (every hyph-utf8 table shipped with the crate)"
python3 "$S/multilang.py" --show 1 --json "$T/multilang.json"

step "5. hyphenate_text round-trip / per-word consistency (ASCII vs Unicode punctuation)"
python3 "$S/text_diff.py" --n 4000 --show 2 --json "$T/text.json"

step "6. DoS / complexity / crash probes (N and 2N; growth 4 = quadratic)"
if [ "$QUICK" = 1 ]; then DOS_ARGS="--quick"; else DOS_ARGS=""; fi
if [ "$HUGE" = 1 ]; then DOS_ARGS="$DOS_ARGS --huge"; fi
# shellcheck disable=SC2086
python3 "$S/dos.py" $DOS_ARGS --json "$T/dos.json"

step "7. 4-mode parity (Native/Wasm32 x debug/release, executed)"
python3 "$S/wasm4.py" --json "$T/wasm4.json"

if [ "$QUICK" != 1 ]; then
  step "8. benchmark fairness re-run (scripts/bench_compare.py, SHA-256 checked)"
  python3 "$S/bench_fair.py" --iters 10 --json "$T/bench_fair.json"
fi

step "9. worktree must be clean"
git -C "$ROOT_DIR" status --porcelain --ignored -- packages/hyphenation
echo "done; artefacts in $T"
