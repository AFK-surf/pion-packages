#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/jwt`.
#
# Builds a throw-away Lake project in /private/tmp/pion-lean-jwt (zero git
# worktree pollution), extracts `packages/jwt` via `pionc extract-lean`,
# compiles `PionLean`, `Jwt`, and `JwtProofs`, rejects any
# `sorry`/`admit`/`native_decide`/`bv_decide`, verifies `#print axioms`
# (only `propext`, `Classical.choice`, `Quot.sound`), and runs `EvalDiff.lean`
# + a Pion native differential cross-check.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_OPTS="${LEAN_OPTS:---memory=8192}"

cleanup() {
  # Terminate any direct child processes started by this script
  pkill -P $$ 2>/dev/null || true
}
trap cleanup EXIT INT TERM

WORK="${LEAN_WORK:-/private/tmp/pion-lean-jwt}"
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

echo "=== [2/7] pionc extract-lean packages/jwt ==="
rm -rf "$PROJ/Jwt"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Jwt/$f.lean" ]; then
    echo "FAIL: missing Jwt/$f.lean" >&2
    exit 1
  fi
done

cp "$SCRIPT_DIR/JwtProofs.lean" "$PROJ/JwtProofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Jwt where\n  globs := #[.submodules `Jwt]\n' >> "$PROJ/lakefile.lean"
printf '\nlean_lib JwtProofs where\n' >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/JwtProofs.lean" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Jwt JwtProofs ==="
cd "$PROJ"
set +e
lake build PionLean Jwt JwtProofs > "$WORK/build.log" 2>&1
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
echo "lake build PionLean Jwt JwtProofs: exit 0, 0 errors"

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

echo "=== [6/7] #eval / #guard on extracted Jwt.Funs ==="
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
name = "jwt_lean_diff"
version = "0.1.0"

[dependencies]
jwt = { path = "$PKG_DIR" }
EOF
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "jwt"

fn report(w : World, name : String, ok : Bool) -> Unit {
  if ok {
    io_println(w, name + ": PASS")
  } else {
    io_println(w, name + ": FAIL")
  }
}

fn alg_ok(s : String, want : jwt::Algorithm) -> Bool {
  match jwt::algorithm_from_str(s) {
    Ok(a) => jwt::algorithm_equals(a, want)
    Err(_) => false
  }
}

fn alg_is_none_err(s : String) -> Bool {
  match jwt::algorithm_from_str(s) {
    Err(jwt::JwtError::AlgorithmNoneNotAllowed) => true
    _ => false
  }
}

fn alg_is_unsupported(s : String) -> Bool {
  match jwt::algorithm_from_str(s) {
    Err(jwt::JwtError::UnsupportedAlgorithm(_)) => true
    _ => false
  }
}

