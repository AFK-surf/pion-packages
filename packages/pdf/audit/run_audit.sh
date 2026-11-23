#!/bin/sh
# One-shot red-team audit of packages/pdf against Rust lopdf =0.35.0 (+ flate2) and hostile inputs.
#   sh packages/pdf/audit/run_audit.sh           # ~3 min on an M-series Mac; peaks at ~1.7 GB RSS (hang probes)
#   HEAVY=1 sh packages/pdf/audit/run_audit.sh   # also the 200M-entry xref probe (~3.4 GB RSS)
#   QUICK=1 sh packages/pdf/audit/run_audit.sh   # skip the hang probes and the head-to-head bench
# Everything generated goes to $AUDIT_TMP (default /private/tmp/redteam-pdf); the repo stays clean.
set -u
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
T="${AUDIT_TMP:-/private/tmp/redteam-pdf}"
B="$T/bin"
mkdir -p "$B" "$T/fx" "$T/fxw" "$T/hv"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
QUICK="${QUICK:-0}"
HEAVY="${HEAVY:-0}"
RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
export RUN_OUT="$T/run.out" RUN_ERR="$T/run.err"
step() { printf '\n==================== %s ====================\n' "$*"; }
# run <timeout_s> <cmd...>: prints the probe's stdout, any panic, wall time and peak RSS
run() {
  to=$1
  shift
  # inner sh (not exec'd: `; exit $?`) swallows the "Abort trap" job message of a panicking probe
  sh -c '/usr/bin/time -l timeout "$@" > "$RUN_OUT" 2> "$RUN_ERR"; exit $?' sh "$to" "$@" 2> /dev/null
  rc=$?
  out=$(tr '\n' ' ' < "$T/run.out" | cut -c1-160)
  pan=$(grep -m1 -o 'pion panic.*' "$T/run.err" | cut -c1-110)
  wall=$(awk '/ real /{print $1}' "$T/run.err")
  rss=$(awk '/maximum resident set size/{printf "%.0f MiB", $1/1048576}' "$T/run.err")
  [ "$rc" = 124 ] && out="$out [KILLED by ${to}s timeout = hang]"
  printf '  %-34s rc=%-3s %6ss %9s | %s %s\n' "$PROBE_LABEL" "$rc" "$wall" "$rss" "$out" "$pan"
}

step "0. toolchain"
pionc --version; cargo --version; node --version; python3 --version
echo "pion-packages HEAD: $(git -C "$ROOT_DIR" rev-parse --short HEAD)  pdf src last commit: $(git -C "$ROOT_DIR" log -1 --format=%h -- packages/pdf/src)"

step "1. build probe (native release, wasm32 release) and the Rust lopdf oracle"
pionc fmt --check "$AUDIT_DIR" "$AUDIT_DIR/probe" || exit 1
pionc build --release -o "$B/probe" "$AUDIT_DIR/probe" || exit 1
pionc build --release --target wasm32 -o "$B/probe.wasm" "$AUDIT_DIR/probe" || exit 1
CARGO_TARGET_DIR="$T/rust-target" cargo build --release -q --locked --manifest-path "$AUDIT_DIR/rust/Cargo.toml" || exit 1
cp "$T/rust-target/release/oracle" "$B/oracle"

step "2. pionc test (p0_/p1_/p2_ FAILURES ARE EXPECTED = evidence; control_ must pass)"
(cd "$AUDIT_DIR" && pionc check --json . | tail -c 120 && echo)
(cd "$AUDIT_DIR" && pionc test --json -p pdf_audit . > "$T/redteam.json" 2> "$T/redteam.stderr")
python3 - "$T/redteam.json" << 'PYEOF'
import json, sys, collections
d = json.load(open(sys.argv[1]))
c = collections.Counter()
for t in d["tests"]:
    c[(t["name"].split("_")[0], t["ok"])] += 1
print(f"total={d['total']} passed={d['passed']} failed={d['failed']}")
for lvl in ("p0", "p1", "p2", "control"):
    print(f"  {lvl:8s} fail={c[(lvl, False)]:3d} pass={c[(lvl, True)]:3d}")
for t in d["tests"]:
    if not t["ok"]:
        print("  FAIL", t["name"])
bad = [t["name"] for t in d["tests"] if t["name"].startswith("control") and not t["ok"]]
if bad:
    print("  !! CONTROL FAILURES:", bad)
PYEOF
grep "pion panic" "$T/redteam.stderr" | sed 's#^.*redteam_test.pion:#  redteam_test.pion:#' | cut -c1-200

