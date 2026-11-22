#!/bin/sh
# Red-team audit of packages/mermaid against official mermaid 12.3.0 + @dagrejs/dagre 3.1.3.
#
#   sh packages/mermaid/audit/run_audit.sh            # everything (~5-8 min on an M-series Mac)
#   STEPS="1 2 3" sh packages/mermaid/audit/run_audit.sh   # a subset
#
# Steps
#   1  pionc test of audit/ (every FAIL is a defect; 3 `control:` tests are expected to pass)
#   2  parse differential: official mermaid vs Pion on audit/diff/corpus.mmd
#   3  layout geometry: Pion scenes vs dagre re-layout of the SAME boxes (audit/geom/layout.mmd)
#   4  crash / DoS probes (SIGSEGV, super-linear time, no input limits)
#   5  output safety: XSS escaping, control chars, invalid UTF-8, <br/>
#   6  benchmark fairness: where the official 290x goes (cpu profile, dagre ranker), and an
#      adversarial head-to-head through scripts/bench_compare.py (SHA-256 verified)
#
# Nothing is written inside the repository: binaries, node_modules and reports go to $AUDIT_OUT
# (default ${TMPDIR:-/tmp}/mermaid-redteam). Needs: pionc (~/.pion/bin), node >= 20, python3, npm.
set -u

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(dirname "$AUDIT_DIR")
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
OUT=${AUDIT_OUT:-${TMPDIR:-/tmp}/mermaid-redteam}
OUT=${OUT%/}
REF=${MERMAID_REF_DIR:-$OUT/node}
STEPS=${STEPS:-"1 2 3 4 5 6"}
export PATH="$HOME/.pion/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1  # keep geom/__pycache__ out of the worktree
mkdir -p "$OUT/bin" "$OUT/gen" "$OUT/reports"

want() { case " $STEPS " in *" $1 "*) return 0 ;; esac; return 1; }
hr() { printf '\n==================== %s ====================\n' "$*"; }
timed() { # timed <label> <timeout_s> cmd... -> prints rc, wall seconds, peak RSS
  label=$1; to=$2; shift 2
  /usr/bin/time -l timeout "$to" "$@" > "$OUT/last.out" 2> "$OUT/last.err"
  rc=$?
  real=$(grep -E '^ *[0-9.]+ real' "$OUT/last.err" | awk '{print $1}')
  rss=$(grep -E 'maximum resident' "$OUT/last.err" | awk '{printf "%.1f", $1/1048576}')
  [ -z "$real" ] && real=$(grep -E '^real' "$OUT/last.err" | awk '{print $2}')
  verdict=ok
  [ "$rc" = 139 ] && verdict="SIGSEGV(crash)"
  [ "$rc" = 134 ] && verdict="SIGABRT(crash)"
  [ "$rc" = 124 ] && verdict="TIMEOUT(>${to}s)"
  [ "$rc" != 0 ] && [ "$verdict" = ok ] && verdict="exit $rc: $(cat "$OUT/last.out" "$OUT/last.err" | grep -E '^([A-Za-z]*Error|ERR)[: ]' | head -1 | cut -c1-70)"
  printf '%-34s %-28s %8ss  rss=%sMB  %s\n' "$label" "$verdict" "${real:-?}" "${rss:-?}" "$(head -c 60 "$OUT/last.out" | tr '\n' ' ')"
}

hr "setup"
if [ ! -f "$REF/node_modules/mermaid/package.json" ] || [ ! -f "$REF/node_modules/@dagrejs/dagre/package.json" ]; then
  echo "installing official reference into $REF (mermaid@12.3.0 @dagrejs/dagre@3.1.3 linkedom@0.18.15)"
  mkdir -p "$REF" && (cd "$REF" && npm init -y >/dev/null 2>&1 && npm i --silent mermaid@12.3.0 @dagrejs/dagre@3.1.3 linkedom@0.18.15) || {
    echo "npm install failed" >&2; exit 1; }