pub fn main(w : World) -> Int {
  let max_i64 : Int64 = 9223372036854775807L
  let min_i64 : Int64 = -9223372036854775807L - 1L

  // 1. Constant-time equality
  report(w, "ct_eq_empty", jwt::constant_time_eq("".to_bytes(), "".to_bytes()))
  report(w, "ct_eq_same", jwt::constant_time_eq("abcdef0123456789".to_bytes(), "abcdef0123456789".to_bytes()))
  report(w, "ct_eq_diff_last", !jwt::constant_time_eq("abcdef0123456789".to_bytes(), "abcdef0123456788".to_bytes()))
  report(w, "ct_eq_diff_first", !jwt::constant_time_eq("abcdef".to_bytes(), "bbcdef".to_bytes()))
  report(w, "ct_eq_diff_len", !jwt::constant_time_eq("abc".to_bytes(), "abcd".to_bytes()))

  // 2. Anti-CVE algorithm & HMAC key gate
  report(w, "alg_hs256", alg_ok("HS256", jwt::Algorithm::HS256))
  report(w, "alg_hs384", alg_ok("HS384", jwt::Algorithm::HS384))
  report(w, "alg_hs512", alg_ok("HS512", jwt::Algorithm::HS512))
  report(w, "alg_reject_none_lower", alg_is_none_err("none"))
  report(w, "alg_reject_none_title", alg_is_none_err("None"))
  report(w, "alg_reject_none_upper", alg_is_none_err("NONE"))
  report(w, "alg_reject_none_mixed", alg_is_none_err("nOnE"))
  report(w, "alg_reject_rs256", alg_is_unsupported("RS256"))
  report(w, "alg_reject_empty", alg_is_unsupported(""))
  report(w, "hmac_key_reject_empty", !jwt::hmac_key_valid("".to_bytes()))
  report(w, "hmac_key_accept_nonempty", jwt::hmac_key_valid("k".to_bytes()))
  let empty_algs : Array[jwt::Algorithm] = []
  let hs256_only : Array[jwt::Algorithm] = [jwt::Algorithm::HS256]
  let hs_256_512 : Array[jwt::Algorithm] = [jwt::Algorithm::HS256, jwt::Algorithm::HS512]
  report(w, "allowlist_empty", !jwt::alg_in_allowlist(jwt::Algorithm::HS256, empty_algs))
  report(w, "allowlist_hit", jwt::alg_in_allowlist(jwt::Algorithm::HS512, hs_256_512))
  report(w, "allowlist_miss", !jwt::alg_in_allowlist(jwt::Algorithm::HS384, hs_256_512))
  report(w, "verifier_alg_match", jwt::check_verifier_alg(jwt::Algorithm::HS256, jwt::Algorithm::HS256, hs256_only))
  report(w, "verifier_alg_mismatch", !jwt::check_verifier_alg(jwt::Algorithm::HS256, jwt::Algorithm::HS512, hs_256_512))

  // 3. Saturating exp / nbf time-window & leeway overflow immunity
  report(w, "exp_exact_boundary", jwt::is_expired(1000L, 1000L, 0L))
  report(w, "exp_before_expiry", !jwt::is_expired(999L, 1000L, 0L))
  report(w, "exp_within_leeway", !jwt::is_expired(1005L, 1000L, 10L))
  report(w, "exp_past_leeway", jwt::is_expired(1010L, 1000L, 10L))
  report(w, "exp_neg_leeway_clamped", jwt::is_expired(1000L, 1000L, -50L))
  report(w, "exp_min_i64_no_wrap", jwt::is_expired(min_i64, min_i64, max_i64))
  report(w, "exp_max_i64_no_wrap", !jwt::is_expired(0L, max_i64, max_i64))
  report(w, "nbf_exact_boundary", !jwt::is_immature(1000L, 1000L, 0L))
  report(w, "nbf_before_valid", jwt::is_immature(999L, 1000L, 0L))
  report(w, "nbf_within_leeway", !jwt::is_immature(995L, 1000L, 10L))
  report(w, "nbf_outside_leeway", jwt::is_immature(989L, 1000L, 10L))
  report(w, "nbf_max_i64_no_wrap", !jwt::is_immature(max_i64, max_i64, max_i64))
  report(w, "nbf_min_i64_no_wrap", jwt::is_immature(min_i64, 0L, 100L))

  // 4. Strict unpadded Base64URL character encode/decode & canonical tail bits
  let mut rt_ok = true
  let mut v = 0
  while v < 64 {
    if jwt::b64url_decode_byte(jwt::b64url_encode_val(v)) != v {
      rt_ok = false
    }
    v = v + 1
  }
  report(w, "b64url_64_roundtrip", rt_ok)
  report(w, "b64url_reject_plus", jwt::b64url_decode_byte((43).to_byte()) == -1)
  report(w, "b64url_reject_slash", jwt::b64url_decode_byte((47).to_byte()) == -1)
  report(w, "b64url_reject_pad", jwt::b64url_decode_byte((61).to_byte()) == -1)
  report(w, "b64url_reject_space", jwt::b64url_decode_byte((32).to_byte()) == -1)
  report(w, "b64url_reject_nul", jwt::b64url_decode_byte((0).to_byte()) == -1)
  report(w, "b64url_len_mod4_eq1_reject", !jwt::base64url_len_valid(1) && !jwt::base64url_len_valid(5))
  report(w, "b64url_len_valid_0234", jwt::base64url_len_valid(0) && jwt::base64url_len_valid(2) && jwt::base64url_len_valid(3) && jwt::base64url_len_valid(4))
  report(w, "b64url_tail_rem2_ok", jwt::base64url_tail_bits_valid(2, 0x30))
  report(w, "b64url_tail_rem2_bad", !jwt::base64url_tail_bits_valid(2, 0x31))
  report(w, "b64url_tail_rem3_ok", jwt::base64url_tail_bits_valid(3, 0x3C))
  report(w, "b64url_tail_rem3_bad", !jwt::base64url_tail_bits_valid(3, 0x3D))

  // 5. SHA-256 bitwise primitives
  report(w, "sha256_ch_same", jwt::sha256_ch(0x12345678U, 0xDEADBEEFU, 0xDEADBEEFU) == 0xDEADBEEFU)
  report(w, "sha256_maj_same", jwt::sha256_maj(0xCAFEBABEU, 0xCAFEBABEU, 0x11223344U) == 0xCAFEBABEU)
  report(w, "sha256_rotr_compose", jwt::sha256_rotr(jwt::sha256_rotr(0x12345678U, 7U), 11U) == jwt::sha256_rotr(0x12345678U, 18U))
  0
}
EOF

"$PIONC" build -o "$DIFF_DIR/diff_bin" "$DIFF_DIR" >/dev/null
"$DIFF_DIR/diff_bin" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native Pion vs Lean EvalDiff: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/jwt Lean 4 proofs"