step "3. adversarial fixtures -> Rust lopdf =0.35.0 oracle (FAIL lines = findings)"
python3 "$AUDIT_DIR/scripts/make_jpegs.py" "$T/fx"
J="$T/fx/gray.jpg $T/fx/rgb.jpg $T/fx/cmyk.jpg $T/fx/prog.jpg"
# shellcheck disable=SC2086
"$B/probe" gen "$T/fx" $J
"$B/oracle" check "$T/fx" > "$T/oracle.txt"
grep -v ' PASS ' "$T/oracle.txt"
echo "  oracle PASS checks: $(grep -c ' PASS ' "$T/oracle.txt")"
echo "  wasm32 parity (same fixtures from probe.wasm under node):"
# shellcheck disable=SC2086
node "$RT" "$B/probe.wasm" gen "$T/fxw" $J > /dev/null
for f in "$T"/fx/*.pdf; do
  if cmp -s "$f" "$T/fxw/$(basename "$f")"; then echo "    same  $(basename "$f")"; else echo "    DIFF  $(basename "$f")"; fi
done

step "4. hostile inputs: validate_pdf / rle_decode / flate_decode / public RGBA helpers"
"$B/oracle" mkvalidate "$T/hv"
PROBE_LABEL="validate v_length_ok (control)"; run 30 "$B/probe" validate "$T/hv/v_length_ok.pdf"
PROBE_LABEL="validate v_length_wrap (305 B)"; run 30 "$B/probe" validate "$T/hv/v_length_wrap.pdf"
PROBE_LABEL="  same, wasm32 under node"; run 30 node "$RT" "$B/probe.wasm" validate "$T/hv/v_length_wrap.pdf"
PROBE_LABEL="validate v_offset_alias (+2^32)"; run 30 "$B/probe" validate "$T/hv/v_offset_alias.pdf"
PROBE_LABEL="validate v_xref_50m (102 B)"; run 60 "$B/probe" validate "$T/hv/v_xref_50m.pdf"
if [ "$HEAVY" = 1 ]; then
  PROBE_LABEL="validate v_xref_200m (104 B)"; run 60 "$B/probe" validate "$T/hv/v_xref_200m.pdf"
fi
PROBE_LABEL="validate v_quadratic_20k (1.1 MB)"; run 120 "$B/probe" validate "$T/hv/v_quadratic_20k.pdf"
PROBE_LABEL="validate v_quadratic_40k (2.3 MB)"; run 120 "$B/probe" validate "$T/hv/v_quadratic_40k.pdf"
PROBE_LABEL="rle r_bomb limit=0"; run 30 "$B/probe" rle "$T/hv/r_bomb.bin" 0
PROBE_LABEL="rle r_bomb limit=1e6 (control)"; run 30 "$B/probe" rle "$T/hv/r_bomb.bin" 1000000
PROBE_LABEL="rle r_trunc_literal (control)"; run 30 "$B/probe" rle "$T/hv/r_trunc_literal.bin" 0
PROBE_LABEL="rle r_trunc_repeat (control)"; run 30 "$B/probe" rle "$T/hv/r_trunc_repeat.bin" 0
PROBE_LABEL="rle r_eod_only (control)"; run 30 "$B/probe" rle "$T/hv/r_eod_only.bin" 0
PROBE_LABEL="flate 512M bomb limit=64M (control)"; run 30 "$B/probe" flate "$T/hv/z_bomb_512m.bin" 67108864
PROBE_LABEL="flate z_trunc (control)"; run 30 "$B/probe" flate "$T/hv/z_trunc.bin" 100
for wh in "40000 20000" "46341 46341" "65536 65536"; do
  # shellcheck disable=SC2086
  PROBE_LABEL="rgba_to_white_rgb $wh"; run 30 "$B/probe" rgba $wh
  # shellcheck disable=SC2086
  PROBE_LABEL="rgba_split_rgb_alpha $wh"; run 30 "$B/probe" split $wh
done
if [ "$QUICK" != 1 ]; then
  echo "  ByteBuf::ensure 2^30 doubling overflow (each is killed by its timeout if it hangs):"
  PROBE_LABEL="bigtext 1100 MiB content stream"; run 45 "$B/probe" bigtext 1100
  PROBE_LABEL="rle r_bomb_2g (33 MiB) limit=0"; run 45 "$B/probe" rle "$T/hv/r_bomb_2g.bin" 0
fi

step "5. performance: phase breakdown (best of 5) and head-to-head vs Rust pdf-writer 0.12.1"
"$B/probe" perf
if [ "$QUICK" != 1 ]; then
  pionc build --release -o "$B/pion_bench" "$PKG_DIR/bench/pion_bench" > /dev/null || exit 1
  mkdir -p "$T/rb"
  cp -R "$PKG_DIR/bench/rust/Cargo.toml" "$PKG_DIR/bench/rust/src" "$T/rb/"
  CARGO_TARGET_DIR="$T/rb-target" cargo build --release -q --manifest-path "$T/rb/Cargo.toml" || exit 1
  echo "  load average: $(uptime | sed 's/.*load averages*: //')"
  for m in report100 images_flate images_rle; do
    python3 "$ROOT_DIR/scripts/bench_compare.py" --title "$m" \
      --impl "pion=$B/pion_bench $m" --impl "rust_pdf_writer=$T/rb-target/release/pdf-bench-rust $m" \
      --baseline rust_pdf_writer --warmup 2 --rounds 15 \
      --md-out "$T/bench_$m.md" --json-out "$T/bench_$m.json" 2>&1 | grep -E '^\| `'
  done
fi

step "6. worktree must be clean (only the committed audit files)"
git -C "$ROOT_DIR" status --porcelain --ignored
echo "(empty above = clean; evidence in $T)"
