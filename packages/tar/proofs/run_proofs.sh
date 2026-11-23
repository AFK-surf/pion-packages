#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/tar`.
#
# Builds a throw-away Lake project in /private/tmp/pion-lean-tar (zero git
# worktree pollution), extracts `packages/tar` via `pionc extract-lean`,
# compiles `PionLean`, `Tar`, and `TarProofs`, rejects any
# `sorry`/`admit`/`native_decide`/`bv_decide`, verifies `#print axioms`
# (only `propext`, `Classical.choice`, `Quot.sound`), and runs `EvalDiff.lean`
# + a Pion native differential cross-check.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"

WORK="${LEAN_WORK:-/private/tmp/pion-lean-tar}"
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
  # Refresh lakefile.lean cleanly from pion/lean so we never duplicate lean_lib blocks
  cp "$PION_REF/lean/lakefile.lean" "$PROJ/lakefile.lean"
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
fi

echo "=== [2/7] pionc extract-lean packages/tar ==="
rm -rf "$PROJ/Tar"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Tar/$f.lean" ]; then
    echo "FAIL: missing Tar/$f.lean" >&2
    exit 1
  fi
done

cp "$SCRIPT_DIR/TarProofs.lean" "$PROJ/TarProofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Tar where\n  globs := #[.submodules `Tar]\n' >> "$PROJ/lakefile.lean"
printf '\nlean_lib TarProofs where\n' >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/TarProofs.lean" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Tar TarProofs ==="
cd "$PROJ"
set +e
lake build PionLean Tar TarProofs > "$WORK/build.log" 2>&1
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
echo "lake build PionLean Tar TarProofs: exit 0, 0 errors"

echo "=== [5/7] #print axioms audit ==="
set +e
AXIOMS_OUT=$(lake env lean CheckAxioms.lean 2>&1)
RC=$?
set -e
printf '%s\n' "$AXIOMS_OUT"
if [ "$RC" -ne 0 ]; then
  echo "FAIL: CheckAxioms.lean (rc=$RC)" >&2
  exit 1
fi
EXPECTED_THMS=$(grep -c '^#print axioms' "$PROJ/CheckAxioms.lean")
printf '%s\n' "$AXIOMS_OUT" | python3 -c '
import re, sys
text = sys.stdin.read()
expected = int(sys.argv[1])
allowed = {"propext", "Classical.choice", "Quot.sound"}
found = re.findall(r"^\x27([^\x27]+)\x27 depends on axioms: \[([^\]]*)\]", text, re.M)
free = re.findall(r"^\x27([^\x27]+)\x27 does not depend on any axioms", text, re.M)
bad = [(n, sorted(set(a.replace(",", " ").split()) - allowed)) for n, a in found
       if set(a.replace(",", " ").split()) - allowed]
if bad or len(found) + len(free) != expected:
    print("FAIL: axioms: non-standard=%r, checked %d of %d" % (bad, len(found) + len(free), expected), file=sys.stderr)
    sys.exit(1)
print("axioms: %d theorems verified, only propext / Classical.choice / Quot.sound" % expected)
' "$EXPECTED_THMS"

echo "=== [6/7] #eval / #guard on extracted Tar.Funs ==="
set +e
EVAL_OUT=$(lake env lean EvalDiff.lean 2>&1)
RC=$?
set -e
printf '%s\n' "$EVAL_OUT"
if [ "$RC" -ne 0 ] || printf '%s' "$EVAL_OUT" | grep -q 'error\|FAIL'; then
  echo "FAIL: EvalDiff.lean (rc=$RC)" >&2
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential check ==="
DIFF_DIR="$WORK/native_diff"
rm -rf "$DIFF_DIR"
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/pion.toml" <<EOF
[package]
name = "tar_lean_diff"
version = "0.1.0"

[dependencies]
tar = { path = "$PKG_DIR" }
EOF
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "tar"

fn report(w : World, name : String, ok : Bool) -> Unit {
  if ok {
    io_println(w, name + ": PASS")
  } else {
    io_println(w, name + ": FAIL")
  }
}

fn hex_val(c : Int) -> Int {
  if c >= 48 && c <= 57 {
    c - 48
  } else if c >= 97 && c <= 102 {
    c - 87
  } else {
    c - 55
  }
}

fn hex_bytes(hex : String) -> Bytes {
  let n = hex.length() / 2
  let out = Bytes::new(n)
  let mut i = 0
  while i < n {
    let hi = hex_val(hex.code_unit_at(i * 2))
    let lo = hex_val(hex.code_unit_at(i * 2 + 1))
    out[i] = (hi * 16 + lo).to_byte()
    i = i + 1
  }
  out
}

fn parse_ok_eq(b : Bytes, want : Int64) -> Bool {
  match tar::parse_numeric(b) {
    Ok(v) => v == want
    Err(_) => false
  }
}

