#!/bin/sh
# Red-team audit of packages/cron (Pion) vs Rust croner 2.1.0, Go robfig/cron/v3 v3.0.1 and
# Java Quartz 2.3.2 (org.quartz.CronExpression).
#
#   sh packages/cron/audit/run_audit.sh            # full run (~3-5 min on an M-series Mac)
#   QUICK=1 sh packages/cron/audit/run_audit.sh    # smaller corpus, skip benchmarks
#
# Needs: pionc ($HOME/.pion/bin), node, go, cargo, java/javac (>= 11), python3, curl (first run
# downloads quartz-2.3.2.jar from Maven Central, sha256-checked). All builds, corpora and reports
# go to $AUDIT_OUT (default /private/tmp/pion-cron-audit); the git worktree is never written to.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CRON_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$CRON_DIR/../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/pion-cron-audit}
BIN="$OUT/bin"
QUICK=${QUICK:-0}
N_RANDOM=20000
[ "$QUICK" = 1 ] && N_RANDOM=3000
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
QJAR="$OUT/java/quartz-2.3.2.jar"
QUARTZ="java -cp $OUT/java:$QJAR QuartzProbe"
mkdir -p "$BIN" "$OUT/java"

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }
secs() { python3 -c 'import sys,time,subprocess;t=time.time();subprocess.run(sys.argv[1:],stdout=subprocess.DEVNULL);print("%.3f"%(time.time()-t))' "$@"; }

section "0. Build (Pion probe native debug/release + wasm32 debug/release, croner, robfig, Quartz)"
pionc build -o "$BIN/probe_debug" "$AUDIT_DIR/probe"
pionc build --release -o "$BIN/probe_release" "$AUDIT_DIR/probe"
pionc build --target wasm32 -o "$BIN/probe_debug.wasm" "$AUDIT_DIR/probe"
pionc build --target wasm32 --release -o "$BIN/probe_release.wasm" "$AUDIT_DIR/probe"
cp "$BIN/probe_release" "$BIN/probe"
for m in debug release; do
  F=""; [ $m = release ] && F=--release
  pionc build $F -o "$BIN/smoke_$m" "$CRON_DIR/wasm_smoke"
  pionc build --target wasm32 $F -o "$BIN/smoke_$m.wasm" "$CRON_DIR/wasm_smoke"
done
rm -rf "$OUT/rust-build" "$OUT/go-build"
cp -R "$AUDIT_DIR/rust" "$OUT/rust-build"
CARGO_TARGET_DIR="$OUT/rust-target" cargo build -q --release --manifest-path "$OUT/rust-build/Cargo.toml"
cp "$OUT/rust-target/release/croner_probe" "$BIN/"
cp -R "$AUDIT_DIR/go" "$OUT/go-build"
(cd "$OUT/go-build" && go build -o "$BIN/robfig_probe" .)
if [ ! -f "$QJAR" ]; then
  curl -sSfL -o "$QJAR" https://repo1.maven.org/maven2/org/quartz-scheduler/quartz/2.3.2/quartz-2.3.2.jar
fi
echo "639c6a675bc472e1568df9d8c954ff702da6f83ed27da0ff9a7bd12ed73b8bf0  $QJAR" | shasum -a 256 -c -
javac -d "$OUT/java" -cp "$QJAR" "$AUDIT_DIR/java/QuartzProbe.java"
python3 "$AUDIT_DIR/gen_corpus.py" "$OUT/corpus" "$N_RANDOM"
python3 "$AUDIT_DIR/gen_bench.py" "$OUT/bench"

section "1. Red-team unit tests: pionc test packages/cron/audit (every redteam_* failure is a finding)"
(cd "$CRON_DIR" && pionc test --json audit > "$OUT/redteam_test.json" 2> "$OUT/redteam_test.stderr") || true
python3 - "$OUT/redteam_test.json" <<'PY' || true
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
mine = [t for t in d["tests"] if t["pkg"] == "cron_audit"]
print("cron_audit: %d tests, %d FAILED (findings), %d passed (controls)" % (
    len(mine), sum(not t["ok"] for t in mine), sum(t["ok"] for t in mine)))
