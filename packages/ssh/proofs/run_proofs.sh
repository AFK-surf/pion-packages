#!/bin/sh
set -eu

export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$PATH"
PROOFS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$PROOFS_DIR/.." && pwd)
WORK="${LEAN_WORK:-/private/tmp/pion-lean-shared}"
PROJ="$WORK/proj"
PION_REF="${PION_LEAN_REF:-$WORK/pion-ref}"
AENEAS_REV=1dc8ad31b1
JOBS="${LEAN_NUM_THREADS:-2}"
MEM="${LEAN_MEM_LIMIT:-8192}"

echo "=== [1/7] Prepare Pion lean/ runtime & Aeneas@$AENEAS_REV in $WORK ==="
mkdir -p "$WORK" "$PROJ/SshProofs"
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
  mkdir -p "$PROJ/.deps" "$PROJ/.lake" "$PROJ/SshProofs"
  (cd "$PION_REF/lean" && tar -cf - --exclude .lake --exclude .deps .) | (cd "$PROJ" && tar -xf -)
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
  (cd "$PROJ" && lake exe cache get)
else
  cp "$PION_REF/lean/lakefile.lean" "$PROJ/lakefile.lean"
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
fi

echo "=== [2/7] pionc extract-lean packages/ssh ==="
pionc extract-lean "$PKG_DIR" --out "$PROJ" --json

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|bv_decide|native_decide)\b|^axiom\b' "$PROOFS_DIR/SshProofs.lean" "$PROOFS_DIR/SshProofs/"; then
  echo "FAIL: forbidden tactic or axiom found" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

cp "$PROOFS_DIR/SshProofs.lean" "$PROJ/SshProofs.lean"
cp "$PROOFS_DIR/SshProofs/"*.lean "$PROJ/SshProofs/"
cp "$PROOFS_DIR/CheckAxioms.lean" "$PROJ/CheckAxiomsSsh.lean"
cp "$PROOFS_DIR/EvalDiff.lean" "$PROJ/EvalDiffSsh.lean"

printf '\nlean_lib Ssh where\n  globs := #[.submodules `Ssh]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$MEM" "$JOBS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib SshProofs where\n  globs := #[.andSubmodules `SshProofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$MEM" "$JOBS" >> "$PROJ/lakefile.lean"

echo "=== [4/7] lake build PionLean Ssh SshProofs ==="
BUILD_LOG="$WORK/ssh_build.log"
(cd "$PROJ" && LEAN_NUM_THREADS="$JOBS" lake build PionLean Ssh SshProofs) > "$BUILD_LOG" 2>&1 || {
  cat "$BUILD_LOG"
  echo "FAIL: lake build failed" >&2
  exit 1
}
cat "$BUILD_LOG"
if grep -qE '^warning:|warning: ' "$BUILD_LOG"; then
  echo "FAIL: warnings found in SshProofs build" >&2
  exit 1
fi
echo "lake build PionLean Ssh SshProofs: exit 0, 0 errors"

echo "=== [5/7] #print axioms audit ==="
AX_OUT=$(cd "$PROJ" && lake env lean --memory="$MEM" -j "$JOBS" CheckAxiomsSsh.lean)
echo "$AX_OUT"
if echo "$AX_OUT" | grep -vE "^'SshProofs\.[a-zA-Z0-9_]+' depends on axioms: \[(propext(, Classical\.choice)?(, Quot\.sound)?|Classical\.choice(, Quot\.sound)?|Quot\.sound)\]$" | grep -vE "^'SshProofs\.[a-zA-Z0-9_]+' does not depend on any axioms$" | grep -q .; then
  echo "FAIL: unexpected axiom detected" >&2
  exit 1
fi
echo "Axioms audit: ONLY standard axioms (propext, Classical.choice, Quot.sound)"

echo "=== [6/7] EvalDiff.lean (#eval) ==="
LEAN_DIFF="$WORK/ssh_lean_diff.txt"
(cd "$PROJ" && lake env lean --memory="$MEM" -j "$JOBS" EvalDiffSsh.lean) > "$LEAN_DIFF"
cat "$LEAN_DIFF"
if grep -q 'FAIL' "$LEAN_DIFF"; then
  echo "FAIL: Lean EvalDiff reported FAIL" >&2
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential cross-check (diff -u) ==="
DIFF_DIR="$WORK/ssh_native_diff"
rm -rf "$DIFF_DIR" && mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/pion.toml" <<EOF
[package]
name = "ssh_diff"
version = "0.1.0"
edition = "2026"

