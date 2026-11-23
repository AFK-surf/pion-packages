#!/bin/sh
# One-command red-team audit of packages/jsonschema (W10 RT-jsonschema) against
# Rust `jsonschema =0.29.1`, Node `ajv@8.17.1` (+ajv-formats@3.0.1) and the official JSON-Schema-Test-Suite.
#
#   sh packages/jsonschema/audit/run_audit.sh [all|build|unit|suite|redteam|modes|deep|dos|bench]
#
# Needs: pionc, cargo (crates cached; builds --offline), node + npm, python3, git (to fetch the suite once).
# All artifacts go to $AUDIT_OUT (default /private/tmp/rt-jsonschema: the *real* /tmp path, the wasm32
# runner does not follow the /tmp symlink). Nothing is written inside the repository.
# Exit code: 0 when every section ran (findings are in the output), 2 on tooling errors.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=${AUDIT_OUT:-/private/tmp/rt-jsonschema}
SUITE_REV=83e866b46c9f9e7082fd51e83a61c5f2145a1ab7 # last JSON-Schema-Test-Suite commit before jsonschema 0.29.1 era (2025-02-19)
SECTION=${1:-all}
DOS_TIMEOUT=${DOS_TIMEOUT:-40}
BIN="$OUT/bin"
NODE_PKG="$OUT/node_pkg"
NODE="env NODE_PATH=$NODE_PKG/node_modules node --stack-size=984 $HERE/diff/node_oracle/oracle.js"
mkdir -p "$BIN" "$OUT/cases"

build() {
  echo "==> build: Pion driver (debug + release), deep probe, Rust jsonschema 0.29.1 oracle, ajv 8.17.1"
  pionc fmt --check "$HERE" "$HERE/diff/pion_driver" "$HERE/dos/pion_deep" || exit 2
  pionc check --json "$HERE" > /dev/null || { pionc check --json "$HERE"; exit 2; }
  pionc build -o "$BIN/pion_driver" "$HERE/diff/pion_driver" > /dev/null || exit 2
  pionc build --release -o "$BIN/pion_driver_rel" "$HERE/diff/pion_driver" > /dev/null || exit 2
  pionc build --release -o "$BIN/pion_deep" "$HERE/dos/pion_deep" > /dev/null || exit 2
  CARGO_TARGET_DIR="$OUT/rust-target" cargo build --quiet --release --locked --offline \
    --manifest-path "$HERE/diff/rust_oracle/Cargo.toml" || exit 2
  cp "$OUT/rust-target/release/jsonschema-audit-oracle" "$BIN/rust_oracle"
  if [ ! -d "$NODE_PKG/node_modules/ajv-formats" ]; then
    mkdir -p "$NODE_PKG"
    (cd "$NODE_PKG" && npm init -y > /dev/null 2>&1 &&
      npm install --no-audit --no-fund ajv@8.17.1 ajv-formats@3.0.1 > /dev/null) || exit 2
  fi
  if [ ! -d "$OUT/suite/.git" ]; then
    git clone -q https://github.com/json-schema-org/JSON-Schema-Test-Suite.git "$OUT/suite" || exit 2
  fi
  git -C "$OUT/suite" checkout -q "$SUITE_REV" || exit 2
  python3 -I "$HERE/diff/gen_suite.py" "$OUT/suite" "$OUT/cases" || exit 2
  python3 -I "$HERE/diff/gen_redteam.py" > "$OUT/cases/redteam.jsonl" || exit 2
  cat "$OUT"/cases/suite_*.jsonl "$OUT/cases/redteam.jsonl" > "$OUT/cases/all.jsonl"
}

unit() {
  echo "==> unit: red-team Pion tests (redteam_* FAIL while a defect exists; control_* must PASS)"
  pionc test --json -p jsonschema_audit "$HERE" > "$OUT/unit.json" 2> "$OUT/unit.stderr"
  python3 - "$OUT/unit.json" "$OUT/unit.stderr" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
bad = 0
for t in d["tests"]:
    kind = "CTRL" if t["name"].startswith("control_") else "RED "
    print(f"  {kind} {'PASS' if t['ok'] else 'FAIL'}  {t['name']}")
    bad += kind == "CTRL" and not t["ok"]
red = [t for t in d["tests"] if not t["name"].startswith("control_")]
print(f"  red: {sum(not t['ok'] for t in red)}/{len(red)} FAIL (evidence) | controls: "
      f"{sum(t['ok'] for t in d['tests'] if t['name'].startswith('control_'))}/"
      f"{sum(1 for t in d['tests'] if t['name'].startswith('control_'))} pass")
for m in re.findall(r"redteam_test\.pion:\d+: (.*?) \(Rust", open(sys.argv[2]).read()):
    print("    failing assertion:", m[:150])
sys.exit(1 if bad else 0)
PY
}

