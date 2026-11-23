#!/bin/sh
# Red-team audit of packages/feed (Pion) vs Rust `feed-rs` =2.4.0 and the specifications
# (RFC 4287, RSS 2.0, RSS 1.0, JSON Feed 1.1, RFC 3986, RFC 3339 / RFC 2822, XML 1.0 + Namespaces). See REPORT.md.
#
#   sh packages/feed/audit/run_audit.sh                       # everything (~1-2 min on an M-series Mac)
#   STEPS="unit diff" sh packages/feed/audit/run_audit.sh     # subset of: unit diff roundtrip fourmode dos bench
#
# Exit status: 0 when every graded step passes, 1 when any finding is still present (the expected state on
# feat/pkg-feed @ 5c5b6fd), 2 on a tooling failure. `bench` is informational and never changes the status.
# A fixed branch must reach 0 without touching packages/feed/audit/.
#
# Needs: pionc ($HOME/.pion/bin, AFK-surf/pion@66d2b4b), node (wasm32 runtime), cargo (feed-rs =2.4.0 from
# Cargo.lock, --locked), python3. Builds, corpora and reports go to $AUDIT_OUT (default /private/tmp/rt-feed-audit;
# a real path: the wasm32 runtime resolves file arguments through realpath). The worktree is never written to.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FEED_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$FEED_DIR/../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/rt-feed-audit}
BIN="$OUT/bin"
STEPS=${STEPS:-"unit diff roundtrip fourmode dos bench"}
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH" PYTHONDONTWRITEBYTECODE=1
export CARGO_TARGET_DIR="$OUT/cargo-target"
mkdir -p "$BIN"
want() { case " $STEPS " in *" $1 "*) return 0 ;; esac; return 1; }
section() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }
D="$AUDIT_DIR/diff"
FAILED=""
mark() { # mark <step> <exit status of the graded check>
  if [ "$2" -ne 0 ]; then FAILED="$FAILED $1"; printf '>>> %s: FINDINGS PRESENT\n' "$1"; else printf '>>> %s: PASS\n' "$1"; fi
}

section "0. Build -> $BIN (Pion probe x4 modes, limits probe, feed-rs =2.4.0 oracle)"
# pionc builds are serial on purpose.
pionc build --release -o "$BIN/probe" "$AUDIT_DIR/probe" || exit 2
pionc build -o "$BIN/probe_dbg" "$AUDIT_DIR/probe" || exit 2
pionc build --release --target wasm32 -o "$BIN/probe.wasm" "$AUDIT_DIR/probe" || exit 2
pionc build --target wasm32 -o "$BIN/probe_dbg.wasm" "$AUDIT_DIR/probe" || exit 2
# limits_probe is the only audit code with a FeedLimits literal; if a fix changes FeedLimits it is skipped.
rm -f "$BIN/limits_probe" "$BIN/limits_probe.wasm"
if pionc build --release -o "$BIN/limits_probe" "$AUDIT_DIR/limits_probe" >"$OUT/limits_probe.build.log" 2>&1 &&
  pionc build --release --target wasm32 -o "$BIN/limits_probe.wasm" "$AUDIT_DIR/limits_probe" >>"$OUT/limits_probe.build.log" 2>&1; then
  echo "limits_probe built"
else
  rm -f "$BIN/limits_probe" "$BIN/limits_probe.wasm"
  echo "limits_probe did not build (see $OUT/limits_probe.build.log); lifted-limit runs will be SKIPPED"
fi
rm -rf "$OUT/src-oracle" && cp -R "$AUDIT_DIR/oracle/rust" "$OUT/src-oracle"
cargo build -q --release --locked --manifest-path "$OUT/src-oracle/Cargo.toml" || exit 2
cp "$CARGO_TARGET_DIR/release/rt_feed_oracle" "$BIN/oracle"

if want unit; then
  section "1. Red-team unit tests: pionc test packages/feed/audit (p1_/p2_ FAIL = finding, control_ must pass)"
  (cd "$FEED_DIR" && pionc test --json audit >"$OUT/redteam_test.json" 2>"$OUT/redteam_test.stderr") || true
  rc=0
  python3 - "$OUT/redteam_test.json" <<'PY' || rc=$?
import json, sys
raw = open(sys.argv[1]).read().strip().splitlines()
if not raw:
    print("no pionc test output (compile error?)"); sys.exit(2)
d = json.loads(raw[-1])
if not d.get("tests"):
    print(json.dumps(d)[:2000]); sys.exit(2)
mine = [t for t in d["tests"] if t["pkg"] == "feed_audit"]
other = [t for t in d["tests"] if t["pkg"] != "feed_audit"]
print("feed_audit: %d tests, %d FAILED, %d passed; dependency tests %d/%d ok" % (
    len(mine), sum(not t["ok"] for t in mine), sum(t["ok"] for t in mine), sum(t["ok"] for t in other), len(other)))
for t in mine:
    print("  %-5s %s" % ("FAIL" if not t["ok"] else "pass", t["name"]))
sys.exit(1 if any(not t["ok"] for t in mine) or not mine else 0)
PY
  [ "$rc" -eq 2 ] && exit 2
  echo "first assertion of each failing test:"; sed 's|^.*/audit/|  |' "$OUT/redteam_test.stderr" | head -40
  mark unit "$rc"
fi

