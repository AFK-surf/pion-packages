#!/bin/sh
# One-shot red-team audit of packages/svg (Pion) against Rust svgtypes =0.15.3 / roxmltree =0.20.0 / kurbo =0.11.3,
# libm, independent Python references (W3C SVG 1.1 F.6.5/F.6.6, CSS Color 4, SVG 2 §8.2) and svgo@3.3.2.
#   sh packages/svg/audit/run_audit.sh           # full run (~1-2 min on an M-series Mac)
#   QUICK=1 sh packages/svg/audit/run_audit.sh   # smaller fuzz corpora, no benchmark-fairness timing
# Everything generated goes to $AUDIT_TMP (default /private/tmp/rt-svg-audit); the repository stays clean.
# Exit status: 0 only when every P0/P1/P2 check and every control passes (i.e. on a branch that fixes all findings).
set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
export AUDIT_TMP="${AUDIT_TMP:-/private/tmp/rt-svg-audit}"
T="$AUDIT_TMP"
B="$T/bin"
mkdir -p "$B"
rm -f "$T"/ledger_*.json
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
QUICK="${QUICK:-0}"
PATH_FUZZ=20000
GEOM_FUZZ=1500
[ "$QUICK" = 1 ] && PATH_FUZZ=3000 && GEOM_FUZZ=300
S="$SCRIPT_DIR/scripts"
STATUS=0
step() { printf '\n==================== %s ====================\n' "$*"; }
fail() { STATUS=1; }

step "0. toolchain / target"
pionc --version; cargo --version; node --version; python3 --version
echo "pion-packages HEAD: $(git -C "$REPO_ROOT" rev-parse --short HEAD)  packages/svg/src last commit: $(git -C "$REPO_ROOT" log -1 --format=%h -- packages/svg/src)"

step "1. build probe (native debug -> native release -> wasm32 debug -> wasm32 release, serial) + Rust oracle (--locked)"
pionc build -o "$B/probe_native_dbg" "$SCRIPT_DIR/probe" || exit 1
pionc build --release -o "$B/probe_native_rel" "$SCRIPT_DIR/probe" || exit 1
pionc build --target wasm32 -o "$B/probe_wasm_dbg.wasm" "$SCRIPT_DIR/probe" || exit 1
pionc build --release --target wasm32 -o "$B/probe_wasm_rel.wasm" "$SCRIPT_DIR/probe" || exit 1
CARGO_TARGET_DIR="$T/rust-target" cargo build --release -q --locked --manifest-path "$SCRIPT_DIR/oracle/Cargo.toml" || exit 1
cp "$T/rust-target/release/svg_audit_oracle" "$B/oracle"
ls -l "$B" | sed 1d

step "2. pionc fmt/check/test of the audit package (p0_/p1_/p2_ FAILURES = open defects, control_ must pass)"
(cd "$SCRIPT_DIR" && pionc fmt --check . && pionc fmt --check probe && pionc check --json . | tail -c 120 && echo) || fail
(cd "$SCRIPT_DIR" && pionc test --json -p svg_audit . > "$T/redteam.json" 2> "$T/redteam.stderr")
python3 - "$T/redteam.json" "$T/redteam.stderr" "$T/ledger_tests.json" << 'PYEOF' || fail
import json, sys, collections, re
d = json.load(open(sys.argv[1]))
err = open(sys.argv[2], errors="replace").read()
c = collections.Counter()
rows = []
for t in d["tests"]:
    lvl = t["name"].split("_")[0]
    c[(lvl, t["ok"])] += 1
    rows.append(dict(name=t["name"], ok=t["ok"], sev=lvl.upper() if lvl != "control" else "ctl", detail=""))
print(f"total={d['total']} passed={d['passed']} failed={d['failed']}")
for lvl in ("p0", "p1", "p2", "control"):
    print(f"  {lvl:8s} fail={c[(lvl, False)]:3d} pass={c[(lvl, True)]:3d}")
for t in d["tests"]:
    if not t["ok"]:
        print("  FAIL", t["name"])
for m in re.findall(r"redteam_test\.pion:(\d+): ([^\n]*)", err):
    print(f"    line {m[0]}: {m[1][:170]}")
json.dump(rows, open(sys.argv[3], "w"), indent=1)
sys.exit(1 if d["failed"] else 0)
PYEOF

step "3. W3C path-data grammar + number parsing differential vs svgtypes (fuzz=$PATH_FUZZ)"
python3 "$S/path_diff.py" "$PATH_FUZZ" || fail

step "4. Geometry: arcs F.6.5/F.6.6, S/T reflection, Z base, exact bbox, path_length, flatten tolerance (fuzz=$GEOM_FUZZ)"
python3 "$S/geom_check.py" "$GEOM_FUZZ" || fail

step "5. Transform / viewBox / preserveAspectRatio / color / length differential"
python3 "$S/attr_diff.py" || fail

step "6. format_path serializer: validity, rounding, relative drift"
python3 "$S/fmt_check.py" || fail

step "7. SVG DOM / entities / namespaces / style cascade / optimize_svg semantics & XML-injection safety"
python3 "$S/dom_opt_check.py" || fail

step "8. DoS / crash probes (4 build modes) + optimize_svg depth scaling"
python3 "$S/dos.py" || fail

step "9. 4-mode byte parity (native rel/dbg, wasm32 rel/dbg executed under node)"
python3 "$S/wasm4.py" || fail

if [ "$QUICK" != 1 ]; then
  step "10. Benchmark fairness measurements (informational, never fails)"
  python3 "$S/bench_fairness.py" || echo "(bench fairness step errored - informational only)"
fi

step "11. summary"
python3 - "$T" << 'PYEOF'
import glob, json, os, sys
rows = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "ledger_*.json"))):
    sec = os.path.basename(f)[7:-5]
    for r in json.load(open(f)):
        rows.append((sec, r))
for sev in ("P0", "P1", "P2", "ctl"):
    sel = [(s, r) for s, r in rows if r["sev"] == sev]
    bad = [(s, r) for s, r in sel if not r["ok"]]
    print(f"{sev:4s}: {len(sel) - len(bad):3d} PASS / {len(bad):3d} FAIL")
    for s, r in bad:
        print(f"      FAIL [{s}] {r['name']}")
PYEOF

step "12. worktree must be clean (only committed audit files)"
git -C "$REPO_ROOT" status --porcelain --ignored -- packages/svg
echo "(empty above = clean; evidence in $T)"
if [ "$STATUS" = 0 ]; then
  echo "RESULT: ALL GREEN (exit 0)"
else
  echo "RESULT: OPEN FINDINGS (exit 1) - see REPORT.md"
fi
exit "$STATUS"
