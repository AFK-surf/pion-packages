#!/bin/sh
# One-shot red-team audit for packages/zstd (RT-zstd, see REPORT.md).
#   sh packages/zstd/audit/run_audit.sh [all|quick|build|static|unit|cases|xxhash|valid|crafted|fuzz|determinism|encoder|dos|smoke|bench|inject]
# (single sections need a previous `build`)
# Requires: pionc (~/.pion/bin), node (wasm32 runtime), the official zstd CLI (v1.5.7 was used), cargo (oracle:
# pure safe Rust ruzstd =0.9.0 + C libzstd 1.5.7 through zstd =0.13.3, --locked; crate cache when offline),
# python3 (stdlib only). Artifacts go to $AUDIT_OUT (default /private/tmp/pion-zstd-audit, the real path of /tmp on
# macOS, because the wasm32 runner resolves symlinks). Nothing is written inside the repository.
# Every number README.md claims (Send table, wasm_smoke SHA-256, cross-check counts, benchmark sizes) is parsed from
# README.md at run time (diff/readme.py).
#
# Exit status: 1 while any P0 condition reproduces (crash / trap / hang / over-budget bomb, a native-vs-wasm32 or
# debug-vs-release divergence, a valid stream Pion does not decode byte for byte, an RFC expectation Pion misses
# that no finding explains, Pion output that differs from libzstd, a Pion frame the official decoders reject, a
# failing control case, a wasm_smoke hash that differs from README.md, or an injected bug the control cases miss).
# Open P1/P2 findings are listed as OPEN and fail the run only with STRICT=1. Repository-root files (BENCHMARKS.md,
# catalog.json, README.md, THIRD_PARTY_NOTICES.md, index/) are only ever reported as INFO.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-zstd-audit}
if [ ! -d /private/tmp ] && [ "$AUDIT_OUT" = /private/tmp/pion-zstd-audit ]; then AUDIT_OUT=/tmp/pion-zstd-audit; fi
BIN="$AUDIT_OUT/bin"
C="$AUDIT_OUT/corpus"
R="$AUDIT_OUT/res"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
STRICT=${STRICT:-0}
FUZZ_N=${FUZZ_N:-6000}
README="$PKG_DIR/README.md"
PY="python3 -I -B"
RD="$PY $AUDIT_DIR/diff/readme.py $README"
MODES="native_dbg native_rel wasm_dbg wasm_rel"
SHA() { if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
mkdir -p "$BIN" "$R"
export PYTHONDONTWRITEBYTECODE=1
RC=0
OPEN=""
INFO=""
fail() { echo "  FAIL (P0): $*"; RC=1; }
open_finding() {
  case "$OPEN" in *"- ${1%%:*}:"*) return ;; esac
  echo "  OPEN: $*"
  OPEN="$OPEN
  - $*"
}
info() {
  echo "  INFO: $*"
  INFO="$INFO
  - $*"
}
title() {
  case "$1" in
    P2-1) echo "README.md claims not reproduced (see the section output)" ;;
    *) echo "(see REPORT.md)" ;;
  esac
}
runner() {
  case "$1" in
    native_dbg) echo "$BIN/za_dbg" ;;
    native_rel) echo "$BIN/za_rel" ;;
    wasm_dbg) echo "node $WASM_RT $BIN/za_dbg.wasm" ;;
    wasm_rel) echo "node $WASM_RT $BIN/za_rel.wasm" ;;
  esac
}
build4() { # <pkg_dir> <prefix>
  pionc build -o "$2_dbg" "$1" > /dev/null &&
    pionc build --release -o "$2_rel" "$1" > /dev/null &&
    pionc build --target wasm32 -o "$2_dbg.wasm" "$1" > /dev/null &&
    pionc build --release --target wasm32 -o "$2_rel.wasm" "$1" > /dev/null
}