if want diff; then
  section "2. Spec-graded differential vs feed-rs =2.4.0 (namespaces, DOCTYPE, types, RFC 3986, xml:base, ints, dates, detection)"
  rc=0; python3 "$D/diff_feed.py" "$OUT/diff" "$BIN/probe" "$BIN/oracle" || rc=$?
  mark diff "$rc"
fi

if want roundtrip; then
  section "3. Serialization safety + roundtrip (to_rss2 / to_atom / to_json_feed -> expat / strict JSON -> reparse)"
  rc=0; python3 "$D/roundtrip.py" "$OUT/rt" "$BIN/probe" "$BIN/oracle" || rc=$?
  mark roundtrip "$rc"
fi

if want fourmode; then
  section "4. 4-mode consistency (native rel/dbg, wasm32 rel/dbg via node): stdout SHA-256 of every request file"
  [ -f "$OUT/diff/diff_requests.tsv" ] || python3 "$D/diff_feed.py" "$OUT/diff" "$BIN/probe" "$BIN/oracle" >/dev/null || true
  [ -f "$OUT/rt/rt_ser.tsv" ] || python3 "$D/roundtrip.py" "$OUT/rt" "$BIN/probe" "$BIN/oracle" >/dev/null || true
  rc=0; python3 "$D/fourmode.py" "$BIN" "$WASM_RT" "$OUT/diff/diff_requests.tsv" "$OUT/rt/rt_parse.tsv" "$OUT/rt/rt_ser.tsv" "$OUT/rt/rt_reparse.tsv" || rc=$?
  mark fourmode "$rc"
fi

if want dos; then
  section "5. DoS / limits in 4 modes (deep nesting, wide documents, text amplification, entity bombs, lifted limits)"
  python3 "$D/gen_dos.py" "$OUT/dos"
  rc=0; python3 "$D/dos.py" "$OUT/dos" "$BIN" "$WASM_RT" "$OUT/dos.tsv" || rc=$?
  mark dos "$rc"
fi

if want bench; then
  section "6. Benchmark fairness (informational): official one-shot harness vs in-process loop vs blind-spot corpora"
  python3 "$FEED_DIR/bench/gen_corpus.py" "$OUT/bench" >/dev/null
  python3 "$D/gen_bench.py" "$OUT/bench"
  pionc build --release -o "$BIN/pion_bench" "$FEED_DIR/bench/pion_bench" || exit 2
  rm -rf "$OUT/src-rust_bench" && mkdir -p "$OUT/src-rust_bench"
  cp -R "$FEED_DIR/bench/rust/Cargo.toml" "$FEED_DIR/bench/rust/Cargo.lock" "$FEED_DIR/bench/rust/src" "$OUT/src-rust_bench/"
  cargo build -q --release --locked --manifest-path "$OUT/src-rust_bench/Cargo.toml" || exit 2
  cp "$CARGO_TARGET_DIR/release/feed-bench-rust" "$BIN/rust_bench"
  printf '<rss version="2.0"><channel><title>t</title><item><title>a</title><guid>g</guid></item></channel></rss>' >"$OUT/bench/tiny.xml"
  bc() { python3 "$ROOT_DIR/scripts/bench_compare.py" --warmup 1 --rounds 5 --baseline rust_feed_rs "$@" | sed -n '/^| Impl/,/^_SHA/p'; }
  echo "### process start-up floor (1-item RSS, official harness binaries)"
  bc --title floor --impl "pion=$BIN/pion_bench rss2 $OUT/bench/tiny.xml" --impl "rust_feed_rs=$BIN/rust_bench rss2 $OUT/bench/tiny.xml"
  for w in "w1_rss2_1500.xml rss2 1500" "w2_atom_1500.xml atom 1500" "w3_jsonfeed_2000.json json_feed 2000"; do
    set -- $w; SZ=$(wc -c <"$OUT/bench/$1" | tr -d ' ')
    echo; echo "### $1: official one-shot harness (bench/pion_bench vs bench/rust)"
    bc --title "$1 one-shot" --bytes "$SZ" --ops "$3" --impl "pion=$BIN/pion_bench $2 $OUT/bench/$1" --impl "rust_feed_rs=$BIN/rust_bench $2 $OUT/bench/$1"
    echo; echo "### $1: in-process x30 (start-up amortised; audit/probe bench vs audit/oracle bench)"
    bc --title "$1 in-process" --bytes $((SZ * 30)) --ops $(($3 * 30)) --impl "pion=$BIN/probe bench $OUT/bench/$1 30" --impl "rust_feed_rs=$BIN/oracle bench $OUT/bench/$1 30"
  done
  for f in b1_atom_xhtml_heavy.xml:500 b2_rss_dirty_dates.xml:3000 b3_rss_long_cdata.xml:150 b4_rss_podcast_ext.xml:1500; do
    n=${f#*:}; f=${f%%:*}; SZ=$(wc -c <"$OUT/bench/$f" | tr -d ' ')
    echo; echo "### blind spot $f: in-process x20"
    bc --title "$f" --bytes $((SZ * 20)) --ops $((n * 20)) --impl "pion=$BIN/probe bench $OUT/bench/$f 20" --impl "rust_feed_rs=$BIN/oracle bench $OUT/bench/$f 20"
  done
fi

section "Done. Artifacts in $OUT"
if [ -n "$FAILED" ]; then
  echo "RESULT: findings present in:$FAILED -> exit 1"
  exit 1
fi
echo "RESULT: every graded step passed -> exit 0"
exit 0
