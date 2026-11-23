#!/bin/sh
# One-shot reproducible red-team audit for packages/jsonpath.
# Usage: sh packages/jsonpath/audit/run_audit.sh [--bench] [--skip-probes]
# Artifacts go to $RT_JSONPATH_AUDIT_OUT (default /private/tmp/rt-jsonpath-audit); the git worktree is never written.
# Exit status: 0 only when every gating check (official CTS, RFC differential, 4-mode consistency, DoS probes) passes.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
OUT_DIR="${RT_JSONPATH_AUDIT_OUT:-/private/tmp/rt-jsonpath-audit}"

export PATH="${HOME}/.pion/bin:${HOME}/.cargo/bin:$PATH"

for tool in pionc cargo node python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: required tool not found on PATH: $tool" >&2
    exit 2
  fi
done

# Fresh artifacts every run (the Rust target dir is kept only as a build cache).
mkdir -p "$OUT_DIR"
find "$OUT_DIR" -mindepth 1 -maxdepth 1 ! -name rust-target -exec rm -rf {} +

echo "==> repo: $REPO_ROOT @ $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
set +e
python3 -I "$SCRIPT_DIR/audit.py" --out "$OUT_DIR" "$@" 2>&1 | tee "$OUT_DIR/audit.log"
set -e
if grep -q '^RESULT: PASS' "$OUT_DIR/audit.log"; then
  exit 0
fi
exit 1
