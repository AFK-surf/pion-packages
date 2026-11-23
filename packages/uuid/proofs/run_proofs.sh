#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/uuid`.
#
# Builds a throw-away Lake project in /private/tmp/pion-lean-uuid (zero git
# worktree pollution), extracts `packages/uuid` via `pionc extract-lean`,
# compiles `PionLean`, `Uuid`, and `UuidProofs`, rejects any
# `sorry`/`admit`/`native_decide`/`bv_decide`, verifies `#print axioms`
# (only `propext`, `Classical.choice`, `Quot.sound`), and runs `EvalDiff.lean`
# + a Pion native differential cross-check.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"

WORK="${LEAN_WORK:-/private/tmp/pion-lean-uuid}"
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

echo "=== [2/7] pionc extract-lean packages/uuid ==="
rm -rf "$PROJ/Uuid"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Uuid/$f.lean" ]; then
    echo "FAIL: missing Uuid/$f.lean" >&2
    exit 1
  fi
done

cp "$SCRIPT_DIR/UuidProofs.lean" "$PROJ/UuidProofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Uuid where\n  globs := #[.submodules `Uuid]\n' >> "$PROJ/lakefile.lean"
printf '\nlean_lib UuidProofs where\n' >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/UuidProofs.lean" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Uuid UuidProofs ==="
cd "$PROJ"
set +e
lake build PionLean Uuid UuidProofs > "$WORK/build.log" 2>&1
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
echo "lake build PionLean Uuid UuidProofs: exit 0, 0 errors"

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

echo "=== [6/7] #eval / #guard on extracted Uuid.Funs ==="
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
name = "uuid_lean_diff"
version = "0.1.0"

[dependencies]
uuid = { path = "$PKG_DIR" }
EOF
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "uuid"

fn report(w : World, name : String, ok : Bool) -> Unit {
  if ok {
    io_println(w, name + ": PASS")
  } else {
    io_println(w, name + ": FAIL")
  }
}

fn ver_is(u : uuid::Uuid, tag : String) -> Bool {
  match u.version() {
    uuid::UuidVersion::Nil => tag == "Nil"
    uuid::UuidVersion::Mac => tag == "Mac"
    uuid::UuidVersion::Dce => tag == "Dce"
    uuid::UuidVersion::Md5 => tag == "Md5"
    uuid::UuidVersion::Random => tag == "Random"
    uuid::UuidVersion::Sha1 => tag == "Sha1"
    uuid::UuidVersion::SortMac => tag == "SortMac"
    uuid::UuidVersion::SortRand => tag == "SortRand"
    uuid::UuidVersion::Custom => tag == "Custom"
    uuid::UuidVersion::Max => tag == "Max"
    uuid::UuidVersion::Unknown(_) => false
  }
}

fn var_rfc(u : uuid::Uuid) -> Bool {
  match u.variant() {
    uuid::UuidVariant::Rfc4122 => true
    _ => false
  }
}

