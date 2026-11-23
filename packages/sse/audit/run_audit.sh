#!/bin/sh
# Red-team audit of packages/sse (Pion WHATWG Server-Sent Events) vs WHATWG HTML §9.2.6
# and Rust eventsource-stream =0.2.3.  See REPORT.md.
#
#   sh packages/sse/audit/run_audit.sh            # full run (~2-3 min on an M-series Mac, incl. bench)
#   QUICK=1 sh packages/sse/audit/run_audit.sh    # 500 random cases, small DoS sizes, no bench
#   SKIP_BENCH=1 sh packages/sse/audit/run_audit.sh
#
# Exit 0 only if every red-team unit test passes, Pion matches the WHATWG oracle under every
# chunking, Rust differs from the oracle only by its catalogued quirks (U-1..U-5), the 4 build
# modes agree byte-for-byte, the encoder round-trips every CR-free payload and every DoS probe
# finishes within its bound.  All builds / inputs / logs go to $AUDIT_OUT
# (default /private/tmp/rt-sse-audit-$USER); the git worktree is never written to.
# Needs: pionc ($HOME/.pion/bin, AFK-surf/pion@66d2b4b), cargo (Cargo.lock, --locked), node (wasm32), python3.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SSE_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SSE_DIR/../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/rt-sse-audit-$(id -un)}
BIN="$OUT/bin"
QUICK=${QUICK:-0}
SKIP_BENCH=${SKIP_BENCH:-$QUICK}
N_RANDOM=${N_RANDOM:-3000}
[ "$QUICK" = 1 ] && N_RANDOM=500
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PION_CACHE_DIR="${PION_CACHE_DIR:-$OUT/pion-cache}"
mkdir -p "$BIN"
FAILS=0
FAILED=""

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); FAILED="$FAILED
  - $1"; printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
pass() { printf '  \033[32mpass\033[0m %s\n' "$1"; }
measure() { python3 "$AUDIT_DIR/oracle/measure.py" "$@"; }

section "0. Build: Pion probe (--release), Rust eventsource-stream =0.2.3 oracle (--locked) -> $BIN"
pionc --version
git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null | sed 's/^/  repo HEAD /' || true
pionc build --release -o "$BIN/pion_probe" "$AUDIT_DIR/probe" >/dev/null
CARGO_TARGET_DIR="$OUT/rust-target" cargo build --release --locked --quiet \
  --manifest-path "$AUDIT_DIR/rust_oracle/Cargo.toml"
cp "$OUT/rust-target/release/sse_audit_rust_oracle" "$BIN/rust_oracle"

section "1. Red-team unit tests: pionc test audit (every redteam_* failure is a finding)"
(cd "$SSE_DIR" && pionc test --json audit > "$OUT/redteam_test.json" 2> "$OUT/redteam_test.stderr") || true
if python3 - "$OUT/redteam_test.json" <<'PY'
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
mine = [t for t in d["tests"] if t["pkg"] == "sse_audit"]
bad = [t for t in mine if not t["ok"]]
up = [t for t in d["tests"] if t["pkg"] != "sse_audit"]
print("sse_audit: %d tests, %d FAILED (findings), %d passed; upstream packages/sse tests: %d/%d pass"
      % (len(mine), len(bad), len(mine) - len(bad), sum(t["ok"] for t in up), len(up)))
for t in mine:
    print("  %-5s %s" % ("FAIL" if not t["ok"] else "pass", t["name"]))
sys.exit(1 if bad or not all(t["ok"] for t in up) or not mine else 0)
PY
then pass "red-team unit tests"; else fail "red-team unit tests (assertion messages below)"; fi
sed 's|^.*/audit/|  |' "$OUT/redteam_test.stderr"

section "2. Differential: WHATWG §9.2.6 oracle vs Pion (6 chunkings + Strict) vs Rust eventsource-stream 0.2.3"
python3 "$AUDIT_DIR/oracle/whatwg_sse.py" gen "$OUT/cases.hex" "$N_RANDOM" 2026
"$BIN/pion_probe" corpus "$OUT/cases.hex" > "$OUT/pion.out"
"$BIN/rust_oracle" "$OUT/cases.hex" > "$OUT/rust.out"
if python3 "$AUDIT_DIR/oracle/whatwg_sse.py" diff "$OUT/cases.hex" "$OUT/pion.out" "$OUT/rust.out" > "$OUT/diff.txt"; then
  pass "Pion == oracle for every case and chunking; every Rust difference is a catalogued upstream quirk"
else
  fail "differential has FINDING / UNEXPLAINED entries"
fi
cat "$OUT/diff.txt"

section "3. Reconnect / cursor / encoder dump (probe misc)"
"$BIN/pion_probe" misc > "$OUT/misc.txt"
grep -E '^(backoff|encoder_fuzz|  first_mismatch|cursor https://h/e\?since=0 id=3432|cursor param|header|encode 2)' "$OUT/misc.txt" | sed 's/^/  /'
if grep -q '^encoder_fuzz no_cr: .* mismatch=0 ' "$OUT/misc.txt"; then pass "format_event -> parse round-trips 3000 CR-free adversarial events byte-for-byte"; else fail "encoder round-trip mismatch on CR-free payloads"; fi
if grep '^backoff' "$OUT/misc.txt" | grep -q 'negative=[1-9]'; then fail "negative backoff delay"; else pass "no negative / overflowing backoff in any config (incl. Int64::MAX cap, 1000 failures)"; fi