for t in mine:
    print("  %-6s %s" % ("FAIL" if not t["ok"] else "pass", t["name"]))
PY
echo "assertion messages:"; sed 's|^.*/audit/|  |' "$OUT/redteam_test.stderr"

section "2. Differential: random + adversarial corpora vs croner / robfig / Quartz"
C="$OUT/corpus"
for s in std sec quartz adv; do
  "$BIN/probe" diff "$C/$s.txt" > "$OUT/$s.pion"
  "$BIN/croner_probe" "$C/$s.txt" > "$OUT/$s.croner"
  "$BIN/robfig_probe" "$C/$s.txt" > "$OUT/$s.robfig"
  $QUARTZ "$C/$s.txt" > "$OUT/$s.quartz"
done
cd "$AUDIT_DIR"
for s in std sec; do
  echo "--- $s.txt ($(wc -l < "$C/$s.txt" | tr -d ' ') cases)"
  python3 compare.py "$C/$s.txt" "$OUT/$s.pion" croner="$OUT/$s.croner" robfig="$OUT/$s.robfig" | grep -v '^      ' || true
  python3 triage.py "$BIN/probe" "$C/$s.txt" "$OUT/$s.pion" croner "$OUT/$s.croner"
  python3 triage.py "$BIN/probe" "$C/$s.txt" "$OUT/$s.pion" robfig "$OUT/$s.robfig"
done
echo "--- quartz.txt ($(wc -l < "$C/quartz.txt" | tr -d ' ') Quartz-comparable cases; all mismatches listed)"
python3 compare.py "$C/quartz.txt" "$OUT/quartz.pion" quartz="$OUT/quartz.quartz" || true
echo "--- adv.txt (hand-written boundary set; side-by-side table in $OUT/adv_table.txt)"
python3 - "$C/adv.txt" "$OUT" > "$OUT/adv_table.txt" <<'PY'
import datetime, sys
cases = [l.rstrip("\n").split("\t") for l in open(sys.argv[1])]
R = {k: [l.rstrip("\n") for l in open("%s/adv.%s" % (sys.argv[2], k))] for k in ("pion", "croner", "robfig", "quartz")}
def iso(v):
    try:
        return (datetime.datetime(1970, 1, 1) + datetime.timedelta(seconds=int(v))).strftime("%Y-%m-%d")
    except ValueError:
        return v
def short(l):
    t = l.split()
    if t[0] != "OK":
        return t[0]
    n = []
    for x in t[3:]:
        if x == "P":
            break
        n.append(iso(x))
    return " ".join(n[:3])
for i, c in enumerate(cases):
    print("%-4s %-36s from %s" % (c[0], c[1], iso(c[2])))
    for k in R:
        print("       %-7s %s" % (k, short(R[k][i])))
PY
grep -c . "$OUT/adv_table.txt" >/dev/null && echo "  written: $OUT/adv_table.txt"

section "3. Invariants (matches/next/prev/inclusive/unix, years 1..9999) -- native debug+release, wasm debug+release"
for m in debug release; do
  printf '  native %-7s ' $m; "$BIN/probe_$m" inv "$C/inv.txt" | tail -1
  printf '  wasm32 %-7s ' $m; node "$RT" "$BIN/probe_$m.wasm" inv "$C/inv.txt" | tail -1
done