pub fn main(w : World) -> Int {
  let max_ts : Int64 = 281474976710655L

  report(w, "uuid_nil_max_order",
    uuid::Uuid::nil().compare(uuid::Uuid::max()) == -1 &&
    uuid::Uuid::max().compare(uuid::Uuid::nil()) == 1)

  let a = uuid::Uuid::from_u64_pair(0x7FFFFFFFFFFFFFFFUL, 0xFFFFFFFFFFFFFFFFUL)
  let b = uuid::Uuid::from_u64_pair(0x8000000000000000UL, 0UL)
  report(w, "uuid_unsigned_sign_boundary", a.compare(b) == -1)

  let node6 = Bytes::new(6)
  node6[0] = (1).to_byte(); node6[1] = (2).to_byte(); node6[2] = (3).to_byte()
  node6[3] = (4).to_byte(); node6[4] = (5).to_byte(); node6[5] = (6).to_byte()
  let v1_ok = match uuid::Uuid::new_v1(0x01B21DD213814000L, 0x1234, node6) {
    Ok(u) => ver_is(u, "Mac") && var_rfc(u)
    Err(_) => false
  }
  report(w, "uuid_v1_ver_var", v1_ok)

  let v3_u = uuid::Uuid::new_v3(uuid::NAMESPACE_DNS, Bytes::new(0))
  report(w, "uuid_v3_ver_var", ver_is(v3_u, "Md5") && var_rfc(v3_u))

  let v4_u = uuid::Uuid::new_v4_from_u64_pair(0UL, 0UL)
  report(w, "uuid_v4_ver_var", ver_is(v4_u, "Random") && var_rfc(v4_u))

  let v5_u = uuid::Uuid::new_v5(uuid::NAMESPACE_DNS, Bytes::new(0))
  report(w, "uuid_v5_ver_var", ver_is(v5_u, "Sha1") && var_rfc(v5_u))

  let node6b = Bytes::new(6)
  node6b[0] = (0xAA).to_byte(); node6b[1] = (0xBB).to_byte(); node6b[2] = (0xCC).to_byte()
  node6b[3] = (0xDD).to_byte(); node6b[4] = (0xEE).to_byte(); node6b[5] = (0xFF).to_byte()
  let v6_ok = match uuid::Uuid::new_v6(0x01B21DD213814000L, 0x3FFF, node6b) {
    Ok(u) => ver_is(u, "SortMac") && var_rfc(u)
    Err(_) => false
  }
  report(w, "uuid_v6_ver_var", v6_ok)

  let v7_zero_ok = match uuid::Uuid::new_v7_from_parts(0L, 0, 0L) {
    Ok(u) => ver_is(u, "SortRand") && var_rfc(u) && match u.timestamp_ms() { Some(t) => t == 0L, None => false }
    Err(_) => false
  }
  let v7_max_ok = match uuid::Uuid::new_v7_from_parts(max_ts, 0xFFF, -1L) {
    Ok(u) => ver_is(u, "SortRand") && var_rfc(u) && match u.timestamp_ms() { Some(t) => t == max_ts, None => false }
    Err(_) => false
  }
  report(w, "uuid_v7_ts_zero_and_max", v7_zero_ok && v7_max_ok)

  let v7_mono = match (uuid::Uuid::new_v7_from_parts(1000L, 0xFFF, -1L), uuid::Uuid::new_v7_from_parts(1001L, 0, 0L)) {
    (Ok(u1), Ok(u2)) => u1.compare(u2) == -1
    _ => false
  }
  report(w, "uuid_v7_strict_monotonic", v7_mono)

  let custom16 = Bytes::new(16)
  let mut ci = 0
  while ci < 16 {
    custom16[ci] = ci.to_byte()
    ci = ci + 1
  }
  let v8_ok = match uuid::Uuid::new_v8(custom16) {
    Ok(u) => ver_is(u, "Custom") && var_rfc(u)
    Err(_) => false
  }
  report(w, "uuid_v8_ver_var", v8_ok)

  let ulid_zero_ok = match uuid::Ulid::from_parts(0L, 0L, 0L) {
    Ok(u) => {
      let (rh, rl) = u.random_parts()
      u.timestamp_ms() == 0L && rh == 0L && rl == 0L
    }
    Err(_) => false
  }
  let ulid_max_ok = match uuid::Ulid::from_parts(max_ts, 0xFFFFL, -1L) {
    Ok(u) => {
      let (rh, rl) = u.random_parts()
      u.timestamp_ms() == max_ts && rh == 0xFFFFL && rl == -1L
    }
    Err(_) => false
  }
  report(w, "ulid_ts_zero_and_max", ulid_zero_ok && ulid_max_ok)

  let ulid_rej_neg = match uuid::Ulid::from_parts(-1L, 0L, 0L) {
    Err(uuid::UlidError::InvalidTimestamp(_)) => true
    _ => false
  }
  let ulid_rej_big = match uuid::Ulid::from_parts(281474976710656L, 0L, 0L) {
    Err(uuid::UlidError::InvalidTimestamp(_)) => true
    _ => false
  }
  report(w, "ulid_reject_invalid_ts", ulid_rej_neg && ulid_rej_big)

  let ulid_mono = match (uuid::Ulid::from_parts(0L, 0xFFFFL, -1L), uuid::Ulid::from_parts(1L, 0L, 0L)) {
    (Ok(u1), Ok(u2)) => u1.compare(u2) == -1
    _ => false
  }
  report(w, "ulid_strict_monotonic", ulid_mono)

  let ulid_inc_ok = match uuid::Ulid::from_parts(42L, 1L, -1L) {
    Ok(u) => match u.increment() {
      Ok(u2) => u2.timestamp_ms() == 42L && u.compare(u2) == -1
      Err(_) => false
    }
    Err(_) => false
  }
  let ulid_inc_ovf = match uuid::Ulid::from_parts(42L, 0xFFFFL, -1L) {
    Ok(u) => match u.increment() {
      Err(uuid::UlidError::Overflow) => true
      _ => false
    }
    Err(_) => false
  }
  report(w, "ulid_increment_carry_and_overflow", ulid_inc_ok && ulid_inc_ovf)

  // Verify hex & Crockford codecs via public parse/format roundtrip + alias / strict checks
  let hex_ok = match uuid::Uuid::parse("01234567-89ab-cdef-0123-456789ABCDEF") {
    Ok(u) => u.to_hyphenated() == "01234567-89ab-cdef-0123-456789abcdef" &&
             u.to_hyphenated_upper() == "01234567-89AB-CDEF-0123-456789ABCDEF"
    Err(_) => false
  }
  report(w, "hex_roundtrip_0_15", hex_ok)

  let ulid_rt = match uuid::Ulid::parse("0123456789ABCDEFGHJKMNPQRS") {
    Ok(u) => u.to_string() == "0123456789ABCDEFGHJKMNPQRS"
    Err(_) => false
  }
  let ulid_rt2 = match uuid::Ulid::parse("7TVWXYZ0123456789ABCDEFGHJ") {
    Ok(u) => u.to_string() == "7TVWXYZ0123456789ABCDEFGHJ"
    Err(_) => false
  }
  report(w, "crockford_roundtrip_0_31", ulid_rt && ulid_rt2)

  let alias_ok = match uuid::Ulid::parse("00000000000000000000IiLlOo") {
    Ok(u) => u.to_string() == "00000000000000000000111100"
    Err(_) => false
  }
  let strict_rej = match uuid::Ulid::parse_strict("00000000000000000000IiLlOo") {
    Err(_) => true
    Ok(_) => false
  }
  report(w, "crockford_aliases_and_strict", alias_ok && strict_rej)

  let rej_u = match uuid::Ulid::parse("0000000000000000000000000U") {
    Err(_) => true
    Ok(_) => false
  }
  let rej_u_low = match uuid::Ulid::parse("0000000000000000000000000u") {
    Err(_) => true
    Ok(_) => false
  }
  let rej_dash = match uuid::Ulid::parse("0000000000000000000000000-") {
    Err(_) => true
    Ok(_) => false
  }
  report(w, "crockford_reject_u_and_invalid", rej_u && rej_u_low && rej_dash)
  0
}
EOF
"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/uuid Lean 4 proofs"
