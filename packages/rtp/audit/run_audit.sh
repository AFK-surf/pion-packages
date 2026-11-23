#!/bin/sh
# Red-team audit runner for packages/rtp (RTP/RTCP/SRTP/SRTCP) @ dfd410cd.
#
#   sh packages/rtp/audit/run_audit.sh [all|unit|compare|fuzz|dos]     (default: all)
#
# unit    : control_test (MUST pass) + redteam_test + whitebox (expected red-team failures = findings)
# compare : bidirectional interop vs Rust webrtc-rs (rtp 0.12 / rtcp 0.12 / webrtc-srtp 0.14)
# fuzz    : 12,000 deterministic malformed RTP/RTCP/SRTP/SRTCP inputs, Native --release vs
#           wasm32 --release (must be byte-identical, 0 crash / 0 trap) and vs webrtc-rs
# dos     : forged-SSRC state growth, maximal compound RTCP, maximal extension block (/usr/bin/time -l)
#
# Needs pionc ($HOME/.pion/bin), cargo, python3, node (wasm32 runner). Every build product, corpus
# and report goes to $RT_RTP_WORK (default /tmp/rt_rtp_work); the git worktree is never written.
set -eu

MODE=${1:-all}
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RTP_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
PKGS_DIR=$(CDPATH= cd -- "$RTP_DIR/.." && pwd)
W=${RT_RTP_WORK:-/tmp/rt_rtp_work}
BIN="$W/bin"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
mkdir -p "$BIN"
FAIL=0

section() { printf '\n=== %s ===\n' "$1"; }

# Expected red-team failures on dfd410cd (each one is a confirmed finding in README.md).
EXPECTED_REDTEAM="redteam_P1_2_srtcp_replay_window_shared_across_ssrcs
redteam_P2_1_encrypt_rtp_reuses_keystream_on_repeated_index
redteam_P2_2_from_session_keys_accepts_empty_hmac_key
redteam_P2_3_marshal_rtp_extension_length_truncated
redteam_P2_4_marshal_silently_truncates_out_of_range_fields
redteam_P2_5_remb_exponent_shift_overflow
wb_redteam_P1_1_forged_ssrcs_grow_state_table_unbounded
wb_redteam_P2_6_srtcp_index_and_roc_wrap_reuse_nonce"

summarise_tests() { # $1 json, $2 package name
  python3 - "$1" "$2" "$EXPECTED_REDTEAM" <<'PY'
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
exp = set(sys.argv[3].split())
mine = [t for t in d["tests"] if t["pkg"] == sys.argv[2]]
bad = 0
for t in mine:
    red = "redteam" in t["name"]
    if red:
        st = "CONFIRMED (fails as expected)" if not t["ok"] and t["name"] in exp else ("FIXED? (now passes)" if t["ok"] else "unexpected failure")
        bad += st.startswith("unexpected")
    else:
        st = "pass" if t["ok"] else "CONTROL FAILED"
        bad += not t["ok"]
    print("  %-62s %s" % (t["name"], st))
print("  -> %d tests: %d controls passed, %d red-team findings reproduced" % (
    len(mine), sum(t["ok"] and "redteam" not in t["name"] for t in mine), sum((not t["ok"]) and "redteam" in t["name"] for t in mine)))
sys.exit(1 if bad else 0)
PY
}

build() {
  [ -x "$BIN/probe" ] && [ -x "$BIN/rtp_oracle" ] && [ "${REBUILD:-0}" = 0 ] && return 0
  section "build: Pion probe (--release) + Rust webrtc-rs oracle (--release) -> $BIN"
  pionc build --release -o "$BIN/probe" "$AUDIT_DIR/probe"
  rm -rf "$W/rust-proj" && cp -R "$AUDIT_DIR/rust" "$W/rust-proj"
  CARGO_TARGET_DIR="$W/rust-target" cargo build -q --release --manifest-path "$W/rust-proj/Cargo.toml"
  cp "$W/rust-target/release/rtp_oracle" "$BIN/rtp_oracle"
}

do_unit() {
  section "unit 1/2: control_test + redteam_test (black-box, pionc test packages/rtp/audit)"
  pionc fmt --check "$AUDIT_DIR" >/dev/null 2>&1 && echo "  pionc fmt --check audit: clean" || echo "  pionc fmt --check audit: (formatting differences)"
  (cd "$PKGS_DIR" && pionc test --json rtp/audit > "$W/unit.json" 2> "$W/unit.stderr") || true
  summarise_tests "$W/unit.json" rtp_audit || FAIL=1
  echo "  assertion messages:"; sed 's|^.*/audit/|    |' "$W/unit.stderr"
  section "unit 2/2: white-box (src/*.pion copied with whitebox_test.pion into $W/whitebox_pkg)"
  rm -rf "$W/whitebox_pkg" && mkdir -p "$W/whitebox_pkg/src"
  cp "$RTP_DIR"/src/*.pion "$W/whitebox_pkg/src/"
  cp "$AUDIT_DIR/whitebox/whitebox_test.pion" "$W/whitebox_pkg/"
  printf '[package]\nname = "rtp_whitebox"\nversion = "0.1.0"\n\n[dependencies]\ncrypto = { path = "%s" }\n' "$PKGS_DIR/crypto" > "$W/whitebox_pkg/pion.toml"
  pionc test --json "$W/whitebox_pkg" > "$W/wb.json" 2> "$W/wb.stderr" || true
  summarise_tests "$W/wb.json" rtp_whitebox || FAIL=1
  echo "  assertion messages:"; sed 's|^.*/whitebox_pkg/|    |' "$W/wb.stderr"
}