[dependencies]
ssh = { path = "$PKG_DIR" }
EOF
cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "ssh"

fn report(w : World, label : String, ok : Bool) -> Unit {
  if ok {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  report(w, "vc_sp", ssh::is_ssh_version_char(32))
  report(w, "vc_tilde", ssh::is_ssh_version_char(126))
  report(w, "vc_lf", !ssh::is_ssh_version_char(10))
  report(w, "vc_del", !ssh::is_ssh_version_char(127))
  report(w, "pad_0_8", ssh::ssh_packet_padding_len(0, 8, 4) == 11)
  report(w, "pad_3_8", ssh::ssh_packet_padding_len(3, 8, 4) == 8)
  report(w, "pad_7_16", ssh::ssh_packet_padding_len(7, 16, 4) == 4)
  report(w, "pad_8_16", ssh::ssh_packet_padding_len(8, 16, 4) == 19)
  report(w, "hdr_ok", ssh::ssh_packet_header_err_code(16, 12U, 4, 35000) == 0)
  report(w, "hdr_over", ssh::ssh_packet_header_err_code(40000, 35001U, 4, 35000) == 1)
  report(w, "hdr_small", ssh::ssh_packet_header_err_code(16, 4U, 4, 35000) == 2)
  report(w, "hdr_eof", ssh::ssh_packet_header_err_code(15, 12U, 4, 35000) == 3)
  report(w, "hdr_align", ssh::ssh_packet_header_err_code(20, 13U, 4, 35000) == 4)
  report(w, "hdr_pad3", ssh::ssh_packet_header_err_code(16, 12U, 3, 35000) == 5)
  report(w, "hdr_padge", ssh::ssh_packet_header_err_code(16, 12U, 12, 35000) == 6)
  report(w, "ct_u", ssh::cert_type_code(ssh::CertType::User) == 1U)
  report(w, "ct_h", ssh::cert_type_code(ssh::CertType::Host) == 2U)
  let ctf_1 = match ssh::cert_type_from_code(1U) { Some(ssh::CertType::User) => true _ => false }
  let ctf_2 = match ssh::cert_type_from_code(2U) { Some(ssh::CertType::Host) => true _ => false }
  let ctf_0 = match ssh::cert_type_from_code(0U) { None => true _ => false }
  report(w, "ctf_1", ctf_1)
  report(w, "ctf_2", ctf_2)
  report(w, "ctf_0", ctf_0)
  report(w, "tv_ok", ssh::cert_time_valid_code(100UL, 50UL, 200UL) == 0)
  report(w, "tv_early", ssh::cert_time_valid_code(49UL, 50UL, 200UL) == 1)
  report(w, "tv_exp", ssh::cert_time_valid_code(200UL, 50UL, 200UL) == 2)
  report(w, "tv_forever", ssh::cert_time_valid_code(18446744073709551615UL, 50UL, 18446744073709551615UL) == 0)
  report(w, "mask_1", ssh::cidr_rem_mask(1) == 128)
  report(w, "mask_4", ssh::cidr_rem_mask(4) == 240)
  report(w, "mask_7", ssh::cidr_rem_mask(7) == 254)
  report(w, "cm_hit", ssh::cidr_byte_match(0xAB, 0xA0, 4))
  report(w, "cm_miss", !ssh::cidr_byte_match(0xAB, 0xB0, 4))
  0
}
EOF
NATIVE_DIFF="$WORK/ssh_native_diff.txt"
pionc build "$DIFF_DIR" -o "$DIFF_DIR/ssh_diff_bin"
"$DIFF_DIR/ssh_diff_bin" > "$NATIVE_DIFF"
diff -u "$NATIVE_DIFF" "$LEAN_DIFF"
COUNT=$(wc -l < "$LEAN_DIFF" | tr -d ' ')
echo "Native vs Lean differential: $COUNT cases identical (diff -u exit 0)"
echo "PASS: packages/ssh Lean 4 proofs"
