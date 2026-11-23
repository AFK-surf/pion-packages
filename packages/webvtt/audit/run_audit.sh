#!/bin/sh
# One-shot red-team audit for packages/webvtt (RT-webvtt). Must be run unmodified by whoever fixes the package.
#
#   sh packages/webvtt/audit/run_audit.sh             # everything (gates + benchmark)
#   sh packages/webvtt/audit/run_audit.sh --no-bench  # skip the timed head-to-head benchmark (step 11)
#
# All build outputs / generated inputs go to $AUDIT_OUT (default ${TMPDIR:-/tmp}/pion-webvtt-audit);
# the git worktree must stay clean. Requires: pionc, python3, node (>= 18), go (bench only).
#
# Exit status: 0 only if every gate passes, i.e. it is NON-ZERO while any audited defect (AUDIT_REPORT.md
# F1..F20) is still present. Each step prints "GATE <id> PASS|FAIL" lines; the summary lists all failures.
set -u

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
O="${AUDIT_OUT:-${TMPDIR:-/tmp}/pion-webvtt-audit}"
O="${O%/}"
BIN="$O/bin"
RUN_BENCH=1
[ "${1:-}" = "--no-bench" ] && RUN_BENCH=0
export PATH="$HOME/.pion/bin:$PATH"
mkdir -p "$BIN"
FAILED=""