fi
export MERMAID_REF_DIR="$REF"
echo "mermaid $(node -p "require('$REF/node_modules/mermaid/package.json').version") / dagre $(node -p "require('$REF/node_modules/@dagrejs/dagre/package.json').version") / $(pionc --version)"
pionc build --release "$AUDIT_DIR/probe" -o "$OUT/bin/probe" >/dev/null || { echo "probe build failed" >&2; exit 1; }
P="$OUT/bin/probe"

if want 1; then
  hr "1. pionc test packages/mermaid/audit (FAIL = reproducible defect)"
  pionc test --json "$AUDIT_DIR" 2>/dev/null > "$OUT/reports/tests.json"
  python3 - "$OUT/reports/tests.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
mine = [t for t in d["tests"] if t["pkg"] == "mermaid_redteam_audit"]
for sev in ("P0", "P1", "P2", "control"):
    rows = [t for t in mine if t["name"].startswith(sev)]
    if rows:
        print(f"--- {sev}: {sum(not t['ok'] for t in rows)} failing / {len(rows)}")
        for t in rows:
            print(("  FAIL " if not t["ok"] else "  pass ") + t["name"])
print(f"\nred-team tests: {sum(not t['ok'] for t in mine)} FAIL / {len(mine)} total "
      f"(upstream mermaid package tests: {sum(t['ok'] for t in d['tests'] if t['pkg']=='mermaid')} pass)")
EOF
  echo "(per-test messages: pionc test $AUDIT_DIR 2>&1 | grep 'pion panic')"
fi

if want 2; then
  hr "2. parse differential vs official mermaid ($AUDIT_DIR/diff/corpus.mmd)"
  node "$AUDIT_DIR/diff/mermaid_ref.mjs" "$AUDIT_DIR/diff/corpus.mmd" > "$OUT/reports/parse_ref.tsv"
  "$P" parse "$AUDIT_DIR/diff/corpus.mmd" > "$OUT/reports/parse_pion.tsv"
  python3 "$AUDIT_DIR/diff/compare.py" "$OUT/reports/parse_ref.tsv" "$OUT/reports/parse_pion.tsv" --md "$OUT/reports/parse_diff.md"
fi

if want 3; then
  hr "3. layout geometry: Pion vs @dagrejs/dagre on identical boxes ($AUDIT_DIR/geom/layout.mmd)"
  "$P" scene "$AUDIT_DIR/geom/layout.mmd" > "$OUT/reports/scene_pion.tsv"
  node "$AUDIT_DIR/geom/dagre_ref.mjs" "$OUT/reports/scene_pion.tsv" > "$OUT/reports/scene_dagre.tsv"
  echo "--- Pion defects"
  python3 "$AUDIT_DIR/geom/geom_check.py" "$OUT/reports/scene_pion.tsv" --json "$OUT/reports/geom_pion.json"
  echo "--- dagre defects (same graphs, same node / label boxes)"
  python3 "$AUDIT_DIR/geom/geom_check.py" "$OUT/reports/scene_dagre.tsv" --json "$OUT/reports/geom_dagre.json"
  echo "--- side by side"
  python3 "$AUDIT_DIR/geom/compare_geom.py" "$OUT/reports/scene_pion.tsv" "$OUT/reports/scene_dagre.tsv" --md "$OUT/reports/geom_compare.md"
  for c in g_subgraphs_cross_linked g_state_composites g_parallel_labelled_edges g_fanout_long_labels; do
    python3 "$AUDIT_DIR/geom/scene_svg.py" "$OUT/reports/scene_pion.tsv" $c > "$OUT/reports/$c.pion.svg"
    python3 "$AUDIT_DIR/geom/scene_svg.py" "$OUT/reports/scene_dagre.tsv" $c > "$OUT/reports/$c.dagre.svg"
  done
  echo "visual exhibits (one neutral renderer, red = defect): $OUT/reports/*.{pion,dagre}.svg"
fi

