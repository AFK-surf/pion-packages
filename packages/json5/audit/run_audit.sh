#!/bin/sh
# Red-team audit of packages/json5 @ b9f6a1f: one command, Pion vs Node json5@2.2.3 / fast-json-patch@3.1.1
# vs Rust json5 =1.3.8 / serde_json =1.0.140 / json-patch =4.2.0.
#
#   sh packages/json5/audit/run_audit.sh                 # every stage (~15 min on an Apple M-series)
#   sh packages/json5/audit/run_audit.sh tests ident     # selected stages only
#
# Stages: tests   - pionc test packages/json5/audit (every p*_ FAIL is an exhibit; ctl_* must pass)
#         ident   - all 1,112,064 code points as raw / escaped IdentifierStart / IdentifierPart / whitespace
#         numbers - 60,000 doubles to_json_string -> parse (vs JSON.stringify), 37,995 numeric literals
#         syntax  - JSON5 / strict-JSON edge cases vs JSON5.parse, JSON.parse, json5-rs, serde_json
#         patch   - RFC 6901 pointer + RFC 6902 patch vectors, 2,000 random diff()/apply_patch round trips
#                   (Pion's patches are also replayed with fast-json-patch)
#         wasm    - every differential above through native debug/release + wasm32 debug/release:
#                   all 4 must be byte-identical
#         deep    - crash depth of drop / to_json_string / value_eq / clone / diff / copy / patch-built nesting
#                   in the 4 build modes (tools/depth_bisect.py)
#         bench   - adversarial workloads via scripts/bench_compare.py (SHA-256 gated, warmup 1, 5 rounds)
#
# Everything is built and written under $OUT (default /private/tmp/pion-json5-audit); the worktree stays clean.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT="${OUT:-/private/tmp/pion-json5-audit}"
export PATH="${HOME}/.pion/bin:${HOME}/.cargo/bin:/opt/homebrew/bin:${PATH}"
STAGES="${*:-tests ident numbers syntax patch wasm deep bench}"
RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
B="$OUT/bin"
C="$OUT/cases"
mkdir -p "$B" "$OUT/node" "$OUT/res"

want() { case " $STAGES " in *" $1 "*) return 0 ;; esac; return 1; }
node_oracle() { NODE_PATH="$OUT/node/node_modules" node "$AUDIT_DIR/oracle/node/oracle.mjs" "$@"; }

echo "==> pionc $(pionc --version 2>&1 | head -1); $(cargo --version); node $(node --version)"
echo "==> Building drivers into $B"
pionc build --release -o "$B/pion_driver" "$AUDIT_DIR/driver"
pionc build -o "$B/pion_driver_dbg" "$AUDIT_DIR/driver"
pionc build --release --target wasm32 -o "$B/pion_driver.wasm" "$AUDIT_DIR/driver"
pionc build --target wasm32 -o "$B/pion_driver_dbg.wasm" "$AUDIT_DIR/driver"
CARGO_TARGET_DIR="$OUT/rust-target" cargo build -q --release --manifest-path "$AUDIT_DIR/oracle/rust/Cargo.toml"
cp "$OUT/rust-target/release/json5_audit_oracle" "$B/rust_oracle"
if [ ! -d "$OUT/node/node_modules/json5" ] || [ ! -d "$OUT/node/node_modules/fast-json-patch" ]; then
  (cd "$OUT/node" && npm init -y >/dev/null 2>&1 && npm install --no-audit --no-fund json5@2.2.3 fast-json-patch@3.1.1 >/dev/null)
fi
python3 "$AUDIT_DIR/tools/gen_cases.py" "$C" >/dev/null
R="$OUT/res"

if want tests; then
  echo
  echo "==> [tests] pionc test packages/json5/audit (p*_ FAIL = evidence against Pion; ctl_* = controls)"
  (cd "$AUDIT_DIR" && pionc test --json . >"$OUT/tests.json" 2>"$OUT/tests.stderr") || true
  python3 - "$OUT/tests.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
mine = [t for t in d["tests"] if t["pkg"] == "json5_redteam_audit"]
up = [t for t in d["tests"] if t["pkg"] == "json5"]
print(f"red-team: {sum(not t['ok'] for t in mine if t['name'].startswith('p'))} exhibits FAIL, "
      f"{sum(t['ok'] for t in mine if t['name'].startswith('ctl'))}/{sum(t['name'].startswith('ctl') for t in mine)} controls pass; "
      f"package's own tests: {sum(t['ok'] for t in up)}/{len(up)} pass")
for t in mine:
    print(("  FAIL " if not t["ok"] else "  pass ") + t["name"])
PYEOF
  echo "  (assertion messages: $OUT/tests.stderr)"
fi

if want ident; then
  echo
  echo "==> [ident] identifier / whitespace scan over every Unicode scalar value"
  "$B/pion_driver" idscan >"$R/id_pion.txt"
  "$B/rust_oracle" idscan >"$R/id_rust.txt"
  node_oracle idscan >"$R/id_node.txt"
  python3 "$AUDIT_DIR/tools/compare_idscan.py" "$R/id_pion.txt" "$R/id_node.txt" "$R/id_rust.txt" --examples 6
