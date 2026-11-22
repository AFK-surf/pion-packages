#!/bin/sh
# One-shot red-team audit of packages/tar:
#   Pion `tar`  vs  Go 1.27 `archive/tar`  vs  Rust `tar` 0.4.46
#
#   sh packages/tar/audit/run_audit.sh             # everything (~10 min on an M-series Mac, ~16 GB RAM peak)
#   sh packages/tar/audit/run_audit.sh --quick     # smaller fuzz + bench, no multi-GiB probes (~3 min)
#   SECTIONS="build tests diff" sh .../run_audit.sh # only some sections:
#        build tests diff trunc mutate writer interop probes heavy bench
#
# Needs: pionc (~/.pion/bin), go >= 1.27, cargo (tar 0.4.46 in the cargo cache or network), python3.
# Everything it builds or generates goes to $AUDIT_OUT (default /tmp/pion-tar-audit); the git worktree
# is never written to (AGENTS.md 1.5). Every number in REPORT.md comes from this script.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT="${AUDIT_OUT:-/tmp/pion-tar-audit}"
BIN="$OUT/bin"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1
if [ $QUICK = 1 ]; then
  SECTIONS="${SECTIONS:-build tests diff trunc mutate writer interop probes bench}"
else
  SECTIONS="${SECTIONS:-build tests diff trunc mutate writer interop probes heavy bench}"
fi
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
mkdir -p "$BIN" "$OUT/logs" "$OUT/bench"
CMP="python3 $AUDIT_DIR/diff/compare.py"
GO="$BIN/go_tar"
PI="$BIN/pion_tar"

want() { case " $SECTIONS " in *" $1 "*) return 0 ;; esac; return 1; }
hdr() { printf '\n\033[1m==== %s ====\033[0m\n' "$*"; }
rss() { # rss <label> <cmd...>: run, print its stdout tail, exit status and peak RSS
  label=$1
  shift
  set +e
  /usr/bin/time -l "$@" > "$OUT/logs/rss.out" 2> "$OUT/logs/rss.err"
  rc=$?
  set -e
  peak=$(awk '/maximum resident set size/ {printf "%.1f MiB", $1/1048576}' "$OUT/logs/rss.err")
  [ -n "$peak" ] || peak=$(awk '/Maximum resident set size/ {printf "%.1f MiB", $NF/1024}' "$OUT/logs/rss.err")
  printf '  %-34s exit=%-3s peakRSS=%-12s %s\n' "$label" "$rc" "$peak" "$(tail -1 "$OUT/logs/rss.out")"
}