section "4. Native vs Wasm32 x debug/release: byte-identical differential output + wasm_smoke under node"
cat "$C/std.txt" "$C/sec.txt" "$C/quartz.txt" "$C/adv.txt" > "$C/all.txt"
for m in debug release; do
  "$BIN/probe_$m" diff "$C/all.txt" > "$OUT/all.native_$m"
  node "$RT" "$BIN/probe_$m.wasm" diff "$C/all.txt" > "$OUT/all.wasm_$m"
  "$BIN/smoke_$m" && echo "  smoke native $m: exit 0" || echo "  smoke native $m: FAILED"
  node "$RT" "$BIN/smoke_$m.wasm" && echo "  smoke wasm32 $m: exit 0" || echo "  smoke wasm32 $m: FAILED"
done
(cd "$OUT" && shasum -a 256 all.native_debug all.native_release all.wasm_debug all.wasm_release | sed 's/^/  /')
echo "  lines: $(wc -l < "$OUT/all.native_release" | tr -d ' ') each"

section "5. DoS / malformed input probes (F4: year list re-parsed on every search step)"
YL=$(python3 -c 'print(",".join(str(y) for y in range(1970,2127)))')
Y2K=$(python3 -c 'print(",".join(str(y) for y in range(1,2001)))')
YALL=$(python3 -c 'print(",".join(str(y) for y in range(1,10000)))')
printf '  %-58s %s\n' "case" "seconds (1 next_after call unless noted)"
for spec in "q|0 0 0 31 2,4,6,9,11 ? 1970-2126|-62135596800" \
            "q|0 0 0 31 2,4,6,9,11 ? 1-9999|-62135596800" \
            "q|0 0 0 31 2,4,6,9,11 ? <157-item list 1970..2126>|-62135596800" \
            "q|0 0 0 31 2,4,6,9,11 ? <2000-item list 1..2000>|-62135596800" \
            "q|0 0 0 31 2,4,6,9,11 ? <9999-item list 1..9999>|-62135596800" \
            "q|0 0 0 29 2 * 2100-2103|0" "and|0 0 0 29 2 1 2000-2100|0" "q|0 0 0 L-30 2 ?|0"; do
  o=${spec%%|*}; rest=${spec#*|}; e=${rest%|*}; st=${rest##*|}
  case "$e" in
    *"<157-item"*) ee="0 0 0 31 2,4,6,9,11 ? $YL" ;;
    *"<2000-item"*) ee="0 0 0 31 2,4,6,9,11 ? $Y2K" ;;
    *"<9999-item"*) ee="0 0 0 31 2,4,6,9,11 ? $YALL" ;;
    *) ee="$e" ;;
  esac
  printf '  %-58s pion %s s\n' "$e" "$(secs timeout 120 "$BIN/probe" time "$o" "$ee" "$st" 1)"
done
printf 'q\t0 0 0 31 2,4,6,9,11 ? %s\t0\t1\n' "$YL" > "$OUT/dos157.txt"
printf '  %-58s quartz %s s (JVM start included; Quartz caps years at 2126)\n' "<157-item list> same call" "$(secs $QUARTZ "$OUT/dos157.txt")"
LONG=$(python3 -c 'print(",".join(["1"]*50000) + " * * * *")')
printf '  %-58s pion %s s\n' "parse 100 KB '1,1,1,...' list" "$(secs "$BIN/probe" time std "$LONG" 0 1)"
SP=$(python3 -c 'print("0"+" "*100000+"0 * * *")')
printf '  %-58s pion %s s\n' "parse 100 KB of spaces between fields" "$(secs "$BIN/probe" time std "$SP" 0 1)"
for e in "$(printf '0 0 * * \001')" "$(printf '0 0 *\v* *')" "$(printf '0 0 1\357\274\221 * *')" "$(printf '0 0 * * MON\303\251')"; do
  printf '  %-58s %s\n' "parse control-char / multi-byte UTF-8 field" "$("$BIN/probe" time std "$e" 0 1)"
done

section "6. F3: from_unix_secs aliasing (32-bit era truncation) -- native and wasm32"
for ts in 3388401920987913600 -3388401919084176000 253402300800 -62135596801; do
  printf '  %-22s native=%s | wasm32=%s\n' "$ts" "$("$BIN/probe" unix "$ts")" "$(node "$RT" "$BIN/probe_release.wasm" unix "$ts")"
