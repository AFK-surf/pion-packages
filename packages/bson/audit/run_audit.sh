#!/bin/sh
# Red-team audit of packages/bson (Pion) vs Rust `bson` =2.15.0 vs Go mongo-driver/v2 bson v2.4.1
# vs the official MongoDB BSON Corpus (specifications @ 2a20bd5). See REPORT.md.
#
#   sh packages/bson/audit/run_audit.sh              # everything (~2 min on an M-series Mac)
#   STEPS="unit corpus" sh packages/bson/audit/run_audit.sh   # subset of: unit corpus vectors fourmode dos bench
#
# Needs: pionc ($HOME/.pion/bin, AFK-surf/pion@79d1fbd), node (wasm32 runtime), cargo, go >= 1.24,
# python3, git, network for the first cargo/go fetch and the corpus clone.
# Every build, corpus, output and report goes to $AUDIT_OUT (default /private/tmp/rt-bson-audit: a real
# path, the wasm32 runtime resolves file arguments through realpath). The worktree is never written to.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BSON_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BSON_DIR/../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/rt-bson-audit}
BIN="$OUT/bin"
STEPS=${STEPS:-"unit corpus vectors fourmode dos bench"}
SPEC_REV=2a20bd509e2ad4ee354b552145094ecdf434ee9d
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH" PYTHONDONTWRITEBYTECODE=1
export CARGO_TARGET_DIR="$OUT/cargo-target" GOPATH="$OUT/gopath" GOCACHE="$OUT/gocache" GOFLAGS=-modcacherw
mkdir -p "$BIN" "$OUT/deep"
want() { case " $STEPS " in *" $1 "*) return 0 ;; esac; return 1; }
section() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }
D="$AUDIT_DIR/diff"

section "0. Build -> $BIN (Pion probe x4 modes, Rust oracle + fair bench, Go oracle, official bench)"
pionc build --release -o "$BIN/probe" "$AUDIT_DIR/probe"
pionc build -o "$BIN/probe_dbg" "$AUDIT_DIR/probe"
pionc build --release --target wasm32 -o "$BIN/probe.wasm" "$AUDIT_DIR/probe"
pionc build --target wasm32 -o "$BIN/probe_dbg.wasm" "$AUDIT_DIR/probe"
for c in oracle/rust bench/rust_fair; do
  rm -rf "$OUT/src-$(basename $c)" && cp -R "$AUDIT_DIR/$c" "$OUT/src-$(basename $c)"
  cargo build -q --release --locked --manifest-path "$OUT/src-$(basename $c)/Cargo.toml"
done
cp "$CARGO_TARGET_DIR/release/rt_bson_oracle" "$BIN/rust_oracle"
cp "$CARGO_TARGET_DIR/release/bson_rust_fair" "$BIN/rust_fair"
rm -rf "$OUT/src-go" && cp -R "$AUDIT_DIR/oracle/go" "$OUT/src-go"
(cd "$OUT/src-go" && go build -o "$BIN/go_oracle" .)
if [ ! -d "$OUT/spec/.git" ]; then
  git clone -q --filter=blob:none --sparse https://github.com/mongodb/specifications "$OUT/spec"
  git -C "$OUT/spec" sparse-checkout set source/bson-corpus source/extended-json
fi
git -C "$OUT/spec" fetch -q origin "$SPEC_REV" 2>/dev/null || true
git -C "$OUT/spec" checkout -q "$SPEC_REV"
CORPUS="$OUT/spec/source/bson-corpus/tests"

if want unit; then
  section "1. Red-team unit tests: pionc test packages/bson/audit (every p0_/p1_/p2_ FAIL is a finding)"
  (cd "$BSON_DIR" && pionc test --json audit > "$OUT/redteam_test.json" 2> "$OUT/redteam_test.stderr") || true
  python3 - "$OUT/redteam_test.json" <<'PY'
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
mine = [t for t in d["tests"] if t["pkg"] == "bson_audit"]
other = [t for t in d["tests"] if t["pkg"] != "bson_audit"]
print("bson_audit: %d tests, %d FAILED (findings), %d passed (controls); dependency tests %d/%d ok" % (
    len(mine), sum(not t["ok"] for t in mine), sum(t["ok"] for t in mine), sum(t["ok"] for t in other), len(other)))
for t in mine:
    print("  %-5s %s" % ("FAIL" if not t["ok"] else "pass", t["name"]))
bad = [t["name"] for t in mine if t["name"].startswith("control_") and not t["ok"]]
if bad:
    print("UNEXPECTED: control tests failing:", bad)
PY
  echo "assertion / panic messages:"; sed 's|^.*/audit/|  |' "$OUT/redteam_test.stderr" | head -60
fi

if want corpus; then
  section "2. Official MongoDB BSON Corpus ($(ls "$CORPUS"/*.json | wc -l | tr -d ' ') files): Pion vs Rust vs Go, graded by the spec runner rules"
  python3 "$D/diff_corpus.py" "$CORPUS" "$OUT/corpus" "$BIN/probe" "$BIN/rust_oracle" "$BIN/go_oracle"
fi