fn parse_is_err(b : Bytes) -> Bool {
  match tar::parse_numeric(b) {
    Ok(_) => false
    Err(_) => true
  }
}

fn roundtrip_eq(width : Int, x : Int64) -> Bool {
  match tar::format_numeric(width, x) {
    Ok(b) => parse_ok_eq(b, x)
    Err(_) => false
  }
}

pub fn main(w : World) -> Int {
  let max_i64 : Int64 = 9223372036854775807L
  let min_i64 : Int64 = -9223372036854775807L - 1L

  // 1. Zip-Slip & extraction path safety
  report(w, "path_valid_simple", tar::validate_extract_path_bytes("a/b/c.txt".to_bytes()))
  report(w, "path_valid_dots_in_name", tar::validate_extract_path_bytes("a..b/.../c".to_bytes()))
  report(w, "path_reject_empty", !tar::validate_extract_path_bytes("".to_bytes()))
  report(w, "path_reject_dot", !tar::validate_extract_path_bytes(".".to_bytes()))
  report(w, "path_reject_dotdot", !tar::validate_extract_path_bytes("../etc/passwd".to_bytes()))
  report(w, "path_reject_mid_dotdot", !tar::validate_extract_path_bytes("a/b/../c".to_bytes()))
  report(w, "path_reject_win_dotdot", !tar::validate_extract_path_bytes("a\\..\\b".to_bytes()))
  report(w, "path_reject_abs_unix", !tar::validate_extract_path_bytes("/etc/passwd".to_bytes()))
  report(w, "path_reject_abs_win", !tar::validate_extract_path_bytes("\\etc\\passwd".to_bytes()))
  report(w, "path_reject_drive", !tar::validate_extract_path_bytes("C:/Windows/win.ini".to_bytes()))
  report(w, "path_reject_ads", !tar::validate_extract_path_bytes("file.txt::$DATA".to_bytes()))
  report(w, "path_reject_nul", !tar::validate_extract_path_bytes(hex_bytes("666f6f00626172")))
  report(w, "path_reject_con", !tar::validate_extract_path_bytes("dir/con.txt".to_bytes()))
  report(w, "path_reject_com1", !tar::validate_extract_path_bytes("COM1".to_bytes()))
  report(w, "path_reject_lpt9", !tar::validate_extract_path_bytes("x/lpt9.bin".to_bytes()))

  // 2. 512-byte block alignment
  report(w, "padded_zero", tar::padded_size(0L) == 0L)
  report(w, "padded_1", tar::padded_size(1L) == 512L)
  report(w, "padded_512", tar::padded_size(512L) == 512L)
  report(w, "padded_513", tar::padded_size(513L) == 1024L)
  report(w, "padded_max_safe", tar::padded_size(9223372036854775296L) == 9223372036854775296L)

  // 3. Octal & GNU base-256 numeric parsing / formatting / roundtrip
  report(w, "fits_octal_neg_false", !tar::fits_in_octal(12, -1L))
  report(w, "fits_octal_8_max", tar::fits_in_octal(8, 2097151L) && !tar::fits_in_octal(8, 2097152L))
  report(w, "fits_b256_9_extremes", tar::fits_in_base256(9, max_i64) && tar::fits_in_base256(9, min_i64))
  report(w, "parse_octal_0644", parse_ok_eq("0000644\u{0000}".to_bytes(), 420L))
  report(w, "parse_octal_bad_digit", parse_is_err("0000648\u{0000}".to_bytes()))
  report(w, "parse_octal_overflow", parse_is_err("7777777777777777777777".to_bytes()))
  report(w, "parse_b256_max", parse_ok_eq(hex_bytes("807fffffffffffffff"), max_i64))
  report(w, "parse_b256_min", parse_ok_eq(hex_bytes("ff8000000000000000"), min_i64))
  report(w, "parse_b256_overflow_pos", parse_is_err(hex_bytes("808000000000000000")))
  report(w, "parse_b256_overflow_neg", parse_is_err(hex_bytes("ff7fffffffffffffff")))
  report(w, "roundtrip_octal_12", roundtrip_eq(12, 8589934591L))
  report(w, "roundtrip_b256_12_max", roundtrip_eq(12, max_i64))
  report(w, "roundtrip_b256_12_min", roundtrip_eq(12, min_i64))
  report(w, "roundtrip_b256_8_neg1", roundtrip_eq(8, -1L))

  // 4. Typeflags & TarFormat
  report(w, "type_dir_header_only", tar::is_header_only_type(tar::type_dir()))
  report(w, "type_reg_not_header_only", !tar::is_header_only_type(tar::type_reg()))
  report(w, "format_eq_refl", tar::format_equals(tar::TarFormat::Pax, tar::TarFormat::Pax))
  report(w, "format_eq_ne", !tar::format_equals(tar::TarFormat::Ustar, tar::TarFormat::Gnu))
  0
}
EOF
"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/tar Lean 4 proofs"