build() {
  echo "==> build: zstd_audit in 4 modes, Rust oracle (ruzstd =0.9.0 + libzstd via zstd =0.13.3, cargo --locked), corpora"
  pionc fmt --check "$AUDIT_DIR" > /dev/null || fail "pionc fmt --check audit"
  pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" || { cat "$AUDIT_OUT/check.json"; fail "pionc check audit"; return; }
  build4 "$AUDIT_DIR" "$BIN/za" || fail "build zstd_audit (4 modes)"
  M="$AUDIT_DIR/diff/rust/Cargo.toml"
  { CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --offline --manifest-path "$M" 2> /dev/null ||
    CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --manifest-path "$M"; } || fail "cargo build oracle"
  cp "$AUDIT_OUT/rust-target/release/zstd_audit_oracle" "$BIN/oracle"
  $PY "$AUDIT_DIR/diff/zmodel.py" selftest | sed 's/^/  /' || fail "reference model self-test"
  rm -rf "$C" && echo "  corpus: $($PY "$AUDIT_DIR/diff/gen.py" "$C" "$FUZZ_N" "$BIN/oracle" 2> "$AUDIT_OUT/gen.err")"
  [ -s "$C/fuzz.json" ] || { cat "$AUDIT_OUT/gen.err"; fail "corpus generation"; }
  echo "  $(pionc --version) | node $(node --version) | $(zstd --version | tr -d '*' | sed 's/^ *//; s/ *$//') | $(cargo --version) | python $(python3 -c 'import sys;print(sys.version.split()[0])') | $(uname -sm)"
}

