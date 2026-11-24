#!/bin/sh
# One-shot red-team audit for packages/encoding (see REPORT.md).
#   sh packages/encoding/audit/run_audit.sh [all|build|cases|unit|diff|dos|portability|smoke|bench|harness|docs]
# (single sections need a previous `build`; `harness` also needs `diff`)
# Requires: pionc (~/.pion/bin), node (wasm32 runtime), cargo (Rust encoding_rs 0.8.44 oracle, locked; uses the
# crate cache when offline), python3 (stdlib only).
# Artifacts go to $AUDIT_OUT (default /private/tmp/pion-encoding-audit: the real path of /tmp on macOS, because
# the wasm32 runner resolves symlinks). Nothing is written inside the repository.
#
# Exit status: 1 while any P0 condition reproduces (crash / trap / hang on any input, an unexplained divergence
# from encoding_rs on any case, a native-vs-wasm32 or debug-vs-release divergence, a failing control case, a P0
# DoS budget breach, a wasm_smoke hash mismatch with README.md, bench output not byte-identical, or a gate that
# does not catch an injected bug). Open P1/P2 findings are listed as OPEN and fail the run only with STRICT=1.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-encoding-audit}
if [ ! -d /private/tmp ] && [ "$AUDIT_OUT" = /private/tmp/pion-encoding-audit ]; then AUDIT_OUT=/tmp/pion-encoding-audit; fi
BIN="$AUDIT_OUT/bin"
C="$AUDIT_OUT/corpus"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
STREAM_N=${STREAM_N:-300}
STRICT=${STRICT:-0}
CMP="python3 -I $AUDIT_DIR/diff/compare.py"
CASE_GROUPS="labels single dbcs threebyte fourbyte iso2022jp utf bom stream encode"
mkdir -p "$BIN"
export PYTHONDONTWRITEBYTECODE=1
RC=0
OPEN=""
fail() { echo "  FAIL (P0): $*"; RC=1; }
open_finding() { echo "  OPEN: $*"; OPEN="$OPEN
  - $*"; }

runner() {
  case "$1" in
    native_dbg) echo "$BIN/encoding_audit_dbg" ;;
    native_rel) echo "$BIN/encoding_audit_rel" ;;
    wasm_dbg) echo "node $WASM_RT $BIN/encoding_audit_dbg.wasm" ;;
    wasm_rel) echo "node $WASM_RT $BIN/encoding_audit_rel.wasm" ;;
  esac
}
MODES="native_dbg native_rel wasm_dbg wasm_rel"

build() {
  echo "==> build: encoding_audit in 4 modes, encoding_rs 0.8.44 oracle (cargo --locked), corpus"
  pionc fmt --check "$AUDIT_DIR" > /dev/null || fail "pionc fmt --check audit"
  pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" || { cat "$AUDIT_OUT/check.json"; fail "pionc check audit"; return; }
  pionc build -o "$BIN/encoding_audit_dbg" "$AUDIT_DIR" > /dev/null || fail "build native_dbg"
  pionc build --release -o "$BIN/encoding_audit_rel" "$AUDIT_DIR" > /dev/null || fail "build native_rel"
  pionc build --target wasm32 -o "$BIN/encoding_audit_dbg.wasm" "$AUDIT_DIR" > /dev/null || fail "build wasm_dbg"
  pionc build --release --target wasm32 -o "$BIN/encoding_audit_rel.wasm" "$AUDIT_DIR" > /dev/null || fail "build wasm_rel"
  M="$AUDIT_DIR/diff/oracle/Cargo.toml"
  { CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --offline --manifest-path "$M" 2> /dev/null ||
    CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --manifest-path "$M"; } || fail "cargo build oracle"
  cp "$AUDIT_OUT/rust-target/release/encoding_audit_oracle" "$BIN/oracle"
  rm -rf "$C" && python3 -I "$AUDIT_DIR/diff/gen.py" "$C" "$STREAM_N" | sed 's/^/  cases: /'
  echo "  $(pionc --version) | node $(node --version) | $(cargo --version) | encoding_rs 0.8.44"
}

