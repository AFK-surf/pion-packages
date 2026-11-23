#!/bin/sh
# RT-ical red-team audit runner for packages/ical.
#   sh packages/ical/audit/run_audit.sh [tests|diff|wasm|dos|all]   (default: all)
# Every artifact goes to /tmp/rt-ical-*; the worktree stays clean.
set -eu
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
WORK=/tmp/rt-ical-work
BIN=$WORK/bin
VENV=/tmp/rt-ical-venv
mkdir -p "$BIN"
STEP=${1:-all}

need_venv() {
  if [ ! -x "$VENV/bin/python" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" -q install "python-dateutil==3.0.0" "icalendar==6.3.2"
  fi
}

build_refs() {
  pionc build --release -o "$BIN/driver" "$AUDIT_DIR/driver"
  rm -rf "$WORK/rust-proj" && mkdir -p "$WORK/rust-proj"
  cp -R "$AUDIT_DIR/rust_ref/Cargo.toml" "$AUDIT_DIR/rust_ref/src" "$WORK/rust-proj/"
  CARGO_TARGET_DIR="$WORK/rust-target" cargo build -q --release --manifest-path "$WORK/rust-proj/Cargo.toml"
  cp "$WORK/rust-target/release/rt-ical-rust-ref" "$BIN/rust_ref"
}

do_tests() {
  echo "==> pionc fmt/check/test (audit package; ical + time tests run as deps)"
  pionc fmt --check "$AUDIT_DIR" "$AUDIT_DIR/driver"
  pionc check --json "$AUDIT_DIR" >/dev/null
  pionc check --json "$AUDIT_DIR/driver" >/dev/null
  pionc test --json "$AUDIT_DIR" 2>/dev/null | python3 "$AUDIT_DIR/diff/summarize_tests.py"
  echo "==> upstream packages/ical suite must stay green"
  pionc test --json "$PKG_DIR" 2>/dev/null | python3 "$AUDIT_DIR/diff/summarize_tests.py" --pkg ical
}

do_diff() {
  need_venv
  build_refs
  echo "==> generating differential corpus (seed 5545)"
  python3 "$AUDIT_DIR/diff/gen_rules.py" 5545 > "$WORK/rules.txt"
  echo "==> expanding: pion / rust rrule 0.14.0 / python-dateutil (3 s per-rule timeout)"
  "$BIN/driver" rrule "$WORK/rules.txt" > "$WORK/pion.txt"
  "$BIN/rust_ref" "$WORK/rules.txt" > "$WORK/rust.txt"
  "$VENV/bin/python" "$AUDIT_DIR/diff/ref_dateutil.py" "$WORK/rules.txt" > "$WORK/dateutil.txt"
  python3 "$AUDIT_DIR/diff/compare.py" "$WORK/rules.txt" "$WORK/pion.txt" "$WORK/dateutil.txt" "$WORK/rust.txt" \
    --examples 2 --json "$WORK/diff.json"
}

do_wasm() {
  echo "==> 4-mode determinism: native debug/release, wasm32 debug/release (clean PION_CACHE_DIR)"
  export PION_CACHE_DIR=/tmp/rt-ical-wasm-cache
  rm -rf "$PION_CACHE_DIR"
  [ -f "$WORK/rules.txt" ] || python3 "$AUDIT_DIR/diff/gen_rules.py" 5545 > "$WORK/rules.txt"
  for mode in native-debug native-release wasm32-debug wasm32-release; do
    flags=""
    case $mode in *release) flags="--release" ;; esac
    case $mode in wasm32*) flags="$flags --target wasm32" ;; esac
    # shellcheck disable=SC2086
    pionc run $flags "$AUDIT_DIR/driver" -- rrule "$WORK/rules.txt" > "$WORK/4mode-$mode.txt"
    printf '%-16s %s\n' "$mode" "$(shasum -a 256 < "$WORK/4mode-$mode.txt" | cut -c1-64)"
  done
  echo "==> wasm32 release: timeset explosion rule (P1 DoS) under the 4 GiB wasm32 address space"
  H=$(seq -s, 0 23 | sed 's/,$//'); M=$(seq -s, 0 59 | sed 's/,$//')
  R="FREQ=YEARLY;BYDAY=MO,TU,WE,TH,FR,SA,SU;BYHOUR=$H;BYMINUTE=$M;BYSECOND=$M;COUNT=1"
  set +e
  pionc run --release --target wasm32 "$AUDIT_DIR/driver" -- time 20250101T000000 "$R" 1 > "$WORK/wasm-dos.txt" 2>&1
  echo "exit=$? $(head -c 300 "$WORK/wasm-dos.txt")"
  set -e
}

do_dos() {
  need_venv
  [ -x "$BIN/driver" ] || build_refs
  sh "$AUDIT_DIR/dos.sh" "$BIN/driver" "$BIN/rust_ref" "$VENV/bin/python"
}

case $STEP in
  tests) do_tests ;;
  diff) do_diff ;;
  wasm) do_wasm ;;
  dos) do_dos ;;
  all) do_tests; do_diff; do_wasm; do_dos ;;
  *) echo "usage: run_audit.sh [tests|diff|wasm|dos|all]" >&2; exit 2 ;;
esac
echo "==> worktree status (must be empty):"
git -C "$PKG_DIR" status --porcelain --ignored