fi

if want numbers; then
  echo
  echo "==> [numbers] 60,000-double format/round trip and 37,995-literal parse differential"
  "$B/pion_driver" numfmt "$C/numfmt.txt" >"$R/nf_pion.txt"
  node_oracle numfmt "$C/numfmt.txt" >"$R/nf_node.txt"
  "$B/rust_oracle" numfmt "$C/numfmt.txt" >"$R/nf_rust.txt"
  python3 - "$C/numfmt.txt" "$R/nf_pion.txt" "$R/nf_node.txt" "$R/nf_rust.txt" <<'PYEOF'
import sys
c, p, n, r = (open(f).read().split("\n") for f in sys.argv[1:])
fmt = rt = rrt = total = 0
bad = []
for i, x in enumerate(c):
    if not x or n[i] == "ERR":  # non-finite input: not representable in JSON
        continue
    total += 1
    ps, pb = p[i].split(" ")
    if ps != n[i].split(" ")[0]:
        fmt += 1
    if pb != "d" + x:
        rt += 1
        bad.append(f"{x} -> {ps!r} -> {pb}")
    if r[i].split(" ")[1] != "d" + x:
        rrt += 1
print(f"  Pion to_json_string vs JSON.stringify: {fmt}/{total} differ")
print(f"  Pion bit-exact round trip failures: {rt}/{total}  {bad[:3]}")
print(f"  (reference: serde_json 1.0.140 default features fails {rrt}/{total} round trips - no float_roundtrip)")
PYEOF
  for m in j5 j5inf; do "$B/pion_driver" parse "$C/numparse.hex" $m >"$R/np_pion_$m.txt"; done
  node_oracle parse "$C/numparse.hex" j5 >"$R/np_node.txt"
  "$B/rust_oracle" parse "$C/numparse.hex" j5 >"$R/np_rust.txt"
  echo "  -- reject_overflow=false (Node/Rust semantics):"
  python3 "$AUDIT_DIR/tools/compare.py" "$C/numparse.hex" pion="$R/np_pion_j5inf.txt" node="$R/np_node.txt" rust="$R/np_rust.txt" --show 6
  echo "  -- default ParseOptions:"
  python3 "$AUDIT_DIR/tools/compare.py" "$C/numparse.hex" pion="$R/np_pion_j5.txt" node="$R/np_node.txt" --show 3
fi

if want syntax; then
  echo
  echo "==> [syntax] JSON5 edge cases (vs JSON5.parse, json5-rs) and strict JSON (vs JSON.parse, serde_json)"
  "$B/pion_driver" parse "$C/syntax.hex" j5 >"$R/sx_pion.txt"
  node_oracle parse "$C/syntax.hex" j5 >"$R/sx_node.txt" 2>/dev/null
  "$B/rust_oracle" parse "$C/syntax.hex" j5 >"$R/sx_rust.txt"
  python3 "$AUDIT_DIR/tools/compare.py" "$C/syntax.hex" pion="$R/sx_pion.txt" node="$R/sx_node.txt" rust="$R/sx_rust.txt" --show 40
  "$B/pion_driver" parse "$C/strict.hex" json >"$R/st_pion.txt"
  node_oracle parse "$C/strict.hex" json >"$R/st_node.txt"
  "$B/rust_oracle" parse "$C/strict.hex" json >"$R/st_rust.txt"
  python3 "$AUDIT_DIR/tools/compare.py" "$C/strict.hex" pion="$R/st_pion.txt" node="$R/st_node.txt" rust="$R/st_rust.txt" --show 10
fi

if want patch; then
  echo
  echo "==> [patch] RFC 6901 pointer (vs serde_json Value::pointer), RFC 6902 patch, diff round trip"
  "$B/pion_driver" ptr "$C/ptr.txt" >"$R/pt_pion.txt"
  "$B/rust_oracle" ptr "$C/ptr.txt" >"$R/pt_rust.txt"
  python3 "$AUDIT_DIR/tools/compare.py" "$C/ptr.txt" pion="$R/pt_pion.txt" rust="$R/pt_rust.txt" --show 10
  "$B/pion_driver" patch "$C/patch.txt" >"$R/pa_pion.txt"
  node_oracle patch "$C/patch.txt" >"$R/pa_node.txt"
  "$B/rust_oracle" patch "$C/patch.txt" >"$R/pa_rust.txt"
  python3 "$AUDIT_DIR/tools/compare.py" "$C/patch.txt" pion="$R/pa_pion.txt" node="$R/pa_node.txt" rust="$R/pa_rust.txt" --show 20
  "$B/pion_driver" diffrt "$C/diff.txt" >"$R/df_pion.txt"
  node_oracle diffcheck "$C/diff.txt" "$R/df_pion.txt" >"$R/df_node.txt"
  "$B/rust_oracle" diffcount "$C/diff.txt" >"$R/df_rust.txt"
  echo "  Pion apply_patch(a, diff(a,b)) == b:        $(grep -c '^RT ' "$R/df_pion.txt")/$(wc -l <"$C/diff.txt" | tr -d ' ')"
  echo "  fast-json-patch replays Pion's diff to b:   $(grep -c '^NODE_OK' "$R/df_node.txt")/$(wc -l <"$C/diff.txt" | tr -d ' ')"
  echo "  Rust json-patch diff round trip:            $(grep -c '^RT ' "$R/df_rust.txt")/$(wc -l <"$C/diff.txt" | tr -d ' ')"
  paste -d' ' "$R/df_pion.txt" "$R/df_node.txt" "$R/df_rust.txt" |
    awk '$5 >= 0 { p += $2; n += $5; r += $7; c++ } END { printf "  total ops over %d pairs: pion %d, fast-json-patch %d, rust json-patch %d\n", c, p, n, r }'
