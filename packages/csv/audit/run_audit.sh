#!/bin/sh
# One-shot red-team audit of packages/csv:
#   Pion `csv` (native + wasm32)  vs  Rust `csv =1.4.0` (csv-core 0.1.13)  vs  Go `encoding/csv` (benchmarks)
#
#   sh packages/csv/audit/run_audit.sh            # everything (~3 min on an M-series Mac)
#   sh packages/csv/audit/run_audit.sh --quick    # smaller fuzz, 3 bench rounds
#   SECTIONS="build tests" sh .../run_audit.sh    # only some of: build tests probes fuzz dos bench clean
#
# Needs: pionc (~/.pion/bin), cargo (crates.io reachable or csv 1.4.0 in ~/.cargo), go, node, python3.
# Everything built or generated goes to $AUDIT_OUT (default /tmp/pion-csv-audit); the git worktree is
# never written to (AGENTS.md 1.5). Exit status is 1 while any red-team test (fN_*) still fails.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
OUT="${AUDIT_OUT:-/tmp/pion-csv-audit}"
BIN="$OUT/bin"
DATA="$OUT/data"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1
SECTIONS="${SECTIONS:-build tests probes fuzz dos bench clean}"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export AUDIT_BIN="$BIN"
mkdir -p "$BIN" "$DATA" "$OUT/logs"
STATUS=0

want() { case " $SECTIONS " in *" $1 "*) return 0 ;; esac; return 1; }
hdr() { printf '\n\033[1m==== %s ====\033[0m\n' "$*"; }

if want build; then
  hdr "build: pion_cli + pion_adv (pionc --release, native + wasm32), rust_ref/rust_bench (csv =1.4.0), go_adv"
  pionc build --release -o "$BIN/pion_cli" "$AUDIT_DIR/tools/pion_cli"
  pionc build --release --target wasm32 -o "$BIN/pion_cli.wasm" "$AUDIT_DIR/tools/pion_cli"
  pionc build --release -o "$BIN/pion_adv" "$AUDIT_DIR/bench/pion_adv"
  CARGO_TARGET_DIR="$OUT/rust-target" cargo build --quiet --release --locked \
    --manifest-path "$AUDIT_DIR/tools/rust_ref/Cargo.toml"
  cp "$OUT/rust-target/release/rust_ref" "$OUT/rust-target/release/rust_bench" "$BIN/"
  (cd "$AUDIT_DIR/bench/go" && go build -o "$BIN/go_adv" .)
  echo "binaries in $BIN"
fi

if want tests; then
  hdr "red-team tests (audit/redteam_test.pion): fN_* FAIL = defect present, control_*/dN_* must PASS"
  pionc fmt --check "$AUDIT_DIR"
  pionc check --json "$AUDIT_DIR" >/dev/null
  pionc test --json "$AUDIT_DIR" > "$OUT/logs/tests.json" 2>"$OUT/logs/tests.err" || true
  python3 - "$OUT/logs/tests.json" "$OUT/logs/tests.err" <<'PY' || STATUS=1
import json, re, sys
j = json.load(open(sys.argv[1]))
err = open(sys.argv[2]).read()
bad = 0
for t in j["tests"]:
    if t["pkg"] != "csv_redteam_audit":
        continue
    red = t["name"].startswith("f")
    state = "PASS" if t["ok"] else "FAIL"
    tag = ("defect fixed" if t["ok"] else "DEFECT PRESENT") if red else ("ok" if t["ok"] else "REGRESSION")
    print("  %-4s %-66s %s" % (state, t["name"], tag))
    bad += not t["ok"]
for m in re.findall(r"pion panic at [^:]+:\d+: (.*)", err):
    print("      " + m[:220])
print("  package csv's own suite: %d tests, %s" % (sum(1 for t in j["tests"] if t["pkg"] == "csv"),
      "all pass" if all(t["ok"] for t in j["tests"] if t["pkg"] == "csv") else "FAILURES"))
sys.exit(1 if bad else 0)
PY
fi

if want probes; then
  hdr "hand-written adversarial probes (diff/probes.py): Pion vs Rust csv 1.4.0"
  python3 "$AUDIT_DIR/diff/probes.py" | tee "$OUT/logs/probes.txt"
fi

if want fuzz; then
  NR=40000; NW=10000
  [ $QUICK = 1 ] && NR=5000 && NW=2000
  hdr "differential fuzz: $NR reader + $NW writer cases, full config matrix, minimized + root-caused"
  python3 "$AUDIT_DIR/diff/fuzz_diff.py" "$NR" "$NW" 4180 "$OUT/fuzz" | tee "$OUT/logs/fuzz.txt"
