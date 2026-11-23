#!/bin/sh
# Head-to-head benchmark runner for packages/fts:
# Pion Native (--release) vs SQLite FTS5 (C -O3 -lsqlite3) vs SQLite FTS5 (Python sqlite3).
# Builds and generated corpus live under $OUT_DIR, never in the worktree.
# Usage: sh run_bench.sh [num_docs]
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="${OUT_DIR:-/tmp/pion-fts-bench}"
BIN_DIR="$OUT_DIR/bin"
NUM_DOCS="${1:-10000}"

PIONC_BIN="${PIONC:-}"
if [ -z "$PIONC_BIN" ]; then
  if command -v pionc >/dev/null 2>&1; then
    PIONC_BIN=$(command -v pionc)
  elif [ -x "${HOME:-}/.pion/bin/pionc" ]; then
    PIONC_BIN="${HOME}/.pion/bin/pionc"
  fi
fi

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_fts_bench" "$BENCH_DIR/pion_bench"

echo "==> Building SQLite FTS5 C benchmark (-O3 -lsqlite3)"
cc -O3 -Wall "$BENCH_DIR/sqlite_c/main.c" -lsqlite3 -o "$BIN_DIR/sqlite_fts5_c"

RAW_TSV="$OUT_DIR/corpus_raw.tsv"
FTS5_TSV="$OUT_DIR/corpus_fts5.tsv"
Q_RAW="$OUT_DIR/queries_raw.txt"
Q_FTS5="$OUT_DIR/queries_fts5.txt"

echo "==> Generating deterministic $NUM_DOCS-doc multilingual + code corpus"
"$BIN_DIR/pion_fts_bench" prepare "$NUM_DOCS" "$RAW_TSV" "$FTS5_TSV" "$Q_RAW" "$Q_FTS5"
RAW_BYTES=$(wc -c < "$RAW_TSV" | tr -d ' ')

echo ""
echo "=== Mode 1: Index $NUM_DOCS docs + 30 queries (1 rep) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "fts index + 30 queries ($NUM_DOCS docs, $RAW_BYTES B raw)" \
  --impl "pion=$BIN_DIR/pion_fts_bench run $RAW_TSV $Q_RAW 1" \
  --impl "sqlite_fts5_c=$BIN_DIR/sqlite_fts5_c $FTS5_TSV $Q_FTS5 1" \
  --impl "sqlite_fts5_py=python3 $BENCH_DIR/sqlite_py/bench.py $FTS5_TSV $Q_FTS5 1" \
  --baseline sqlite_fts5_c \
  --warmup 1 --rounds 5 --bytes "$RAW_BYTES" \
  --md-out "$OUT_DIR/index_and_query.md" --json-out "$OUT_DIR/index_and_query.json"

echo ""
echo "=== Mode 2: Index $NUM_DOCS docs + 600 queries (30 queries x 20 reps) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "fts index + 600 queries ($NUM_DOCS docs)" \
  --impl "pion=$BIN_DIR/pion_fts_bench run $RAW_TSV $Q_RAW 20" \
  --impl "sqlite_fts5_c=$BIN_DIR/sqlite_fts5_c $FTS5_TSV $Q_FTS5 20" \
  --impl "sqlite_fts5_py=python3 $BENCH_DIR/sqlite_py/bench.py $FTS5_TSV $Q_FTS5 20" \
  --baseline sqlite_fts5_c \
  --warmup 1 --rounds 5 --ops 600 \
  --md-out "$OUT_DIR/query_heavy.md" --json-out "$OUT_DIR/query_heavy.json"
