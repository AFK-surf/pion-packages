#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/base64`.
# All Lake build artifacts stay in /private/tmp/pion-lean-shared (single shared Mathlib .lake, zero git worktree pollution).

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

WORK="${LEAN_WORK:-/private/tmp/pion-lean-shared}"
PROJ="$WORK/proj"
PION_REF="${PION_LEAN_REF:-$WORK/pion-ref}"
AENEAS_REV=1dc8ad31b1
PIONC="${PIONC:-pionc}"

mkdir -p "$WORK"

echo "=== [1/7] Prepare Pion lean/ runtime & Aeneas@$AENEAS_REV in $WORK ==="
if [ ! -d "$PION_REF/lean" ]; then
  if [ -d "/private/tmp/pion-lean-ref/lean" ]; then
    PION_REF="/private/tmp/pion-lean-ref"
  elif [ -d "/private/tmp/pion-lean-ref-semver/lean" ]; then
    PION_REF="/private/tmp/pion-lean-ref-semver"
  else
    git clone --depth 1 -q https://github.com/AFK-surf/pion.git "$PION_REF"
  fi
fi

if [ -z "${AENEAS_DIR:-}" ]; then
  if [ -d "/private/tmp/pion-lean-semver/aeneas/backends/lean" ]; then
    AENEAS_DIR="/private/tmp/pion-lean-semver/aeneas/backends/lean"
  else
    if [ ! -d "$WORK/aeneas/.git" ]; then
      git clone -q https://github.com/AeneasVerif/aeneas.git "$WORK/aeneas"
    fi
    git -C "$WORK/aeneas" checkout -q "$AENEAS_REV"
    AENEAS_DIR="$WORK/aeneas/backends/lean"
  fi
fi

if [ ! -f "$PROJ/lakefile.lean" ] || [ ! -d "$PROJ/.lake/packages/mathlib" ]; then
  rm -rf "$PROJ"
  mkdir -p "$PROJ/.deps" "$PROJ/.lake"
  (cd "$PION_REF/lean" && tar -cf - --exclude .lake --exclude .deps .) | (cd "$PROJ" && tar -xf -)
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
  (cd "$PROJ" && lake exe cache get)
else
  cp "$PION_REF/lean/lakefile.lean" "$PROJ/lakefile.lean"
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
fi

echo "=== [2/7] pionc extract-lean packages/base64 ==="
rm -rf "$PROJ/Base64"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Base64/$f.lean" ]; then
    echo "FAIL: missing Base64/$f.lean" >&2
    exit 1
  fi
done

rm -rf "$PROJ/Base64Proofs"
cp -R "$SCRIPT_DIR/Base64Proofs" "$PROJ/Base64Proofs"
cp "$SCRIPT_DIR/Base64Proofs.lean" "$PROJ/Base64Proofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Base64 where\n  globs := #[.submodules `Base64]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib Base64Proofs where\n  globs := #[.andSubmodules `Base64Proofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/Base64Proofs.lean" "$SCRIPT_DIR/Base64Proofs" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Base64 Base64Proofs ==="
cd "$PROJ"
set +e
lake build PionLean Base64 Base64Proofs > "$WORK/build.log" 2>&1
RC=$?
set -e
grep -v '^✔\|^trace\|^info' "$WORK/build.log" | tail -80 || true
if [ "$RC" -ne 0 ] || grep -q '^error' "$WORK/build.log"; then
  echo "FAIL: lake build failed (rc=$RC)" >&2
  cat "$WORK/build.log" >&2
  exit 1
fi
if grep -q "declaration uses .sorry" "$WORK/build.log"; then
  echo "FAIL: declaration uses sorry" >&2
  exit 1
fi
echo "lake build PionLean Base64 Base64Proofs: exit 0, 0 errors"

echo "=== [5/7] #print axioms audit ==="
AXIOMS_OUT=$(lake env lean --memory="$LEAN_MEM_LIMIT" -j "$LEAN_NUM_THREADS" CheckAxioms.lean 2>&1)
echo "$AXIOMS_OUT"
BAD_AXIOMS=$(printf '%s\n' "$AXIOMS_OUT" | grep -E "depends on axioms:" | sed 's/.*\[//;s/\].*//;s/,/\n/g' | tr -d ' ' | sort -u | grep -v -E '^(propext|Classical\.choice|Quot\.sound)$' || true)
if [ -n "$BAD_AXIOMS" ]; then
  echo "FAIL: unexpected axioms found: $BAD_AXIOMS" >&2
  exit 1
fi
if printf '%s\n' "$AXIOMS_OUT" | grep -q "error:"; then
  echo "FAIL: CheckAxioms.lean reported errors" >&2
  exit 1
fi
echo "Axioms audit: ONLY standard axioms (propext, Classical.choice, Quot.sound)"

