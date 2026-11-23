#!/usr/bin/env bash
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="$HOME/.elan/bin:$HOME/.pion/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_NAME="uuid"
LEAN_MOD="Uuid"
PROOF_MOD="UuidProofs"
PIONC_BIN="${PIONC:-$(command -v pionc 2>/dev/null || echo "$HOME/.pion/bin/pionc")}"
LEAN_CACHE="${LEAN_CACHE:-/private/tmp/pion-lean-shared}"
PION_LEAN_REF="${PION_LEAN_REF:-/private/tmp/pion-lean-ref/lean}"
WORK_DIR="${LEAN_WORK:-/private/tmp/pion-lean-work/$PKG_NAME}"

if [ ! -d "$LEAN_CACHE/aeneas/backends/lean" ] || [ ! -d "$LEAN_CACHE/proj/.lake/packages" ]; then
  echo "ERROR: shared Aeneas/Mathlib cache not found under $LEAN_CACHE" >&2
  exit 1
fi
if [ ! -d "$PION_LEAN_REF/PionLean" ] || [ ! -f "$PION_LEAN_REF/PionLean.lean" ]; then
  echo "ERROR: PionLean reference not found at $PION_LEAN_REF/PionLean" >&2
  exit 1
fi

echo "=== [1/7] Checking forbidden proof tokens ==="
SCAN_PATHS=("$SCRIPT_DIR/$PROOF_MOD.lean")
if [ -d "$SCRIPT_DIR/$PROOF_MOD" ]; then
  SCAN_PATHS+=("$SCRIPT_DIR/$PROOF_MOD")
fi
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide|unsafe|implemented_by|opaque|extern)\b' "${SCAN_PATHS[@]}"; then
  echo "FAIL: forbidden token found in proofs" >&2
  exit 1
fi

echo "=== [2/7] Preparing isolated workspace $WORK_DIR and extracting Lean 4 model ==="
mkdir -p "$WORK_DIR/.deps" "$WORK_DIR/.lake"
ln -sfn "$LEAN_CACHE/aeneas/backends/lean" "$WORK_DIR/.deps/aeneas"
ln -sfn "$LEAN_CACHE/proj/.lake/packages" "$WORK_DIR/.lake/packages"
cp -f "$PION_LEAN_REF/lean-toolchain" "$WORK_DIR/lean-toolchain"
cp -f "$LEAN_CACHE/proj/lake-manifest.json" "$WORK_DIR/lake-manifest.json"
rm -rf "$WORK_DIR/PionLean" "$WORK_DIR/PionLean.lean"
cp -f "$PION_LEAN_REF/PionLean.lean" "$WORK_DIR/PionLean.lean"
cp -R "$PION_LEAN_REF/PionLean" "$WORK_DIR/PionLean"
rm -rf "$WORK_DIR/$LEAN_MOD" "$WORK_DIR/$LEAN_MOD.lean" "$WORK_DIR/$PROOF_MOD" "$WORK_DIR/$PROOF_MOD.lean" \
       "$WORK_DIR/CheckAxioms.lean" "$WORK_DIR/EvalDiff.lean"

"$PIONC_BIN" extract-lean "$PKG_DIR" --out "$WORK_DIR"
if [ -f "$WORK_DIR/$LEAN_MOD/FunsExternal.lean" ] && grep -qE '^\s*axiom\b' "$WORK_DIR/$LEAN_MOD/FunsExternal.lean"; then
  echo "FAIL: unexpected axiom found in generated $LEAN_MOD/FunsExternal.lean" >&2
  exit 1
fi

echo "=== [3/7] Staging $PROOF_MOD into $WORK_DIR ==="
cp "$SCRIPT_DIR/$PROOF_MOD.lean" "$WORK_DIR/"
if [ -d "$SCRIPT_DIR/$PROOF_MOD" ]; then
  cp -R "$SCRIPT_DIR/$PROOF_MOD" "$WORK_DIR/"
fi
cp "$SCRIPT_DIR/CheckAxioms.lean" "$WORK_DIR/"
cp "$SCRIPT_DIR/EvalDiff.lean" "$WORK_DIR/"

cat > "$WORK_DIR/lakefile.lean" <<EOF
import Lake
open Lake DSL

package pion_proofs where
  moreLeanArgs := #["-DwarningAsError=false"]

require aeneas from ".deps/aeneas"

lean_lib PionLean
lean_lib $LEAN_MOD
lean_lib $PROOF_MOD
EOF

