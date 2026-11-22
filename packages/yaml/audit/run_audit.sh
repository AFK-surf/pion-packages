#!/bin/sh
# Red-team audit of packages/yaml: one command, Pion vs Rust yaml-rust2 0.10.4 vs Go yaml.v3 v3.0.1.
#
#   sh packages/yaml/audit/run_audit.sh            # everything (~10 min on Apple M-series)
#   sh packages/yaml/audit/run_audit.sh tests yts  # only selected stages
#
# Stages: tests  - `pionc test packages/yaml/audit` (every FAIL is an exhibit; exit status ignored)
#         yts    - full official yaml-test-suite (data branch) through all 3 impls + strict typed event oracle
#         probes - targeted differential probes + emitter round-trip
#         fuzz   - mutation fuzz: 00b956c vs parent 09ca291 (regressions) and Pion vs yaml-rust2
#         dos    - alias bombs, depth, merge-key quadratic, budget false positives, emit amplification
#         bench  - adversarial corpora via scripts/bench_compare.py (SHA-256 gated, warmup 1, 5 rounds)
#
# All binaries, corpora and the yaml-test-suite checkout live in $OUT (default $TMPDIR/pion-yaml-audit);
# nothing is written inside the repository.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
H="$AUDIT_DIR/harness"
OUT="${OUT:-${TMPDIR:-/tmp}/pion-yaml-audit}"
export OUT
export PATH="${HOME}/.pion/bin:${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/go/bin:${PATH}"
YTS_REV="${YTS_REV:-data}"
STAGES="${*:-tests yts probes fuzz dos bench}"
mkdir -p "$OUT"

want() { case " $STAGES " in *" $1 "*) return 0 ;; esac; return 1; }

echo "==> Building drivers into $OUT"
sh "$H/build_drivers.sh" >/dev/null
P="$OUT/pion_driver"; R="$OUT/rust_driver"; G="$OUT/go_driver"

if want tests; then
  echo
  echo "==> [tests] pionc test packages/yaml/audit (FAIL = evidence against Pion)"
  pionc test --json "$AUDIT_DIR" >"$OUT/tests.json" 2>"$OUT/tests.stderr" || true
  python3 - "$OUT/tests.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
mine = [t for t in d["tests"] if t["pkg"] == "yaml_redteam_audit"]
bad = [t for t in mine if not t["ok"]]
print(f"red-team tests: {len(bad)}/{len(mine)} FAIL (upstream yaml tests: {sum(t['ok'] for t in d['tests'] if t['pkg']=='yaml')} pass)")
for t in mine:
    print(("  FAIL " if not t["ok"] else "  pass ") + t["name"])
PYEOF
  echo "  (assertion messages: $OUT/tests.stderr)"
fi

if want yts; then
  echo
  echo "==> [yts] official yaml-test-suite ($YTS_REV branch)"
  if [ ! -d "$OUT/yts/.git" ]; then
    git clone -q --depth 1 -b "$YTS_REV" https://github.com/yaml/yaml-test-suite.git "$OUT/yts"
  fi
  echo "    suite commit: $(git -C "$OUT/yts" rev-parse --short HEAD)"
  python3 "$H/yts_run.py" "$OUT/yts" "$P" "$R" "$G" "$OUT/yts.json"
  python3 "$H/yts_events.py" "$OUT/yts" "$P" || true
  echo "    emitter round trip over every valid suite case:"
  n=0; bad=0
  for f in $(find "$OUT/yts" -name in.yaml | sort); do
    d=$(dirname "$f"); [ -e "$d/error" ] && continue
    n=$((n + 1))
    if ! "$P" rt "$f" >"$OUT/rt_case.txt" 2>&1; then
      bad=$((bad + 1)); echo "    RT FAIL ${d#$OUT/yts/}: $(head -1 "$OUT/rt_case.txt")"
    fi
  done
  echo "    stringify round trip: $((n - bad))/$n valid suite cases preserve type+value"
fi

if want probes; then
  echo
  echo "==> [probes] targeted differential probes"
  python3 "$H/probes.py" "$P" "$R" "$G" "$OUT/probes"