static() {
  echo "==> static: license, dependencies, extern \"C\", World, module-level state, floats, panics, internal names, Send"
  SRC=$(cat "$PKG_DIR"/src/*.pion | grep -v '^ *//')
  lic=$(grep -cE '^license *= *"MIT"' "$PKG_DIR/pion.toml")
  echo "  pion.toml license = \"MIT\": $lic"; [ "$lic" = 1 ] || fail "pion.toml license is not MIT"
  deps=$(sed -n '/^\[dependencies\]/,/^\[/p' "$PKG_DIR/pion.toml" | grep -vc '^\[\|^ *$\|^#')
  echo "  [dependencies] entries: $deps"; [ "$deps" = 0 ] || fail "external dependencies"
  for pat in 'extern "C"' '^import '; do
    n=$(printf '%s\n' "$SRC" | grep -c "$pat")
    echo "  $pat: $n"; [ "$n" = 0 ] || fail "$pat in src"
  done
  n=$(printf '%s\n' "$SRC" | grep -cw 'World')
  echo "  World: $n"; [ "$n" = 0 ] || fail "World in src"
  n=$(printf '%s\n' "$SRC" | grep -cE '^(pub )?let mut ')
  echo "  module-level let mut: $n"; [ "$n" = 0 ] || fail "module-level let mut"
  m=$(grep -hE '^(pub )?let [a-zA-Z_0-9]+ *(: *[A-Za-z]|=)' "$PKG_DIR"/src/*.pion)
  nm=$(printf '%s\n' "$m" | grep -c .)
  ns=$(printf '%s\n' "$m" | grep -cvE ': (Int|UInt|UInt64|Int64) = -?(0x)?[0-9A-Fa-f]+(U|UL|L)?$')
  echo "  module-level lets: $nm ($ns not a scalar integer constant)"; [ "$ns" = 0 ] || fail "module-level binding other than a scalar constant"
  n=$(printf '%s\n' "$SRC" | grep -cE 'Double|Float|to_double|\.to_float')
  echo "  Double / Float: $n"; [ "$n" = 0 ] || fail "floating point in src"
  n=$(printf '%s\n' "$SRC" | grep -cE '\bpanic\(|\babort\(|\.unwrap\(\)')
  echo "  panic / abort / unwrap in src: $n"; [ "$n" = 0 ] || fail "panic path in src"
  n=$(cat "$README" "$PKG_DIR"/src/*.pion "$PKG_DIR"/*.pion "$PKG_DIR"/bench/*.sh "$PKG_DIR"/bench/*.py "$PKG_DIR"/bench/*/src/* "$PKG_DIR"/wasm_smoke/src/* |
    grep -ciE 'tokyo|pvg-office|afk-ap|gt1|gt2|office-host|mac-studio|stillfail|/Users/|/home/')
  echo "  internal machine names / paths in README, src, tests, bench, wasm_smoke: $n"; [ "$n" = 0 ] || fail "internal names"
  # (the two scan commands themselves are excluded: they have to spell the patterns)
  n=$(cat "$AUDIT_DIR"/REPORT.md "$AUDIT_DIR"/run_audit.sh "$AUDIT_DIR"/diff/*.py "$AUDIT_DIR"/src/*.pion "$AUDIT_DIR"/*.pion "$AUDIT_DIR"/diff/rust/src/* |
    grep -v "grep -ciE" | grep -ciE 'tokyo|pvg-office|afk-ap-pool|office-host|mac-studio|/Users/|/home/')
  echo "  internal machine names / paths in audit/: $n"; [ "$n" = 0 ] || fail "internal names in audit/"
  grep -q '"zstd"' "$ROOT_DIR/catalog.json" 2> /dev/null ||
    info "root catalog.json / README.md / BENCHMARKS.md / index/ do not list zstd yet (release integration, not this branch)"
  echo "  Send probe: every public type captured in spawn (pionc check), against README.md"
  P="$AUDIT_OUT/send_probe" && rm -rf "$P" && mkdir -p "$P/src"
  printf '[package]\nname = "send_probe"\nversion = "0.1.0"\n\n[dependencies]\nzstd = { path = "%s" }\n' "$PKG_DIR" > "$P/pion.toml"
  probe() { # <type> <body using v>
    printf 'import "zstd"\n\nfn probe(v : %s, world : World) -> Unit {\n%s\n}\n\n///|\npub fn main(world : World) -> Int {\n  0\n}\n' "$1" "$2" > "$P/src/main.pion"
    pionc check --json "$P" 2>&1 | $PY -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d.get("ok") else ",".join(x.get("code","?") for x in d.get("diagnostics",[])))' 2> /dev/null
  }
  for v in "zstd::ZstdLimits:Send" "zstd::ZstdError:Send" "Int64:Send" "Bytes:!Send" "Result[Bytes, zstd::ZstdError]:!Send"; do
    t=${v%:*}; claim=${v##*:}
    r=$(probe "$t" '  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })')
    if [ "$r" = ok ]; then st=Send; else st="!Send ($r)"; fi
    printf '    %-36s %-30s README.md: %s\n' "$t" "$st" "$claim"
    case "$claim:$st" in Send:Send | '!Send:!Send'*) ;; *) open_finding "P2-1: $(title P2-1)"; echo "    ^ Send claim not reproduced" ;; esac
  done
  r=$(probe "String" '  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = zstd::compress(v.to_bytes()) }) })')
  echo "  String captured and compressed inside spawn (README.md pattern): $r"
  $RD send_table > /dev/null || open_finding "P2-1: $(title P2-1)"
}

unit() {
  echo "==> unit: pionc fmt/check/test of packages/zstd, scripts/verify.sh, pionc test of the audit package (control_* must pass)"
  pionc fmt --check "$PKG_DIR" > /dev/null 2>&1 || fail "pionc fmt --check packages/zstd"
  pionc check --json "$PKG_DIR" > /dev/null || fail "pionc check packages/zstd"
  pionc test --json "$PKG_DIR" > "$AUDIT_OUT/unit_pkg.json" 2> /dev/null
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit_audit.json" 2> "$AUDIT_OUT/unit_audit.stderr"
  $PY - "$AUDIT_OUT/unit_pkg.json" "$AUDIT_OUT/unit_audit.json" <<'PY' || fail "unit tests"
import json, sys
pkg = json.load(open(sys.argv[1]))
own = [t for t in pkg["tests"] if t.get("pkg") == "zstd"]
bad = sum(1 for t in own if not t["ok"])
print("  packages/zstd own tests: %d/%d pass" % (len(own) - bad, len(own)))
d = json.load(open(sys.argv[2]))
n = {"PASS": 0, "OPEN": 0, "FAIL": 0}
for t in d["tests"]:
    if t.get("pkg") != "zstd_audit":
        continue
    k = "PASS" if t["ok"] else ("OPEN" if t["name"].startswith("redteam_") else "FAIL")
    n[k] += 1
    if k != "PASS":
        print("  %s  %s" % (k, t["name"]))
    if k == "FAIL":
        bad += 1
print("  audit tests under pionc test: %d pass, %d red-team open, %d control failing" % (n["PASS"], n["OPEN"], n["FAIL"]))
sys.exit(1 if bad else 0)
PY
  # outside a git checkout (or with an uncommitted audit/) the clean-worktree step of verify.sh cannot apply
  flag="--allow-dirty"
  if git -C "$ROOT_DIR" rev-parse --git-dir > /dev/null 2>&1 && [ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]; then flag=""; fi
  sh "$ROOT_DIR/scripts/verify.sh" $flag packages/zstd > "$AUDIT_OUT/verify.log" 2>&1
  v=$?
  echo "  sh scripts/verify.sh $flag packages/zstd: exit $v ($(grep -c '^==> ' "$AUDIT_OUT/verify.log") steps)"
  [ $v = 0 ] || { tail -5 "$AUDIT_OUT/verify.log" | sed 's/^/    /' | cut -c1-200; fail "scripts/verify.sh packages/zstd"; }
}

cases() {
  echo "==> cases: red-team + control cases, one process per case, in all 4 modes"
  names=$("$BIN/za_rel" list)
  for m in $MODES; do
    : > "$R/cases_$m.txt"
    for c in $names; do
      # shellcheck disable=SC2046
      raw=$($(runner $m) case "$c" 2>&1; echo "exit=$?")
      out=$(printf '%s\n' "$raw" | grep -E '^(PASS|FAIL) ' | tail -1)
      [ -n "$out" ] || out="FAIL $c :: ABORT ($(printf '%s\n' "$raw" | tail -2 | tr '\n' ' '))"
      echo "$out" >> "$R/cases_$m.txt"
    done
    cut -d' ' -f1,2 "$R/cases_$m.txt" > "$R/status_$m.txt"
    echo "  $m: $(grep -c '^PASS' "$R/cases_$m.txt")/$(echo "$names" | wc -w | tr -d ' ') pass"
  done
  sed 's/^/    /' "$R/cases_native_rel.txt" | cut -c1-240
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$R/status_native_rel.txt" "$R/status_$m.txt" || { diff "$R/status_native_rel.txt" "$R/status_$m.txt" | head -6; fail "case results of $m differ from native_rel"; }
  done
  grep -q 'ABORT' "$R"/cases_*.txt && fail "a case aborted (panic / trap)"
  grep -q '^FAIL control_' "$R/cases_native_rel.txt" && fail "control case failing"
  for f in $(grep '^FAIL redteam_' "$R/cases_native_rel.txt" | awk '{print $2}'); do
    id=$(echo "$f" | sed -E 's/redteam_p([0-9])_([0-9]+)_.*/P\1-\2/')
    open_finding "$id: $(title "$id")"
    case "$f" in redteam_p0_*) fail "P0 red-team case $f" ;; esac
  done
}

dec_all() { # <group> <mode> -> $R/pion_<group>[_<mode>].txt, plus per-record custom limits
  g=$1; m=$2
  # shellcheck disable=SC2046
  $(runner $m) dec "$C/$g.bin" > "$R/pion_${g}_$m.txt" 2> "$R/pion_${g}_$m.err" || fail "$g: $m exited non-zero ($(tail -1 "$R/pion_${g}_$m.err"))"
}

lim_all() { # <group>: records with custom ZstdLimits, one process each (native --release)
  $PY - "$C" "$1" "$BIN/za_rel" "$R" <<'PY'
import json, subprocess, sys
C, g, za, R = sys.argv[1:5]
idx = [json.loads(l) for l in open("%s/%s.json" % (C, g))]
blob = open("%s/%s.bin" % (C, g), "rb").read()
recs, p = [], 0
while p < len(blob):
    n = int.from_bytes(blob[p:p + 4], "little")
    recs.append(blob[p + 4:p + 4 + n])
    p += 4 + n
with open("%s/pion_%s_lim.txt" % (R, g), "w") as out:
    for r, d in zip(idx, recs):
        if r.get("limits"):
            f = "%s/one.bin" % R
            open(f, "wb").write(len(d).to_bytes(4, "little") + d)
            o = subprocess.run([za, "dec", f] + [str(x) for x in r["limits"]], capture_output=True, text=True).stdout.strip()
            out.write("%s\t%s\n" % (r["name"], o))
PY
}

diffgroup() { # <group>
  g=$1
  dec_all "$g" native_rel
  cp "$R/pion_${g}_native_rel.txt" "$R/pion_$g.txt"
  lim_all "$g"
  "$BIN/oracle" dec "$C/$g.bin" > "$R/oracle_$g.txt" || fail "oracle crashed on $g"
  $PY "$AUDIT_DIR/diff/compare.py" "$C" "$R" "$R" "$g" > "$R/compare_$g.txt" 2>&1
  r=$?
  grep -v '^P0 ' "$R/compare_$g.txt" | sed 's/^/  /' | cut -c1-250
  [ $r = 0 ] || fail "$g: unexplained divergence (see above)"
}

xxhash() {
  echo "==> xxhash: xxhash64() vs the independent model and Rust twox-hash 2.1.5 on 81 inputs (0..1024 B) x 7 seeds (incl. sign-bit seeds), 4 modes"
  $PY - "$AUDIT_DIR/diff" "$R" <<'PY' > "$R/xxh_inputs.txt"
import sys
sys.path.insert(0, sys.argv[1])
import zmodel as Z
lens = [0, 1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 100, 101, 127, 128, 255, 256, 257, 1023, 1024]
recs = []
for n in lens:
    recs.append(bytes((i * 167 + 13) & 255 for i in range(n)))
    recs.append(bytes([0xFF]) * n)
    recs.append(bytes([0x80 | (i & 0x7F) for i in range(n)]))
open(sys.argv[2] + "/xxh.bin", "wb").write(b"".join(len(r).to_bytes(4, "little") + r for r in recs))
seeds = [0, 1, 2654435761, -1, -(1 << 63), (1 << 63) - 1, -2654435761]
for s in seeds:
    print(s, " ".join("%016x" % Z.xxh64(r, s) for r in recs))
PY
  n=0; bad=0
  while read -r seed want; do
    tw=$("$BIN/oracle" xxh "$R/xxh.bin" "$seed" | tr '\n' ' ' | sed 's/ $//')
    [ "$tw" = "$want" ] || { bad=$((bad + 1)); echo "  MODEL != twox-hash for seed=$seed"; }
    for m in $MODES; do
      # shellcheck disable=SC2046
      got=$($(runner $m) xxh "$R/xxh.bin" "$seed" | tr '\n' ' ' | sed 's/ $//')
      n=$((n + $(echo "$want" | wc -w)))
      [ "$got" = "$want" ] || { bad=$((bad + 1)); echo "  MISMATCH seed=$seed mode=$m"; }
    done
  done < "$R/xxh_inputs.txt"
  echo "  $n Pion hash comparisons (81 inputs x 7 seeds x 4 modes) + 567 model-vs-twox-hash, $bad mismatching (seed, mode) pairs"
  [ $bad = 0 ] || fail "xxhash64 differs from the xxHash specification"
  if command -v xxhsum > /dev/null; then
    printf 'The quick brown fox jumps over the lazy dog' > "$R/fox.txt"
    echo "  xxhsum -H64 fox: $(xxhsum -H64 "$R/fox.txt" | cut -d' ' -f1) (model: 0b242d361fda71bc)"
  fi
}

valid() {
  echo "==> valid: official zstd CLI (all levels, --ultra, --long, windows, strategies, stdin), libzstd bulk, ruzstd, multi-frame + skippable -> Pion"
  diffgroup valid
}

crafted() {
  echo "==> crafted: hand-built RFC 8878 adversarial frames (diff/gen.py) -> Pion vs RFC expectation, model, ruzstd, libzstd"
  diffgroup crafted
}

fuzz() {
  echo "==> fuzz: $FUZZ_N mutated / random streams -> Pion vs model vs libzstd vs ruzstd (0 panic / hang / OOM)"
  t0=$(date +%s)
  diffgroup fuzz
  echo "  wall time for $FUZZ_N Pion decodes in one native --release process: $(( $(date +%s) - t0 )) s (incl. oracle)"
}

determinism() {
  echo "==> determinism: every corpus in all 4 modes must decode byte-identically (and encode byte-identically)"
  for g in valid crafted fuzz; do
    for m in native_dbg wasm_dbg wasm_rel; do
      dec_all "$g" "$m"
      cmp -s "$R/pion_${g}_native_rel.txt" "$R/pion_${g}_$m.txt" || fail "$g: $m differs from native_rel"
    done
    echo "  [$g] $(wc -l < "$R/pion_${g}_native_rel.txt" | tr -d ' ') records, results sha256 $(SHA "$R/pion_${g}_native_rel.txt" | cut -c1-16), 4 modes byte-identical"
  done
}

encoder() {
  echo "==> encoder: Pion compress (levels 0..9, +-checksum) of every raw input -> official zstd -t / -d, libzstd, ruzstd, strict model; 4 modes byte-identical"
  $PY "$AUDIT_DIR/diff/encoder.py" "$C" "$R" "$BIN/oracle" "$(runner native_rel)" "$(runner native_dbg)" "$(runner wasm_dbg)" "$(runner wasm_rel)" > "$R/encoder.txt" 2>&1
  r=$?
  sed 's/^/  /' "$R/encoder.txt" | cut -c1-250
  [ $r = 0 ] || fail "a Pion frame is rejected / misdecoded by an official decoder, or the 4 modes differ"
}

dos() {
  echo "==> dos: bombs under default and custom ZstdLimits, native --release and wasm32 --release; scaling; compressor"
  out=$($PY "$AUDIT_DIR/diff/dos.py" "$AUDIT_OUT/dos" "$BIN/za_rel" "node $WASM_RT $BIN/za_rel.wasm")
  r=$?
  printf '%s\n' "$out" | grep -v '^OPENIDS' | cut -c1-230
  for id in $(printf '%s\n' "$out" | grep '^OPENIDS' | cut -d' ' -f2-); do
    open_finding "$id: $(title "$id")"
  done
  [ $r = 0 ] || fail "DoS bomb crashed / trapped / diverged / over budget / superlinear (see above)"
}

smoke() {
  echo "==> smoke: packages/zstd/wasm_smoke in 4 modes vs README.md"
  S="$PKG_DIR/wasm_smoke"
  build4 "$S" "$BIN/smoke" || { fail "build wasm_smoke"; return; }
  want=$($RD smoke_sha)
  for m in native_dbg native_rel wasm_dbg wasm_rel; do
    case $m in
      native_dbg) "$BIN/smoke_dbg" > "$R/smoke_$m.txt" ;;
      native_rel) "$BIN/smoke_rel" > "$R/smoke_$m.txt" ;;
      wasm_dbg) node "$WASM_RT" "$BIN/smoke_dbg.wasm" > "$R/smoke_$m.txt" ;;
      wasm_rel) node "$WASM_RT" "$BIN/smoke_rel.wasm" > "$R/smoke_$m.txt" ;;
    esac || fail "wasm_smoke $m exited non-zero"
    got=$(SHA "$R/smoke_$m.txt")
    echo "  $m sha256 $got ($(wc -c < "$R/smoke_$m.txt" | tr -d ' ') B)"
    [ "$got" = "$want" ] || fail "wasm_smoke $m sha256 != README.md ($want)"
  done
  sed 's/^/    /' "$R/smoke_native_rel.txt"
  for k in smoke_dbg smoke_rel smoke_dbg.wasm smoke_rel.wasm; do printf '  %s %s B' "$k" "$(wc -c < "$BIN/$k" | tr -d ' ')"; done
  echo
}