echo "=== [4/7] Building $LEAN_MOD + $PROOF_MOD (0 errors, 0 warnings) ==="
BUILD_LOG="$(mktemp /tmp/${PKG_NAME}_lean_build.XXXXXX)"
AXIOM_LOG="$(mktemp /tmp/${PKG_NAME}_axioms.XXXXXX)"
LEAN_OUT="$(mktemp /tmp/${PKG_NAME}_lean_eval.XXXXXX)"
NATIVE_OUT="$(mktemp /tmp/${PKG_NAME}_native_eval.XXXXXX)"
DIFF_DIR="$(mktemp -d /tmp/${PKG_NAME}_diff.XXXXXX)"
trap 'rm -rf "$BUILD_LOG" "$AXIOM_LOG" "$LEAN_OUT" "$NATIVE_OUT" "$DIFF_DIR"; kill -- -$$ 2>/dev/null || true' EXIT INT TERM

(cd "$WORK_DIR" && lake build "$LEAN_MOD.Types" "$LEAN_MOD.Funs" "$PROOF_MOD") 2>&1 | tee "$BUILD_LOG"
if grep -E '^warning:|^error:' "$BUILD_LOG"; then
  echo "FAIL: Lean build emitted warnings or errors" >&2
  exit 1
fi

echo "=== [5/7] Auditing 1:1 theorem coverage & strict axiom whitelist (CheckAxioms.lean) ==="
(cd "$WORK_DIR" && lake env lean CheckAxioms.lean) 2>&1 | tee "$AXIOM_LOG"
python3 - "$SCRIPT_DIR" "$PROOF_MOD" "$AXIOM_LOG" <<'PYEOF'
import os, re, sys

script_dir, proof_mod, axiom_log = sys.argv[1], sys.argv[2], sys.argv[3]
declared = set()
scan_files = [os.path.join(script_dir, f"{proof_mod}.lean")]
mod_dir = os.path.join(script_dir, proof_mod)
if os.path.isdir(mod_dir):
    for root, _, files in os.walk(mod_dir):
        for fn in files:
            if fn.endswith(".lean"):
                scan_files.append(os.path.join(root, fn))
for path in scan_files:
    if os.path.isfile(path):
        with open(path) as f:
            for line in f:
                m = re.match(r"^\s*theorem\s+([A-Za-z0-9_.']+)", line)
                if m:
                    declared.add(f"{proof_mod}.{m.group(1)}")

allowed = {"propext", "Classical.choice", "Quot.sound"}
audited = set()
with open(axiom_log) as f:
    text = f.read()
for m in re.finditer(r"'([^']+)' depends on axioms: \[([^\]]*)\]", text, re.S):
    thm, ax_str = m.group(1), m.group(2)
    audited.add(thm)
    axs = {a.strip() for a in ax_str.split(",") if a.strip()}
    bad = axs - allowed
    if bad:
        sys.exit(f"FAIL: {thm} uses non-standard axioms: {sorted(bad)}")
for m in re.finditer(r"'([^']+)' does not depend on any axioms", text):
    audited.add(m.group(1))

if not declared:
    sys.exit("FAIL: no non-private theorems declared")
if declared != audited:
    missing = sorted(declared - audited)
    extra = sorted(audited - declared)
    sys.exit(f"FAIL: CheckAxioms mismatch (missing={missing}, extra={extra})")
print(f"Axiom whitelist OK: {len(audited)}/{len(declared)} theorems verified (standard axioms only)")
PYEOF

echo "=== [6/7] Running Lean differential evaluator (EvalDiff.lean) ==="
(cd "$WORK_DIR" && lake env lean EvalDiff.lean) | tee "$LEAN_OUT"

echo "=== [7/7] Native Pion vs Lean value differential cross-check (diff -u) ==="
cat > "$DIFF_DIR/pion.toml" <<EOF
[package]
name = "${PKG_NAME}_diff"
version = "0.1.0"