fi

if want dos; then
  hdr "DoS / O(n^2) scaling probe (t(4N)/t(N); ~4 = linear)"
  python3 "$AUDIT_DIR/dos/dos_probe.py" "$OUT/dos" | tee "$OUT/logs/dos.txt"
fi

if want bench; then
  R=5; [ $QUICK = 1 ] && R=3
  hdr "adversarial head-to-head benchmarks (scripts/bench_compare.py, warmup 1, rounds $R, SHA-256 checked)"
  python3 "$AUDIT_DIR/bench/gen_adversarial.py" "$DATA"
  python3 "$PKG_DIR/bench/gen_data.py" "$DATA" >/dev/null
  { cat "$DATA/mixed_200k.csv"; for i in 1 2 3 4; do tail -n +2 "$DATA/mixed_200k.csv"; done; } > "$DATA/mixed_1m.csv"
  : > "$OUT/logs/bench.md"
  for spec in "default mixed_200k" "default mixed_1m" "bytes mixed_1m" "fields mixed_1m" "default heavy_quote" "default wide_1000" \
              "semicolon semicolon" "trim_comment trim_comment" "escape escape" "read_all narrow"; do
    set -- $spec
    f="$DATA/$2.csv"
    ops=$("$BIN/rust_bench" "$1" byte "$f" | awk -F= '/^records=/{print $2}')
    bytes=$(wc -c < "$f" | tr -d ' ')
    log="$OUT/logs/bench_$1_$2"
    if [ "$1" = escape ]; then   # encoding/csv has no escape character
      python3 "$ROOT_DIR/scripts/bench_compare.py" --title "$1 on $2.csv" \
        --impl "pion=$BIN/pion_adv $1 $f" --impl "rust_str=$BIN/rust_bench $1 str $f" \
        --impl "rust_byte=$BIN/rust_bench $1 byte $f" --baseline rust_byte --warmup 1 --rounds "$R" \
        --ops "$ops" --bytes "$bytes" --md-out "$log.md" > "$log.log" 2>&1 || { tail -20 "$log.log"; STATUS=1; }
    else
      python3 "$ROOT_DIR/scripts/bench_compare.py" --title "$1 on $2.csv" \
        --impl "pion=$BIN/pion_adv $1 $f" --impl "rust_str=$BIN/rust_bench $1 str $f" \
        --impl "rust_byte=$BIN/rust_bench $1 byte $f" --impl "go_csv=$BIN/go_adv $1 $f" \
        --baseline rust_byte --warmup 1 --rounds "$R" \
        --ops "$ops" --bytes "$bytes" --md-out "$log.md" > "$log.log" 2>&1 || { tail -20 "$log.log"; STATUS=1; }
    fi
    cat "$OUT/logs/bench_$1_$2.md" | tee -a "$OUT/logs/bench.md"
  done
  hdr "fast-path cliff: inputs > max_record_bytes (16 MiB) never take read_record_fast until the last 16 MiB"
  for c in mixed_200k mixed_1m; do
    f="$DATA/$c.csv"
    python3 "$ROOT_DIR/scripts/bench_compare.py" --title "fast-path cliff on $c.csv ($(wc -c < "$f" | tr -d ' ') B)" \
      --impl "pion_default=$BIN/pion_adv default $f" --impl "pion_max_record_bytes_0=$BIN/pion_adv nolimit $f" \
      --impl "rust_byte=$BIN/rust_bench default byte $f" --baseline pion_default --warmup 1 --rounds "$R" \
      --md-out "$OUT/logs/cliff_$c.md" > "$OUT/logs/cliff_$c.log" 2>&1 || { tail -20 "$OUT/logs/cliff_$c.log"; STATUS=1; }
    tee -a "$OUT/logs/bench.md" < "$OUT/logs/cliff_$c.md"
  done
  hdr "default Limits on legitimate input: 10,000,001 one-byte rows (20 MB)"
  "$BIN/pion_adv" default "$DATA/many_rows.csv" | head -3 || true
  "$BIN/rust_bench" default byte "$DATA/many_rows.csv" | head -1
fi

if want clean; then
  hdr "worktree must stay clean (AGENTS.md 1.5)"
  if [ -n "$(git -C "$ROOT_DIR" status --porcelain --ignored)" ]; then
    git -C "$ROOT_DIR" status --porcelain --ignored; STATUS=1
  else
    echo "clean"
  fi
fi
exit $STATUS
