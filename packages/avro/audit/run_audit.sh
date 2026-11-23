#!/bin/sh
# Red-team audit of packages/avro (Pion) vs Apache Avro 1.11.1 / Go hamba/avro/v2 v2.28.0.
#
#   sh packages/avro/audit/run_audit.sh              # full run (~2 min on an M-series Mac; wasm32 OOM probe peaks at 4 GB)
#   QUICK=1 sh packages/avro/audit/run_audit.sh      # fewer fuzz cases, no wasm OOM probe, no bench
#   SKIP_BENCH=1 sh packages/avro/audit/run_audit.sh # everything except the bench re-run
#
# Exit status: 0 only if every red-team unit test passes, the hamba differential has no FINDING
# bucket, every DoS / crash probe stays within its bound and the 4 build modes agree.
# Needs: pionc ($HOME/.pion/bin, AFK-surf/pion@66d2b4b), go >= 1.24, node (wasm32 runs), python3.
# All builds, inputs and logs go to $AUDIT_OUT (default /private/tmp/rt-avro-audit-$USER);
# the git worktree is never written to. Go builds use the committed go.sum (-mod=readonly).
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AVRO_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$AVRO_DIR/../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/rt-avro-audit-$(id -un)}
BIN="$OUT/bin"
QUICK=${QUICK:-0}
SKIP_BENCH=${SKIP_BENCH:-$QUICK}
FUZZ_N=${FUZZ_N:-10000}
[ "$QUICK" = 1 ] && FUZZ_N=2000
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export GOFLAGS=-mod=readonly
mkdir -p "$BIN"
FAILS=0
FAILED=""

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); FAILED="$FAILED\n  - $1"; printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
pass() { printf '  \033[32mpass\033[0m %s\n' "$1"; }
measure() { python3 "$AUDIT_DIR/measure.py" "$@"; }
# field <key> <line>: extract "key=value" from a measure.py line
field() { printf '%s\n' "$2" | sed -n "s/.*$1=[ ]*\([^ ]*\).*/\1/p"; }

section "0. Build (serial): Pion probe --release, Go oracle (locked go.sum) -> $BIN"
pionc --version
pionc build --release -o "$BIN/pion_probe" "$AUDIT_DIR/probe" >/dev/null
rm -rf "$OUT/go-build" && cp -R "$AUDIT_DIR/go" "$OUT/go-build"
(cd "$OUT/go-build" && go build -o "$BIN/go_oracle" .)
python3 "$AUDIT_DIR/gen_ocf.py" "$OUT/ocf"

section "1. Red-team unit tests: pionc test packages/avro/audit (every redteam_* failure is a finding)"
(cd "$AVRO_DIR" && pionc test --json audit > "$OUT/redteam_test.json" 2> "$OUT/redteam_test.stderr") || true
if python3 - "$OUT/redteam_test.json" <<'PY'
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
mine = [t for t in d["tests"] if t["pkg"] == "avro_audit"]
bad = [t for t in mine if not t["ok"]]
print("avro_audit: %d tests, %d FAILED (findings), %d passed" % (len(mine), len(bad), len(mine) - len(bad)))
for t in mine:
    print("  %-5s %s" % ("FAIL" if not t["ok"] else "pass", t["name"]))
others = [t for t in d["tests"] if t["pkg"] != "avro_audit" and not t["ok"]]
if others:
    print("upstream package tests failing: %d" % len(others))
sys.exit(1 if bad or others or len(mine) == 0 else 0)
PY
then pass "red-team unit tests"; else fail "red-team unit tests (see assertion messages)"; fi
echo "assertion messages:"; sed 's|^.*/audit/|  |' "$OUT/redteam_test.stderr"

section "2. Differential vs Go hamba/avro/v2 v2.28.0 (hand-written spec cases + $FUZZ_N random schemas/datums/evolutions)"
if python3 "$AUDIT_DIR/diff_oracle.py" "$BIN/pion_probe" "$BIN/go_oracle" "$OUT/diff" "$FUZZ_N" 1111 > "$OUT/diff.txt"; then
  pass "no FINDING bucket"; else fail "differential has FINDING buckets"; fi
grep -v '^      case:' "$OUT/diff.txt"
python3 - "$OUT/diff" <<'PY'
import os, sys
d = sys.argv[1]
C = open(os.path.join(d, "cases.txt")).read().split("\n")
P = open(os.path.join(d, "pion.out")).read().split("\n")
G = open(os.path.join(d, "go.out")).read().split("\n")
s = [(p, g) for c, p, g in zip(C, P, G) if c.startswith("S ") and p.startswith("ok") and g.startswith("ok")]
print("PCF + CRC-64-AVRO byte-identical with hamba on %d/%d schemas both accept" % (sum(p == g for p, g in s), len(s)))
PY