section "4. 4-mode consistency (native dbg/rel, wasm32 dbg/rel)"
H1=""; H2=""; H3=""
for m in "" "--release" "--target wasm32" "--target wasm32 --release"; do
  # shellcheck disable=SC2086
  (cd "$SSE_DIR" && pionc run $m audit/probe -- corpus "$OUT/cases.hex") > "$OUT/m_corpus.txt" 2>&1 || true
  # shellcheck disable=SC2086
  (cd "$SSE_DIR" && pionc run $m audit/probe -- misc) > "$OUT/m_misc.txt" 2>&1 || true
  # shellcheck disable=SC2086
  (cd "$SSE_DIR" && pionc run $m wasm_smoke) > "$OUT/m_smoke.txt" 2>&1 || true
  a=$(shasum -a 256 "$OUT/m_corpus.txt" | cut -c1-16); b=$(shasum -a 256 "$OUT/m_misc.txt" | cut -c1-16)
  c=$(shasum -a 256 "$OUT/m_smoke.txt" | cut -c1-16)
  printf '  [%-26s] corpus sha256=%s (%s lines)  misc sha256=%s  wasm_smoke sha256=%s\n' "$m" "$a" \
    "$(wc -l < "$OUT/m_corpus.txt" | tr -d ' ')" "$b" "$c"
  H1="$H1 $a"; H2="$H2 $b"; H3="$H3 $c"
done
ref=$(shasum -a 256 "$OUT/pion.out" | cut -c1-16)
if [ "$(printf '%s\n' $H1 | sort -u)" = "$ref" ] && [ "$(printf '%s\n' $H2 | sort -u | wc -l | tr -d ' ')" = 1 ] \
   && [ "$(printf '%s\n' $H3 | sort -u | wc -l | tr -d ' ')" = 1 ]; then
  pass "corpus / misc / wasm_smoke outputs byte-identical in all 4 modes (corpus == differential run)"
else
  fail "4-mode outputs differ"
fi

section "5. DoS probes (default SseLimits; input is generated inside the probe, so RSS includes it)"
if [ "$QUICK" = 1 ]; then BIG=16777216; BL=10000000; TN=1000000; else BIG=268435456; BL=100000000; TN=5000000; fi
DOSFAIL=0
for spec in "longline_whole $BIG" "longline_4k $BIG" "blank $BL" "comment $TN" "tiny $TN" "datalines 1000000" "ff 1048000" "drip 8000000"; do
  set -- $spec; kind=$1; n=$2
  L=$(measure "native --release $kind n=$n" 120 "$BIN/pion_probe" dos "$kind" "$n"); echo "  $L"
  case "$L" in *"rc=0 "*) ;; *) DOSFAIL=1;; esac
done
for spec in "longline_4k 67108864" "blank 20000000" "tiny 1000000" "ff 1048000" "datalines 300000"; do
  set -- $spec; kind=$1; n=$2
  L=$(cd "$SSE_DIR" && measure "wasm32 --release $kind n=$n" 300 pionc run --target wasm32 --release audit/probe -- dos "$kind" "$n"); echo "  $L"
  case "$L" in *"rc=0 "*) ;; *) DOSFAIL=1;; esac
done
if [ "$DOSFAIL" = 0 ]; then pass "every DoS probe returns (no SIGSEGV / wasm trap / timeout); line limit rejects before buffering"; else fail "DoS probe crashed or timed out"; fi
echo "  note: 'ff' shows max_event_bytes counted before U+FFFD expansion (F-08); 'datalines' shows a rejected"
echo "        event later dispatched truncated after an Err (F-02)."

if [ "$SKIP_BENCH" != 1 ]; then
  section "6. Re-run of the package's own head-to-head bench (fairness check; not gating except SHA)"
  if SSE_BENCH_OUT="$OUT/bench" sh "$SSE_DIR/bench/run_bench.sh" > "$OUT/bench.txt" 2>&1; then
    grep -E '^\| `|SHA-256 verified' "$OUT/bench.txt" | sed 's/^/  /'
    pass "bench stdout SHA-256 identical (pion vs rust)"
  else
    tail -20 "$OUT/bench.txt"; fail "bench failed or SHA mismatch"
  fi
fi

section "Summary"
# build artifacts (ignored files) anywhere, or changes outside packages/sse/audit/, are pollution
DIRTY=$(git -C "$REPO_ROOT" status --porcelain --ignored 2>/dev/null | grep -v '^?? packages/sse/audit/$' \
  | grep -E '^!!|^.. ' | grep -vE '^(\?\?|.M|M.|A.) packages/sse/audit/' || true)
if [ -n "$DIRTY" ]; then
  fail "git worktree polluted by the audit: $DIRTY"
else
  pass "git status --porcelain --ignored: no artifacts, nothing outside packages/sse/audit/ touched"
fi
if [ "$FAILS" = 0 ]; then
  echo "AUDIT CLEAN: no finding reproduced"
  exit 0
fi
printf 'AUDIT: %d failing gate(s):%s\n' "$FAILS" "$FAILED"
exit 1