fi

if want wasm; then
  echo
  echo "==> [wasm] the same differential outputs from 4 build modes must be byte-identical"
  run4() {
    tag=$1; shift
    "$B/pion_driver" "$@" >"$R/w_${tag}_nrel.txt" 2>/dev/null || echo "  native-release exit $? on $tag"
    "$B/pion_driver_dbg" "$@" >"$R/w_${tag}_ndbg.txt" 2>/dev/null || echo "  native-debug exit $? on $tag"
    node "$RT" "$B/pion_driver.wasm" "$@" >"$R/w_${tag}_wrel.txt" 2>"$R/w_${tag}_wrel.err" || echo "  wasm32-release exit $? on $tag"
    node "$RT" "$B/pion_driver_dbg.wasm" "$@" >"$R/w_${tag}_wdbg.txt" 2>"$R/w_${tag}_wdbg.err" || echo "  wasm32-debug exit $? on $tag"
    n=$(cat "$R"/w_${tag}_*.txt | wc -l | tr -d ' ')
    u=$(shasum -a 256 "$R"/w_${tag}_*.txt | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
    if [ "$u" = 1 ]; then echo "  $tag: 4/4 identical ($((n / 4)) lines)"; else echo "  $tag: DIFFERENT across modes"; shasum -a 256 "$R"/w_${tag}_*.txt; fi
  }
  run4 numfmt numfmt "$C/numfmt.txt"
  run4 numparse parse "$C/numparse.hex" j5inf
  run4 syntax parse "$C/syntax.hex" j5
  run4 strict parse "$C/strict.hex" json
  run4 ptr ptr "$C/ptr.txt"
  run4 patch patch "$C/patch.txt"
  run4 diffrt diffrt "$C/diff.txt"
  run4 idscan idscan
  run4 deep1000 deep 1000 diff
fi

if want deep; then
  echo
  echo "==> [deep] smallest nesting depth that crashes (1% precision); default max_depth is 128,"
  echo "    the package's own red-team test advertises max_depth 12000 as safe"
  python3 "$AUDIT_DIR/tools/depth_bisect.py" "$B" "$RT"
fi

if want bench; then
  echo
  echo "==> [bench] adversarial workloads (stdout SHA-256 identical across impls)"
  python3 "$AUDIT_DIR/tools/gen_bench.py" "$OUT/bench" >/dev/null
  W="$OUT/bench"
  bc() {
    title=$1; shift
    python3 "$ROOT_DIR/scripts/bench_compare.py" --title "$title" \
      --impl "pion=$B/pion_driver $*" \
      --impl "rust=$B/rust_oracle $*" \
      --impl "node=env NODE_PATH=$OUT/node/node_modules node $AUDIT_DIR/oracle/node/oracle.mjs $*" \
      --baseline rust --warmup 1 --rounds 5 --md-out "$OUT/bench.md" >/dev/null
    cat "$OUT/bench.md"
    echo
  }
  bc "A1 parse 5.5 MB JSON5, 240k unquoted non-ASCII identifier keys" adv unikeys "$W/unikeys.json5"
  bc "A2 parse 6.9 MB, 300k 17-digit doubles" adv numbers "$W/numbers.json"
  bc "A3 RFC 6902 test op: 50k-key object vs itself" adv widetest "$W/wide_a.json" "$W/wide_a.json"
  bc "A4 diff(): 50k-key objects, 1 value changed" adv diff "$W/wide_a.json" "$W/wide_b.json"
  bc "A5 diff(): 100-level spine, 5k-int pad per level" adv diff "$W/spine_a.json" "$W/spine_b.json"
  bc "A6 50k RFC 6901 pointer lookups on a 50k-key object" adv ptrwide "$W/wide_a.json"
  bc "A7 200 single-op atomic patches on a 2.5 MB document" adv bigapply "$W/big.json" 200
  # A8: fast-json-patch@3.1.1 throws on this input (stack overflow in its own recursion), so Pion vs Rust only
  python3 "$ROOT_DIR/scripts/bench_compare.py" --title "A8 one 18,000-op patch of constant-size add/move ops nesting 6,000 levels" \
    --impl "pion=$B/pion_driver patch $W/grow.txt" --impl "rust=$B/rust_oracle patch $W/grow.txt" \
    --baseline rust --warmup 1 --rounds 5 --md-out "$OUT/bench.md" >/dev/null
  cat "$OUT/bench.md"
fi