fi

if want dos; then
  echo
  echo "==> [dos] pathological inputs (wall time / peak RSS)"
  python3 "$H/dos.py" "$P" "$R" "$G" "$OUT/dos"
fi

if want fuzz; then
  echo
  echo "==> [fuzz] mutation differential: 00b956c vs parent 09ca291, and Pion vs yaml-rust2"
  [ -d "$OUT/yts/.git" ] || git clone -q --depth 1 -b "$YTS_REV" https://github.com/yaml/yaml-test-suite.git "$OUT/yts"
  rm -rf "$OUT/prev" && mkdir -p "$OUT/prev/drv/src"
  git -C "$ROOT_DIR" archive 09ca291 packages/yaml | tar -x -C "$OUT/prev"
  sed 's/yaml::write_canonical_json_to(sb, \(.*\))$/sb.write_string(yaml::to_canonical_json(\1))/; s/yaml::write_canonical_json_to(sb, yaml::YamlValue::Str(s))/sb.write_string(yaml::to_canonical_json(yaml::YamlValue::Str(s)))/; s/Ok(v) => yaml::write_canonical_json_to(sb, v)/Ok(v) => sb.write_string(yaml::to_canonical_json(v))/' \
    "$H/pion_driver/src/main.pion" >"$OUT/prev/drv/src/main.pion"
  printf '[package]\nname = "yaml_audit_pion_prev"\nversion = "0.1.0"\n\n[dependencies]\nyaml = { path = "%s" }\n' "$OUT/prev/packages/yaml" >"$OUT/prev/drv/pion.toml"
  pionc build --release -o "$OUT/pion_prev" "$OUT/prev/drv" >/dev/null
  python3 "$H/yts_events.py" "$OUT/yts" "$OUT/pion_prev" --show 5 || true
  python3 "$H/regress_fuzz.py" "$OUT/yts" "$P" "$OUT/pion_prev" 20 7 | tail -15
  python3 "$H/fuzz_vs_rust.py" "$OUT/yts" "$P" "$R" 10 11
fi

if want bench; then
  echo
  echo "==> [bench] adversarial corpora (bench_compare.py, SHA-256 gated)"
  python3 "$H/gen_corpora.py" "$OUT/corpora" >/dev/null
  for c in flow_json dq_escapes block_scalars wide_map many_small_docs deep_nesting plain_multiline_comments long_plain_lines anchors_aliases; do
    f="$OUT/corpora/$c.yaml"
    bytes=$(wc -c <"$f" | tr -d ' ')
    set -- --impl "rust_yaml_rust2=$R json $f" --impl "pion_yaml=$P json $f"
    # yaml.v3 needs ~90 s for wide_map (quadratic duplicate-key check); measured once in REPORT.md.
    [ "$c" != wide_map ] && set -- "$@" --impl "go_yaml_v3=$G json $f"
    python3 "$ROOT_DIR/scripts/bench_compare.py" --title "parse+canonical JSON: $c" "$@" \
      --baseline rust_yaml_rust2 --warmup 1 --rounds 5 --bytes "$bytes" --md-out "$OUT/bench_$c.md" >/dev/null
    cat "$OUT/bench_$c.md"; echo
  done
  for c in flow_json many_small_docs block_scalars plain_multiline_comments; do
    f="$OUT/corpora/$c.yaml"
    bytes=$(wc -c <"$f" | tr -d ' ')
    python3 "$ROOT_DIR/scripts/bench_compare.py" --title "emit round trip (parse+emit+reparse+JSON): $c" \
      --impl "rust_yaml_rust2=$R rtjson $f" --impl "pion_yaml=$P rtjson $f" --impl "go_yaml_v3=$G rtjson $f" \
      --baseline rust_yaml_rust2 --warmup 1 --rounds 5 --bytes "$bytes" --md-out "$OUT/bench_rt_$c.md" >/dev/null
    cat "$OUT/bench_rt_$c.md"; echo
  done
fi

echo "==> done; artifacts in $OUT"
