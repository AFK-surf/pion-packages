#!/bin/sh
# Head-to-head steady-state benchmark runner for packages/sql:
# Pion Native (`packages/sql`) vs Rust `sqlparser =0.53.0` (--release, LTO).
# All build artifacts and temporary inputs are placed in /private/tmp to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/pion-sql-bench"
BIN_DIR="$OUT_DIR/bin"
QUERIES_FILE="$OUT_DIR/queries.sql"
SCRIPT_FILE="$OUT_DIR/large_script.sql"

PARSE_ROUNDS="${SQL_PARSE_ROUNDS:-2000}"
PARSE_OPS=$((PARSE_ROUNDS * 10))
TOK_REPEATS="${SQL_TOK_REPEATS:-400}"
TOK_ROUNDS="${SQL_TOK_ROUNDS:-10}"
RT_ROUNDS="${SQL_RT_ROUNDS:-1000}"
RT_OPS=$((RT_ROUNDS * 10))

mkdir -p "$BIN_DIR"

echo "==> Generating benchmark inputs -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" queries "$QUERIES_FILE"
python3 "$BENCH_DIR/gen_data.py" script "$SCRIPT_FILE" "$TOK_REPEATS"

QUERIES_BYTES=$(wc -c < "$QUERIES_FILE" | tr -d ' ')
SCRIPT_BYTES=$(wc -c < "$SCRIPT_FILE" | tr -d ' ')
PARSE_TOTAL_BYTES=$((QUERIES_BYTES * PARSE_ROUNDS))
TOK_TOTAL_BYTES=$((SCRIPT_BYTES * TOK_ROUNDS))
RT_TOTAL_BYTES=$((QUERIES_BYTES * RT_ROUNDS))
echo "    queries=${QUERIES_BYTES} B (10 stmts), parse_ops=${PARSE_OPS}, script=${SCRIPT_BYTES} B x${TOK_ROUNDS}, rt_ops=${RT_OPS}"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_sql" "$BENCH_DIR/pion_bench"

echo "==> Building Rust sqlparser benchmark (--release, target in /private/tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/sql_bench_rust" "$BIN_DIR/rust_sql"

echo ""
echo "=== Workload 1: Complex Production SQL Parse (${PARSE_OPS} ops, ${PARSE_TOTAL_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Workload 1: Complex Production SQL Parse (${PARSE_OPS} ops)" \
  --impl "pion=$BIN_DIR/pion_sql parse $QUERIES_FILE $PARSE_ROUNDS" \
  --impl "rust_sqlparser=$BIN_DIR/rust_sql parse $QUERIES_FILE $PARSE_ROUNDS" \
  --baseline rust_sqlparser \
  --warmup 1 --rounds 5 --bytes "$PARSE_TOTAL_BYTES" --ops "$PARSE_OPS" \
  --md-out "$OUT_DIR/bench_parse.md" --json-out "$OUT_DIR/bench_parse.json"

echo ""
echo "=== Workload 2: Large SQL Script Tokenize (${TOK_ROUNDS}x ${SCRIPT_BYTES} B = ${TOK_TOTAL_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Workload 2: Large SQL Script Tokenize (${TOK_ROUNDS}x Script)" \
  --impl "pion=$BIN_DIR/pion_sql tokenize $SCRIPT_FILE $TOK_ROUNDS" \
  --impl "rust_sqlparser=$BIN_DIR/rust_sql tokenize $SCRIPT_FILE $TOK_ROUNDS" \
  --baseline rust_sqlparser \
  --warmup 1 --rounds 5 --bytes "$TOK_TOTAL_BYTES" --ops "$TOK_ROUNDS" \
  --md-out "$OUT_DIR/bench_tokenize.md" --json-out "$OUT_DIR/bench_tokenize.json"

echo ""
echo "=== Workload 3: SQL Parse -> to_sql() -> Reparse Roundtrip (${RT_OPS} ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Workload 3: SQL Parse -> to_sql() Roundtrip (${RT_OPS} ops)" \
  --impl "pion=$BIN_DIR/pion_sql roundtrip $QUERIES_FILE $RT_ROUNDS" \
  --impl "rust_sqlparser=$BIN_DIR/rust_sql roundtrip $QUERIES_FILE $RT_ROUNDS" \
  --baseline rust_sqlparser \
  --warmup 1 --rounds 5 --bytes "$RT_TOTAL_BYTES" --ops "$RT_OPS" \
  --md-out "$OUT_DIR/bench_roundtrip.md" --json-out "$OUT_DIR/bench_roundtrip.json"
