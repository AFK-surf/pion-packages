#!/bin/sh
# One-shot red-team audit: Pion `packages/graph` vs Rust petgraph =0.8.3 (+ exact / brute-force references).
#
#   sh packages/graph/audit/run_audit.sh [--quick] [OUT_DIR]
#
# 1. build: Rust oracle (petgraph =0.8.3, --release, lto), Pion runner native debug/release + wasm32 debug/release
# 2. pionc test packages/graph/audit   (p1_/p2_ tests are EXPECTED to fail = evidence; ctl_ must pass)
# 3. differential fuzz: SEEDS x CASES random graphs (multi-edges, self-loops, Int64::MAX/2, negative cycles,
#    add/remove churn), 22 sections, Pion vs ground truth; petgraph's own defects reported separately
# 4. the same fuzz stream on wasm32 debug/release and native debug must be byte-identical to native release
# 5. 100k-scale stress (chain / cycle / star / rand / dense) x 4 modes: exit code + SHA-256 per mode
# 6. robustness probes (Int width, CSR / Floyd size overflow, transitive-reduction memory) native + wasm32
# 7. adversarial head-to-head benchmarks through scripts/bench_compare.py (+ build-vs-algorithm split)
# Everything is written under OUT_DIR (default /private/tmp/graph-redteam); the worktree stays clean.
set -eu
QUICK=0
if [ "${1:-}" = "--quick" ]; then QUICK=1; shift; fi
OUT=${1:-/private/tmp/graph-redteam}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
BIN="$OUT/bin"
mkdir -p "$BIN"
SEEDS=1,2,3,4,5,6,7,8,9,10; CASES=1000; ROUNDS=5
if [ $QUICK = 1 ]; then SEEDS=1,2; CASES=300; ROUNDS=3; fi
say() { printf '%s\n' "$*"; }

say "== setup: $(uname -sm), $(pionc --version 2>&1 | head -1), $(cargo --version), node $(node --version)"
say "   packages/graph @ $(git -C "$ROOT" rev-parse --short HEAD)"

say "==> [1/7] build"
CARGO_TARGET_DIR="$OUT/rust-target" cargo build --release -q --manifest-path "$HERE/rust_oracle/Cargo.toml"
ORACLE="$OUT/rust-target/release/graph_oracle"
pionc build --release -o "$BIN/runner_release" "$HERE/runner"
pionc build -o "$BIN/runner_debug" "$HERE/runner"
pionc build --target wasm32 -o "$BIN/runner_debug.wasm" "$HERE/runner"
pionc build --target wasm32 --release -o "$BIN/runner_release.wasm" "$HERE/runner"
RUNNER="$BIN/runner_release"

say "==> [2/7] pionc test packages/graph/audit (p1_/p2_ failures are the evidence)"
pionc test "$HERE" > "$OUT/redteam_tests.log" 2>&1 || true
grep '^test graph_audit::' "$OUT/redteam_tests.log" | sed 's/^/    /' || true
tail -1 "$OUT/redteam_tests.log" | sed 's/^/    /'

say "==> [3/7] differential fuzz vs petgraph =0.8.3 (seeds $SEEDS x $CASES cases)"
python3 "$HERE/fuzz.py" --oracle "$ORACLE" --runner "$RUNNER" --seeds "$SEEDS" --cases "$CASES" --out "$OUT/fuzz" | sed 's/^/    /'

say "==> [4/7] fuzz stream determinism: native debug / wasm32 debug / wasm32 release vs native release (seed 1)"
"$RUNNER" fuzz 1 "$CASES" > "$OUT/fuzz/stream.native_release"
"$BIN/runner_debug" fuzz 1 "$CASES" > "$OUT/fuzz/stream.native_debug"
node "$RT" "$BIN/runner_debug.wasm" fuzz 1 "$CASES" > "$OUT/fuzz/stream.wasm_debug"
node "$RT" "$BIN/runner_release.wasm" fuzz 1 "$CASES" > "$OUT/fuzz/stream.wasm_release"
(cd "$OUT/fuzz" && shasum -a 256 stream.* | sed 's/^/    /')