if want vectors; then
  section "3. Adversarial differential (BSON lengths/UTF-8/types, ExtJSON wrappers, Decimal128, 2000 mutations)"
  python3 "$D/gen_vectors.py" "$OUT/vectors.tsv" 20261123 2000
  python3 "$D/diff_vectors.py" "$OUT/vectors.tsv" "$OUT/vectors" "$BIN/probe" "$BIN/rust_oracle" "$BIN/go_oracle" 4
fi

if want fourmode; then
  section "4. 4-mode consistency over corpus + vectors (native rel/dbg, wasm32 rel/dbg via node)"
  [ -f "$OUT/corpus/corpus_requests.tsv" ] || python3 "$D/diff_corpus.py" "$CORPUS" "$OUT/corpus" "$BIN/probe" "$BIN/rust_oracle" "$BIN/go_oracle" >/dev/null
  [ -f "$OUT/vectors/vectors_requests.tsv" ] || { python3 "$D/gen_vectors.py" "$OUT/vectors.tsv" 20261123 2000 >/dev/null;
    python3 "$D/diff_vectors.py" "$OUT/vectors.tsv" "$OUT/vectors" "$BIN/probe" "$BIN/rust_oracle" "$BIN/go_oracle" >/dev/null; }
  cat "$OUT/corpus/corpus_requests.tsv" "$OUT/vectors/vectors_requests.tsv" > "$OUT/all_requests.tsv"
  python3 "$D/fourmode.py" "$OUT/all_requests.tsv" "$BIN" "$WASM_RT" || true
fi

if want dos; then
  section "5a. Deep nesting, limits lifted (max_depth = 2^31-1): Pion native + wasm32"
  for w in bin_dec enc ej_ser ej_parse drop eq; do
    for n in 500 5000 20000 1000000; do
      python3 "$D/oneshot.py" "pion native  $w n=$n" 120 "$BIN/probe" deep $w $n
      python3 "$D/oneshot.py" "pion wasm32  $w n=$n" 120 node "$WASM_RT" "$BIN/probe.wasm" deep $w $n
    done
  done
  section "5b. Same depths through the reference implementations (default APIs)"
  python3 "$D/gen_deep.py" "$OUT/deep" 500 5000 20000 100000
  for n in 500 5000 20000 100000; do
    python3 "$D/oneshot.py" "rust Document::from_reader n=$n" 120 "$BIN/rust_oracle" "$OUT/deep/deep_bson_$n.tsv"
    python3 "$D/oneshot.py" "go   Raw.Validate+Unmarshal n=$n" 120 "$BIN/go_oracle" "$OUT/deep/deep_bson_$n.tsv"
    python3 "$D/oneshot.py" "rust extjson parse n=$n" 120 "$BIN/rust_oracle" "$OUT/deep/deep_json_$n.tsv"
    python3 "$D/oneshot.py" "go   UnmarshalExtJSON n=$n" 120 "$BIN/go_oracle" "$OUT/deep/deep_json_$n.tsv"
  done
  section "5c. Wide documents (O(n^2) hunt): n-key flat document, limits lifted"
  for w in enc dec ej_ser ej_parse; do
    for n in 100000 400000 1000000; do
      python3 "$D/oneshot.py" "pion native  wide $w n=$n" 120 "$BIN/probe" wide $w $n
    done
  done
fi

if want bench; then
  section "6. Benchmark fairness: official W1/W2/W3 harness vs Rust without harness overhead / idiomatic raw API"
  python3 "$BSON_DIR/bench/gen_corpus.py" "$OUT/corpus_1000.bson" 1000 >/dev/null
  pionc build --release -o "$BIN/pion_bench" "$BSON_DIR/bench/pion_bench"
  rm -rf "$OUT/src-rust_bench" && cp -R "$BSON_DIR/bench/rust_bench" "$OUT/src-rust_bench"
  cargo build -q --release --locked --manifest-path "$OUT/src-rust_bench/Cargo.toml"
  cp "$CARGO_TARGET_DIR/release/bson_rust_bench" "$BIN/rust_bench"
  C="$OUT/corpus_1000.bson"; SZ=$(wc -c < "$C" | tr -d ' ')
  bc() { python3 "$ROOT_DIR/scripts/bench_compare.py" --warmup 1 --rounds 7 --baseline rust_official "$@" | sed -n '/^| Impl/,/^_SHA/p'; }
  echo "### W1 decode + walk, 50,000 docs"
  bc --title W1 --ops 50000 --bytes $((SZ * 50)) \
    --impl "pion=$BIN/pion_bench decode $C 50" --impl "rust_official=$BIN/rust_bench decode $C 50" \
    --impl "rust_ref=$BIN/rust_fair decode_ref $C 50" --impl "rust_raw=$BIN/rust_fair decode_raw $C 50"
  echo; echo "### W2 encode, 50,000 docs"
  bc --title W2 --ops 50000 --bytes $((SZ * 50)) \
    --impl "pion=$BIN/pion_bench encode $C 50" --impl "rust_official=$BIN/rust_bench encode $C 50" \
    --impl "rust_to_vec=$BIN/rust_fair encode_vec $C 50"
  echo; echo "### W3 ExtJSON canonical+relaxed roundtrip, 20,000 docs (unchanged harness, for reference)"
  bc --title W3 --ops 20000 --bytes $((SZ * 20)) \
    --impl "pion=$BIN/pion_bench extjson $C 20" --impl "rust_official=$BIN/rust_bench extjson $C 20"
fi

section "Done. Artifacts in $OUT"
