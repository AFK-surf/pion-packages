#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/http2`.
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

echo "=== [2/7] pionc extract-lean packages/http2 ==="
rm -rf "$PROJ/Http2"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Http2/$f.lean" ]; then
    echo "FAIL: missing Http2/$f.lean" >&2
    exit 1
  fi
done

rm -rf "$PROJ/Http2Proofs"
cp -R "$SCRIPT_DIR/Http2Proofs" "$PROJ/Http2Proofs"
cp "$SCRIPT_DIR/Http2Proofs.lean" "$PROJ/Http2Proofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Http2 where\n  globs := #[.submodules `Http2]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib Http2Proofs where\n  globs := #[.andSubmodules `Http2Proofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/Http2Proofs.lean" "$SCRIPT_DIR/Http2Proofs" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Http2 Http2Proofs ==="
cd "$PROJ"
set +e
lake build PionLean Http2 Http2Proofs > "$WORK/build.log" 2>&1
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
echo "lake build PionLean Http2 Http2Proofs: exit 0, 0 errors"

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
name = "http2_lean_diff"
version = "0.1.0"

[dependencies]
http2 = { path = "$PKG_DIR" }
EOF

cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "http2"

fn report(w : World, label : String, passed : Bool) -> Unit {
  if passed {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  report(w, "hpack_sz_0", http2::hpack_entry_size(0, 0) == 32)
  report(w, "hpack_sz_ex", http2::hpack_entry_size(10, 20) == 62)
  report(w, "st_eq_open", http2::stream_state_eq(http2::StreamState::Open, http2::StreamState::Open))
  report(w, "st_eq_diff", !http2::stream_state_eq(http2::StreamState::Open, http2::StreamState::Closed))
  report(w, "parity_srv_1", http2::is_remote_stream_parity(true, 1))
  report(w, "parity_srv_2", !http2::is_remote_stream_parity(true, 2))
  report(w, "parity_cli_2", http2::is_remote_stream_parity(false, 2))
  report(w, "parity_cli_1", !http2::is_remote_stream_parity(false, 1))
  report(w, "flow_ok", http2::flow_window_add_ok(65535L, 1024L))
  report(w, "flow_zero", !http2::flow_window_add_ok(65535L, 0L))
  report(w, "flow_ovf", !http2::flow_window_add_ok(2147483647L, 1L))
  report(w, "recv_data_open", http2::can_recv_data_in_state(http2::StreamState::Open) == 0)
  report(w, "recv_data_hcr", http2::can_recv_data_in_state(http2::StreamState::HalfClosedRemote) == 1)
  report(w, "recv_data_idle", http2::can_recv_data_in_state(http2::StreamState::Idle) == 2)
  report(w, "next_es_open", http2::stream_state_eq(http2::next_state_on_recv_end_stream(http2::StreamState::Open), http2::StreamState::HalfClosedRemote))
  report(w, "next_es_hcl", http2::stream_state_eq(http2::next_state_on_recv_end_stream(http2::StreamState::HalfClosedLocal), http2::StreamState::Closed))

  report(w, "u24_b0", http2::pack_u24_b0(1193046) == 18)
  report(w, "u24_b1", http2::pack_u24_b1(1193046) == 52)
  report(w, "u24_b2", http2::pack_u24_b2(1193046) == 86)
  report(w, "u24_rt", http2::unpack_u24_be(18, 52, 86) == 1193046)
  report(w, "u31_b0", http2::pack_u31_b0(305419896) == 18)
  report(w, "u31_rt", http2::unpack_u31_be(18, 52, 86, 120) == 305419896)
  report(w, "u31_rbit", http2::unpack_u31_be(146, 52, 86, 120) == 305419896)
  report(w, "prio_pack_t", http2::pack_priority_dep(true, 13) == 2147483661L)
  report(w, "prio_pack_f", http2::pack_priority_dep(false, 13) == 13L)
  report(w, "prio_excl_t", http2::unpack_priority_exclusive(2147483661L))
  report(w, "prio_excl_f", !http2::unpack_priority_exclusive(13L))
  report(w, "prio_dep_rt", http2::unpack_priority_dep(2147483661L) == 13)
  report(w, "hdr_flags_all", http2::encode_headers_flags(true, true, true) == 37)
  report(w, "hdr_flags_none", http2::encode_headers_flags(false, false, false) == 0)
  report(w, "win_inc_ok", http2::is_valid_window_increment(1))
  report(w, "win_inc_0", !http2::is_valid_window_increment(0))

  report(w, "set_push_ok", http2::validate_setting_value(2, 1L) == 0)
  report(w, "set_push_bad", http2::validate_setting_value(2, 2L) == 1)
  report(w, "set_win_ok", http2::validate_setting_value(4, 2147483647L) == 0)
  report(w, "set_win_bad", http2::validate_setting_value(4, 2147483648L) == 2)
  report(w, "set_mfs_ok", http2::validate_setting_value(5, 16384L) == 0)
  report(w, "set_mfs_lo", http2::validate_setting_value(5, 16383L) == 1)
  report(w, "set_mfs_hi", http2::validate_setting_value(5, 16777216L) == 1)
  report(w, "set_conn_bad", http2::validate_setting_value(8, 3L) == 1)
  report(w, "set_unk_ok", http2::validate_setting_value(99, 9999999999L) == 0)
  report(w, "name_lower", http2::is_valid_h2_name_byte(97))
  report(w, "name_upper", !http2::is_valid_h2_name_byte(65))
  report(w, "name_space", !http2::is_valid_h2_name_byte(32))
  report(w, "val_ctl_0", http2::is_h2_value_ctl(0))
  report(w, "val_ctl_tab", !http2::is_h2_value_ctl(9))
  report(w, "val_ctl_del", http2::is_h2_value_ctl(127))
  report(w, "val_ws_sp", http2::is_h2_value_edge_ws(32))
  report(w, "digit_5", http2::is_ascii_digit(53))
  report(w, "digit_a", !http2::is_ascii_digit(97))
  0
}
EOF

"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/http2 Lean 4 proofs"