if want 4; then
  hr "4. crash / DoS probes (Pion: parse + layout + render_svg in one process)"
  for spec in "chain 100000" "chain 200000" "seqnest 10000" "seqnest 20000" "scc 500" "scc 1000" "scc 2000" \
              "dense 120" "nest 20000" "nest 50000" "subgraphs 20000" "wide 100000"; do
    set -- $spec
    f="$OUT/gen/$1_$2.mmd"
    "$P" gen "$1" "$2" > "$f"
    timed "pion $1 n=$2 ($(wc -c < "$f" | tr -d ' ')B)" 300 "$P" time "$f"
  done
  echo "--- official pipeline on the same inputs (mermaid parse + dagre), default config first"
  timed "mermaid default cfg chain 200000" 120 node "$AUDIT_DIR/bench/mermaid_dagre_full.mjs" "$OUT/gen/chain_200000.mmd" --default-limits
  "$P" gen chain 3000 > "$OUT/gen/chain_3000.mmd"
  timed "mermaid+dagre chain 3000" 120 node "$AUDIT_DIR/bench/mermaid_dagre_full.mjs" "$OUT/gen/chain_3000.mmd"
  timed "mermaid+dagre scc 500" 300 node "$AUDIT_DIR/bench/mermaid_dagre_full.mjs" "$OUT/gen/scc_500.mmd"
  timed "mermaid parse seqnest 10000" 120 node "$AUDIT_DIR/bench/mermaid_dagre_full.mjs" "$OUT/gen/seqnest_10000.mmd" --parse-only
  timed "mermaid parse seqnest 20000" 60 node "$AUDIT_DIR/bench/mermaid_dagre_full.mjs" "$OUT/gen/seqnest_20000.mmd" --parse-only
fi

if want 5; then
  hr "5. output safety"
  printf 'flowchart LR\n  A["<script>alert(1)</script>"] -->|"x\\" onload=\\"alert(1)"| B("it'"'"'s & <b>")\n  C[ctl\001\002char] --> D["emoji 🚀 测试"]\n  E[line1<br/>line2] --> F\n' > "$OUT/gen/xss.mmd"
  printf 'flowchart LR\n  A["bad \377\376 bytes"] --> B\n' > "$OUT/gen/badutf8.mmd"
  "$P" svg "$OUT/gen/xss.mmd" > "$OUT/reports/xss.svg"
  "$P" svg "$OUT/gen/badutf8.mmd" > "$OUT/reports/badutf8.svg"
  python3 - "$OUT/reports/xss.svg" "$OUT/reports/badutf8.svg" <<'EOF'
import sys, xml.dom.minidom
for p in sys.argv[1:]:
    raw = open(p, "rb").read()
    try:
        s = raw.decode("utf-8"); utf8 = "valid UTF-8"
    except UnicodeDecodeError as e:
        s = raw.decode("utf-8", "replace"); utf8 = f"INVALID UTF-8 ({e.reason} at byte {e.start})"
    try:
        xml.dom.minidom.parseString(raw); wf = "well-formed XML"
    except Exception as e:
        wf = f"NOT well-formed XML ({e})"
    breakout = '" onload=' in s
    print(f"{p.split('/')[-1]}: {utf8}; {wf}; raw <script: {'<script' in s}; attr breakout: {breakout}; literal <br/>: {'&lt;br/&gt;' in s}")
EOF
fi

if want 6; then
  hr "6. benchmark fairness"
  python3 "$PKG_DIR/bench/gen_corpus.py" "$OUT/bd" >/dev/null
  echo "--- 6a. where the official 'parse' time goes (node --cpu-prof on bench_node_parse.mjs, 10 iters)"
  rm -rf "$OUT/prof" && mkdir -p "$OUT/prof"
  MERMAID_BENCH_NODE_DIR="$REF" node --cpu-prof --cpu-prof-dir="$OUT/prof" "$PKG_DIR/bench/bench_node_parse.mjs" "$OUT/bd/parse_corpus.txt" --iters 10 >/dev/null
  python3 - "$OUT/prof" "$REF" <<'EOF'