section "3. 4-mode consistency (native dbg/rel, wasm32 dbg/rel)"
H=""
for m in "" "--release" "--target wasm32" "--target wasm32 --release"; do
  # shellcheck disable=SC2086
  (cd "$AVRO_DIR" && pionc run $m audit/probe -- smoke) > "$OUT/smoke.txt" 2>&1 || true
  h=$(shasum -a 256 "$OUT/smoke.txt" | cut -c1-16)
  printf '  audit/probe smoke [%-26s] sha256=%s lines=%s\n' "$m" "$h" "$(wc -l < "$OUT/smoke.txt" | tr -d ' ')"
  H="$H $h"
done
if [ "$(printf '%s\n' $H | sort -u | wc -l | tr -d ' ')" = 1 ]; then pass "probe smoke digest identical in 4 modes"; else fail "probe smoke digest differs between modes"; fi
H=""
for m in "" "--release" "--target wasm32" "--target wasm32 --release"; do
  # shellcheck disable=SC2086
  (cd "$AVRO_DIR" && pionc run $m wasm_smoke) > "$OUT/wasm_smoke.txt" 2>&1 || true
  h=$(shasum -a 256 "$OUT/wasm_smoke.txt" | cut -d' ' -f1)
  printf '  packages/avro/wasm_smoke [%-26s] sha256=%s\n' "$m" "$h"
  H="$H $h"
done
if [ "$(printf '%s\n' $H | sort -u | wc -l | tr -d ' ')" = 1 ]; then pass "wasm_smoke identical in 4 modes"; else fail "wasm_smoke differs between modes"; fi

section "4. DoS / crash probes (default AvroLimits unless stated)"
echo "--- 4a. OCF element amplification: each block = 1 datum array<null> x 1,000,000 (max_elements is per block)"
for f in amp_1 amp_8 amp_32 amp_64 amp_deflate_64; do
  measure "pion read_ocf $f ($(wc -c < "$OUT/ocf/$f.avro" | tr -d ' ') B)" 120 "$BIN/pion_probe" ocf_read "$OUT/ocf/$f.avro"
done
measure "go   read_ocf_all amp_64 (hamba, retains every record)" 120 "$BIN/go_oracle" ocf_read_all "$OUT/ocf/amp_64.avro"
measure "go   read_ocf amp_64 (hamba streaming decoder)" 120 "$BIN/go_oracle" ocf_read "$OUT/ocf/amp_64.avro"
L=$(measure "pion read_ocf amp_64 [gate]" 120 "$BIN/pion_probe" ocf_read "$OUT/ocf/amp_64.avro")
RSS=$(field peak_rss "$L" | cut -d. -f1)
if [ "${RSS:-9999}" -lt 128 ]; then pass "amp_64: 1.5 KB file stays under 128 MiB (${RSS} MiB)"; else fail "F-03 amp_64: 1,493-byte OCF costs ${RSS} MiB with default limits"; fi
if [ "$QUICK" != 1 ]; then
  python3 -c "
import sys; sys.path.insert(0, '$AUDIT_DIR'); import gen_ocf as g
open('$OUT/ocf/amp_512.avro', 'wb').write(g.header({'type': 'array', 'items': 'null'}) + g.block(1, g.lng(1000000) + b'\x00') * 512)"
  L=$(cd "$AVRO_DIR" && measure "wasm32 --release read_ocf amp_512 (11.8 KB)" 300 pionc run --release --target wasm32 audit/probe -- ocf_read "$OUT/ocf/amp_512.avro")
  echo "$L"
  case "$L" in *"Memory.grow"*|*RangeError*|*TIMEOUT*) fail "F-03 wasm32: 11.8 KB OCF traps WebAssembly.Memory.grow";; *) pass "wasm32 amp_512";; esac
fi

echo "--- 4b. deflate bombs (max_bytes = 64 MiB per block)"
measure "pion read_ocf bomb_512m (512 MiB of zeros, 510 KB)" 120 "$BIN/pion_probe" ocf_read "$OUT/ocf/bomb_512m.avro"
measure "go   read_ocf bomb_512m" 120 "$BIN/go_oracle" ocf_read "$OUT/ocf/bomb_512m.avro"
measure "pion read_ocf bomb_8x60m (8 legal 60 MiB blocks, 478 KB)" 120 "$BIN/pion_probe" ocf_read "$OUT/ocf/bomb_8x60m.avro"
L=$(measure "pion bomb_512m [gate]" 120 "$BIN/pion_probe" ocf_read "$OUT/ocf/bomb_512m.avro")
RSS=$(field peak_rss "$L" | cut -d. -f1)
case "$L" in *"out=err"*) if [ "${RSS:-9999}" -lt 256 ]; then pass "bomb_512m rejected, peak ${RSS} MiB"; else fail "bomb_512m peak ${RSS} MiB"; fi;; *) fail "bomb_512m not rejected";; esac

echo "--- 4c. OCF header schema: enum symbol de-duplication is O(n^2) (schema comes from the untrusted file)"
python3 -c "
import sys, json; sys.path.insert(0, '$AUDIT_DIR'); import gen_ocf as g
for n in (20000, 40000, 80000, 160000):
    open('$OUT/ocf/enum_%d.avro' % n, 'wb').write(g.header({'type': 'enum', 'name': 'E', 'symbols': ['S%d' % i for i in range(n)]}))"
