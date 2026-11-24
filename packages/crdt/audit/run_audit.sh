#!/bin/sh
# One-shot red-team audit of packages/crdt against official Node.js yjs and Rust yrs.
#
#   sh packages/crdt/audit/run_audit.sh            # everything (tests, fuzz, malformed, bench)
#   SECTIONS="tests fuzz" sh .../run_audit.sh      # subset: tests fuzz yrs malformed size bench
#   SEEDS=200 ROUNDS=5 sh .../run_audit.sh
#
# Nothing is written inside the git worktree: node_modules, cargo target, binaries, traces and
# logs live in $AUDIT_CACHE (default ~/.cache/pion-crdt-audit) and $AUDIT_OUT.
# Exit code is 0 even though findings are expected; read $AUDIT_OUT/summary.txt.
set -u

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_CACHE=${AUDIT_CACHE:-$HOME/.cache/pion-crdt-audit}
AUDIT_OUT=${AUDIT_OUT:-/tmp/pion-crdt-audit-out}
SECTIONS=${SECTIONS:-"tests fuzz yrs malformed size bench"}
SEEDS=${SEEDS:-60}
ROUNDS=${ROUNDS:-5}
YJS_VERSION=13.6.33
YOCTO_REV=$(awk -F'"' '/^[[:space:]]*y-octo[[:space:]]*=/{for(i=1;i<=NF;i++) if($i ~ /rev[[:space:]]*=/) {print $(i+1); exit}}' "$AUDIT_DIR/rust/Cargo.toml")
if [ -z "$YOCTO_REV" ]; then
  echo "failed to parse y-octo rev from $AUDIT_DIR/rust/Cargo.toml" >&2
  exit 1