import collections, glob, json, re, sys
p = json.load(open(glob.glob(sys.argv[1] + "/*.cpuprofile")[0]))
nodes = {n["id"]: n for n in p["nodes"]}
dt = collections.Counter()
for s, d in zip(p["samples"], p["timeDeltas"]):
    dt[s] += d
tot = sum(dt.values())
# identify mermaid's assignWithDepth (config deep-merge) by name in the minified chunk
merge = gc = 0
for nid, t in dt.items():
    cf = nodes[nid]["callFrame"]
    if cf["functionName"] == "(garbage collector)":
        gc += t
    url = cf["url"]
    if "chunk-" in url and cf["lineNumber"] == 3:
        src = open(url.replace("file://", ""), encoding="utf-8").read().split("\n")[3]
        head = src[cf["columnNumber"] - 40: cf["columnNumber"] + 120]
        if '"assignWithDepth"' in src[cf["columnNumber"]: cf["columnNumber"] + 1200] or "depth:r=2" in head:
            merge += t
print(f"total {tot/1e3:.0f} ms; assignWithDepth (config deep-merge per vertex/class/state): {merge/tot*100:.1f}%; GC: {gc/tot*100:.1f}%")
print("=> the official 'parse' benchmark is dominated by mermaid re-merging its config object on every")
print("   getConfig() call, not by lexing/parsing; Pion does no config/sanitise/entity/frontmatter work at all.")
EOF
  echo "--- 6b. official layout bench with dagre rankers (5 iters, g50/g200/g500; Pion = longest-path + source tightening)"
  sed 's/rankdir: "TB", nodesep/rankdir: "TB", ranker: process.env.DAGRE_RANKER || "network-simplex", nodesep/' \
    "$PKG_DIR/bench/bench_node_layout.mjs" > "$OUT/bench_node_layout_ranker.mjs"
  pionc build --release "$PKG_DIR/bench/bench_layout" -o "$OUT/bin/bench_layout" >/dev/null
  for r in network-simplex longest-path; do
    s=$(python3 -c 'import time;print(time.time())')
    DAGRE_RANKER=$r MERMAID_BENCH_NODE_DIR="$REF" node "$OUT/bench_node_layout_ranker.mjs" "$OUT/bd/layout_graphs.txt" --iters 5 --metrics | grep g500 | sed "s/^/  dagre[$r] /"
    python3 -c "import time;print('    wall %.2fs' % (time.time()-$s))"
  done
  "$OUT/bin/bench_layout" "$OUT/bd/layout_graphs.txt" --iters 1 --metrics | grep g500 | sed 's/^/  pion /'
  echo "  NOTE: the official corpus has no clusters and no edge labels, exactly the two things Pion's"
  echo "  layout does not reserve space for (step 3); its better crossings/edge_len there come from"
  echo "  doing less, not from better optimisation."
  echo "--- 6c. adversarial head-to-head through scripts/bench_compare.py (stdout SHA-256 verified)"
  for spec in "subgraphs 300" "wide 2000" "dense 40" "scc 200"; do
    set -- $spec
    f="$OUT/gen/h2h_$1_$2.mmd"
    "$P" gen "$1" "$2" > "$f"
    echo "  [$1 n=$2, $(wc -c < "$f" | tr -d ' ') B]"
    python3 "$ROOT_DIR/scripts/bench_compare.py" \
      --title "adversarial $1 n=$2: mermaid parse+dagre layout vs Pion parse+layout+svg" \
      --impl "mermaid-dagre=node $AUDIT_DIR/bench/mermaid_dagre_full.mjs $f --count" \
      --impl "pion=$P count $f" --baseline mermaid-dagre --warmup 1 --rounds 5 \
      --bytes "$(wc -c < "$f" | tr -d ' ')" --md-out "$OUT/reports/h2h_$1_$2.md" 2>&1 | tail -6
  done
fi

hr "done"
echo "reports: $OUT/reports"
git -C "$ROOT_DIR" status --porcelain --ignored -- packages/mermaid ':!packages/mermaid/audit' | head
