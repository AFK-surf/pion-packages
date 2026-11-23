#!/bin/sh
# Red-team audit of packages/sql @ 1425a54: one command, Pion vs Rust sqlparser =0.53.0 vs real
# PostgreSQL 16 and SQLite 3.
#
#   sh packages/sql/audit/run_audit.sh                    # every stage (~25 min on an Apple M-series)
#   sh packages/sql/audit/run_audit.sh tests security     # selected stages only
#
# Stages: tests    - pionc test packages/sql/audit (every p*_ FAIL is an exhibit; ctl_* must pass)
#         security - to_sql injection (executed in PostgreSQL), extract_tables vs PostgreSQL's privilege
#                    check, SQLite statement smuggling (executed in SQLite), split_statements vs psql
#         diff     - 156 PostgreSQL + 47 SQLite statements: Pion vs sqlparser 0.53 vs the real engine,
#                    plus 29 constant expressions evaluated by PostgreSQL under Pion's tree
#         wasm     - security / diff driver outputs from native debug/release + wasm32 debug/release
#                    must be byte-identical
#         deep     - crash length of left-deep chains and of max_depth-guarded nesting, 4 build modes
#         scale    - time complexity: each workload at n, 2n, 4n, 8n (extract_tables is quadratic)
#         bench    - the package's W1/W3 corpus + adversarial workloads via scripts/bench_compare.py (SHA-256
#                    gated, warmup 1, 5 rounds) against sqlparser 0.53 with the system allocator and with mimalloc
#
# Needs: pionc, cargo, node, python3, PostgreSQL 16 binaries (initdb/pg_ctl/psql on PATH or in
# /opt/homebrew/opt/postgresql@16/bin). A throw-away cluster is started on a Unix socket under $OUT
# (port $PG_PORT, default 55439) and stopped at the end. Everything is built and written under $OUT
# (default /private/tmp/pion-sql-audit); the worktree stays clean.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT="${OUT:-/private/tmp/pion-sql-audit}"
PG_PORT="${PG_PORT:-55439}"
export OUT PG_PORT PG_SOCK="$OUT" PYTHONDONTWRITEBYTECODE=1
export PATH="${HOME}/.pion/bin:${HOME}/.cargo/bin:/opt/homebrew/opt/postgresql@16/bin:/opt/homebrew/bin:${PATH}"
STAGES="${*:-tests security diff wasm deep scale bench}"
RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
B="$OUT/bin"
S="$AUDIT_DIR/scripts"
mkdir -p "$B" "$OUT/res"

want() { case " $STAGES " in *" $1 "*) return 0 ;; esac; return 1; }

echo "==> pionc $(pionc --version 2>&1 | head -1); $(cargo --version); node $(node --version); $(postgres --version); sqlite $(python3 -c 'import sqlite3; print(sqlite3.sqlite_version)')"
echo "==> Building drivers into $B"
pionc build --release -o "$B/drv" "$AUDIT_DIR/driver" >/dev/null
pionc build -o "$B/drv_dbg" "$AUDIT_DIR/driver" >/dev/null
pionc build --release --target wasm32 -o "$B/drv.wasm" "$AUDIT_DIR/driver" >/dev/null
pionc build --target wasm32 -o "$B/drv_dbg.wasm" "$AUDIT_DIR/driver" >/dev/null
CARGO_TARGET_DIR="$OUT/rust-target" cargo build -q --release --manifest-path "$AUDIT_DIR/rust/Cargo.toml"
cp "$OUT/rust-target/release/sql_audit_oracle" "$B/rust_oracle"
if want bench; then  # fairness probe: identical oracle, mimalloc instead of the macOS system allocator
  CARGO_TARGET_DIR="$OUT/rust-target-mi" cargo build -q --release --features mimalloc --manifest-path "$AUDIT_DIR/rust/Cargo.toml"
  cp "$OUT/rust-target-mi/release/sql_audit_oracle" "$B/rust_oracle_mi"
fi

if want security || want diff || want wasm; then
  if [ ! -d "$OUT/pg" ]; then
    LC_ALL=C initdb -D "$OUT/pg" -U postgres -A trust --locale=C -E UTF8 >/dev/null
  fi
  if ! pg_ctl -D "$OUT/pg" status >/dev/null 2>&1; then
    LC_ALL=C pg_ctl -D "$OUT/pg" -o "-p $PG_PORT -k $OUT -c listen_addresses=''" -l "$OUT/pg.log" -w start >/dev/null
    trap 'pg_ctl -D "$OUT/pg" -m fast stop >/dev/null 2>&1 || true' EXIT
  fi
