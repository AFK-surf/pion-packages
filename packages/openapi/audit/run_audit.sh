#!/bin/sh
# One-command red-team audit of packages/openapi (Wave 15 RT-openapi) against OpenAPI 3.0.3 / 3.1.0 and
# Go github.com/getkin/kin-openapi v0.131.0.
#
#   sh packages/openapi/audit/run_audit.sh [all|build|unit|diff|modes|dos|bench]
#
# Needs: pionc (AFK-surf/pion@66d2b4b), go >= 1.24 (modules pinned by go.sum, built -mod=readonly), python3.
# All artifacts go to $AUDIT_OUT (default /private/tmp/rt-openapi: the real /tmp path, the wasm32 runner
# does not follow the /tmp symlink). Nothing is written inside the repository.
#
# Exit code: 0 when every red-team test passes, the spec-verdict differential has 0 PION-WRONG fields,
# the 4 build modes agree byte-for-byte and no DoS probe crashes / traps / times out / exceeds 1 GiB RSS;
# 1 while any defect remains; 2 on tooling errors. `bench` never affects the exit code.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=${AUDIT_OUT:-/private/tmp/rt-openapi}
SECTION=${1:-all}
DOS_TIMEOUT=${DOS_TIMEOUT:-60}
BIN="$OUT/bin"
export PION_CACHE_DIR="${PION_CACHE_DIR:-$OUT/pion-cache}"
export GOFLAGS=-mod=readonly GOCACHE="$OUT/gocache" GOPATH="$OUT/gopath" GOTOOLCHAIN=local
export GOPROXY="${GOPROXY:-https://proxy.golang.org}"
mkdir -p "$BIN"
FAILED=0

build() {
  echo "==> build: Pion diff driver / DoS driver (release), Go kin-openapi v0.131.0 oracle, corpora"
  pionc fmt --check "$HERE" "$HERE/diff/pion_driver" "$HERE/dos/pion_dos" "$HERE/bench/pion_fair" || exit 2
  pionc check --json "$HERE" > /dev/null || { pionc check --json "$HERE"; exit 2; }
  pionc build --release -o "$BIN/pion_driver" "$HERE/diff/pion_driver" > /dev/null || exit 2
  pionc build --release -o "$BIN/pion_dos" "$HERE/dos/pion_dos" > /dev/null || exit 2
  (cd "$HERE/diff/go_oracle" && go build -o "$BIN/go_oracle" .) || exit 2
  python3 -I "$HERE/diff/gen_cases.py" > "$OUT/cases.jsonl" || exit 2
  python3 -I "$HERE/dos/gen_dos.py" "$OUT/dos" || exit 2
}

unit() {
  echo "==> unit: red-team Pion tests (p0_/p1_/p2_ FAIL while a defect exists; control_* must PASS)"
  pionc test --json -p openapi_redteam_audit "$HERE" > "$OUT/unit.json" 2> "$OUT/unit.stderr"
  python3 -I - "$OUT/unit.json" "$OUT/unit.stderr" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
msgs = dict()
for ln, m in re.findall(r"redteam_test\.pion:(\d+): (.*?)(?=pion panic at |\Z)", open(sys.argv[2]).read(), re.S):
    msgs.setdefault(int(ln), m.strip()[:170])
red_fail = ctrl_fail = 0
for t in d["tests"]:
    ctrl = t["name"].startswith("control_")
    print(f"  {'CTRL' if ctrl else 'RED '} {'PASS' if t['ok'] else 'FAIL'}  {t['name']}")
    if not t["ok"]:
        ctrl_fail += ctrl
        red_fail += not ctrl
red = [t for t in d["tests"] if not t["name"].startswith("control_")]
ctl = [t for t in d["tests"] if t["name"].startswith("control_")]
print(f"  red: {red_fail}/{len(red)} FAIL (open defects) | controls: {len(ctl) - ctrl_fail}/{len(ctl)} pass")
for ln in sorted(msgs):
    print(f"    redteam_test.pion:{ln}: {msgs[ln]}")
sys.exit(2 if ctrl_fail else (1 if red_fail else 0))
PY
  rc=$?
  [ $rc = 2 ] && { echo "  control test failed: tooling/regression error"; exit 2; }
  [ $rc = 0 ] || FAILED=1
}

