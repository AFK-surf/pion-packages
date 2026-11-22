#!/bin/sh
# Unified fast-check script for AFK-surf/pion-packages.
# Usage: sh scripts/verify.sh [--allow-dirty] [target_dir]
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ALLOW_DIRTY=0
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    -h|--help)
      echo "usage: sh scripts/verify.sh [--allow-dirty] [package_or_workspace_dir]"
      exit 0
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [ -n "$TARGET" ]; then
        echo "error: multiple target directories specified" >&2
        exit 1
      fi
      TARGET="$1"
      shift
      ;;
  esac
done

if [ -z "$TARGET" ]; then
  TARGET="$ROOT_DIR"
else
  case "$TARGET" in
    /*) ;;
    *) TARGET="$ROOT_DIR/$TARGET" ;;
  esac
fi

if [ ! -e "$TARGET" ]; then
  echo "FAIL: target path does not exist: $TARGET" >&2
  exit 1
fi

PIONC_BIN="${PIONC:-}"
if [ -z "$PIONC_BIN" ]; then
  if command -v pionc >/dev/null 2>&1; then
    PIONC_BIN=$(command -v pionc)
  elif [ -x "${HOME:-}/.pion/bin/pionc" ]; then
    PIONC_BIN="${HOME}/.pion/bin/pionc"
  fi
fi

if [ -z "$PIONC_BIN" ] || [ ! -x "$PIONC_BIN" ]; then
  echo "FAIL: pionc not found on PATH or at \$HOME/.pion/bin/pionc" >&2
  exit 1
fi

echo "==> pionc version"
"$PIONC_BIN" --version

echo "==> pionc fmt --check ($TARGET)"
"$PIONC_BIN" fmt --check "$TARGET"

echo "==> pionc check --json ($TARGET)"
"$PIONC_BIN" check --json "$TARGET"

echo "==> pionc test --json ($TARGET)"
"$PIONC_BIN" test --json "$TARGET"

if [ "$ALLOW_DIRTY" -eq 0 ]; then
  echo "==> git status --porcelain (clean worktree check)"
  DIRTY=$(git -C "$ROOT_DIR" status --porcelain)
  if [ -n "$DIRTY" ]; then
    echo "FAIL: worktree is not clean:" >&2
    printf '%s\n' "$DIRTY" >&2
    exit 1
  fi
  echo "worktree clean"
fi

echo "PASS: verify.sh succeeded for $TARGET"
