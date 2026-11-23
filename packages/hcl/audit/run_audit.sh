#!/bin/sh
# Red-team audit of packages/hcl (Pion HCL2) against official Go github.com/hashicorp/hcl/v2 v2.23.0.
# One command reproduces every piece of evidence in REPORT.md:
#
#   sh packages/hcl/audit/run_audit.sh
#
# Sections (each prints PASS/FAIL lines and a summary):
#   control  the package's own suite (`pionc test packages/hcl`) must stay green
#   diff     differential corpus (cases.py) through the Go oracle and the Pion driver in all four
#            build modes (native_rel, native_dbg, wasm_rel, wasm_dbg): verdict + exact value vs Go,
#            and every mode byte-identical to native_rel
#   fuzz     4000 deterministic mutants (fuzz.py, fixed seed): no crash in any mode, modes identical
#   probe    DoS / robustness probes (probes.py) in all four modes
#
# Exit status is 0 only when every check PASSes, i.e. when no P0/P1/P2 defect of REPORT.md is left.
# Needs: pionc ($HOME/.pion/bin or PATH), node (wasm32 runtime), go, python3.
# Builds run serially; all artefacts go to $AUDIT_OUT (default ${TMPDIR:-/tmp}/pion-hcl-audit),
# never into the git worktree.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
OUT=${AUDIT_OUT:-${TMPDIR:-/tmp}/pion-hcl-audit}
OUT=${OUT%/}
BIN="$OUT/bin"
export PATH="$HOME/.pion/bin:$PATH"
WASM_RT=${PION_WASM_RT:-$HOME/.pion/share/pion/pion_wasm_rt.mjs}
mkdir -p "$BIN"
rm -f "$OUT"/*.status

step() { printf '\n==== %s ====\n' "$*"; }
record() { echo "$2" > "$OUT/$1.status"; }

step "build: Go oracle (hashicorp/hcl/v2 v2.23.0, go-cty v1.16.2, pinned by go.sum)"
(cd "$AUDIT_DIR/go_oracle" && GOFLAGS=-mod=readonly GOCACHE="$OUT/gocache" GOPATH="$OUT/gopath" \
  go build -o "$BIN/go_oracle" .)
echo "ok: $BIN/go_oracle"

step "build: Pion driver in 4 modes (serial, each with its own PION_CACHE_DIR)"
for m in native_rel native_dbg wasm_rel wasm_dbg; do
  case $m in
    native_rel) flags="--release"; out="$BIN/drv_$m" ;;
    native_dbg) flags=""; out="$BIN/drv_$m" ;;
    wasm_rel) flags="--release --target wasm32"; out="$BIN/drv_$m.wasm" ;;
    wasm_dbg) flags="--target wasm32"; out="$BIN/drv_$m.wasm" ;;
  esac
  # shellcheck disable=SC2086
  PION_CACHE_DIR="$OUT/pion-cache-$m" pionc build $flags -o "$out" "$AUDIT_DIR/pion_driver"
  echo "ok: $out"
done

run_mode() { # mode cases.tsv out
  case $1 in
    native_*) python3 "$AUDIT_DIR/run_cases.py" "$3" "$2" -- "$BIN/drv_$1" ;;
    wasm_*) python3 "$AUDIT_DIR/run_cases.py" "$3" "$2" -- node "$WASM_RT" "$BIN/drv_$1.wasm" ;;
  esac
}

step "control: pionc test packages/hcl (package's own suite must stay green)"
set +e
PION_CACHE_DIR="$OUT/pion-cache-test" pionc test --json "$PKG_DIR" > "$OUT/control.json" 2> "$OUT/control.stderr"
set -e
if python3 - "$OUT/control.json" <<'PY'
import json, sys
t = open(sys.argv[1]).read()
d = json.loads(t[t.find('{"ok"'):])
for x in d["tests"]:
    if not x["ok"]:
        print("FAIL control/" + x["name"])
print(f"control: {d['passed']}/{d['total']} PASS, {d['failed']} FAIL")
sys.exit(0 if d["failed"] == 0 else 1)
PY
then record control PASS; else record control FAIL; fi

step "diff: differential corpus vs Go hcl/v2 + 4-mode byte identity"
python3 "$AUDIT_DIR/cases.py" "$OUT/cases.tsv"
"$BIN/go_oracle" "$OUT/cases.tsv" > "$OUT/cases.go.out"
for m in native_rel native_dbg wasm_rel wasm_dbg; do run_mode $m "$OUT/cases.tsv" "$OUT/cases.$m.out"; done
if python3 "$AUDIT_DIR/compare.py" "$OUT/cases.go.out" "$OUT/cases.native_rel.out" \
  --modes "$OUT/cases.native_dbg.out" "$OUT/cases.wasm_rel.out" "$OUT/cases.wasm_dbg.out" > "$OUT/diff.txt"; then
  record diff PASS; else record diff FAIL; fi
grep -v '^PASS ' "$OUT/diff.txt" || true

step "fuzz: 4000 deterministic mutants, no crash + 4-mode identity"
python3 "$AUDIT_DIR/fuzz.py" "$OUT/fuzz.tsv" 4000 20261123
for m in native_rel native_dbg wasm_rel wasm_dbg; do run_mode $m "$OUT/fuzz.tsv" "$OUT/fuzz.$m.out"; done
if python3 "$AUDIT_DIR/compare.py" --robust "$OUT/fuzz.native_rel.out" "$OUT/fuzz.native_dbg.out" \
  "$OUT/fuzz.wasm_rel.out" "$OUT/fuzz.wasm_dbg.out" > "$OUT/fuzz.txt"; then
  record fuzz PASS; else record fuzz FAIL; fi
cat "$OUT/fuzz.txt"

step "probe: DoS / robustness probes in 4 modes"
if python3 "$AUDIT_DIR/probes.py" "native_rel=$BIN/drv_native_rel" "native_dbg=$BIN/drv_native_dbg" \
  "wasm_rel=node $WASM_RT $BIN/drv_wasm_rel.wasm" "wasm_dbg=node $WASM_RT $BIN/drv_wasm_dbg.wasm" > "$OUT/probe.txt"; then
  record probe PASS; else record probe FAIL; fi
cat "$OUT/probe.txt"

step "summary"
rc=0
for s in control diff fuzz probe; do
  v=$(cat "$OUT/$s.status")
  printf '%-8s %s\n' "$s" "$v"
  [ "$v" = PASS ] || rc=1
done
grep -h -E '^(control|differential|4-mode|fuzz|probes):' "$OUT/diff.txt" "$OUT/fuzz.txt" "$OUT/probe.txt" 2>/dev/null || true
if [ $rc -eq 0 ]; then echo "AUDIT: PASS (no open P0/P1/P2)"; else echo "AUDIT: FAIL (open defects, see REPORT.md)"; fi
exit $rc
