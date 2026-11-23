#!/usr/bin/env bash
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

LEAN_WORK="${LEAN_WORK:-/private/tmp/pion-lean-shared}"
LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"
PROJ="$LEAN_WORK/proj"

echo "=== [1/7] Prepare Pion lean/ runtime & Aeneas in $LEAN_WORK ==="
mkdir -p "$PROJ"
if [ ! -d "$PROJ/PionLean" ]; then
  if [ -d /private/tmp/pion-lean-ref/PionLean ]; then
    cp -R /private/tmp/pion-lean-ref/PionLean "$PROJ/PionLean"
    cp /private/tmp/pion-lean-ref/PionLean.lean "$PROJ/PionLean.lean"
  else
    echo "ERROR: PionLean reference missing" >&2
    exit 1
  fi
fi

rm -f "$PROJ/lakefile.toml"
cat > "$PROJ/lakefile.lean" <<EOF
import Lake
open Lake DSL

require aeneas from "./.deps/aeneas"

package «pionlean» where
  leanOptions := #[⟨\`weak.linter.dupNamespace, false⟩]

@[default_target] lean_lib PionLean

lean_lib Url where
  moreLeanArgs := #["--memory=$LEAN_MEM_LIMIT", "-j", "$LEAN_NUM_THREADS"]

lean_lib UrlProofs where
  moreLeanArgs := #["--memory=$LEAN_MEM_LIMIT", "-j", "$LEAN_NUM_THREADS"]
EOF

echo "=== [2/7] pionc extract-lean packages/url ==="
rm -rf "$PROJ/Url" "$PROJ/UrlProofs" "$PROJ/UrlProofs.lean" "$PROJ/CheckAxioms.lean" "$PROJ/EvalDiff.lean"
pionc extract-lean --json "$PKG_DIR" --out "$PROJ"

cp "$SCRIPT_DIR/UrlProofs.lean" "$PROJ/UrlProofs.lean"
cp -R "$SCRIPT_DIR/UrlProofs" "$PROJ/UrlProofs"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "$SCRIPT_DIR/UrlProofs" "$SCRIPT_DIR/UrlProofs.lean"; then
  echo "FAIL: forbidden tactic or axiom found" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Url.Types Url.Funs UrlProofs ==="
(
  cd "$PROJ"
  LEAN_NUM_THREADS="$LEAN_NUM_THREADS" lake build \
    PionLean Url.Types Url.Funs UrlProofs
)

echo "=== [5/7] CheckAxioms (standard axioms only) ==="
AXIOM_OUT="$(cd "$PROJ" && lake env lean "$PROJ/CheckAxioms.lean")"
echo "$AXIOM_OUT"
if echo "$AXIOM_OUT" | grep -E 'sorryAx|Lean\.ofReduceBool|Lean\.trustCompiler'; then
  echo "FAIL: non-standard axiom detected" >&2
  exit 1
fi
THM_COUNT="$(echo "$AXIOM_OUT" | grep -c "^'UrlProofs\." || true)"
if [ "$THM_COUNT" -ne 24 ]; then
  echo "FAIL: expected 24 theorems in CheckAxioms, got $THM_COUNT" >&2
  exit 1
fi
echo "CheckAxioms: $THM_COUNT theorems verified, standard axioms only"

echo "=== [6/7] Lean EvalDiff ==="
LEAN_DIFF_OUT="$(cd "$PROJ" && lake env lean "$PROJ/EvalDiff.lean")"
echo "$LEAN_DIFF_OUT"
if echo "$LEAN_DIFF_OUT" | grep -q "FAIL"; then
  echo "FAIL: Lean EvalDiff reported FAIL" >&2
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential cross-check (diff -u) ==="
DIFF_TMP="$(mktemp -d /tmp/url-diff.XXXXXX)"
trap 'rm -rf "$DIFF_TMP"; kill -- -$$ 2>/dev/null || true' EXIT INT TERM
mkdir -p "$DIFF_TMP/src"

cat > "$DIFF_TMP/pion.toml" <<EOF
[package]
name = "url_diff"
version = "0.1.0"

[dependencies]
url = { path = "$PKG_DIR" }
EOF

cat > "$DIFF_TMP/src/main.pion" <<'EOF'
import "url"