step() { printf '\n==> %s\n' "$*"; }
gate() { # gate <id> <0|1> <description>
  if [ "$2" -eq 0 ]; then
    echo "GATE $1 PASS  $3"
  else
    echo "GATE $1 FAIL  $3"
    FAILED="$FAILED $1"
  fi
}
now() { python3 -c 'import time;print(time.time())'; }
# best-of-3 wall seconds of a command (stdout discarded)
wall() {
  python3 - "$@" <<'EOF'
import subprocess, sys, time
best = None
for _ in range(3):
    t0 = time.perf_counter()
    r = subprocess.run(sys.argv[1:], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    dt = time.perf_counter() - t0
    if r.returncode != 0:
        print("ERR"); sys.exit(0)
    best = dt if best is None else min(best, dt)
print("%.4f" % best)
EOF
}

step "0. toolchain"
pionc --version
node --version
python3 --version
uname -sm

step "1. source hygiene of packages/webvtt/src (portability, Send-cleanliness, dead variants)"
SRC="$PKG_DIR/src"
n_extern=$(grep -c 'extern "C"' "$SRC"/*.pion | awk -F: '{s+=$2} END {print s+0}')
n_world=$(grep -cw 'World' "$SRC"/*.pion | awk -F: '{s+=$2} END {print s+0}')
n_glob=$(grep -cE '^(pub )?(let mut|var) ' "$SRC"/*.pion | awk -F: '{s+=$2} END {print s+0}')
n_unimpl=$(grep -c 'Unimplemented' "$SRC"/*.pion | awk -F: '{s+=$2} END {print s+0}')
echo "extern \"C\": $n_extern | World: $n_world | module-level mutable bindings: $n_glob | Unimplemented: $n_unimpl"
gate H1 $([ "$n_extern" -eq 0 ] && [ "$n_world" -eq 0 ] && [ "$n_glob" -eq 0 ]; echo $?) "0 extern \"C\" / 0 World / 0 module-level mutable state"
gate F16 $([ "$n_unimpl" -eq 0 ]; echo $?) "no dead WebVttError::Unimplemented variant left from the Red-phase stubs"

step "2. package's own gate (scripts/verify.sh --allow-dirty packages/webvtt)"
sh "$ROOT_DIR/scripts/verify.sh" --allow-dirty "$PKG_DIR" >"$O/verify.log" 2>&1
rc=$?
tail -3 "$O/verify.log"
gate PKG $rc "fmt --check / check / test of packages/webvtt"

step "3. fmt + check of the audit packages"
rc=0
for p in "$AUDIT_DIR" "$AUDIT_DIR/probe"; do
  pionc fmt --check "$p" || rc=1
  pionc check --json "$p" >"$O/check.json" 2>&1 || { cat "$O/check.json"; rc=1; }
done
gate AUDIT-BUILD $rc "audit test package + probe compile and are formatted"
pionc build --release -o "$BIN/probe" "$AUDIT_DIR/probe" || { echo "probe build failed"; exit 2; }

step "4. red-team tests (p1_/p2_ FAIL while the defect exists; ctl_ must PASS)"
pionc test --json "$AUDIT_DIR" 2>"$O/test.stderr" >"$O/test.json"
python3 - "$O/test.json" "$O/test.stderr" <<'EOF'
import json, sys
j = json.load(open(sys.argv[1]))
mine = [t for t in j.get("tests", []) if t.get("pkg") == "webvtt_audit"]
for t in mine:
    print(("PASS " if t["ok"] else "FAIL ") + t["name"])
bad_ctl = [t["name"] for t in mine if t["name"].startswith("ctl_") and not t["ok"]]
if bad_ctl:
    print("UNEXPECTED control failures (regression):", bad_ctl)
print("--- assertion messages ---")
for line in open(sys.argv[2], errors="replace"):
    print("  " + line.rstrip()[:240])
EOF
for t in $(python3 -c "
import json,sys
j=json.load(open('$O/test.json'))
for t in j.get('tests',[]):
    if t.get('pkg')=='webvtt_audit': print(t['name']+':'+('0' if t['ok'] else '1'))
"); do
  name=${t%:*}
  gate "T:$name" "${t##*:}" "redteam_test.pion"
done
python3 -c "import json;j=json.load(open('$O/test.json'));import sys;sys.exit(0 if any(t.get('pkg')=='webvtt_audit' for t in j.get('tests',[])) else 1)"
gate AUDIT-TESTS-RAN $? "red-team test package executed"

step "5. F4: mutate WebVttTrack.cues then query (no panic, no stale index)"
if pionc build --release -o "$BIN/mutation" "$AUDIT_DIR/mutation" >"$O/mutation_build.log" 2>&1; then
  "$BIN/mutation" >"$O/mutation.out" 2>&1
  rc=$?
  cat "$O/mutation.out"
  gate F4 $rc "active_cues_at after cues.push / cues[i]=... (exit $rc)"
else
  # Fixed by making the cue list immutable: the build error must be in mutation/src, not in packages/webvtt.
  cat "$O/mutation_build.log" | head -20
  if pionc check --json "$PKG_DIR" >/dev/null 2>&1 && grep -q 'mutation/src/main.pion' "$O/mutation_build.log"; then
    gate F4 0 "cue list no longer mutable through the public API (probe does not compile)"
  else
    gate F4 1 "mutation probe failed to build for an unrelated reason"
  fi
fi

step "6. upstream WPT conformance (native): webvtt/parsing/file-parsing + cue-text-parsing"
node "$AUDIT_DIR/wpt/run_file_parsing.mjs" "$BIN/probe" >"$O/wpt_fp_native.txt" 2>&1
rc=$?
cat "$O/wpt_fp_native.txt"
gate WPT-FP $rc "WPT file-parsing (42 files + 11 invalid signatures; stylesheets n/a)"
python3 "$AUDIT_DIR/wpt/run_cue_text.py" "$BIN/probe" "$O/cuetext" >"$O/wpt_ct_native.txt" 2>&1
rc=$?
cat "$O/wpt_ct_native.txt"
gate WPT-CT $rc "WPT cue-text-parsing (78 trees) + plain_text/AST invariant"

step "7. wasm32: same probe, same WPT inputs, must be byte-identical to native and pass the same gates"
cat >"$BIN/probe_wasm" <<EOF
#!/bin/sh
exec pionc run --release --target wasm32 "$AUDIT_DIR/probe" -- "\$@"
EOF
chmod +x "$BIN/probe_wasm"
T0=$(now)
node "$AUDIT_DIR/wpt/run_file_parsing.mjs" "$BIN/probe_wasm" >"$O/wpt_fp_wasm.txt" 2>&1
python3 "$AUDIT_DIR/wpt/run_cue_text.py" "$BIN/probe_wasm" "$O/cuetext" >"$O/wpt_ct_wasm.txt" 2>&1
T1=$(now)
rc=0
cmp -s "$O/wpt_fp_native.txt" "$O/wpt_fp_wasm.txt" || { echo "file-parsing native/wasm DIFFER:"; diff "$O/wpt_fp_native.txt" "$O/wpt_fp_wasm.txt" | head -20; rc=1; }
cmp -s "$O/wpt_ct_native.txt" "$O/wpt_ct_wasm.txt" || { echo "cue-text native/wasm DIFFER:"; diff "$O/wpt_ct_native.txt" "$O/wpt_ct_wasm.txt" | head -20; rc=1; }
echo "wasm32 WPT run: $(tail -1 "$O/wpt_fp_wasm.txt") / $(tail -1 "$O/wpt_ct_wasm.txt") ($(python3 -c "print(round($T1-$T0,1))") s incl. compile)"
gate WASM-EQ $rc "wasm32 WPT results byte-identical to native"
grep -q 'RESULT: PASS' "$O/wpt_fp_wasm.txt" && grep -q 'RESULT: PASS' "$O/wpt_ct_wasm.txt"
gate WPT-WASM $? "WPT conformance on wasm32"

step "8. wasm_smoke in four modes (native debug/release, wasm32 debug/release): exit 0 + identical stdout"
rc=0
i=0
for mode in "" "--release" "--target wasm32" "--release --target wasm32"; do
  i=$((i + 1))
  # shellcheck disable=SC2086
  pionc run $mode "$PKG_DIR/wasm_smoke" >"$O/smoke_$i.txt" 2>"$O/smoke_$i.err"
  r=$?
  echo "mode[$i] '${mode:-debug}': exit $r, $(head -1 "$O/smoke_$i.txt")"
  [ $r -eq 0 ] || rc=1
  [ $i -gt 1 ] && { cmp -s "$O/smoke_1.txt" "$O/smoke_$i.txt" || { echo "  stdout differs from mode[1]"; rc=1; }; }
done
gate SMOKE4 $rc "wasm_smoke 4-mode"

step "9. resource exhaustion: deep payload trees must not overflow the stack (F5)"
"$BIN/probe" deep 300000 >"$O/deep_native.txt" 2>&1
rc=$?
echo "native deep 300000: exit $rc, $(head -c 80 "$O/deep_native.txt")"
gate F5-NATIVE $rc "parse_cue_payload_with_limits(<b>x300000, 300001) + nodes_to_plain_text (native)"
pionc run --release --target wasm32 "$AUDIT_DIR/probe" -- deep 20000 >"$O/deep_wasm.txt" 2>&1
rc=$?
echo "wasm32 deep 20000: exit $rc, $(head -c 80 "$O/deep_wasm.txt")"
gate F5-WASM $rc "same with 20000 levels on wasm32"

step "10. algorithmic complexity gates (generated 3-16 MB inputs; best of 3 wall times)"
python3 - "$O" <<'EOF'
import os, sys
o = sys.argv[1]
def ts(ms): return "%02d:%02d:%02d.%03d" % (ms // 3600000, ms // 60000 % 60, ms // 1000 % 60, ms % 1000)
N = 99999
def timeline(long):
    p = ["WEBVTT\n\n"]
    p.append("00:00:00.000 --> %s\nbanner\n\n" % (ts(N * 1000 + 5000) if long else "00:00:01.000"))
    for i in range(N):
        p.append("%s --> %s\nx\n\n" % (ts(i * 1000 + 1), ts(i * 1000 + 900)))
    return "".join(p)
open(os.path.join(o, "tl_long.vtt"), "w").write(timeline(True))
open(os.path.join(o, "tl_short.vtt"), "w").write(timeline(False))
blk = "REGION\nid:r0999\n\n"
p = ["WEBVTT\n\n"] + ["REGION\nid:r%04d\n\n" % i for i in range(1000)]
base = sum(map(len, p))
p.append(blk * ((16_000_000 - base) // len(blk)))
open(os.path.join(o, "region_dup.vtt"), "w").write("".join(p))
open(os.path.join(o, "region_single.vtt"), "w").write("WEBVTT\n\n" + blk * ((16_000_000 - 8) // len(blk)))
EOF
Q=20000
t0=$(wall "$BIN/probe" timeline "$O/tl_long.vtt" 0)
tq=$(wall "$BIN/probe" timeline "$O/tl_long.vtt" $Q)
s0=$(wall "$BIN/probe" timeline "$O/tl_short.vtt" 0)
sq=$(wall "$BIN/probe" timeline "$O/tl_short.vtt" $Q)
per_long=$(python3 -c "print(round(max(0.0,$tq-$t0)/$Q*1e6,2))")
per_short=$(python3 -c "print(round(max(0.0,$sq-$s0)/$Q*1e6,2))")
echo "100k cues, $Q queries: one early full-length cue -> ${per_long} us/query; without it -> ${per_short} us/query"
gate F17 $(python3 -c "import sys;sys.exit(0 if $per_long <= 20 else 1)"; echo $?) "active_cue_indices_at stays O(log N + K) with an early long cue (<= 20 us/query; measured ${per_long})"
rd=$(wall "$BIN/probe" parse "$O/region_dup.vtt")
rs=$(wall "$BIN/probe" parse "$O/region_single.vtt")
ratio=$(python3 -c "print(round($rd/max($rs,0.005),1))")
echo "16 MB of duplicate-id REGION blocks after 1000 regions: ${rd}s vs ${rs}s with 1 region (x${ratio})"
gate F19 $(python3 -c "import sys;sys.exit(0 if $ratio <= 5 else 1)"; echo $?) "REGION upsert is not O(regions) per block (<= 5x; measured x${ratio})"

if [ "$RUN_BENCH" -eq 1 ]; then
  step "11. head-to-head benchmark: pion vs go_ref (package bench) vs go_tuned (audit, same rules, idiomatic Go)"
  WEBVTT_DATA="$O/bench_corpus.vtt"
  python3 "$PKG_DIR/bench/gen_data.py" "$WEBVTT_DATA" 8000
  FB=$(wc -c <"$WEBVTT_DATA" | tr -d ' ')
  pionc build --release -o "$BIN/pion_webvtt" "$PKG_DIR/bench/pion_bench" || exit 2
  (cd "$PKG_DIR/bench/go_bench" && go build -o "$BIN/go_ref" .) || exit 2
  (cd "$AUDIT_DIR/bench/go_tuned" && go build -o "$BIN/go_tuned" .) || exit 2
  python3 "$ROOT_DIR/scripts/bench_compare.py" \
    --title "webvtt audit: steady-state parse + plain_text + 2000 queries (20x 8000 cues)" \
    --impl "pion=$BIN/pion_webvtt $WEBVTT_DATA 20" \
    --impl "go_ref=$BIN/go_ref $WEBVTT_DATA 20" \
    --impl "go_tuned=$BIN/go_tuned $WEBVTT_DATA 20" \
    --baseline go_ref --warmup 2 --rounds 9 --bytes $((FB * 20)) --ops 20 \
    --md-out "$O/bench.md" --json-out "$O/bench.json"
  rc=$?
  gate BENCH-SHA $rc "bench_compare.py completed with identical stdout SHA-256"
  python3 - "$O/bench.json" <<'EOF' >"$O/bench_gates.txt"
import json, sys
j = json.load(open(sys.argv[1]))
impls = j.get("impls") or j.get("results") or j
def med(name):
    for it in (impls if isinstance(impls, list) else []):
        if it.get("name") == name:
            return it.get("median_ms") or it.get("median")
    if isinstance(impls, dict) and name in impls:
        v = impls[name]
        return v.get("median_ms") or v.get("median")
    return None
p, g, t = med("pion"), med("go_ref"), med("go_tuned")
print("pion=%s go_ref=%s go_tuned=%s" % (p, g, t))
print("STEADY %d" % (0 if p and p >= 40 else 1))
print("VSREF %d" % (0 if p and g and g / p >= 1.0 else 1))
print("INFO pion vs go_tuned: %s" % (("%.2fx" % (t / p)) if p and t else "n/a"))
EOF
  cat "$O/bench_gates.txt"
  gate BENCH-STEADY "$(awk '/^STEADY/{print $2}' "$O/bench_gates.txt")" "pion median >= 40 ms (steady state)"
  gate BENCH-VSREF "$(awk '/^VSREF/{print $2}' "$O/bench_gates.txt")" "pion >= 1.0x go_ref (package's own claim)"
fi

step "12. worktree must stay clean"
DIRTY=$(git -C "$ROOT_DIR" status --porcelain --ignored -- "$PKG_DIR")
[ -z "$DIRTY" ] || printf '%s\n' "$DIRTY"
gate CLEAN $([ -z "$DIRTY" ]; echo $?) "git status --porcelain --ignored packages/webvtt is empty"

step "SUMMARY"
if [ -z "$FAILED" ]; then
  echo "ALL GATES PASS"
  exit 0
fi
echo "FAILED GATES:$FAILED"
exit 1