say "==> [5/7] 100k-scale stress x 4 modes (exit code, wall ms, sha256 of output)"
mkdir -p "$OUT/modes"
for spec in "chain 100000" "cycle 100000" "star 100000" "rand 100000" "dense 2000"; do
  set -- $spec
  for algo in all kosaraju csr_tarjan df; do
    for m in native_debug native_release wasm_debug wasm_release; do
      case $m in
        native_*) C="$BIN/runner_${m#native_}" ;;
        wasm_*) C="node $RT $BIN/runner_${m#wasm_}.wasm" ;;
      esac
      t0=$(python3 -c 'import time; print(time.time())')
      rc=0; $C stress "$1" "$2" "$algo" > "$OUT/modes/$1_$algo.$m" 2>&1 || rc=$?
      ms=$(python3 -c "import time; print(round((time.time() - $t0) * 1000))")
      printf '    %-6s %-10s %-15s rc=%d %6s ms  %s\n' "$1" "$algo" "$m" "$rc" "$ms" "$(shasum -a 256 "$OUT/modes/$1_$algo.$m" | cut -c1-16)"
    done
  done
done | tee "$OUT/modes/summary.txt"
python3 - "$OUT/modes/summary.txt" <<'PY'
import sys, collections
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
groups = collections.defaultdict(set); bad = [r for r in rows if r[3] != "rc=0"]
for r in rows:
    groups[(r[0], r[1])].add(r[-1])
diverge = [k for k, v in groups.items() if len(v) != 1]
print(f"    {len(rows)} runs, non-zero exits: {len(bad)}, mode-divergent outputs: {len(diverge)} {diverge if diverge else ''}")
PY

say "==> [6/7] robustness probes (native release and wasm32 release)"
for p in int_width csr_from_edges_intmax floyd_46341 csr_from_edges_1e9 tred_chain_100k tred_star_370800 star_remove_hub; do
  if [ $QUICK = 1 ] && [ $p = csr_from_edges_1e9 ]; then continue; fi
  n=$( { /usr/bin/time -l "$RUNNER" probe $p; } 2>&1 | grep -E 'Ok|Err|edges|panic|Int max|maximum resident' | tr '\n' ' ' | sed 's/  */ /g')
  say "    native $p: $n"
  w=$(node "$RT" "$BIN/runner_release.wasm" probe $p 2>&1 | grep -vE '^\s+at ' | head -2 | tr '\n' ' ')
  say "    wasm32 $p: $w"
done
say "    petgraph 0.8.3 on the same transitive-reduction inputs:"
for x in "star 100000" "chain 20000"; do
  set -- $x
  r=$( { /usr/bin/time -l "$ORACLE" stress $1 $2 tred; } 2>&1 | grep -E 'algo|maximum resident' | tr '\n' ' ' | sed 's/  */ /g')
  q=$( { /usr/bin/time -l "$RUNNER" stress $1 $2 tred; } 2>&1 | grep -E 'maximum resident' | tr '\n' ' ' | sed 's/  */ /g')
  say "      $1 $2: petgraph [$r]  pion [$q]"
done

if [ $QUICK = 1 ]; then
  say "==> [7/7] skipped (--quick)"
  exit 0
fi
say "==> [7/7] adversarial head-to-head benchmarks (warmup 1, rounds $ROUNDS, SHA-256 checked)"
sh "$HERE/bench_adversarial.sh" "$ORACLE" "$RUNNER" "$ROOT" "$OUT/bench" "$ROUNDS"
say "    build-vs-algorithm split (median of 7 process runs, algorithm = total - build-only):"
python3 "$HERE/split_bench.py" "$ORACLE" "$RUNNER" dense:2000:dij rand:50000:dij rand:100000:tarjan rand:100000:kosaraju \
  chain:100000:topo rand:50000:kruskal rand:50000:prim rand:20000:bf rand:50000:astar rand:50000:dom \
  layers:2002:dinic dense:300:floyd rand:20000:removenodes | sed 's/^/    /'
say ""
say "Results: $OUT (fuzz/summary.json, modes/summary.txt, bench/*.md, redteam_tests.log)"
