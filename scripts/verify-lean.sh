#!/bin/sh
# Strictly serial Lean 4 formal verification runner for AFK-surf/pion-packages.
#
# Enforces machine-safety invariants on every run:
#   - Strictly single-slot sequential execution (one package at a time)
#   - LEAN_NUM_THREADS=2 (override via env)
#   - LEAN_MEM_LIMIT=8192 MB (override via env)
#   - Per-package timeout (default 1200s = 20 min, override via LEAN_PKG_TIMEOUT_SEC)
#   - Process-group isolation & cleanup trap (never leaves orphan lake/lean processes,
#     never calls pkill -f / killall)
#
# Usage:
#   sh scripts/verify-lean.sh                  # run all packages/*/proofs/run_proofs.sh serially
#   sh scripts/verify-lean.sh semver tar uuid  # run selected packages serially
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"
export LEAN_OPTS="${LEAN_OPTS:---memory=${LEAN_MEM_LIMIT}}"
TIMEOUT_SEC="${LEAN_PKG_TIMEOUT_SEC:-1200}"

PKGS=""
if [ $# -gt 0 ]; then
  for arg in "$@"; do
    case "$arg" in
      -h|--help)
        echo "usage: sh scripts/verify-lean.sh [pkg ...]"
        exit 0
        ;;
      packages/*)
        pkg=$(basename "$arg")
        ;;
      *)
        pkg="$arg"
        ;;
    esac
    PKGS="$PKGS $pkg"
  done
else
  for f in "$ROOT_DIR"/packages/*/proofs/run_proofs.sh; do
    if [ -f "$f" ]; then
      pkg=$(basename "$(dirname "$(dirname "$f")")")
      PKGS="$PKGS $pkg"
    fi
  done
fi

if [ -z "$PKGS" ]; then
  echo "No packages with proofs/run_proofs.sh found." >&2
  exit 1
fi

run_with_pgroup_guard() {
  pkg_name="$1"
  script_path="$2"
  timeout_s="$3"
  python3 - "$pkg_name" "$script_path" "$timeout_s" <<'PY'
import os, signal, subprocess, sys, time

pkg, script, timeout_s = sys.argv[1], sys.argv[2], int(sys.argv[3])
proc = subprocess.Popen(
    ["/bin/sh", script],
    start_new_session=True,
)
pgid = proc.pid

def kill_group():
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return
        time.sleep(0.1)
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass

def on_signal(signum, _frame):
    sys.stderr.write(f"\n[verify-lean] caught signal {signum}, cleaning up process group {pgid} for {pkg}\n")
    kill_group()
    sys.exit(128 + signum)

signal.signal(signal.SIGINT, on_signal)
signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGHUP, on_signal)

t0 = time.monotonic()
try:
    rc = proc.wait(timeout=timeout_s)
except subprocess.TimeoutExpired:
    sys.stderr.write(
        f"\nFAIL: {pkg} exceeded timeout ({timeout_s}s); terminating process group {pgid}\n"
    )
    kill_group()
    sys.exit(124)
finally:
    # Ensure no stray descendants remain in the process group
    if proc.poll() is None:
        kill_group()

elapsed = time.monotonic() - t0
if rc != 0:
    sys.stderr.write(f"FAIL: {pkg} exited with code {rc} after {elapsed:.1f}s\n")
    sys.exit(rc)
print(f"PASS: {pkg} verified in {elapsed:.1f}s")
PY
}

TOTAL=0
for pkg in $PKGS; do
  script="$ROOT_DIR/packages/$pkg/proofs/run_proofs.sh"
  if [ ! -f "$script" ]; then
    echo "FAIL: missing $script" >&2
    exit 1
  fi
  echo "============================================================"
  echo "==> [verify-lean] package=$pkg threads=$LEAN_NUM_THREADS mem=${LEAN_MEM_LIMIT}MB timeout=${TIMEOUT_SEC}s"
  echo "============================================================"
  run_with_pgroup_guard "$pkg" "$script" "$TIMEOUT_SEC"
  TOTAL=$((TOTAL + 1))
done

echo "==> git status --porcelain (clean worktree check)"
DIRTY=$(git -C "$ROOT_DIR" status --porcelain)
if [ -n "$DIRTY" ]; then
  echo "FAIL: worktree is not clean after Lean verification:" >&2
  printf '%s\n' "$DIRTY" >&2
  exit 1
fi

echo "ALL PASS: $TOTAL package(s) formally verified serially."