fi
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export CARGO_TARGET_DIR="$AUDIT_CACHE/target"
export CARGO_NET_GIT_FETCH_WITH_CLI=true
export YJS_MODULE="$AUDIT_CACHE/node_modules/yjs"
BIN="$AUDIT_CACHE/bin"
HARNESS="$BIN/harness"
PBENCH="$BIN/pion_bench"
YRS_INTERP="$CARGO_TARGET_DIR/release/yrs_interp"
YRS_BENCH="$CARGO_TARGET_DIR/release/yrs_bench"
YOCTO_BENCH="$CARGO_TARGET_DIR/release/y_octo_bench"
TRACE="$AUDIT_CACHE/traces/automerge-paper.ops"
TRACE_UPD="$AUDIT_CACHE/traces/automerge-paper.update.hex"
mkdir -p "$AUDIT_CACHE/bin" "$AUDIT_CACHE/traces" "$AUDIT_OUT/fuzz"
SUMMARY="$AUDIT_OUT/summary.txt"
: >"$SUMMARY"
say() { echo "$*" | tee -a "$SUMMARY"; }
has() { case " $SECTIONS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

say "== setup ($(uname -sm), node $(node --version), $(pionc --version), $(cargo --version))"
if [ ! -d "$YJS_MODULE" ] || ! grep -q "\"version\": \"$YJS_VERSION\"" "$YJS_MODULE/package.json"; then
  (cd "$AUDIT_CACHE" && { [ -f package.json ] || npm init -y >/dev/null; } && npm install "yjs@$YJS_VERSION" >/dev/null 2>&1) || { say "npm install yjs failed"; exit 1; }
fi
say "yjs $(node -p "require('$YJS_MODULE/package.json').version")"
pionc build --release -o "$HARNESS" "$AUDIT_DIR/harness" || exit 1
pionc build --release -o "$PBENCH" "$AUDIT_DIR/bench/pion_bench" || exit 1
(cd "$AUDIT_DIR/rust" && cargo build --release --locked --bins >"$AUDIT_OUT/cargo-rust.log" 2>&1) || { tail -30 "$AUDIT_OUT/cargo-rust.log"; exit 1; }
tail -1 "$AUDIT_OUT/cargo-rust.log"
YOCTO_DIR="$AUDIT_CACHE/y-octo"
YOCTO_SRC="${YOCTO_REPO:-https://github.com/y-crdt/y-octo.git}"
if [ ! -d "$YOCTO_DIR/.git" ]; then
  git clone --filter=blob:none "$YOCTO_SRC" "$YOCTO_DIR" >"$AUDIT_OUT/y-octo-git.log" 2>&1 || { tail -20 "$AUDIT_OUT/y-octo-git.log"; say "git clone y-octo failed"; exit 1; }
fi
if [ "$(git -C "$YOCTO_DIR" rev-parse HEAD 2>/dev/null)" != "$YOCTO_REV" ]; then
  git -C "$YOCTO_DIR" fetch --depth=1 "$YOCTO_SRC" "$YOCTO_REV" >"$AUDIT_OUT/y-octo-git.log" 2>&1 \
    || git -C "$YOCTO_DIR" fetch "$YOCTO_SRC" >"$AUDIT_OUT/y-octo-git.log" 2>&1 \
    || { tail -20 "$AUDIT_OUT/y-octo-git.log"; say "git fetch y-octo failed"; exit 1; }
  git -C "$YOCTO_DIR" checkout --detach "$YOCTO_REV" >"$AUDIT_OUT/y-octo-git.log" 2>&1 \
    || { tail -20 "$AUDIT_OUT/y-octo-git.log"; say "git checkout y-octo $YOCTO_REV failed"; exit 1; }
fi
cp "$AUDIT_DIR/rust/y-octo-wasm.Cargo.lock" "$YOCTO_DIR/Cargo.lock" || { say "missing $AUDIT_DIR/rust/y-octo-wasm.Cargo.lock"; exit 1; }
(cd "$YOCTO_DIR" && CARGO_TARGET_DIR="$AUDIT_CACHE/target-yocto-wasm" cargo build -p y-octo-wasm --target wasm32-unknown-unknown --release --locked >"$AUDIT_OUT/cargo-yocto-wasm.log" 2>&1) || { tail -30 "$AUDIT_OUT/cargo-yocto-wasm.log"; exit 1; }
tail -1 "$AUDIT_OUT/cargo-yocto-wasm.log"
export YOCTO_WASM="$AUDIT_CACHE/target-yocto-wasm/wasm32-unknown-unknown/release/y_octo_wasm.wasm"
export YOCTO_WASM_JS="$YOCTO_DIR/y-octo-wasm/js/index.mjs"
say "y-octo rev $(git -C "$YOCTO_DIR" rev-parse --short HEAD)"
if [ ! -f "$TRACE" ]; then
  curl -sSfL -o "$AUDIT_CACHE/traces/automerge-paper.json.gz" \
    https://raw.githubusercontent.com/josephg/editing-traces/master/sequential_traces/automerge-paper.json.gz || exit 1
  node -e "
    const z=require('zlib'),fs=require('fs');
    const j=JSON.parse(z.gunzipSync(fs.readFileSync('$AUDIT_CACHE/traces/automerge-paper.json.gz')));
    const out=[];for(const t of j.txns)for(const [p,d,s] of t.patches)out.push(p+' '+d+' '+Buffer.from(s,'utf8').toString('hex'));
    fs.writeFileSync('$TRACE',out.join('\n')+'\n');"
fi
[ -f "$TRACE_UPD" ] || node "$AUDIT_DIR/bench/make_update.mjs" "$TRACE" "$TRACE_UPD"

# ---------------------------------------------------------------------------------------------
if has tests; then
  say ""
  say "== [1] pionc test packages/crdt/audit (each FAIL = evidence; control_* must PASS)"
  pionc test --json -p crdt_redteam_audit "$AUDIT_DIR" 2>"$AUDIT_OUT/tests.stderr" >"$AUDIT_OUT/tests.json"
  python3 - "$AUDIT_OUT/tests.json" "$AUDIT_OUT/tests.stderr" <<'EOF' | tee -a "$SUMMARY"
import json, sys
j = json.load(open(sys.argv[1]))
err = open(sys.argv[2]).read().splitlines()
print(f"total={j['total']} passed={j['passed']} failed={j['failed']}")
for t in j['tests']:
    print(("PASS " if t['ok'] else "FAIL ") + t['name'])
print("-- failure messages:")
for l in err:
    if 'pion panic' in l:
        print("  " + l.split('redteam_test.pion:')[-1][:220])
EOF
fi

# ---------------------------------------------------------------------------------------------
if has fuzz; then
  say ""
  say "== [2] differential fuzz vs official yjs ($SEEDS seeds per mode; 3-5 clients, random partial syncs)"
  say "   '+nm' = harness clears search markers before every local op (isolates bugs other than P0-1)"
  for m in ops-ascii ops-unicode ops-emoji shuffle shuffle-emoji format ops-ascii+nm ops-unicode+nm ops-emoji+nm format+nm; do
    node "$AUDIT_DIR/node/fuzz.mjs" "$HARNESS" "$m" "$SEEDS" "$AUDIT_OUT/fuzz" >"$AUDIT_OUT/fuzz-$m.log" 2>&1
    say "   $(tail -1 "$AUDIT_OUT/fuzz-$m.log")"
  done
  node "$AUDIT_DIR/node/fuzz_merge.mjs" "$HARNESS" "$SEEDS" "$AUDIT_OUT/fuzz" >"$AUDIT_OUT/fuzz-merge.log" 2>&1
  say "   $(tail -1 "$AUDIT_OUT/fuzz-merge.log")"
  say "   (failing scripts: $AUDIT_OUT/fuzz/*.txt; shrink with: node node/minimize.mjs $HARNESS <script>)"
fi

# ---------------------------------------------------------------------------------------------
if has yrs; then
  say ""
  say "== [3] triangulation: Rust yrs replays the same shuffled-delivery scripts"
  ok=0
  bad=0
  for f in "$AUDIT_OUT"/fuzz/shuffle-*.txt; do
    [ -f "$f" ] || continue
    exp="D 99 $(grep '^# expect' "$f" | cut -c10-)"
    got=$("$YRS_INTERP" "$f" | grep '^D 99')
    if [ "$exp" = "$got" ]; then ok=$((ok + 1)); else bad=$((bad + 1)); fi
  done
  say "   yrs == yjs on $ok scripts, differs on $bad (Pion: see shuffle / shuffle-emoji above)"
fi

# ---------------------------------------------------------------------------------------------
if has malformed; then
  say ""
  say "== [4] malformed / adversarial Yjs v1 input (Pion vs yjs vs yrs; !! = Pion crash/hang/OOM)"
  node "$AUDIT_DIR/node/fuzz_malformed.mjs" "$HARNESS" "$YRS_INTERP" "$((SEEDS * 5))" "$AUDIT_OUT/malformed" >"$AUDIT_OUT/malformed.log" 2>&1
  grep -v '^  *mut_' "$AUDIT_OUT/malformed.log" | tee -a "$SUMMARY" >/dev/null
  sed 's/^/   /' "$AUDIT_OUT/malformed.log" | grep -E '!!|MALFORMED' | head -20
fi

# ---------------------------------------------------------------------------------------------
if has size; then
  say ""
  say "== [5] update size after the automerge-paper trace (259,778 edits, 104,852 chars final)"
  python3 - "$TRACE" "$AUDIT_OUT/trace_script.txt" <<'EOF'
import sys
lines = ['doc 1 1']
for l in open(sys.argv[1]):
    p, d, h = l.rstrip('\n').split(' ')
    if int(d): lines.append(f'td 1 t {p} {d}')
    if h: lines.append(f'ti 1 t {p} {h}')
lines.append('upd 1')
open(sys.argv[2], 'w').write('\n'.join(lines) + '\n')
EOF
  p=$("$HARNESS" "$AUDIT_OUT/trace_script.txt" | awk '/^U /{print length($3)/2}')
  r=$("$YRS_INTERP" "$AUDIT_OUT/trace_script.txt" | awk '/^U /{print length($3)/2}')
  [ -n "$p" ] || { say "harness size failed"; exit 1; }
  [ -n "$r" ] || { say "yrs_interp size failed"; exit 1; }
  yo=$("$YOCTO_BENCH" size 0 1 "$TRACE") || { say "y_octo_bench size failed"; exit 1; }
  yw=$(node "$AUDIT_DIR/bench/yocto_wasm_bench.mjs" size 0 1 "$TRACE") || { say "yocto_wasm_bench size failed"; exit 1; }
  y=$(($(wc -c <"$TRACE_UPD") / 2))
  say "   encodeStateAsUpdate bytes: node_yjs=$y rust_yrs=$r rust_y_octo=$yo node_y_octo_wasm=$yw pion=$p"
fi

# ---------------------------------------------------------------------------------------------
if has bench; then
  say ""
  say "== [6] head-to-head benchmarks: Pion vs Node yjs vs Rust yrs vs Rust y-octo vs Node y-octo-wasm (--release), warmup 1, rounds $ROUNDS"
  bench() {
    name=$1
    shift
    rm -f "$AUDIT_OUT/bench-$name.md" "$AUDIT_OUT/bench-$name.json"
    if ! python3 "$ROOT_DIR/scripts/bench_compare.py" --title "$name" --warmup 1 --rounds "$ROUNDS" \
      --impl "pion=$PBENCH $*" \
      --impl "node_yjs=node $AUDIT_DIR/bench/node_bench.mjs $*" \
      --impl "rust_yrs=$YRS_BENCH $*" \
      --impl "rust_y_octo=$YOCTO_BENCH $*" \
      --impl "node_y_octo_wasm=node $AUDIT_DIR/bench/yocto_wasm_bench.mjs $*" \
      --baseline rust_yrs \
      --md-out "$AUDIT_OUT/bench-$name.md" --json-out "$AUDIT_OUT/bench-$name.json" >"$AUDIT_OUT/bench-$name.log" 2>&1; then
      tail -30 "$AUDIT_OUT/bench-$name.log"
      say "bench $name failed"
      exit 1
    fi
    say ""
    say "### $name ($*)"
    grep -E '^\||SHA-256|mismatch' "$AUDIT_OUT/bench-$name.md" | tee -a "$SUMMARY" >/dev/null
    grep -E '^\| `|SHA' "$AUDIT_OUT/bench-$name.md"
  }
  bench text_w1 text 20000 3
  bench append_50k append 50000 1
  bench append_100k append 100000 1
  bench append_200k append 200000 1
  bench tombstone_50k tombstone 50000 1
  bench trace_automerge trace 0 1 "$TRACE"
  bench remote_apply remote 0 20 "$TRACE_UPD"
fi

say ""
say "summary: $SUMMARY"
