#!/bin/sh
# Red-team audit of packages/time vs Rust jiff 0.2 and Go time — one-shot runner.
#   sh packages/time/audit/run_audit.sh            # everything
#   SKIP_BENCH=1 sh packages/time/audit/run_audit.sh   # correctness only
# All build outputs and data go to $OUT_DIR (default /tmp/pion-time-redteam); the worktree stays clean.
set -u

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT_DIR="${OUT_DIR:-/tmp/pion-time-redteam}"
BIN="$OUT_DIR/bin"
ROUNDS="${ROUNDS:-5}"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
mkdir -p "$BIN"
fail() { echo "FATAL: $*" >&2; exit 2; }

echo "==> [build] Pion probe + fairness benches (--release)"
pionc build --release -o "$BIN/pion_probe" "$AUDIT_DIR/probe" || fail "pion probe build"
for b in rfc3339_typed rfc3339_split civil_typed duration_iso http_date sd_arith; do
  pionc build --release -o "$BIN/pion_$b" "$AUDIT_DIR/bench/pion_$b" || fail "pion bench $b"
done
pionc build --release -o "$BIN/pion_rfc3339_raw" "$AUDIT_DIR/../bench/pion_rfc3339" || fail "orig bench"
pionc build --release -o "$BIN/pion_civil_packed" "$AUDIT_DIR/../bench/pion_civil" || fail "orig bench"

echo "==> [build] Rust jiff probe + benches (--release, --locked)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked --offline \
  --manifest-path "$AUDIT_DIR/rust/Cargo.toml" 2>/dev/null ||
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$AUDIT_DIR/rust/Cargo.toml" || fail "cargo build"
for b in probe gaps rfc3339 civil civil_fast duration_iso http_date sd_arith; do
  cp "$OUT_DIR/rust-target/release/$b" "$BIN/rust_$b"
done

echo "==> [build] Go probe + benches"
(cd "$AUDIT_DIR/go" && for b in probe rfc3339 civil http_date sd_arith; do
  go build -o "$BIN/go_$b" "./cmd/$b" || exit 1
done) || fail "go build"

STATUS=0
echo ""
echo "=== 1. Red-team assertion suite (every FAIL is a finding; asserts encode jiff / RFC behaviour) ==="
pionc test --json -p time_redteam_audit "$AUDIT_DIR" > "$OUT_DIR/redteam_test.json" 2> "$OUT_DIR/redteam_test.stderr"
python3 - "$OUT_DIR/redteam_test.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"total={d['total']} passed={d['passed']} failed={d['failed']}")
for t in d["tests"]:
    print(("  PASS " if t["ok"] else "  FAIL ") + t["name"])
PY
[ -s "$OUT_DIR/redteam_test.json" ] || STATUS=2

echo ""
echo "=== 2. Differential: Pion vs jiff vs Go on cases/differential.tsv ==="
CASES="$AUDIT_DIR/cases/differential.tsv"
"$BIN/rust_probe" "$CASES" > "$OUT_DIR/diff_jiff.tsv" || fail "jiff probe"
"$BIN/pion_probe" "$CASES" > "$OUT_DIR/diff_pion.tsv" || fail "pion probe"
"$BIN/go_probe" "$CASES" > "$OUT_DIR/diff_go.tsv" || fail "go probe"
python3 "$AUDIT_DIR/diff.py" "$OUT_DIR/diff_jiff.tsv" "$OUT_DIR/diff_pion.tsv" "$OUT_DIR/diff_go.tsv" \
  --md "$OUT_DIR/differential.md"

echo ""
echo "=== 3. Exhaustive civil calendar (all 7,304,484 days; typed + packed API) vs jiff ==="
"$BIN/pion_probe" --civil-all > "$OUT_DIR/civil_pion.txt"
"$BIN/rust_probe" --civil-all > "$OUT_DIR/civil_jiff.txt"
echo "packed-vs-typed mismatches: $(grep -c '!!' "$OUT_DIR/civil_pion.txt")"
if cmp -s "$OUT_DIR/civil_pion.txt" "$OUT_DIR/civil_jiff.txt"; then
  echo "IDENTICAL to jiff: $(shasum -a 256 "$OUT_DIR/civil_jiff.txt" | cut -d' ' -f1)"
else
  echo "DIVERGES from jiff:"; diff "$OUT_DIR/civil_pion.txt" "$OUT_DIR/civil_jiff.txt" | head -20
fi

echo ""
echo "=== 4. Robustness / overflow / invariant probes (Pion) ==="
"$BIN/pion_probe" --robust | tee "$OUT_DIR/robust.txt"