fi

if want tests; then
  echo
  echo "==> [tests] pionc test packages/sql/audit (p*_ FAIL = evidence against Pion; ctl_* = controls)"
  (cd "$AUDIT_DIR" && pionc test --json . >"$OUT/tests.json" 2>"$OUT/tests.stderr") || true
  python3 - "$OUT/tests.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
mine = [t for t in d["tests"] if t["pkg"] == "sql_redteam_audit"]
up = [t for t in d["tests"] if t["pkg"] == "sql"]
print(f"red-team: {sum(not t['ok'] for t in mine if t['name'].startswith('p'))}/{sum(t['name'].startswith('p') for t in mine)} exhibits FAIL, "
      f"{sum(t['ok'] for t in mine if t['name'].startswith('ctl'))}/{sum(t['name'].startswith('ctl') for t in mine)} controls pass; "
      f"package's own tests: {sum(t['ok'] for t in up)}/{len(up)} pass")
for t in mine:
    print(("  FAIL " if not t["ok"] else "  pass ") + t["name"])
PYEOF
  echo "  (assertion messages: $OUT/tests.stderr)"
fi

if want security; then
  echo
  echo "==> [security] injection / authorisation / smuggling exhibits judged by PostgreSQL 16, SQLite 3, sqlparser 0.53"
  (cd "$S" && python3 security.py) | tee "$OUT/res/security.txt"
fi

if want diff; then
  echo
  echo "==> [diff] grammar / lexer / precedence differential"
  (cd "$S" && python3 differential.py) | tee "$OUT/res/diff.txt"
fi

if want wasm; then
  echo
  echo "==> [wasm] the differential driver outputs of 4 build modes must be byte-identical"
  (cd "$S" && python3 wasm4.py) | tee "$OUT/res/wasm.txt"
fi

if want deep; then
  echo
  echo "==> [deep] crash length per recursive consumer, 4 build modes (and sqlparser 0.53 on the same inputs)"
  python3 "$S/depth.py" "$B" "$RT" | tee "$OUT/res/depth.md"
  echo "  sqlparser 0.53 (native release, default recursion limit) on the same chains:"
  for shape in plus union cast; do
    for n in 1100 4200 110000; do
      for st in none sql; do
        r=$("$B/rust_oracle" deep "$shape" "$n" "$st" 2>&1 | tail -1 | cut -c1-70) || true
        echo "    $shape n=$n $st: $r"
      done
    done
  done
fi

if want scale; then
  echo
  echo "==> [scale] doubling test (native release)"
  python3 "$S/scale.py" "$B" | tee "$OUT/res/scale.md"
fi

if want bench; then
  echo
  echo "==> [bench] adversarial workloads (bench_compare.py, SHA-256 gated, warmup 1, rounds 5)"
  python3 "$S/gen_adv.py" "$OUT/adv"
  # the package's own W1/W3 corpus (bench/gen_data.py), re-run with an allocator-matched Rust baseline
  python3 "$AUDIT_DIR/../bench/gen_data.py" queries "$OUT/adv/queries.sql"
  for spec in "parse queries.sql 2000" "rt queries.sql 1000" "parse chain.sql 5" "rt chain.sql 5" "parse inlist.sql 5" "rt inlist.sql 5" "parse quotes.sql 5" \
              "rt quotes.sql 5" "parse errors.sql 20" "split script.sql 10" "script script.sql 5"; do
    set -- $spec
    bytes=$(( $(wc -c <"$OUT/adv/$2") * $3 ))
    python3 "$ROOT_DIR/scripts/bench_compare.py" \
      --title "A: $1 $2 x$3" \
      --impl "pion=$B/drv adv $1 $OUT/adv/$2 $3" \
      --impl "rust_sqlparser=$B/rust_oracle adv $1 $OUT/adv/$2 $3" \
      --impl "rust_sqlparser_mimalloc=$B/rust_oracle_mi adv $1 $OUT/adv/$2 $3" \
      --baseline rust_sqlparser --warmup 1 --rounds 5 --bytes "$bytes" \
      --md-out "$OUT/res/bench_$1_$2.md" --json-out "$OUT/res/bench_$1_$2.json" >/dev/null
    grep -E '^\| `' "$OUT/res/bench_$1_$2.md" | sed "s/^/  [$1 $2] /"
  done
fi