bench() {
  echo "==> bench: independent re-run of bench/run_bench.sh against README.md"
  sh "$PKG_DIR/bench/run_bench.sh" > "$R/bench.log" 2>&1 || { tail -20 "$R/bench.log"; fail "bench/run_bench.sh failed"; return; }
  grep -E 'PASS|Ratio|^\| `|SHA-256|sha256' "$R/bench.log" | sed 's/^/    /' | cut -c1-240
  $PY "$AUDIT_DIR/diff/readme.py" "$README" bench_check "$R/bench.log" || open_finding "P2-1: $(title P2-1)"
  info "benchmark speed ratios depend on machine load; compare the table above with README.md by hand (re-run on an idle machine before quoting)"
}

inject() {
  echo "==> inject: real bugs injected into an isolated copy of the package must be caught by the control tests"
  $PY "$AUDIT_DIR/diff/inject.py" "$PKG_DIR" "$AUDIT_OUT/inject" || fail "an injected bug was not caught"
}

summary() {
  echo "==> summary"
  [ -n "$INFO" ] && echo "  INFO (not blocking):$INFO"
  if [ -n "$OPEN" ]; then echo "  OPEN findings:$OPEN"; else echo "  OPEN findings: none"; fi
  nopen=$(printf '%s' "$OPEN" | grep -c '^  - ')
  echo "  P0 conditions: $([ $RC = 0 ] && echo none || echo YES)   OPEN: $nopen   STRICT=$STRICT"
  if [ "$STRICT" = 1 ] && [ "$nopen" != 0 ]; then RC=1; fi
  if git -C "$ROOT_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    git -C "$ROOT_DIR" status --porcelain --ignored -- "$PKG_DIR" | grep -v '^?? packages/zstd/audit/$' | grep . && fail "audit left files in the worktree"
  fi
  find "$AUDIT_DIR" -name __pycache__ | grep -q . && fail "__pycache__ left in audit/"
  echo "EXIT=$RC"
}

case "$SECTION" in
  all) build; static; unit; cases; xxhash; valid; crafted; fuzz; determinism; encoder; dos; smoke; bench; inject; summary ;;
  quick) build; unit; cases; xxhash; valid; crafted; fuzz; encoder; summary ;;
  build | static | unit | cases | xxhash | valid | crafted | fuzz | determinism | encoder | dos | smoke | bench | inject) "$SECTION"; summary ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
exit $RC