cases() {
  echo "==> cases: red-team + control cases, one process per case, in all 4 modes"
  names=$("$BIN/encoding_audit_rel" list)
  for m in $MODES; do
    : > "$AUDIT_OUT/cases_$m.txt"
    for c in $names; do
      # shellcheck disable=SC2046
      raw=$($(runner $m) case "$c" 2>&1)
      out=$(printf '%s\n' "$raw" | grep -E '^(PASS|FAIL) ' | tail -1)
      [ -n "$out" ] || out="FAIL $c :: ABORT ($(printf '%s\n' "$raw" | grep -m1 'pion panic' || printf '%s\n' "$raw" | tail -1))"
      echo "$out" >> "$AUDIT_OUT/cases_$m.txt"
    done
    echo "  $m: $(grep -c '^PASS' "$AUDIT_OUT/cases_$m.txt")/$(echo "$names" | wc -w | tr -d ' ') pass"
  done
  sed 's/^/    /' "$AUDIT_OUT/cases_native_rel.txt" | cut -c1-240
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/cases_native_rel.txt" "$AUDIT_OUT/cases_$m.txt" || { diff "$AUDIT_OUT/cases_native_rel.txt" "$AUDIT_OUT/cases_$m.txt" | head -6; fail "case results of $m differ from native_rel"; }
  done
  grep -q 'ABORT' "$AUDIT_OUT"/cases_*.txt && fail "a case aborted (panic / trap)"
  grep -q '^FAIL control_' "$AUDIT_OUT/cases_native_rel.txt" && fail "control case failing"
  for f in $(grep '^FAIL redteam_' "$AUDIT_OUT/cases_native_rel.txt" | awk '{print $2}'); do
    open_finding "$(echo "$f" | sed -E 's/redteam_p([0-9])_([0-9]+)_.*/P\1-\2/'): case $f"
    case "$f" in redteam_p0_*) fail "P0 red-team case $f" ;; esac
  done
}

unit() {
  echo "==> unit: pionc fmt/check/test of packages/encoding, pionc test of audit (control_* must pass)"
  pionc fmt --check "$PKG_DIR" > /dev/null 2>&1 || fail "pionc fmt --check packages/encoding"
  pionc check --json "$PKG_DIR" > /dev/null || fail "pionc check packages/encoding"
  pionc test --json "$PKG_DIR" > "$AUDIT_OUT/unit_pkg.json" 2> /dev/null
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit_audit.json" 2> "$AUDIT_OUT/unit_audit.stderr"
  python3 -I - "$AUDIT_OUT/unit_pkg.json" "$AUDIT_OUT/unit_audit.json" <<'PY' || fail "unit tests"
import json, sys
pkg = json.load(open(sys.argv[1]))
print("  packages/encoding own tests: %d/%d pass" % (pkg["passed"], pkg["total"]))
bad = pkg["failed"]
d = json.load(open(sys.argv[2]))
for t in d["tests"]:
    if t["pkg"] != "encoding_audit":
        continue
    print("  %s  %s" % ("PASS" if t["ok"] else ("OPEN" if t["name"].startswith("redteam_") else "FAIL"), t["name"]))
    if not t["ok"] and not t["name"].startswith("redteam_"):
        bad += 1
sys.exit(1 if bad else 0)
PY
}

diff_corpus() {
  echo "==> diff: every group in all 4 modes (must be byte-identical), native_rel vs encoding_rs 0.8.44 line by line"
  for g in $CASE_GROUPS; do
    "$BIN/oracle" run "$C/$g.cases" > "$AUDIT_OUT/oracle_$g.txt" || fail "oracle crashed on $g"
    for m in $MODES; do
      # shellcheck disable=SC2046
      $(runner $m) run "$C/$g.cases" > "$AUDIT_OUT/pion_${g}_$m.txt" 2> "$AUDIT_OUT/pion_${g}_$m.err" || fail "$g: $m exited non-zero ($(tail -1 "$AUDIT_OUT/pion_${g}_$m.err"))"
    done
    for m in native_dbg wasm_dbg wasm_rel; do
      $CMP same "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_${g}_$m.txt" || fail "$g: $m differs from native_rel"
    done
    echo "  [$g] $(wc -l < "$C/$g.cases" | tr -d ' ') cases, 4 modes identical"
    $CMP diff "$C/$g.cases" "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/oracle_$g.txt" 2 | cut -c1-200
    r=$?
    # (the exit status of the pipeline is cut's; re-run for the verdict)
    $CMP diff "$C/$g.cases" "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/oracle_$g.txt" 0 > /dev/null
    r=$?
    [ $r = 1 ] && fail "$g: unexplained divergence from encoding_rs"
    [ $r = 3 ] && open_finding "P2-1: ISO-2022-JP encode_html leaves the Roman state before an NCR ($g group)"
  done
}