for n in 20000 40000 80000; do
  measure "pion read_ocf header with enum of $n symbols ($(wc -c < "$OUT/ocf/enum_$n.avro" | tr -d ' ') B)" 300 "$BIN/pion_probe" ocf_read "$OUT/ocf/enum_$n.avro"
  measure "go   read_ocf header with enum of $n symbols" 300 "$BIN/go_oracle" ocf_read "$OUT/ocf/enum_$n.avro"
done
L=$(measure "pion enum 160000 symbols [gate]" 300 "$BIN/pion_probe" ocf_read "$OUT/ocf/enum_160000.avro")
echo "$L"
W=$(field wall "$L" | tr -d 's' | cut -d. -f1)
if [ "${W:-999}" -lt 2 ]; then pass "160k-symbol header parsed in ${W}s"; else fail "F-11 1.6 MB OCF header (160k enum symbols) costs ${W:-timeout}s of CPU"; fi

echo "--- 4d. recursion: linked list Node{v:long, next:[null,Node]} decoded from attacker bytes"
for n in 32 33; do measure "pion decode n=$n default max_depth=64" 60 "$BIN/pion_probe" deep_list_dec $n 64; done
measure "go   decode n=1000000 (hamba, no depth limit)" 120 "$BIN/go_oracle" deep_list_dec 1000000
for n in 10000 25000 30000 100000; do measure "pion native --release n=$n max_depth=1000000" 60 "$BIN/pion_probe" deep_list_dec $n 1000000; done
L=$(measure "pion native n=100000 max_depth=1000000 [gate]" 60 "$BIN/pion_probe" deep_list_dec 100000 1000000)
case "$L" in *"rc=0 "*|*"out=err"*) pass "native deep decode returns ok/err";; *) fail "F-12 native SIGSEGV decoding a 100,000-node list (200 KB input) with max_depth=1e6";; esac
for n in 400 700; do
  L=$(cd "$AVRO_DIR" && measure "pion wasm32 --release n=$n max_depth=1000000" 120 pionc run --release --target wasm32 audit/probe -- deep_list_dec $n 1000000)
  echo "$L"
done
case "$L" in *"out=ok"*|*"out=err"*) pass "wasm32 deep decode returns ok/err";; *) fail "F-12 wasm32 RangeError (stack) decoding a 700-node list (1.4 KB input)";; esac
L=$(measure "pion native deep_schema n=100000 max_depth=1000000" 60 "$BIN/pion_probe" deep_schema 100000 1000000)
echo "$L"

echo "--- 4e. decode_json: record field lookup is a linear scan of the JSON object (O(fields x keys))"
python3 -c "
import json
f, k = 1000, 200000
open('$OUT/rec_1000.json', 'w').write(json.dumps({'type': 'record', 'name': 'W', 'fields': [{'name': 'f%d' % i, 'type': 'int', 'default': 0} for i in range(f)]}))
open('$OUT/junk.json', 'w').write('{' + ','.join('\"j%d\":0' % i for i in range(k)) + '}')"
measure "pion decode_json 1000-field record, 200k junk keys (2.3 MB)" 120 "$BIN/pion_probe" decode_json_file "$OUT/rec_1000.json" "$OUT/junk.json"

echo "--- 4f. interop: Go reads a Pion-written OCF whose schema had timestamp-millis / uuid / decimal (F-02)"
"$BIN/pion_probe" ocf_write_ts "$OUT/pion_logical.avro"
"$BIN/go_oracle" ocf_info "$OUT/pion_logical.avro" | sed 's/^/  /'

section "5. Benchmark fairness: re-run packages/avro/bench (SHA-256 verified by scripts/bench_compare.py)"
if [ "$SKIP_BENCH" = 1 ]; then
  echo "(skipped)"
else
  BENCH_OUT="$OUT/bench" sh "$AVRO_DIR/bench/run_bench.sh" > "$OUT/bench.txt" 2>&1 || fail "bench run failed (see $OUT/bench.txt)"
  grep -E '^\| |SHA|interop|Pion:|Go:|Pion ->|Go ->' "$OUT/bench.txt" || true
fi

section "6. Worktree cleanliness"
DIRTY=$(git -C "$REPO_ROOT" status --porcelain --ignored -- "$AVRO_DIR" | grep -v '^?? packages/avro/audit/$' || true)
if [ -z "$DIRTY" ]; then pass "no build artefacts in the worktree"; else fail "worktree dirty: $DIRTY"; fi

section "Summary"
if [ "$FAILS" -eq 0 ]; then
  echo "ALL GATES PASS (artefacts in $OUT)"
  exit 0
fi
printf 'FAILED GATES: %d%b\n' "$FAILS" "$FAILED"
echo "(artefacts in $OUT)"
exit 1