diff_() {
  echo "==> diff: $(wc -l < "$OUT/cases.jsonl" | tr -d ' ') curated cases, Pion vs Go kin-openapi vs spec verdict"
  "$BIN/pion_driver" "$OUT/cases.jsonl" > "$OUT/pion.tsv" || exit 2
  "$BIN/go_oracle" < "$OUT/cases.jsonl" > "$OUT/go.tsv" || exit 2
  python3 -I "$HERE/diff/run_diff.py" "$OUT/cases.jsonl" "$OUT/pion.tsv" "$OUT/go.tsv" > "$OUT/diff.txt" || exit 2
  cut -c1-200 "$OUT/diff.txt"
  tail -1 "$OUT/diff.txt" | grep -q 'PION-WRONG=0 ' || FAILED=1
}

modes() {
  echo "==> modes: diff driver x4 (native/wasm32 x debug/release) over the corpus"
  sh "$HERE/diff/four_modes.sh" "$OUT/cases.jsonl" "$OUT/modes" || FAILED=1
  echo "==> modes: DoS driver x4 on bounded probes (outputs must be identical, rc 0, no trap)"
  # the wasm32 runner resolves relative paths against the cwd
  for probe in "from_doc dag_bomb_18.json" "export dag_bomb_25.json" "export recursive_mutual.json" \
               "from_doc ref_chain_200.json" "parse yaml_laughs_1e9.yaml" "parse json_deep_100k.json" \
               "from_doc fanout_4000x50.json"; do
    ref=""
    line=""
    for m in debug release; do
      for t in native wasm32; do
        set --
        [ "$m" = release ] && set -- "$@" --release
        [ "$t" = wasm32 ] && set -- "$@" --target wasm32
        # shellcheck disable=SC2086
        (cd "$OUT/dos" && pionc run "$@" "$HERE/dos/pion_dos" -- $probe > "$OUT/modes/dos.out" 2> "$OUT/modes/dos.err")
        rc=$?
        r=$(tail -1 "$OUT/modes/dos.out")
        [ -z "$ref" ] && ref=$r
        tag=same
        [ "$r" = "$ref" ] && [ $rc = 0 ] && [ -n "$r" ] || { tag="DIFF(rc=$rc)"; FAILED=1; }
        line="$line $m-$t:$tag"
      done
    done
    printf '  %-32s %s | %s\n' "$probe" "$(echo "$ref" | cut -c1-70)" "$line"
  done
  echo "==> modes: wasm32 memory-exhaustion probe (92 KB spec, Validator::from_doc, default limits)"
  (cd "$OUT/dos" && pionc run --release --target wasm32 "$HERE/dos/pion_dos" -- from_doc fanout_ops_30.json \
    > "$OUT/modes/trap.out" 2> "$OUT/modes/trap.err")
  rc=$?
  r=$(tail -1 "$OUT/modes/trap.out")
  if [ $rc != 0 ] || [ -z "$r" ]; then
    echo "  DEFECT wasm32-release rc=$rc: $(grep -v '^ *at ' "$OUT/modes/trap.err" | head -1 | cut -c1-120)"
    FAILED=1
  else
    echo "  wasm32-release rc=0: $r"
  fi
}

dos() {
  echo "==> dos: probes under default OpenApiLimits (verdict wall peakRSS), timeout ${DOS_TIMEOUT}s, cap 1 GiB"
  python3 -I "$HERE/dos/run_dos.py" "$OUT/dos" --pion "$BIN/pion_dos" --go "$BIN/go_oracle" \
    --timeout "$DOS_TIMEOUT" --rss-mb 1024 --tsv "$OUT/dos.tsv" || FAILED=1
}

bench() {
  echo "==> bench: re-run W1/W2/W3 + work-equivalence variants (informational, never gates)"
  sh "$HERE/bench/run_fair.sh" "$OUT/bench" || echo "  (bench run failed)"
}

case "$SECTION" in
  all) build; unit; diff_; modes; dos; bench ;;
  build) build ;;
  unit) build; unit ;;
  diff) build; diff_ ;;
  modes) build; modes ;;
  dos) build; dos ;;
  bench) bench ;;
  *) echo "unknown section: $SECTION"; exit 2 ;;
esac
echo "==> done; artifacts in $OUT; open defects: $([ $FAILED = 0 ] && echo none || echo YES)"
exit $FAILED