suite() {
  echo "==> suite: official JSON-Schema-Test-Suite @${SUITE_REV%????????????????????????????????} (refRemote.json excluded), Pion vs Rust vs ajv"
  for g in core2020 core7 opt2020 opt7 fmt2020 fmt7; do
    echo "  -- $g (every disagreement: $OUT/out_$g.report.txt)"
    python3 -I "$HERE/diff/run_diff.py" "$OUT/cases/suite_$g.jsonl" "$OUT/out_$g" \
      --pion "$BIN/pion_driver_rel" --rust "$BIN/rust_oracle" --node "$NODE" --quiet || exit 2
  done
  echo "  -- Pion failures by file:"
  cat "$OUT"/out_*.report.txt | grep PION-WRONG | cut -f1 | sed 's/#.*//' | sort | uniq -c | sort -rn | sed 's/^/    /'
}

redteam() {
  echo "==> redteam: curated adversarial differential corpus (spec verdict where defined)"
  python3 -I "$HERE/diff/run_diff.py" "$OUT/cases/redteam.jsonl" "$OUT/out_redteam" \
    --pion "$BIN/pion_driver_rel" --rust "$BIN/rust_oracle" --node "$NODE" | cut -c1-230 || exit 2
}

modes() {
  echo "==> modes: Pion driver x4 (native/wasm32 x debug/release) over all $(wc -l < "$OUT/cases/all.jsonl" | tr -d ' ') cases"
  sh "$HERE/diff/four_modes.sh" "$OUT/cases/all.jsonl" "$OUT/modes"
}

deep() {
  echo "==> deep: stack safety through the public API (native release + wasm32 debug/release)"
  for a in "instance_str 100000" "schema_str 100000" "instance_str 127" "instance_mem 20000" \
           "schema_str_opt 5000 1000000" "schema_str_opt 10000 1000000" "build_only 40000" "build_only 50000"; do
    # shellcheck disable=SC2086
    r=$("$BIN/pion_deep" $a 2>&1 | tail -1 | cut -c1-90); rc=$?
    [ -z "$r" ] && r="(no output)"
    # shellcheck disable=SC2086
    "$BIN/pion_deep" $a > /dev/null 2>&1; rc=$?
    printf '  native-release  %-28s rc=%-3s %s\n' "$a" "$rc" "$r"
  done
  for m in "" "--release"; do
    for a in "instance_str 100000" "schema_str 100000" "instance_str 127" "schema_str_opt 200 1000000" \
             "schema_str_opt 300 1000000" "build_only 1000" "build_only 2000"; do
      # shellcheck disable=SC2086
      r=$(pionc run $m --target wasm32 "$HERE/dos/pion_deep" -- $a 2>&1 | grep -v '^    at' | tail -1 | cut -c1-90)
      printf '  wasm32%-9s %-28s %s\n' "${m:+-release}" "$a" "$r"
    done
  done
}

dos() {
  echo "==> dos: complexity probes (verdict[compile/is_valid/validate ms] wall peakRSS), timeout ${DOS_TIMEOUT}s"
  python3 -I "$HERE/dos/gen_dos.py" "$OUT/dos" || exit 2
  python3 -I "$HERE/dos/run_dos.py" "$OUT/dos" --pion "$BIN/pion_driver_rel" --rust "$BIN/rust_oracle" \
    --node "$NODE" --timeout "$DOS_TIMEOUT"
}

bench() {
  echo "==> bench: adversarial head-to-head with the package's own bench drivers"
  NODE_PKG="$NODE_PKG" sh "$HERE/bench/run_adv.sh" "$OUT/adv"
}

case "$SECTION" in
  all) build; unit; suite; redteam; modes; deep; dos; bench ;;
  build) build ;;
  unit|suite|redteam|modes|deep|dos|bench) [ -x "$BIN/rust_oracle" ] || build; "$SECTION" ;;
  *) echo "unknown section: $SECTION"; exit 2 ;;
esac
echo "==> done; artifacts in $OUT"