do_compare() {
  build
  section "compare: Pion <-> Rust webrtc-rs bidirectional SRTP/SRTCP + RTP/RTCP codec interop"
  "$BIN/probe" gen > "$W/pion_cases.txt"
  "$BIN/rtp_oracle" gen > "$W/rust_cases.txt"
  "$BIN/rtp_oracle" verify "$W/pion_cases.txt" > "$W/rust_verify.txt"
  "$BIN/probe" verify "$W/rust_cases.txt" > "$W/pion_verify.txt"
  python3 "$AUDIT_DIR/tools/interop_summary.py" "$W/pion_cases.txt" "$W/rust_cases.txt" "$W/rust_verify.txt" "$W/pion_verify.txt" || FAIL=1
}

do_fuzz() {
  build
  [ -s "$W/pion_cases.txt" ] || { "$BIN/probe" gen > "$W/pion_cases.txt"; "$BIN/rtp_oracle" gen > "$W/rust_cases.txt"; }
  section "fuzz: 12,000 malformed inputs (seed 3711), Native --release vs wasm32 --release vs webrtc-rs"
  python3 "$AUDIT_DIR/tools/gen_corpus.py" "$W/pion_cases.txt" "$W/rust_cases.txt" "$W/corpus.txt" 3000 3711
  /usr/bin/time -l "$BIN/probe" fuzz "$W/corpus.txt" > "$W/fuzz_native.txt" 2> "$W/fuzz_native.time"
  echo "  native exit=0 lines=$(wc -l < "$W/fuzz_native.txt") $(grep -E 'real|maximum resident' "$W/fuzz_native.time" | awk '{printf "%s %s ", $1, $2}')"
  pionc build --release --target wasm32 -o "$BIN/probe.wasm" "$AUDIT_DIR/probe" >/dev/null
  pionc run --target wasm32 --release "$AUDIT_DIR/probe" -- fuzz "$W/corpus.txt" > "$W/fuzz_wasm.txt" 2> "$W/fuzz_wasm.err"
  echo "  wasm32 exit=0 lines=$(wc -l < "$W/fuzz_wasm.txt") traps=$(grep -ci 'trap\|panic\|unreachable' "$W/fuzz_wasm.err" || true)"
  if cmp -s "$W/fuzz_native.txt" "$W/fuzz_wasm.txt"; then
    echo "  Native == wasm32: byte-identical verdicts, sha256 $(shasum -a 256 "$W/fuzz_native.txt" | cut -c1-16)"
  else
    echo "  Native != wasm32: MISMATCH"; FAIL=1
  fi
  "$BIN/rtp_oracle" fuzz "$W/corpus.txt" > "$W/fuzz_rust.txt"
  python3 "$AUDIT_DIR/tools/fuzz_compare.py" "$W/corpus.txt" "$W/fuzz_native.txt" "$W/fuzz_rust.txt" || FAIL=1
}

timed() { # label, cmd...
  label=$1; shift
  out=$(/usr/bin/time -l "$@" 2> "$W/t.err")
  printf '  %-34s %-70s %8s s  RSS %6.1f MiB\n' "$label" "$out" "$(awk '/real/{print $1}' "$W/t.err")" \
    "$(awk '/maximum resident/{print $1/1048576}' "$W/t.err")"
}

do_dos() {
  build
  section "dos 1/3: forged SRTP packets with fresh SSRCs (no key), then 10,000 genuine packets (P1-1)"
  for n in 0 10000 50000 100000; do
    timed "pion  forged=$n" "$BIN/probe" dos-ssrc "$n"
    timed "rust  forged=$n" "$BIN/rtp_oracle" dos-ssrc "$n"
  done
  section "dos 2/3: maximal compound RTCP under DecodeLimits::default() (64 x FIR, 256 KiB)"
  timed "pion  parse x1" "$BIN/probe" dos-rtcp 1
  timed "pion  parse x200" "$BIN/probe" dos-rtcp 200
  section "dos 3/3: 65535-word RFC 5285 block (limits raised; default limits reject it)"
  timed "pion  parse x1" "$BIN/probe" dos-ext 1
  timed "pion  parse x50" "$BIN/probe" dos-ext 50
}

case "$MODE" in
  unit) do_unit ;;
  compare) do_compare ;;
  fuzz) do_fuzz ;;
  dos) do_dos ;;
  all) do_unit; do_compare; do_fuzz; do_dos ;;
  *) echo "usage: $0 [all|unit|compare|fuzz|dos]" >&2; exit 2 ;;
esac
section "result: $( [ $FAIL = 0 ] && echo 'OK (controls pass, findings reproduced as documented)' || echo 'FAIL (see above)')"
exit $FAIL
