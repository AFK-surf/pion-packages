#!/bin/sh
# One-shot red-team audit of packages/toml:
#   Pion `toml`  vs  Rust `toml` 1.2.2 (latest) / 0.8.23 (what bench/rust_bench pins)  vs  Go BurntSushi/toml v1.6.0
#
#   sh packages/toml/audit/run_audit.sh            # everything (~10 min on an M-series Mac)
#   sh packages/toml/audit/run_audit.sh --quick    # smaller fuzz / DoS / bench sizes (~3 min)
#   SECTIONS="build compliance" sh .../run_audit.sh # only some sections:
#        build compliance probes fuzz floats roundtrip errpos tests dos bench
#
# Needs: pionc (~/.pion/bin), cargo, go, python3, cc, git, network for the first cargo/go/git fetch.
# Everything it builds or generates goes to $AUDIT_OUT (default /tmp/pion-toml-audit); the git
# worktree is never written to (AGENTS.md 1.5).
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT="${AUDIT_OUT:-/tmp/pion-toml-audit}"
BIN="$OUT/bin"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1
SECTIONS="${SECTIONS:-build compliance probes fuzz floats roundtrip errpos tests dos bench}"
TOML_TEST_TAG="${TOML_TEST_TAG:-v2.2.0}"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export AUDIT_BIN="$BIN"
mkdir -p "$BIN" "$OUT/logs"

want() { case " $SECTIONS " in *" $1 "*) return 0 ;; esac; return 1; }
hdr() { printf '\n\033[1m==== %s ====\033[0m\n' "$*"; }

if want build; then
  hdr "build: pion_cli (pionc --release), rust_ref (toml 1.2.2 + 0.8.23), go_ref (BurntSushi v1.6.0), toml-test $TOML_TEST_TAG"
  pionc build --release -o "$BIN/pion_cli" "$AUDIT_DIR/tools/pion_cli"
  CARGO_TARGET_DIR="$OUT/rust-target" cargo build --quiet --release --locked \
    --manifest-path "$AUDIT_DIR/tools/rust_ref/Cargo.toml"
  cp "$OUT/rust-target/release/rust_ref" "$BIN/rust_ref"
  (cd "$AUDIT_DIR/tools/go_ref" && GOFLAGS=-mod=mod go build -o "$BIN/go_ref" .)
  cc -O2 -o "$BIN/hashdos_gen" "$AUDIT_DIR/dos/hashdos_gen.c"
  if [ ! -d "$OUT/toml-test" ]; then
    git clone --quiet https://github.com/toml-lang/toml-test.git "$OUT/toml-test"
  fi
  git -C "$OUT/toml-test" fetch --quiet --tags origin
  git -C "$OUT/toml-test" -c advice.detachedHead=false checkout --quiet "$TOML_TEST_TAG"
  (cd "$OUT/toml-test" && go build -o "$BIN/toml-test" ./cmd/toml-test)
  python3 "$ROOT_DIR/packages/toml/bench/gen_data.py" "$OUT/data/corpus.toml" 240 >/dev/null
  python3 "$AUDIT_DIR/bench/gen_adversarial.py" "$OUT/data" >/dev/null
  echo "binaries in $BIN"
fi

if want compliance; then
  for spec in 1.0 1.1; do
    for impl in pion_cli rust_ref; do
      hdr "toml-test $TOML_TEST_TAG, TOML $spec: $impl (decoder + encoder)"
      "$BIN/toml-test" test -toml "$spec" -color never \
        -decoder "sh $AUDIT_DIR/scripts/pion_stdin.sh $BIN/$impl decode" \
        -encoder "sh $AUDIT_DIR/scripts/pion_stdin.sh $BIN/$impl encode" \
        > "$OUT/logs/toml-test-$spec-$impl.txt" 2>&1 || true
      grep -E '^FAIL' "$OUT/logs/toml-test-$spec-$impl.txt" | sed 's/^/  /' || true
      tail -3 "$OUT/logs/toml-test-$spec-$impl.txt"
    done
  done
  echo "  (packages/toml/README.md claims 208 valid + 509 invalid: that is an older toml-test release;"
  echo "   $TOML_TEST_TAG lists $(grep -c '^valid/.*\.toml$' "$OUT/toml-test/tests/files-toml-1.0.0") valid + $(grep -c '^invalid/.*\.toml$' "$OUT/toml-test/tests/files-toml-1.0.0") invalid for TOML 1.0.0)"
fi

if want probes; then
  hdr "hand-written adversarial probes (diff/probes.py): pion vs rust 1.2 / 0.8 vs go"
  python3 "$AUDIT_DIR/diff/diff_probe.py" "$OUT/logs/probes.json"
fi

if want fuzz; then
  N=20000
  [ $QUICK = 1 ] && N=3000
  hdr "mutational differential fuzz: $N cases (pion vs rust 0.8 + go, reported only when both refs agree)"
  python3 "$AUDIT_DIR/diff/fuzz_diff.py" "$OUT/toml-test" "$N" 2 "$OUT/fuzz"
fi

if want floats; then
  N=20000
  [ $QUICK = 1 ] && N=5000
  hdr "F1 float fidelity: $N doubles per set"
  python3 "$AUDIT_DIR/diff/float_fuzz.py" "$OUT/floats" "$N" || true
fi

if want roundtrip; then
  hdr "stringify round-trip over the toml-test valid corpus (re-parsed by Rust toml 1.2)"
  python3 "$AUDIT_DIR/diff/roundtrip_corpus.py" "$OUT/toml-test"
fi

if want errpos; then
  hdr "F5 error locations over the toml-test invalid corpus"
  python3 "$AUDIT_DIR/diff/errpos_corpus.py" "$OUT/toml-test"
fi