done

if [ "$QUICK" = 1 ]; then echo; echo "QUICK=1: benchmarks skipped"; exit 0; fi

section "7. Adversarial head-to-head benchmarks (scripts/bench_compare.py, SHA-256 checked)"
B="$OUT/bench"
bc() { python3 "$ROOT_DIR/scripts/bench_compare.py" --warmup 1 --rounds 5 "$@" || echo "  (bench_compare failed)"; }
bc --title "A1 Quartz day features L/W/#/nL (8 exprs x 200 steps x 200 rounds)" --ops 320000 \
  --impl "pion=$BIN/probe bench-step $B/b_quartz3.txt 200 200" \
  --impl "rust_croner=$BIN/croner_probe bench-step $B/b_quartz3.txt 200 200" \
  --impl "quartz=$QUARTZ bench-step $B/b_quartz3.txt 200 200" --baseline rust_croner --md-out "$OUT/a1.md"
bc --title "A2 Quartz-only LW / L-n (5 exprs x 100 steps x 400 rounds)" --ops 200000 \
  --impl "pion=$BIN/probe bench-step $B/b_quartz_ext.txt 100 400" \
  --impl "quartz=$QUARTZ bench-step $B/b_quartz_ext.txt 100 400" --baseline quartz --md-out "$OUT/a2.md"
bc --title "A3 7-field year ranges/steps/lists (5 exprs x <=100 steps x 200 rounds)" --ops 66800 \
  --impl "pion=$BIN/probe bench-step $B/b_years.txt 100 200" \
  --impl "quartz=$QUARTZ bench-step $B/b_years.txt 100 200" --baseline quartz --md-out "$OUT/a3.md"
bc --title "A4 F4 DoS: impossible date + 157-item year list (1 search x 2000 rounds)" --ops 2000 \
  --impl "pion=$BIN/probe bench-step $B/b_yearlist_dos.txt 1 2000" \
  --impl "quartz=$QUARTZ bench-step $B/b_yearlist_dos.txt 1 2000" --baseline quartz --md-out "$OUT/a4.md"
bc --title "A5 Reject malformed input (21 exprs x 20000 rounds)" --ops 420000 \
  --impl "pion=$BIN/probe bench-parse $B/b_invalid.txt 20000" \
  --impl "rust_croner=$BIN/croner_probe bench-parse $B/b_invalid.txt 20000" \
  --impl "go_robfig=$BIN/robfig_probe bench-parse $B/b_invalid.txt 20000" --baseline rust_croner --md-out "$OUT/a5.md"
bc --title "A6 Long explicit lists (3 exprs, up to 2 KB, x 20000 rounds)" --ops 60000 \
  --impl "pion=$BIN/probe bench-parse $B/b_longlist.txt 20000" \
  --impl "rust_croner=$BIN/croner_probe bench-parse $B/b_longlist.txt 20000" \
  --impl "go_robfig=$BIN/robfig_probe bench-parse $B/b_longlist.txt 20000" --baseline rust_croner --md-out "$OUT/a6.md"

section "8. Benchmark fairness: W1 dead-code-elimination control (Pion parse result folded vs unused)"
python3 "$CRON_DIR/bench/gen_data.py" "$OUT/exprs_100.txt" >/dev/null
sed 's/^/std\t/' "$OUT/exprs_100.txt" > "$OUT/w1_std.txt"
for i in 1 2 3; do
  printf '  round %d: W1-style parse (result unused) %s s | parse + fold every mask %s s\n' "$i" \
    "$(secs "$BIN/probe" bench-parse "$OUT/w1_std.txt" 1000)" "$(secs "$BIN/probe" bench-parse-fold "$OUT/w1_std.txt" 1000)"
done

echo; echo "done; artifacts in $OUT"
