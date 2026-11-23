#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/dns`.
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

echo "=== [2/7] pionc extract-lean packages/dns ==="
rm -rf "$PROJ/Dns"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Dns/$f.lean" ]; then
    echo "FAIL: missing Dns/$f.lean" >&2
    exit 1
  fi
done

rm -rf "$PROJ/DnsProofs"
cp -R "$SCRIPT_DIR/DnsProofs" "$PROJ/DnsProofs"
cp "$SCRIPT_DIR/DnsProofs.lean" "$PROJ/DnsProofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Dns where\n  globs := #[.submodules `Dns]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib DnsProofs where\n  globs := #[.andSubmodules `DnsProofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/DnsProofs.lean" "$SCRIPT_DIR/DnsProofs" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Dns DnsProofs ==="
cd "$PROJ"
set +e
lake build PionLean Dns DnsProofs > "$WORK/build.log" 2>&1
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
echo "lake build PionLean Dns DnsProofs: exit 0, 0 errors"

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
name = "dns_lean_diff"
version = "0.1.0"

[dependencies]
dns = { path = "$PKG_DIR" }
EOF

cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "dns"

fn report(w : World, label : String, passed : Bool) -> Unit {
  if passed {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  report(w, "lim_def_ptrs", dns::DecodeLimits::default().max_pointers == 128)
  report(w, "lim_strict_trail", !dns::DecodeLimits::strict().allow_trailing_bytes)
  report(w, "enc_opt_def", dns::EncodeOptions::default().compress)
  report(w, "enc_opt_uncomp", !dns::EncodeOptions::uncompressed().compress)
  let a = dns::Ipv4Addr::new(1, 1, 1, 1)
  let b = dns::Ipv4Addr::new(257, 1, 1, 1)
  report(w, "ipv4_eq_true", a.eq(b))
  let v6a = dns::Ipv6Addr::{ hi: 0UL, lo: 1UL }
  let v6b = dns::Ipv6Addr::{ hi: 0UL, lo: 2UL }
  report(w, "ipv6_eq_false", !v6a.eq(v6b))
  report(w, "is_u8_255", dns::is_u8(255))
  report(w, "is_u8_256", !dns::is_u8(256))
  report(w, "is_u16_max", dns::is_u16(65535))
  report(w, "is_u16_neg", !dns::is_u16(-1))
  report(w, "is_u32_max", dns::is_u32(4294967295L))
  report(w, "is_u32_over", !dns::is_u32(4294967296L))

  report(w, "lower_A", dns::ascii_lower_byte(65) == 97)
  report(w, "lower_Z", dns::ascii_lower_byte(90) == 122)
  report(w, "lower_a", dns::ascii_lower_byte(97) == 97)
  report(w, "digit_0", dns::is_ascii_digit(48))
  report(w, "digit_slash", !dns::is_ascii_digit(47))
  report(w, "hex_F", dns::hex_val(70) == 15)
  report(w, "hex_bad", dns::hex_val(71) == -1)
  report(w, "b64_A", dns::b64url_val(65) == 0)
  report(w, "b64_z", dns::b64url_val(122) == 51)
  report(w, "b64_0", dns::b64url_val(48) == 52)
  report(w, "b64_dash", dns::b64url_val(45) == 62)
  report(w, "b64_under", dns::b64url_val(95) == 63)
  report(w, "b64_plus_bad", dns::b64url_val(43) == -1)

  report(w, "hdr_hi_pack", dns::pack_header_flags_hi(true, 5, true, false, true) == 173)
  report(w, "hdr_hi_qr", dns::unpack_header_qr(173))
  report(w, "hdr_hi_op", dns::unpack_header_opcode(173) == 5)
  report(w, "hdr_hi_aa", dns::unpack_header_aa(173))
  report(w, "hdr_hi_tc", !dns::unpack_header_tc(173))
  report(w, "hdr_hi_rd", dns::unpack_header_rd(173))
  report(w, "hdr_lo_pack", dns::pack_header_flags_lo(true, false, true, true, 3) == 179)
  report(w, "hdr_lo_ra", dns::unpack_header_ra(179))
  report(w, "hdr_lo_z", !dns::unpack_header_z(179))
  report(w, "hdr_lo_ad", dns::unpack_header_ad(179))
  report(w, "hdr_lo_cd", dns::unpack_header_cd(179))
  report(w, "hdr_lo_rcode", dns::unpack_header_rcode(179) == 3)

  report(w, "edns_ext_rt", dns::edns_ttl_ext_rcode(dns::edns_pack_ttl(1, 0, true)) == 1)
  report(w, "edns_ver_rt", dns::edns_ttl_version(dns::edns_pack_ttl(1, 2, true)) == 2)
  report(w, "edns_do_t", dns::edns_ttl_dnssec_ok(dns::edns_pack_ttl(1, 0, true)))
  report(w, "edns_do_f", !dns::edns_ttl_dnssec_ok(dns::edns_pack_ttl(1, 0, false)))
  report(w, "edns_badvers", dns::combine_extended_rcode(1, 0) == 16)
  report(w, "edns_badcookie", dns::combine_extended_rcode(1, 7) == 23)
  0
}
EOF

"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/dns Lean 4 proofs"