if want tests; then
  hdr "pionc test packages/toml/audit (every FAILED test is a finding; see REPORT.md)"
  pionc test --json -p toml_redteam_audit "$AUDIT_DIR" > "$OUT/logs/pionc-test.json" 2>"$OUT/logs/pionc-test.stderr" || true
  python3 - "$OUT/logs/pionc-test.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  total={d['total']} passed={d['passed']} failed={d['failed']}")
for t in d["tests"]:
    print(f"  {'pass' if t['ok'] else 'FAIL'}  {t['name']}")
EOF
fi

if want dos; then
  hdr "DoS / pathological inputs (F8 stack overflow, F9 inline nesting, F10 HashDoS, F11 O(n^2) get)"
  if [ $QUICK = 1 ]; then
    DOS_TIMEOUT=30 python3 "$AUDIT_DIR/dos/dos_probe.py" "$OUT/dos" --quick
  else
    DOS_TIMEOUT=60 python3 "$AUDIT_DIR/dos/dos_probe.py" "$OUT/dos"
  fi
fi

if want bench; then
  R=5
  [ $QUICK = 1 ] && R=3
  BC="python3 $ROOT_DIR/scripts/bench_compare.py --warmup 1 --rounds $R --baseline rust_toml_1.2"
  D="$OUT/data"
  mkdir -p "$OUT/bench"
  : > "$OUT/bench/ALL.md"
  parse4() { # title file iters
    bytes=$(( $(wc -c < "$D/$2") * $3 ))
    hdr "bench parse: $1"
    $BC --title "parse: $1" --bytes "$bytes" --ops "$3" \
      --impl "pion=$BIN/pion_cli bench-parse $D/$2 $3" \
      --impl "rust_toml_1.2=$BIN/rust_ref bench-parse $D/$2 $3" \
      --impl "rust_toml_0.8=$BIN/rust_ref v08-bench-parse $D/$2 $3" \
      --impl "go_burntsushi=$BIN/go_ref bench-parse $D/$2 $3" \
      --md-out "$OUT/bench/parse-$2.md" --json-out "$OUT/bench/parse-$2.json"
    cat "$OUT/bench/parse-$2.md" >> "$OUT/bench/ALL.md"
  }
  ser3() { # title file iters
    hdr "bench stringify: $1"
    $BC --title "stringify: $1" --ops "$3" \
      --impl "pion=$BIN/pion_cli bench-stringify $D/$2 $3" \
      --impl "rust_toml_1.2=$BIN/rust_ref bench-stringify $D/$2 $3" \
      --impl "rust_toml_0.8=$BIN/rust_ref v08-bench-stringify $D/$2 $3" \
      --md-out "$OUT/bench/ser-$2.md" --json-out "$OUT/bench/ser-$2.json"
    cat "$OUT/bench/ser-$2.md" >> "$OUT/bench/ALL.md"
  }
  # Steady state matters: a single parse per process hides Pion's tree-teardown cost (REPORT B2),
  # so every workload is parsed >= 10 times per process, as packages/toml/bench does (x50).
  hdr "steady-state check: ms per parse vs parses per process (cargo_lock.toml, parse only, no walk)"
  python3 "$AUDIT_DIR/bench/steady_state.py" "$BIN" "$D/cargo_lock.toml"
  parse4 "packages/toml/bench corpus (150 KB) x50 -- the README's own workload" corpus.toml 50
  parse4 "Cargo.lock-like, 30k [[package]] (7.5 MB) x10" cargo_lock.toml 10
  parse4 "50k inline-table rows (2.8 MB) x10" inline_rows.toml 10
  parse4 "200k program-written doubles (3.8 MB) x10" floats.toml 10
  parse4 "20k escape-heavy basic strings (2.3 MB) x10" escapes.toml 10
  parse4 "400 multi-line doc strings (3.9 MB) x10" multiline.toml 10
  parse4 "wide table, 100k keys (2.9 MB) x10" wide.toml 10
  parse4 "3000 dotted headers up to 60 deep (0.4 MB) x30" deep_headers.toml 30
  hdr "bench parse: 5000 small manifests, one file each"
  $BC --title "parse: 5000 small Cargo-style manifests" --ops 5000 \
    --impl "pion=$BIN/pion_cli bench-many $D/small_list.txt" \
    --impl "rust_toml_1.2=$BIN/rust_ref bench-many $D/small_list.txt" \
    --impl "rust_toml_0.8=$BIN/rust_ref v08-bench-many $D/small_list.txt" \
    --impl "go_burntsushi=$BIN/go_ref bench-many $D/small_list.txt" \
    --md-out "$OUT/bench/parse-small.md" --json-out "$OUT/bench/parse-small.json"
  cat "$OUT/bench/parse-small.md" >> "$OUT/bench/ALL.md"
  ser3 "corpus x50" corpus.toml 50
  ser3 "Cargo.lock-like (7.5 MB)" cargo_lock.toml 3
  ser3 "200k doubles" floats.toml 3
  python3 -c "print(''.join(f'key_{i} = {i}\n' for i in range(30000)), end='')" > "$D/lookup30k.toml"
  hdr "bench lookup: toml::get / Table::get of every key of a 30k-key table"
  $BC --title "lookup: get() each key of a 30k-key table" --rounds 3 --ops 30000 \
    --impl "pion=$BIN/pion_cli bench-lookup $D/lookup30k.toml 1" \
    --impl "rust_toml_1.2=$BIN/rust_ref bench-lookup $D/lookup30k.toml 1" \
    --md-out "$OUT/bench/lookup.md" --json-out "$OUT/bench/lookup.json"
  cat "$OUT/bench/lookup.md" >> "$OUT/bench/ALL.md"
  echo "all benchmark tables: $OUT/bench/ALL.md"
fi

hdr "done; logs in $OUT"