if want build; then
  hdr "build: pion_tar + pion_probe (pionc --release), go_tar (Go $(go env GOVERSION)), rust_tar (tar 0.4.46)"
  pionc build --release -o "$BIN/pion_tar" "$AUDIT_DIR/tools/pion_tar"
  pionc build --release -o "$BIN/pion_probe" "$AUDIT_DIR/probe"
  (cd "$AUDIT_DIR/tools/go_tar" && go build -o "$BIN/go_tar" .)
  CARGO_TARGET_DIR="$OUT/rust-target" cargo build --quiet --release --locked \
    --manifest-path "$AUDIT_DIR/tools/rust_tar/Cargo.toml"
  cp "$OUT/rust-target/release/rust_tar" "$BIN/rust_tar"
  # Corpora: Go's own archive/tar/testdata (decoded), the adversarial corpus, the writer spec.
  TD="$(go env GOROOT)/src/archive/tar/testdata"
  rm -rf "$OUT/gotd" "$OUT/corpus"
  mkdir -p "$OUT/gotd"
  for f in "$TD"/*.tar; do cp "$f" "$OUT/gotd/"; done
  for f in "$TD"/*.tar.base64; do base64 -d < "$f" > "$OUT/gotd/$(basename "$f" .base64)"; done
  for f in "$TD"/*.tar.bz2; do bzip2 -dc "$f" > "$OUT/gotd/$(basename "$f" .bz2)"; done
  "$GO" gencorpus "$OUT/corpus"
  "$GO" genspec "$OUT/spec.txt"
  echo "binaries in $BIN; $(ls "$OUT/gotd" | wc -l | tr -d ' ') Go testdata archives; spec $(wc -l < "$OUT/spec.txt" | tr -d ' ') headers"
fi

ALL_TARS=$(ls "$OUT"/gotd/*.tar "$OUT"/corpus/*.tar 2>/dev/null || true)
small_tars() { for f in $ALL_TARS; do if [ "$(wc -c < "$f")" -le "$1" ]; then echo "$f"; fi; done; }

if want tests; then
  hdr "pionc test packages/tar/audit (every FAILED p0_/p1_/p2_ test is a finding; control_ must pass)"
  pionc test --json -p tar_redteam_audit "$AUDIT_DIR" > "$OUT/logs/pionc-test.json" 2> "$OUT/logs/pionc-test.stderr" || true
  python3 - "$OUT/logs/pionc-test.json" "$OUT/logs/pionc-test.stderr" <<'EOF'
import json, re, sys
d = json.load(open(sys.argv[1]))
msgs = {}
for line in open(sys.argv[2], errors="replace"):
    m = re.search(r"redteam_test\.pion:\d+: (\[[^\]]+\].*)", line)
    if m:
        msgs.setdefault(m.group(1).split("]")[0] + "]", m.group(1))
for t in d["tests"]:
    tag = re.match(r"p(\d)_", t["name"])
    print(f"  {'PASS' if t['ok'] else 'FAIL'}  {t['name']}")
print(f"  total={d['total']} passed={d['passed']} failed={d['failed']}")
print("  first assertion message of each failing test:")
for v in msgs.values():
    print("    " + v[:200])
EOF
fi

if want diff; then
  hdr "reader differential: Go testdata + adversarial corpus, Go-equivalent limits (fmt shown)"
  $CMP dump "$GO" "$PI" $ALL_TARS > "$OUT/logs/diff-dump.txt" || true
  grep -E '^(DIFF|    )' "$OUT/logs/diff-dump.txt" | sed 's/^/  /' || true
  tail -1 "$OUT/logs/diff-dump.txt"
  hdr "reader differential, Format field ignored"
  $CMP dump "$GO" "$PI" $ALL_TARS nofmt > "$OUT/logs/diff-dump-nofmt.txt" || true
  grep -E '^DIFF' "$OUT/logs/diff-dump-nofmt.txt" | sed 's/^/  /' || true
  tail -1 "$OUT/logs/diff-dump-nofmt.txt"
  hdr "reader differential with Pion Limits::default() (what read_all/Reader::new users get)"
  n=0
  for f in $ALL_TARS; do
    if [ "$("$GO" dump "$f" nofmt)" != "$("$PI" dump "$f" default nofmt)" ] && \
       [ "$("$GO" dump "$f" nofmt)" = "$("$PI" dump "$f" nofmt)" ]; then
      n=$((n + 1))
      echo "  LIMITS-ONLY $f: go=$("$GO" dump "$f" | tail -1) pion(default)=$("$PI" dump "$f" default | tail -1)"
    fi
  done
  echo "  $n archives where Pion with Go-like limits matches Go but Limits::default() stops earlier (Go reads on)"
fi

if want trunc; then
  hdr "truncation sweep: every prefix length (stride 1 <= 20 KiB, stride 509 <= 2 MiB)"
  $CMP trunc "$GO" "$PI" 1 $(small_tars 20000) nofmt | grep -v '^KNOWN' | sed 's/^/  /'
  big=$(for f in $ALL_TARS; do n=$(wc -c < "$f"); if [ "$n" -gt 20000 ] && [ "$n" -le 2000000 ]; then echo "$f"; fi; done)
  $CMP trunc "$GO" "$PI" 509 $big nofmt | grep -v '^KNOWN' | sed 's/^/  /'
fi

if want mutate; then
  N=2000
  [ $QUICK = 1 ] && N=300
  for seed in 12345 987654321; do
    hdr "mutation sweep: seed $seed, $N mutants per archive (<= 20 KiB), checksum re-stamped 2/3 of the time"
    $CMP mutate "$GO" "$PI" $seed $N $(small_tars 20000) nofmt > "$OUT/logs/mutate-$seed.txt" || true
    grep -E '^(DIFF|PION CRASH)' "$OUT/logs/mutate-$seed.txt" | sed 's/^/  /' || true
    tail -1 "$OUT/logs/mutate-$seed.txt"
  done
  echo "  (triage a case: python3 $AUDIT_DIR/diff/mutate_one.py <file> <seed> <i> /tmp/m.tar && $CMP dump $GO $PI /tmp/m.tar)"
fi

if want writer; then
  hdr "writer differential: $(grep -c '^H ' "$OUT/spec.txt") header specs, one archive each, Go vs Pion bytes + Go/Rust re-read"
  RUST_BIN="$BIN/rust_tar" $CMP writer "$GO" "$PI" "$OUT/spec.txt" "$OUT/wtmp" | sed 's/^/  /' || true
fi

if want interop; then
  hdr "interop: Rust-written complex archive -> Go vs Pion readers"
  "$BIN/rust_tar" write "$OUT/rust-written.tar"
  $CMP dump "$GO" "$PI" "$OUT/rust-written.tar" | sed 's/^/  /' || true
  hdr "interop: Go-written spec archive -> Rust reader sees the same as for the Pion-written one"
  "$GO" writespec "$OUT/spec.txt" "$OUT/w_go.tar" > /dev/null
  "$PI" writespec "$OUT/spec.txt" "$OUT/w_pion.tar" > /dev/null
  "$BIN/rust_tar" lite "$OUT/w_go.tar" > "$OUT/logs/rust-lite-go.txt" || true
  "$BIN/rust_tar" lite "$OUT/w_pion.tar" > "$OUT/logs/rust-lite-pion.txt" || true
  echo "  rust-lite(go-written) vs rust-lite(pion-written): $(diff "$OUT/logs/rust-lite-go.txt" "$OUT/logs/rust-lite-pion.txt" | grep -c '^[<>]') differing lines"
  diff "$OUT/logs/rust-lite-go.txt" "$OUT/logs/rust-lite-pion.txt" | head -6 | sed 's/^/    /' || true
fi

if want probes; then
  hdr "probes: sparse bomb (old-GNU 'S', 512 B per entry, realsize 256 MiB)"
  rss "pion read_all, 2 entries (2 KiB)" "$BIN/pion_probe" sparse-bomb 2
  rss "pion read_all, 8 entries (5 KiB)" "$BIN/pion_probe" sparse-bomb 8
  rss "pion Reader streaming, 8 entries" "$BIN/pion_probe" sparse-stream 8
  "$BIN/pion_probe" emit-sparse-bomb 8 "$OUT/sparse-bomb-8.tar"
  rss "go Reader+io.Copy streaming, 8 ent." "$GO" readbench "$OUT/sparse-bomb-8.tar" 1
  hdr "probes: uncapped limits + huge size field (P1-4)"
  "$BIN/pion_probe" huge-size-read | sed 's/^/  /'
  hdr "probes: default max_entries"
  rss "pion read_all 100,000 files" "$BIN/pion_probe" many 100000
  rss "pion read_all 100,001 files" "$BIN/pion_probe" many 100001
  echo "  Pion Int width: $("$BIN/pion_probe" int-width)"
fi

if want heavy; then
  hdr "heavy probes: archives past 2 GiB / 4 GiB (needs ~8 GB free RAM)"
  rss "pion 2.25 GiB archive (finish+read)" "$BIN/pion_probe" big2g-write
  rss "pion 4.5 GiB archive (finish)" "$BIN/pion_probe" big4g-write
  echo "  exit=139 is SIGSEGV: pion_strbuf_to_str allocates (uint32_t)(len+17) bytes, then memcpy's len."
fi

if want bench; then
  hdr "bench: generate workloads (Go writer; same bytes for every reader)"
  for k in tiny big xattr longname paxrecs; do
    "$GO" genbenchspec "$k" "$OUT/bench/$k.spec"
    "$GO" writespec "$OUT/bench/$k.spec" "$OUT/bench/$k.tar" > /dev/null
  done
  python3 "$ROOT_DIR/packages/tar/bench/gen_corpus.py" "$OUT/bench/mixed.tar" 2000 > /dev/null
  python3 "$AUDIT_DIR/bench/gen_sparse.py" "$OUT/bench/sparse.tar" 400 > /dev/null
  ls -l "$OUT"/bench/*.tar | awk '{printf "  %12d  %s\n", $5, $NF}'
  bench() { # bench <title> <pion cmd> <go cmd> [rust cmd]
    title=$1
    shift
    md="$OUT/bench/$(echo "$title" | tr ' /,' '___').md"
    set -- --impl "pion=$1" --impl "go_tar=$2" ${3:+--impl} ${3:+"rust_tar=$3"}
    python3 "$ROOT_DIR/scripts/bench_compare.py" --title "$title" "$@" \
      --baseline go_tar --warmup 1 --rounds 5 --md-out "$md" \
      > "$OUT/logs/bench.log" 2>&1 || { echo "  FAILED: $title"; tail -3 "$OUT/logs/bench.log"; return 0; }
    echo "  -- $title  (median ms | min | p95 | peak RSS | vs go_tar)"
    grep -E '^\| `' "$md" | awk -F'|' '{printf "     %-10s %10s %10s %10s %12s %s\n",$2,$3,$4,$5,$6,$7}'
  }
  b="$OUT/bench"
  hdr "bench: header-only scan (payloads never touched; Go skips with Seek)"
  bench "scan mixed x20" "$PI scanbench $b/mixed.tar 20" "$GO scanbench $b/mixed.tar 20" "$BIN/rust_tar scanbench $b/mixed.tar 20"
  bench "scan tiny100k x3" "$PI scanbench $b/tiny.tar 3" "$GO scanbench $b/tiny.tar 3" "$BIN/rust_tar scanbench $b/tiny.tar 3"
  bench "scan big64MiB x100" "$PI scanbench $b/big.tar 100" "$GO scanbench $b/big.tar 100" "$BIN/rust_tar scanbench $b/big.tar 100"
  bench "scan longname x5" "$PI scanbench $b/longname.tar 5" "$GO scanbench $b/longname.tar 5" "$BIN/rust_tar scanbench $b/longname.tar 5"
  bench "scan xattr32 x10" "$PI scanbench $b/xattr.tar 10" "$GO scanbench $b/xattr.tar 10" "$BIN/rust_tar scanbench $b/xattr.tar 10"
  bench "scan paxrecs4000 x1" "$PI scanbench $b/paxrecs.tar 1" "$GO scanbench $b/paxrecs.tar 1" "$BIN/rust_tar scanbench $b/paxrecs.tar 1"
  bench "scan sparse x10" "$PI scanbench $b/sparse.tar 10" "$GO scanbench $b/sparse.tar 10"
  hdr "bench: full read (every payload byte hashed with FNV-1a in all three)"
  bench "read mixed x20" "$PI readbench $b/mixed.tar 20" "$GO readbench $b/mixed.tar 20" "$BIN/rust_tar readbench $b/mixed.tar 20"
  bench "read tiny100k x3" "$PI readbench $b/tiny.tar 3" "$GO readbench $b/tiny.tar 3" "$BIN/rust_tar readbench $b/tiny.tar 3"
  bench "read big64MiB x3" "$PI readbench $b/big.tar 3" "$GO readbench $b/big.tar 3" "$BIN/rust_tar readbench $b/big.tar 3"
  bench "read xattr32 x10" "$PI readbench $b/xattr.tar 10" "$GO readbench $b/xattr.tar 10" "$BIN/rust_tar readbench $b/xattr.tar 10"
  bench "read sparse1.0 x1" "$PI readbench $b/sparse.tar 1" "$GO readbench $b/sparse.tar 1"
  hdr "bench: write (same header spec; Rust only where its bytes are the same size)"
  bench "write tiny100k x3" "$PI writebench $b/tiny.spec 3" "$GO writebench $b/tiny.spec 3" "$BIN/rust_tar writebench tiny 3"
  bench "write big64MiB x10" "$PI writebench $b/big.spec 10" "$GO writebench $b/big.spec 10" "$BIN/rust_tar writebench big 10"
  bench "write xattr32 x10" "$PI writebench $b/xattr.spec 10" "$GO writebench $b/xattr.spec 10"
  bench "write longname x5" "$PI writebench $b/longname.spec 5" "$GO writebench $b/longname.spec 5"
  bench "write paxrecs4000 x1" "$PI writebench $b/paxrecs.spec 1" "$GO writebench $b/paxrecs.spec 1"
fi

hdr "done; logs in $OUT/logs, bench tables in $OUT/bench"
git -C "$ROOT_DIR" status --porcelain --ignored -- packages/tar | sed 's/^/  worktree: /' || true