echo ""
echo "=== 5. Functional gaps: what jiff computes vs public API surface of packages/time ==="
"$BIN/rust_gaps"
echo "--- packages/time public fns matching zone|tz|dst|posix|strftime|strptime|span|round|disambig:"
grep -hoE '^pub fn [A-Za-z_:]+' "$AUDIT_DIR"/../src/*.pion | grep -iE 'zone|tz|dst|posix|strf|strp|span|round|disamb|zoned' || true
echo "--- (only SignedDuration::round_secs/round_millis exist; no Zoned / TimeZone / Span / strtime types)"

if [ "${SKIP_BENCH:-0}" = "1" ]; then exit $STATUS; fi

echo ""
echo "=== 6. Fairness benchmarks (idiomatic API vs idiomatic API) ==="
python3 "$ROOT_DIR/packages/time/bench/gen_data.py" "$OUT_DIR/rfc3339_200k.txt" 200000 >/dev/null
python3 "$AUDIT_DIR/gen_data.py" "$OUT_DIR" 200000
BYTES=$(wc -c < "$OUT_DIR/rfc3339_200k.txt" | tr -d ' ')
bcmp() {
  python3 "$ROOT_DIR/scripts/bench_compare.py" --baseline rust_jiff --warmup 1 --rounds "$ROUNDS" "$@"
}
echo "--- W1 RFC 3339 parse + shift(+09:00) + format, 200k"
bcmp --title "W1 RFC 3339 (200k)" --ops 200000 --bytes "$BYTES" \
  --impl "pion_raw_b423882=$BIN/pion_rfc3339_raw $OUT_DIR/rfc3339_200k.txt" \
  --impl "pion_typed_slice=$BIN/pion_rfc3339_typed $OUT_DIR/rfc3339_200k.txt" \
  --impl "pion_typed_split=$BIN/pion_rfc3339_split $OUT_DIR/rfc3339_200k.txt" \
  --impl "rust_jiff=$BIN/rust_rfc3339 $OUT_DIR/rfc3339_200k.txt" \
  --impl "go_time=$BIN/go_rfc3339 $OUT_DIR/rfc3339_200k.txt" \
  --md-out "$OUT_DIR/w1.md" --json-out "$OUT_DIR/w1.json" || STATUS=3
echo "--- W2 civil calendar, 2M ops"
bcmp --title "W2 civil (2M)" --ops 2000000 \
  --impl "pion_packed_b423882=$BIN/pion_civil_packed" \
  --impl "pion_typed=$BIN/pion_civil_typed" \
  --impl "rust_jiff=$BIN/rust_civil" \
  --impl "rust_jiff_sd=$BIN/rust_civil_fast" \
  --impl "go_time=$BIN/go_civil" \
  --md-out "$OUT_DIR/w2.md" --json-out "$OUT_DIR/w2.json" || STATUS=3
echo "--- W3 ISO 8601 SignedDuration parse + format, 200k (Go stdlib has no ISO 8601 duration)"
bcmp --title "W3 ISO 8601 duration (200k)" --ops 200000 \
  --impl "pion=$BIN/pion_duration_iso $OUT_DIR/durations.txt" \
  --impl "rust_jiff=$BIN/rust_duration_iso $OUT_DIR/durations.txt" \
  --md-out "$OUT_DIR/w3.md" --json-out "$OUT_DIR/w3.json" || STATUS=3
echo "--- W4 HTTP-date (IMF-fixdate) parse + format, 200k"
bcmp --title "W4 HTTP-date (200k)" --ops 200000 \
  --impl "pion=$BIN/pion_http_date $OUT_DIR/http_dates.txt" \
  --impl "rust_jiff=$BIN/rust_http_date $OUT_DIR/http_dates.txt" \
  --impl "go_time=$BIN/go_http_date $OUT_DIR/http_dates.txt" \
  --md-out "$OUT_DIR/w4.md" --json-out "$OUT_DIR/w4.json" || STATUS=3
echo "--- W5 SignedDuration + Timestamp arithmetic, 5M"
bcmp --title "W5 duration arithmetic (5M)" --ops 5000000 \
  --impl "pion=$BIN/pion_sd_arith" \
  --impl "rust_jiff=$BIN/rust_sd_arith" \
  --impl "go_time=$BIN/go_sd_arith" \
  --md-out "$OUT_DIR/w5.md" --json-out "$OUT_DIR/w5.json" || STATUS=3
echo ""
echo "=== 7. Root cause of W5: heap allocations per checked op (call sites of _pion_alloc* in each fn) ==="
otool -tV "$BIN/pion_sd_arith" 2>/dev/null | awk '/^_.*:$/{f=$0} /bl\t_pion_alloc/{c[f]++} END{for(k in c) print "  " c[k] "\t" k}' | grep -E 'time_(m|fn)_' | sort -rn ||
  echo "  (otool unavailable; on Linux use objdump -d)"
echo ""
echo "Reports: $OUT_DIR/{differential,w1,w2,w3,w4,w5}.md"
exit $STATUS