fn check_i32(w : World, label : String, actual : Int, expected : Int) -> Unit {
  if actual == expected { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn check_u32(w : World, label : String, actual : UInt, expected : UInt) -> Unit {
  if actual == expected { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn check_bool(w : World, label : String, actual : Bool, expected : Bool) -> Unit {
  if actual == expected { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn check_i64(w : World, label : String, actual : Int64, expected : Int64) -> Unit {
  if actual == expected { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

pub fn main(w : World) -> Int {
  check_i64(w, "pth_lo", url::puny_threshold(36L, 72L), 1L)
  check_i64(w, "pth_eq", url::puny_threshold(72L, 72L), 1L)
  check_i64(w, "pth_mid", url::puny_threshold(80L, 72L), 8L)
  check_i64(w, "pth_hi", url::puny_threshold(108L, 72L), 26L)
  check_i32(w, "penc_0", url::puny_encode_digit(0L).to_int(), 97)
  check_i32(w, "penc_25", url::puny_encode_digit(25L).to_int(), 122)
  check_i32(w, "penc_26", url::puny_encode_digit(26L).to_int(), 48)
  check_i32(w, "penc_35", url::puny_encode_digit(35L).to_int(), 57)
  check_i64(w, "pdec_a", url::puny_decode_digit(97), 0L)
  check_i64(w, "pdec_Z", url::puny_decode_digit(90), 25L)
  check_i64(w, "pdec_0", url::puny_decode_digit(48), 26L)
  check_i64(w, "pdec_9", url::puny_decode_digit(57), 35L)
  check_i64(w, "pdec_bad", url::puny_decode_digit(45), -1L)
  check_i32(w, "emask_nul", url::encode_byte_mask(0), 255)
  check_i32(w, "emask_tab", url::encode_byte_mask(9), 255)
  check_i32(w, "emask_sp", url::encode_byte_mask(32), 254)
  check_i32(w, "emask_hash", url::encode_byte_mask(35), 252)
  check_i32(w, "emask_apos", url::encode_byte_mask(39), 136)
  check_i32(w, "emask_star", url::encode_byte_mask(42), 0)
  check_i32(w, "emask_slash", url::encode_byte_mask(47), 224)
  check_i32(w, "emask_A", url::encode_byte_mask(65), 0)
  check_i32(w, "emask_qmark", url::encode_byte_mask(63), 240)
  check_i32(w, "emask_dollar", url::encode_byte_mask(36), 192)
  check_i32(w, "emask_del", url::encode_byte_mask(127), 255)
  check_i32(w, "emask_utf8", url::encode_byte_mask(200), 255)
  check_i32(w, "eset_ctrl", url::encode_set_mask(url::EncodeSet::Controls), 1)
  check_i32(w, "eset_comp", url::encode_set_mask(url::EncodeSet::Component), 64)
  check_u32(w, "v4_loopback", url::Ipv4Addr::new(127, 0, 0, 1).to_u32(), 2130706433U)
  check_u32(w, "v4_bcast", url::Ipv4Addr::new(255, 255, 255, 255).to_u32(), 4294967295U)
  let (o0, o1, o2, o3) = url::Ipv4Addr::from_u32(3232235777U).octets()
  check_bool(w, "v4_octets", o0 == 192 && o1 == 168 && o2 == 1 && o3 == 1, true)
  check_bool(w, "v4_eq_t", url::Ipv4Addr::from_u32(1U).eq(url::Ipv4Addr::from_u32(1U)), true)
  check_bool(w, "v4_eq_f", url::Ipv4Addr::from_u32(1U).eq(url::Ipv4Addr::from_u32(2U)), false)
  let ip6a = url::Ipv6Addr::new(0x2001, 0x0db8, 0, 0, 0, 0, 0, 1)
  check_i32(w, "v6_seg0", url::ipv6_seg(ip6a, 0), 0x2001)
  let ip6b = url::Ipv6Addr::new(0x2001, 0x0db8, 0, 0, 0, 0, 0, 0x10001)
  check_i32(w, "v6_seg7", url::ipv6_seg(ip6b, 7), 1)
  let ip6c = url::Ipv6Addr::new(1, 2, 3, 4, 5, 6, 7, 8)
  let ip6d = url::Ipv6Addr::new(1, 2, 3, 4, 5, 6, 7, 8)
  let ip6e = url::Ipv6Addr::new(1, 2, 3, 4, 5, 6, 7, 9)
  check_bool(w, "v6_eq_t", ip6c.eq(ip6d), true)
  check_bool(w, "v6_eq_f", ip6c.eq(ip6e), false)
  0
}
EOF

printf '%s\n' "$LEAN_DIFF_OUT" > "$DIFF_TMP/lean.out"
PION_CACHE_DIR="$DIFF_TMP/cache" pionc run "$DIFF_TMP" > "$DIFF_TMP/pion.out"
diff -u "$DIFF_TMP/lean.out" "$DIFF_TMP/pion.out"
CASE_COUNT="$(wc -l < "$DIFF_TMP/lean.out" | tr -d ' ')"
echo "Native vs Lean differential: $CASE_COUNT cases identical (diff -u exit 0)"
echo "PASS: packages/url Lean 4 proofs"