echo "=== [6/7] EvalDiff.lean (#eval) ==="
EVAL_OUT=$(lake env lean --memory="$LEAN_MEM_LIMIT" -j "$LEAN_NUM_THREADS" --run EvalDiff.lean 2>&1)
echo "$EVAL_OUT"
if printf '%s\n' "$EVAL_OUT" | grep -q "error:"; then
  echo "FAIL: EvalDiff.lean reported errors" >&2
  exit 1
fi
if printf '%s\n' "$EVAL_OUT" | grep -q ': FAIL$'; then
  echo "FAIL: EvalDiff.lean had a FAIL check" >&2
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential cross-check (diff -u) ==="
DIFF_DIR="$WORK/native-diff"
rm -rf "$DIFF_DIR"
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/pion.toml" <<EOF
[package]
name = "base64_lean_diff"
version = "0.1.0"

[dependencies]
base64 = { path = "$PKG_DIR" }
EOF

cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "base64"

fn report(w : World, label : String, passed : Bool) -> Unit {
  if passed {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  report(w, "b64_enc_pad_0", base64::encoded_len(0, true) == 0)
  report(w, "b64_enc_pad_1", base64::encoded_len(1, true) == 4)
  report(w, "b64_enc_pad_2", base64::encoded_len(2, true) == 4)
  report(w, "b64_enc_pad_3", base64::encoded_len(3, true) == 4)
  report(w, "b64_enc_nopad_1", base64::encoded_len(1, false) == 2)
  report(w, "b64_enc_nopad_2", base64::encoded_len(2, false) == 3)
  report(w, "b64_enc_nopad_10", base64::encoded_len(10, false) == 14)
  report(w, "b64_dec_len_0", base64::b64_decoded_len(0) == 0)
  report(w, "b64_dec_len_1_bad", base64::b64_decoded_len(1) == -1)
  report(w, "b64_dec_len_2", base64::b64_decoded_len(2) == 1)
  report(w, "b64_dec_len_3", base64::b64_decoded_len(3) == 2)
  report(w, "b64_dec_len_14", base64::b64_decoded_len(14) == 10)
  report(w, "b64_pack3_abc", base64::b64_pack3(97, 98, 99) == 6382179)
  report(w, "b64_pack4_ok", base64::b64_pack4_sextets(24, 22, 9, 35) == 6382179)
  report(w, "b64_pack4_bad", base64::b64_pack4_sextets(0, -1, 0, 0) < 0)
  report(w, "b64_mask_2", base64::b64_tail_canonical_mask(2) == 15)
  report(w, "b64_mask_3", base64::b64_tail_canonical_mask(3) == 3)
  report(w, "b64_pad_0", base64::b64_expected_pad(0) == 0)
  report(w, "b64_pad_2", base64::b64_expected_pad(2) == 2)
  report(w, "b64_pad_3", base64::b64_expected_pad(3) == 1)

  report(w, "b32_tsym_0", base64::b32_tail_symbols(0) == 0)
  report(w, "b32_tsym_1", base64::b32_tail_symbols(1) == 2)
  report(w, "b32_tsym_2", base64::b32_tail_symbols(2) == 4)
  report(w, "b32_tsym_3", base64::b32_tail_symbols(3) == 5)
  report(w, "b32_tsym_4", base64::b32_tail_symbols(4) == 7)
  report(w, "b32_tbyt_1_bad", base64::b32_tail_bytes(1) == -1)
  report(w, "b32_tbyt_3_bad", base64::b32_tail_bytes(3) == -1)
  report(w, "b32_tbyt_6_bad", base64::b32_tail_bytes(6) == -1)
  report(w, "b32_tbyt_7", base64::b32_tail_bytes(7) == 4)
  report(w, "b32_enc_pad_6", base64::b32_encoded_len(6, true) == 16)
  report(w, "b32_enc_nopad_6", base64::b32_encoded_len(6, false) == 10)
  report(w, "b32_spare_2", base64::b32_spare_mask(2) == 3)
  report(w, "b32_spare_4", base64::b32_spare_mask(4) == 15)
  report(w, "b32_spare_5", base64::b32_spare_mask(5) == 1)
  report(w, "b32_spare_7", base64::b32_spare_mask(7) == 7)

  report(w, "hex_enc_7", base64::hex_encoded_len(7) == 14)
  report(w, "hex_dec_14", base64::hex_decoded_len(14) == 7)
  report(w, "hex_dec_odd", base64::hex_decoded_len(15) == -1)
  report(w, "hex_pack_ab", base64::hex_pack_byte(10, 11) == 171)
  report(w, "hex_pack_bad", base64::hex_pack_byte(10, -1) < 0)
  0
}
EOF

"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/base64 Lean 4 proofs"