dos() {
  echo "==> dos: decoder bombs + encoder worst cases, native_rel (budgets in diff/dos.py)"
  python3 -I "$AUDIT_DIR/diff/dos.py" "$BIN/encoding_audit_rel" -- "$BIN/oracle"
  r=$?
  [ $r = 1 ] && fail "DoS P0 budget"
  [ $r = 3 ] && open_finding "P1-1: legacy CJK encoders take > 1 s per MiB (up to ~6 s/MiB, 15-30x encoding_rs)"
  echo "==> dos (wasm_rel, information): 1 MiB gb18030 4-byte fallback bomb and Big5 encode worst case under node"
  # shellcheck disable=SC2046
  echo "  decode 81308120 x 1 MiB, 1-byte chunks: $($(runner wasm_rel) time gb18030 81308120 1048576 1)"
  # shellcheck disable=SC2046
  echo "  encode_html Big5 U+00E9 x 1 MiB:       $($(runner wasm_rel) enctime Big5 c3a9 1048576)"
}

portability() {
  echo "==> portability: packages/encoding/src: 0 extern \"C\", 0 World, 0 external deps, 0 module-level mutable state"
  # comments are stripped first: types.pion documents "zero extern \"C\", zero World" in a ///| comment
  SRC=$(cat "$PKG_DIR"/src/*.pion | grep -v '^ *//')
  n=$(printf '%s\n' "$SRC" | grep -c 'extern "C"')
  echo "  extern \"C\": $n"; [ "$n" = 0 ] || fail "extern \"C\" in packages/encoding/src"
  n=$(printf '%s\n' "$SRC" | grep -cw 'World')
  echo "  World: $n"; [ "$n" = 0 ] || fail "World in packages/encoding/src"
  n=$(printf '%s\n' "$SRC" | grep -c '^import ')
  echo "  imports: $n"; [ "$n" = 0 ] || fail "imports in packages/encoding/src"
  deps=$(sed -n '/^\[dependencies\]/,/^\[/p' "$PKG_DIR/pion.toml" | grep -vc '^\[\|^ *$\|^#')
  echo "  pion.toml [dependencies] entries: $deps"; [ "$deps" = 0 ] || fail "external dependencies"
  n=$(printf '%s\n' "$SRC" | grep -cE '^(pub )?let mut ')
  echo "  module-level let mut: $n"; [ "$n" = 0 ] || fail "module-level let mut"
  echo "  module-level lets: $(printf '%s\n' "$SRC" | grep -cE '^(pub )?let ') ($(printf '%s\n' "$SRC" | grep -cE '^(pub )?let [a-z0-9_]+ : String') immutable String tables)"
  m=$(grep -nE '^(pub )?let [a-zA-Z_0-9]+ *: *(Array|Bytes|Map|FixedArray|StringBuilder|Ref)' "$PKG_DIR"/src/*.pion | sed "s|$PKG_DIR/||")
  if [ -n "$m" ]; then
    printf '%s\n' "$m" | sed 's/=.*//; s/^/    mutable container at module level: /'
    # prove the container really is shared mutable state: a module-level FixedArray written from a spawned task
    P="$AUDIT_OUT/global_probe" && rm -rf "$P" && mkdir -p "$P/src"
    printf '[package]\nname = "global_probe"\nversion = "0.1.0"\n' > "$P/pion.toml"
    printf 'let tbl : FixedArray[Int] = [1, 2]\n\npub fn main(world : World) -> Int {\n  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { tbl[0] = 99 }) })\n  io_println(world, tbl[0].to_string())\n  0\n}\n' > "$P/src/main.pion"
    echo "    probe: module-level FixedArray written from spawn() compiles and prints $(pionc run "$P" 2>&1 | tail -1) (was 1)"
    open_finding "P1-2: $(printf '%s\n' "$m" | wc -l | tr -d ' ') module-level FixedArray tables = mutable global state (README/types.pion claim zero)"
  fi
  echo "  Send probe (information): which public values may cross a spawn boundary"
  P="$AUDIT_OUT/send_probe" && rm -rf "$P" && mkdir -p "$P/src"
  printf '[package]\nname = "send_probe"\nversion = "0.1.0"\n\n[dependencies]\nencoding = { path = "%s" }\n' "$PKG_DIR" > "$P/pion.toml"
  for v in "encoding::Encoding::Gb18030" "encoding::DecodeOptions::new(true, false)" "encoding::Decoder::new(encoding::Encoding::Utf8)" \
    "encoding::decode(encoding::Encoding::Utf8, Bytes::new(1))" "encoding::encode(encoding::Encoding::Big5, \"x\")" \
    "encoding::encode_html(encoding::Encoding::Big5, \"x\")" "encoding::sniff_bom(Bytes::new(0))"; do
    printf 'import "encoding"\n\n///|\npub fn main(world : World) -> Int {\n  let v = %s\n  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })\n  0\n}\n' "$v" > "$P/src/main.pion"
    r=$(pionc check --json "$P" 2>&1 | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("Send" if d.get("ok") else ",".join(x.get("code","?") for x in d.get("diagnostics",[])))')
    printf '    %-60s %s\n' "$v" "$r"
  done
}

smoke() {
  echo "==> smoke: packages/encoding/wasm_smoke in 4 modes vs README.md"
  want=$(grep -o 'SHA-256: `[0-9a-f]*`' "$PKG_DIR/README.md" | head -1 | sed 's/.*`\([0-9a-f]*\)`/\1/')
  : > "$AUDIT_OUT/smoke.txt"
  for flags in "" "--release" "--target wasm32" "--release --target wasm32"; do
    # shellcheck disable=SC2086
    out=$(pionc run $flags "$PKG_DIR/wasm_smoke" 2>&1 | tail -1)
    h=$(printf '%s\n' "$out" | shasum -a 256 | awk '{print $1}')
    echo "  [${flags:-native debug}] $out  sha256=$h"
    echo "$h" >> "$AUDIT_OUT/smoke.txt"
  done
  [ "$(sort -u "$AUDIT_OUT/smoke.txt" | wc -l | tr -d ' ')" = 1 ] || fail "wasm_smoke output differs between modes"
  [ "$(head -1 "$AUDIT_OUT/smoke.txt")" = "$want" ] || fail "wasm_smoke sha256 differs from README.md ($want)"
  echo "  README.md sha256: $want"
  D="$AUDIT_OUT/smoke_bin" && mkdir -p "$D"
  pionc build -o "$D/n_dbg" "$PKG_DIR/wasm_smoke" > /dev/null && pionc build --release -o "$D/n_rel" "$PKG_DIR/wasm_smoke" > /dev/null &&
    pionc build --target wasm32 -o "$D/w_dbg.wasm" "$PKG_DIR/wasm_smoke" > /dev/null &&
    pionc build --release --target wasm32 -o "$D/w_rel.wasm" "$PKG_DIR/wasm_smoke" > /dev/null
  sizes=$(for f in n_dbg n_rel w_dbg.wasm w_rel.wasm; do printf '%s ' $(($(wc -c < "$D/$f") / 1024)); done)
  echo "$sizes" > "$AUDIT_OUT/smoke_sizes.txt"
  echo "  binary sizes KiB (native dbg / rel, wasm32 dbg / rel): $sizes  README: 358 423 296 297"
}

docs() {
  echo "==> docs: README.md claims vs measurements, upstream test port (AGENTS.md 1.1)"
  why=""
  n=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["total"])' "$AUDIT_OUT/unit_pkg.json" 2> /dev/null || echo 0)
  echo "  packages/encoding unit tests: $n (encoding_rs 0.8.44 ships 158 #[test]s; no WPT encoding vectors ported)"
  [ "$n" -lt 20 ] && why="$why upstream-tests($n)"
  if grep -q '0 divergences' "$PKG_DIR/README.md"; then
    if grep -q 'ISO-2022-JP' "$PKG_DIR/README.md" && [ -f "$AUDIT_OUT/pion_encode_native_rel.txt" ] &&
      ! $CMP diff "$C/encode.cases" "$AUDIT_OUT/pion_encode_native_rel.txt" "$AUDIT_OUT/oracle_encode.txt" 0 > /dev/null; then
      echo "  README: \"0 divergences ... All 10 encoders (... ISO-2022-JP) with HTML NCR fallback\" is contradicted by the encode group"
      why="$why zero-divergence-claim"
    fi
  fi
  ls "$PKG_DIR"/src "$PKG_DIR"/tests 2> /dev/null | grep -qi 'diff\|oracle' || { echo "  README differential claims ship no harness (only bench/ references encoding_rs)"; why="$why no-diff-harness"; }
  if [ -f "$AUDIT_OUT/smoke_sizes.txt" ]; then
    got=$(cat "$AUDIT_OUT/smoke_sizes.txt" | tr -s ' ' | sed 's/ $//')
    [ "$got" = "358 423 296 297" ] || { echo "  README binary sizes 358/423/296/297 KB, measured $got KiB"; why="$why sizes"; }
  fi
  [ -n "$why" ] && open_finding "P2-5: README / process claims not backed:$why"
}

bench() {
  echo "==> bench: packages/encoding/bench/run_bench.sh as shipped (stdout SHA-256 must be identical per scenario)"
  ENCODING_BENCH_ITERS=${ENCODING_BENCH_ITERS:-100} sh "$PKG_DIR/bench/run_bench.sh" > "$AUDIT_OUT/bench.log" 2>&1 || { tail -20 "$AUDIT_OUT/bench.log"; fail "run_bench.sh"; return; }
  grep -E '^\| `|SHA-256 verified' "$AUDIT_OUT/bench.log" | sed 's/^/  /'
  python3 -I - /tmp/pion-encoding-bench <<'PY' || fail "shipped bench: output hash / protocol"
import json, sys, os
ok = True
for s in ("utf8", "gb18030", "sjis"):
    d = json.load(open(os.path.join(sys.argv[1], "bench_%s.json" % s)))
    r = {x["name"]: x for x in d["results"]}
    good = bool(d.get("sha256")) and d["rounds"] >= 5 and d["warmup"] >= 1
    ok &= good
    print("  %-8s sha256 %s  pion %.1f ms  encoding_rs %.1f ms  speedup %.2fx  warmup %d rounds %d" % (
        s, d.get("sha256", "?")[:16], r["pion_encoding"]["median_ms"], r["rust_encoding_rs"]["median_ms"],
        r["pion_encoding"]["speedup_vs_baseline"], d["warmup"], d["rounds"]))
sys.exit(0 if ok else 1)
PY
  # the shipped bench never measures an encoder or a streaming decoder: same binaries, same machine, one round
  echo "  not covered by the shipped bench (information, 1 MiB, single run):"
  for e in gb18030 Shift_JIS; do
    cp=$([ "$e" = gb18030 ] && echo e4b8ad || echo e38182)
    echo "    encode_html $e U+$( [ "$e" = gb18030 ] && echo 4E2D || echo 3042 ): pion $("$BIN/encoding_audit_rel" enctime $e $cp 1048576 | cut -d' ' -f1) ms, encoding_rs $("$BIN/oracle" enctime $e $cp 1048576 | cut -d' ' -f1) ms"
  done
}

harness() {
  echo "==> harness: the diff gate must catch injected decoder bugs (copies in \$AUDIT_OUT)"
  for bug in gb_prepend big5_restore utf8_bom iso2022jp_escape; do
    H="$AUDIT_OUT/inject_$bug" && rm -rf "$H" && mkdir -p "$H" && cp -R "$PKG_DIR" "$H/encoding"
    python3 -I - "$H/encoding/src" "$bug" <<'PY'
import sys, os
d, bug = sys.argv[1], sys.argv[2]
if bug == "gb_prepend":  # gb18030: forget to restore the second (ASCII digit) byte when the 3rd byte is bad
    p, old, new = "cjk.pion", "      out.push_replacement()\n      out.push_u8(sec_byte)\n    } else {", "      out.push_replacement()\n    } else {"
elif bug == "big5_restore":  # Big5: swallow an ASCII trail byte after a valid-range but unmapped pointer
    p = "cjk.pion"
    old = "          out.push_replacement()\n          if b >= 0x80 {\n            i = i + 1\n          }\n        }\n      } else if big5_is_astral"
    new = "          out.push_replacement()\n          i = i + 1\n        }\n      } else if big5_is_astral"
elif bug == "utf8_bom":  # UTF-8: EF BB <not BF> resumes the 3-byte sequence with the wrong number of seen bytes
    p, old, new = "utf.pion", "      st.needed = 2\n      st.seen = 1\n", "      st.needed = 2\n      st.seen = 0\n"
else:  # ISO-2022-JP: a failed escape forgets to replay the '$' / '(' byte in the ASCII / Roman state
    p = "cjk.pion"
    old = "        if st.output_state == 0 || st.output_state == 1 {\n          out.push_u8(saved_lead)\n        } else if st.output_state == 2 {\n          out.push_upper_bmp(0xFF61 + (saved_lead - 0x21))\n        } else {\n          // LeadByte: saved_lead (0x24 or 0x28) becomes lead"
    new = "        if st.output_state == 0 || st.output_state == 1 {\n          ()\n        } else if st.output_state == 2 {\n          out.push_upper_bmp(0xFF61 + (saved_lead - 0x21))\n        } else {\n          // LeadByte: saved_lead (0x24 or 0x28) becomes lead"
s = open(os.path.join(d, p)).read()
assert s.count(old) == 1, bug
open(os.path.join(d, p), "w").write(s.replace(old, new))
PY
    pionc build --release -o "$H/ea" "$H/encoding/audit" > /dev/null || { fail "harness build ($bug)"; continue; }
    caught=""
    for g in fourbyte dbcs utf iso2022jp bom stream; do
      "$H/ea" run "$C/$g.cases" > "$H/$g.txt"
      $CMP diff "$C/$g.cases" "$H/$g.txt" "$AUDIT_OUT/oracle_$g.txt" 0 > "$H/$g.log"
      [ $? = 1 ] && caught="$caught $g($(grep -m1 'divergent' "$H/$g.log" | awk '{print $4}'))"
    done
    if [ -z "$caught" ]; then
      fail "harness: injected $bug bug not caught by the diff gate"
    else
      echo "  injected $bug: diff gate fails as it must in$caught"
    fi
  done
}

clean_check() {
  d=$(git -C "$ROOT_DIR" status --porcelain --ignored -- packages/encoding | grep -v '^?? packages/encoding/audit/$')
  [ -z "$d" ] || { echo "$d"; fail "worktree not clean after audit"; }
}

case "$SECTION" in
  build) build ;;
  cases) cases ;;
  unit) unit ;;
  diff) diff_corpus ;;
  dos) dos ;;
  portability) portability ;;
  smoke) smoke ;;
  bench) bench ;;
  harness) harness ;;
  docs) docs ;;
  all)
    build
    cases
    unit
    diff_corpus
    dos
    portability
    smoke
    bench
    harness
    docs
    ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
clean_check
if [ -n "$OPEN" ]; then
  echo "==> open non-P0 findings (REPORT.md):$OPEN" | awk '!seen[$0]++'
  [ "$STRICT" = 1 ] && RC=1
fi
if [ "$RC" = 0 ]; then echo "AUDIT PASS (0 P0)"; else echo "AUDIT FAIL"; fi
exit $RC
