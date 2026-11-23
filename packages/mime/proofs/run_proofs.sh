#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/mime`.
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

echo "=== [2/7] pionc extract-lean packages/mime ==="
rm -rf "$PROJ/Mime"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Mime/$f.lean" ]; then
    echo "FAIL: missing Mime/$f.lean" >&2
    exit 1
  fi
done

rm -rf "$PROJ/MimeProofs"
cp -R "$SCRIPT_DIR/MimeProofs" "$PROJ/MimeProofs"
cp "$SCRIPT_DIR/MimeProofs.lean" "$PROJ/MimeProofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Mime where\n  globs := #[.submodules `Mime]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib MimeProofs where\n  globs := #[.andSubmodules `MimeProofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/MimeProofs.lean" "$SCRIPT_DIR/MimeProofs" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Mime MimeProofs ==="
cd "$PROJ"
set +e
lake build PionLean Mime MimeProofs > "$WORK/build.log" 2>&1
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
echo "lake build PionLean Mime MimeProofs: exit 0, 0 errors"

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
name = "mime_lean_diff"
version = "0.1.0"

[dependencies]
mime = { path = "$PKG_DIR" }
EOF

cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "mime"

fn report(w : World, label : String, passed : Bool) -> Unit {
  if passed {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  report(w, "hex_up_0", mime::hex_upper_digit(0) == 48)
  report(w, "hex_up_9", mime::hex_upper_digit(9) == 57)
  report(w, "hex_up_10", mime::hex_upper_digit(10) == 65)
  report(w, "hex_up_15", mime::hex_upper_digit(15) == 70)
  report(w, "hex_val_0", mime::hex_nibble_val(48) == 0)
  report(w, "hex_val_A", mime::hex_nibble_val(65) == 10)
  report(w, "hex_val_f", mime::hex_nibble_val(102) == 15)
  report(w, "hex_val_bad", mime::hex_nibble_val(103) == -1)
  report(w, "lower_A", mime::ascii_lower_byte(65) == 97)
  report(w, "lower_Z", mime::ascii_lower_byte(90) == 122)
  report(w, "lower_a", mime::ascii_lower_byte(97) == 97)

  report(w, "qp_hi_ab", mime::qp_hi_nibble(171) == 10)
  report(w, "qp_lo_ab", mime::qp_lo_nibble(171) == 11)
  report(w, "qp_pack_ab", mime::qp_pack_hex_byte(10, 11) == 171)
  report(w, "qp_lit_a", mime::qp_encode_is_literal(97, false))
  report(w, "qp_lit_eq", !mime::qp_encode_is_literal(61, false))
  report(w, "qp_lit_eol", !mime::qp_encode_is_literal(32, true))
  report(w, "qp_dec_nul", !mime::qp_decode_allowed_literal(0))
  report(w, "qp_dec_tab", mime::qp_decode_allowed_literal(9))
  report(w, "qp_dec_del", !mime::qp_decode_allowed_literal(127))
  report(w, "qp_wrap_75_1", mime::qp_needs_soft_wrap(75, 1))
  report(w, "qp_wrap_74_1", !mime::qp_needs_soft_wrap(74, 1))
  report(w, "qp_wrap_73_3", mime::qp_needs_soft_wrap(73, 3))

  report(w, "tchar_a", mime::is_tchar_byte(97))
  report(w, "tchar_pct", mime::is_tchar_byte(37))
  report(w, "tchar_slash", !mime::is_tchar_byte(47))
  report(w, "tchar_sp", !mime::is_tchar_byte(32))
  report(w, "attr_a", mime::is_attr_char_byte(97))
  report(w, "attr_pct", !mime::is_attr_char_byte(37))
  report(w, "attr_star", !mime::is_attr_char_byte(42))
  report(w, "attr_apos", !mime::is_attr_char_byte(39))
  report(w, "bchar_eq", mime::is_bchar_nospace_byte(61))
  report(w, "bchar_sp", !mime::is_bchar_nospace_byte(32))
  report(w, "bchar_quot", !mime::is_bchar_nospace_byte(34))

  report(w, "sep_slash", mime::is_path_sep_byte(47))
  report(w, "sep_bslash", mime::is_path_sep_byte(92))
  report(w, "sep_a", !mime::is_path_sep_byte(97))
  report(w, "c0_nul", mime::is_filename_c0_or_del(0))
  report(w, "c0_del", mime::is_filename_c0_or_del(127))
  report(w, "c0_sp", !mime::is_filename_c0_or_del(32))
  report(w, "c1_80", mime::is_utf8_c1_pair(194, 128))
  report(w, "c1_a0", !mime::is_utf8_c1_pair(194, 160))
  report(w, "bidi_rlo", mime::is_utf8_bidi_3byte(226, 128, 174))
  report(w, "bidi_lri", mime::is_utf8_bidi_3byte(226, 129, 166))
  report(w, "bidi_ok", !mime::is_utf8_bidi_3byte(226, 128, 160))
  0
}
EOF

"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/mime Lean 4 proofs"
