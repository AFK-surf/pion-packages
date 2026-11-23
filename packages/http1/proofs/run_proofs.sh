#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/http1`.
#
# Builds a throw-away Lake project in /private/tmp/pion-lean-http1 (zero git
# worktree pollution), extracts `packages/http1` via `pionc extract-lean`,
# compiles `PionLean`, `Http1`, and `Http1Proofs`, rejects any
# `sorry`/`admit`/`native_decide`/`bv_decide`, verifies `#print axioms`
# (only `propext`, `Classical.choice`, `Quot.sound`), and runs `EvalDiff.lean`
# + a Pion native differential cross-check (`diff -u`).

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

WORK="${LEAN_WORK:-/private/tmp/pion-lean-http1}"
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

echo "=== [2/7] pionc extract-lean packages/http1 ==="
rm -rf "$PROJ/Http1"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Http1/$f.lean" ]; then
    echo "FAIL: missing Http1/$f.lean" >&2
    exit 1
  fi
done

rm -rf "$PROJ/Http1Proofs"
cp -R "$SCRIPT_DIR/Http1Proofs" "$PROJ/Http1Proofs"
cp "$SCRIPT_DIR/Http1Proofs.lean" "$PROJ/Http1Proofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Http1 where\n  globs := #[.submodules `Http1]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib Http1Proofs where\n  globs := #[.andSubmodules `Http1Proofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/Http1Proofs.lean" "$SCRIPT_DIR/Http1Proofs" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Http1 Http1Proofs ==="
cd "$PROJ"
set +e
lake build PionLean Http1 Http1Proofs > "$WORK/build.log" 2>&1
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
echo "lake build PionLean Http1 Http1Proofs: exit 0, 0 errors"

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
EVAL_OUT=$(lake env lean --memory="$LEAN_MEM_LIMIT" -j "$LEAN_NUM_THREADS" EvalDiff.lean 2>&1)
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
name = "http1_lean_diff"
version = "0.1.0"

[dependencies]
http1 = { path = "$PKG_DIR" }
EOF
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "http1"

fn report(w : World, name : String, ok : Bool) -> Unit {
  if ok {
    io_println(w, name + ": PASS")
  } else {
    io_println(w, name + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  report(w, "tchar_A", http1::is_tchar_byte(65) == true)
  report(w, "tchar_sp_false", http1::is_tchar_byte(32) == false)
  report(w, "tchar_cr_false", http1::is_tchar_byte(13) == false)
  report(w, "uri_slash", http1::is_uri_byte(47) == true)
  report(w, "uri_sp_false", http1::is_uri_byte(32) == false)
  report(w, "hdrval_htab", http1::is_header_val_byte(9) == true)
  report(w, "hdrval_obstext", http1::is_header_val_byte(200) == true)
  report(w, "hdrval_cr_false", http1::is_header_val_byte(13) == false)
  report(w, "hdrval_nul_false", http1::is_header_val_byte(0) == false)
  report(w, "hex_0", http1::hex_digit_value(48) == 0)
  report(w, "hex_F", http1::hex_digit_value(70) == 15)
  report(w, "hex_f", http1::hex_digit_value(102) == 15)
  report(w, "hex_g_neg1", http1::hex_digit_value(103) == -1)
  report(w, "lower_Z", http1::ascii_lower_byte(90) == 122)
  report(w, "lower_a", http1::ascii_lower_byte(97) == 97)
  report(w, "bodyless_101", http1::is_bodyless_status(101) == true)
  report(w, "bodyless_204", http1::is_bodyless_status(204) == true)
  report(w, "bodyless_304", http1::is_bodyless_status(304) == true)
  report(w, "bodyless_200_false", http1::is_bodyless_status(200) == false)
  report(
    w,
    "eff_framing_204",
    match http1::effective_response_framing(204, http1::Framing::ContentLength(99L)) {
      http1::Framing::None => true
      _ => false
    },
  )
  report(
    w,
    "eff_framing_200",
    match http1::effective_response_framing(200, http1::Framing::ContentLength(99L)) {
      http1::Framing::ContentLength(v) => v == 99L
      _ => false
    },
  )
  report(w, "te_after_chunked_neg1", http1::te_coding_step(1, true, false) == -1)
  report(w, "te_gzip_then_chunked", http1::te_coding_step(0, true, false) == 1)
  report(w, "minor_0", http1::parse_http_minor(48) == 0)
  report(w, "minor_1", http1::parse_http_minor(49) == 1)
  report(w, "minor_x", http1::parse_http_minor(120) == -1)
  report(w, "status_200", http1::parse_status_digits(50, 48, 48) == 200)
  report(w, "status_bad", http1::parse_status_digits(50, 65, 48) == -1)
  report(w, "u63_step_ok", http1::u63_decimal_step(123L, 52) == 1234L)
  report(w, "u63_step_max_ok", http1::u63_decimal_step(922337203685477580L, 55) == 9223372036854775807L)
  report(w, "u63_step_max_ovf", http1::u63_decimal_step(922337203685477580L, 56) == -1L)
  report(w, "chunk_hex_ok", http1::chunk_size_hex_step(16L, 2, 10) == 266L)
  report(w, "chunk_hex_16dig_err", http1::chunk_size_hex_step(0L, 16, 1) == -1L)
  report(w, "chunk_hex_ovf", http1::chunk_size_hex_step(576460752303423488L, 15, 0) == -2L)
  report(w, "smuggle_cl_after_te", http1::check_framing_cl(true, false, 5L) == 1)
  report(w, "smuggle_te_after_cl", http1::check_framing_te(true, http1::Version::Http11, 1) == 1)
  report(w, "smuggle_http10_te", http1::check_framing_te(false, http1::Version::Http10, 1) == 2)
  report(w, "smuggle_dup_host", http1::check_framing_host(1, true) == 1)
  report(w, "finalize_missing_host", http1::check_framing_finalize(false, false, 0, 0, true, http1::Version::Http11) == -1)
  report(w, "finalize_chunked_ok", http1::check_framing_finalize(false, true, 1, 1, true, http1::Version::Http11) == 2)
  report(w, "finalize_cl_ok", http1::check_framing_finalize(true, false, 0, 1, true, http1::Version::Http11) == 1)
  0
}
EOF
"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/http1 Lean 4 proofs"