[dependencies]
uuid = { path = "$PKG_DIR" }
EOF
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "uuid"
fn bstr(b : Bool) -> String { if b { "true" } else { "false" } }
fn ver_tag(v : uuid::UuidVersion) -> String {
  match v {
    uuid::UuidVersion::Nil => "Nil"
    uuid::UuidVersion::Mac => "Mac"
    uuid::UuidVersion::Dce => "Dce"
    uuid::UuidVersion::Md5 => "Md5"
    uuid::UuidVersion::Random => "Random"
    uuid::UuidVersion::Sha1 => "Sha1"
    uuid::UuidVersion::SortMac => "SortMac"
    uuid::UuidVersion::SortRand => "SortRand"
    uuid::UuidVersion::Custom => "Custom"
    uuid::UuidVersion::Max => "Max"
    uuid::UuidVersion::Unknown(n) => "Unknown(" + n.to_string() + ")"
  }
}
fn var_tag(v : uuid::UuidVariant) -> String {
  match v {
    uuid::UuidVariant::Ncs => "Ncs"
    uuid::UuidVariant::Rfc4122 => "Rfc4122"
    uuid::UuidVariant::Microsoft => "Microsoft"
    uuid::UuidVariant::Future => "Future"
  }
}
fn fmt_v7(ts : Int64, ra : Int, rb : Int64) -> String {
  match uuid::Uuid::new_v7_from_parts(ts, ra, rb) {
    Ok(u) => match u.timestamp_ms() { Some(t) => "Ok(" + t.to_string() + ")", None => "Ok(None)" }
    Err(_) => "Err"
  }
}
fn fmt_ulid(ts : Int64, rhi : Int64, rlo : Int64) -> String {
  match uuid::Ulid::from_parts(ts, rhi, rlo) {
    Ok(u) => "Ok(" + u.timestamp_ms().to_string() + ")"
    Err(_) => "Err"
  }
}
fn fmt_ulid_inc(ts : Int64, rhi : Int64, rlo : Int64) -> String {
  match uuid::Ulid::from_parts(ts, rhi, rlo) {
    Ok(u) => match u.increment() {
      Ok(u2) => "Ok(" + u2.timestamp_ms().to_string() + "," + u.compare(u2).to_string() + ")"
      Err(_) => "Err"
    }
    Err(_) => "Err"
  }
}
pub fn main(world : World) -> Int {
  let max_ts : Int64 = 281474976710655L
  io_println(world, "nil_max_cmp=" + uuid::Uuid::nil().compare(uuid::Uuid::max()).to_string())
  io_println(world, "max_nil_cmp=" + uuid::Uuid::max().compare(uuid::Uuid::nil()).to_string())
  let a = uuid::Uuid::from_u64_pair(0x7FFFFFFFFFFFFFFFUL, 0xFFFFFFFFFFFFFFFFUL)
  let b = uuid::Uuid::from_u64_pair(0x8000000000000000UL, 0UL)
  io_println(world, "sign_bnd_cmp=" + a.compare(b).to_string())
  io_println(world, "nil_ver=" + ver_tag(uuid::Uuid::nil().version()))
  io_println(world, "max_ver=" + ver_tag(uuid::Uuid::max().version()))
  let u7 = match uuid::Uuid::new_v7_from_parts(1000L, 0xFFF, -1L) { Ok(u) => u, Err(_) => uuid::Uuid::nil() }
  io_println(world, "v7_ver=" + ver_tag(u7.version()))
  io_println(world, "v7_var=" + var_tag(u7.variant()))
  io_println(world, "v7_ts0=" + fmt_v7(0L, 0, 0L))
  io_println(world, "v7_tsmax=" + fmt_v7(max_ts, 0xFFF, -1L))
  io_println(world, "v7_bad=" + fmt_v7(-1L, 0, 0L))
  io_println(world, "ulid_ts0=" + fmt_ulid(0L, 0L, 0L))
  io_println(world, "ulid_tsmax=" + fmt_ulid(max_ts, 0xFFFFL, -1L))
  io_println(world, "ulid_neg=" + fmt_ulid(-1L, 0L, 0L))
  io_println(world, "ulid_over=" + fmt_ulid(281474976710656L, 0L, 0L))
  io_println(world, "ulid_inc_ok=" + fmt_ulid_inc(42L, 1L, -1L))
  io_println(world, "ulid_inc_ovf=" + fmt_ulid_inc(42L, 0xFFFFL, -1L))
  io_println(world, "nil_is_nil=" + bstr(uuid::Uuid::nil().is_nil()))
  io_println(world, "max_is_max=" + bstr(uuid::Uuid::max().is_max()))
  0
}
EOF
"$PIONC_BIN" build "$DIFF_DIR" -o "$DIFF_DIR/diff_bin" >/dev/null
"$DIFF_DIR/diff_bin" > "$NATIVE_OUT"
diff -u "$NATIVE_OUT" "$LEAN_OUT"
CASES="$(wc -l < "$LEAN_OUT" | tr -d ' ')"
echo "Native vs Lean value differential: $CASES cases identical (diff -u exit 0)"
echo "PASS: packages/$PKG_NAME Lean 4 proofs"
