# `sql`

Pure Pion **SQL Lexer**, **Pratt Recursive-Descent AST Parser**, **Canonical SQL Formatter**, and **Static Analyzer** supporting **SQLite**, **PostgreSQL**, and **Generic** dialects — modeled after Rust [`sqlparser-rs`](https://github.com/apache/datafusion-sqlparser-rs).

- **Zero external / C / `World` dependencies** — pure Pion, `Send`-safe immutable AST types, verified across **Native** and **`wasm32`** (`debug` & `release`, 4/4 smoke modes exit 0).
- **Rich SQLite + PostgreSQL Lexer**:
  - Case-insensitive ASCII keywords (zero-allocation static keyword matching).
  - Double-quoted (`"a""b"`), backtick (`` `a``b` ``), and SQLite bracket (`[a b]`) identifiers.
  - Single-quoted strings (`'it''s'`), PostgreSQL escaped strings (`E'...\n\t\\\''`), and dollar-quoted strings (`$$...$$`, `$tag$...$tag$`).
  - Decimal, floating-point, scientific, and hexadecimal (`0xFF`) numeric literals.
  - Line comments (`--`) and PostgreSQL-standard **nested block comments** (`/* /* ... */ */`).
  - Placeholders (`?`, `?1`, `$1`, `:name`, `@name`) and full operator set (`=`, `!=`, `<>`, `<=`, `>=`, `||`, `->`, `->>`, `#>`, `#>>`, `::`, `@>`, `<@`, `~`, `~*`, `!~`, `!~*`, bitwise/shift).
  - Precise 1-based `line`/`col` and 0-based byte `offset` diagnostics.
- **Complete Core DML / DDL / TCL AST**:
  - `SELECT` (`DISTINCT`, `ALL`, `DISTINCT ON (...)`, aliases, `FROM`, `INNER`/`LEFT`/`RIGHT`/`FULL`/`CROSS`/`NATURAL` `JOIN` with `ON`/`USING`, `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY ASC/DESC NULLS FIRST/LAST`, `LIMIT`/`OFFSET`, `UNION`/`INTERSECT`/`EXCEPT [ALL]`, `WITH [RECURSIVE]` CTEs, subqueries, `EXISTS`, window functions `OVER (PARTITION BY ... ORDER BY ... ROWS/RANGE/GROUPS BETWEEN ...)`).
  - `INSERT INTO ... VALUES / SELECT ... [ON CONFLICT (...) DO NOTHING | DO UPDATE SET ... [WHERE ...]] [RETURNING ...]`.
  - `UPDATE ... SET ... [FROM ...] [WHERE ...] [RETURNING ...]`.
  - `DELETE FROM ... [WHERE ...] [RETURNING ...]`.
  - `CREATE [TEMP] TABLE [IF NOT EXISTS]` (column types including `[]` arrays, `PRIMARY KEY [AUTOINCREMENT]`, `NOT NULL`, `UNIQUE`, `DEFAULT`, `CHECK`, `REFERENCES ... ON DELETE/UPDATE ...`, table constraints, `WITHOUT ROWID`), `CREATE [UNIQUE] INDEX [IF NOT EXISTS] ... [WHERE ...]`, `CREATE [OR REPLACE] [TEMP] VIEW`, `ALTER TABLE` (`ADD`/`DROP`/`RENAME COLUMN`, `RENAME TO`), `DROP TABLE/INDEX/VIEW [IF EXISTS] ... [CASCADE]`.
  - `BEGIN`, `COMMIT`, `ROLLBACK [TO SAVEPOINT]`, `SAVEPOINT`, `RELEASE SAVEPOINT`, `EXPLAIN [ANALYZE]`.
- **Pratt Expression Engine**:
  - Full SQL precedence hierarchy (`OR` < `AND` < `NOT` < comparisons/`IS [NOT] NULL|TRUE|FALSE|DISTINCT FROM`/`[NOT] IN`/`[NOT] BETWEEN`/`[NOT] LIKE|ILIKE` < bitwise < `+`/`-`/`||` < `*`/`/`/`%` < `^` < JSON `->`/`->>`/`#>`/`#>>` < unary `+`/`-`/`~` < `COLLATE` < `::` cast / `[idx]` subscript).
  - `CASE [expr] WHEN ... THEN ... ELSE ... END`, `CAST(x AS T)`, `x::T`, function calls with `DISTINCT` & `FILTER (WHERE ...)`, `ARRAY[...]` literals & subscripts, tuples.
- **Formatting & Static Analysis**:
  - `to_sql()` / `statements_to_sql()` / `expr_to_sql()` with roundtrip structural AST equivalence (`stmt_eq(stmt, parse_one(to_sql(stmt)))`).
  - `extract_tables(stmt)` — deduplicated base table names in encounter order (excluding CTE aliases).
  - `extract_placeholders(stmt)` — ordered parameter placeholder list preserving duplicates.
  - `split_statements(src)` — lexically-aware top-level `;` splitter (ignores semicolons inside strings, comments, dollar-quotes, and parentheses).
- **Day-1 Red-Team Defenses**:
  - Explicit `max_depth` (default `128`), `max_tokens` (default `500,000`), and `max_nodes` (default `1,000,000`) guards with zero crashes on adversarial nesting.
  - Iterative Pratt infix loop guarantees O(1) recursion depth and O(N) linear time for massive `OR`/`AND`/comma-list chains.
  - Unterminated strings, identifiers, nested block comments, and dollar-quotes fail fast with exact opening `line`/`col`.

## API

```pion
pub enum Dialect { Generic, SQLite, Postgres }

pub struct ParseOptions {
  pub dialect : Dialect
  pub max_depth : Int      // default: 128
  pub max_tokens : Int     // default: 500000
  pub max_nodes : Int      // default: 1000000
}

pub fn ParseOptions::default() -> ParseOptions
pub fn ParseOptions::sqlite() -> ParseOptions
pub fn ParseOptions::postgres() -> ParseOptions

// Lexing & Parsing
pub fn tokenize(src : String) -> Result[Array[Token], SqlError]
pub fn tokenize_with_options(src : String, opts : ParseOptions) -> Result[Array[Token], SqlError]
pub fn parse(src : String) -> Result[Array[Statement], SqlError]
pub fn parse_with_options(src : String, opts : ParseOptions) -> Result[Array[Statement], SqlError]
pub fn parse_one(src : String) -> Result[Statement, SqlError]
pub fn parse_one_with_options(src : String, opts : ParseOptions) -> Result[Statement, SqlError]
pub fn parse_sqlite(src : String) -> Result[Array[Statement], SqlError]
pub fn parse_postgres(src : String) -> Result[Array[Statement], SqlError]

// Formatting & Structural Equality
pub fn to_sql(stmt : Statement) -> String
pub fn statements_to_sql(stmts : Array[Statement]) -> String
pub fn expr_to_sql(expr : Expr) -> String
pub fn stmt_eq(a : Statement, b : Statement) -> Bool
pub fn stmts_eq(a : Array[Statement], b : Array[Statement]) -> Bool

// Static Analysis & Script Splitting
pub fn extract_tables(stmt : Statement) -> Array[String]
pub fn extract_placeholders(stmt : Statement) -> Array[String]
pub fn split_statements(src : String) -> Result[Array[String], SqlError]
```

## Example

```pion
import "sql"

let query = "WITH active AS (SELECT id FROM users WHERE active = TRUE) SELECT u.id, o.total FROM active u JOIN orders o ON u.id = o.user_id WHERE o.total > $1"
match sql::parse_one_with_options(query, sql::ParseOptions::postgres()) {
  Ok(stmt) => {
    let tables = sql::extract_tables(stmt)       // ["users", "orders"]
    let params = sql::extract_placeholders(stmt) // ["$1"]
    let canonical = sql::to_sql(stmt)
    let _ = (tables, params, canonical)
  }
  Err(e) => {
    // e.line, e.col, e.offset, e.message
    let _ = e
  }
}
```

## Verification

```sh
pionc fmt --check packages/sql
pionc check --json packages/sql
pionc test --json packages/sql
pionc run packages/sql/wasm_smoke
pionc run --release packages/sql/wasm_smoke
pionc run --target wasm32 packages/sql/wasm_smoke
pionc run --target wasm32 --release packages/sql/wasm_smoke
```

## Head-to-Head Benchmarks

All benchmarks run via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, **mandatory stdout SHA-256 byte-for-byte verification**) on `Darwin arm64` against:
- **Rust**: `sqlparser =0.53.0` (`--release`, `opt-level = 3`, `lto = true`, `codegen-units = 1`, `PostgreSqlDialect`)

### Workload 1: Complex Production SQL Parse (20,000 ops / 4.83 MB)

10 production-grade PostgreSQL statements (CTEs, recursive CTEs, multi-table `JOIN`s, window functions with `ROWS BETWEEN`, `EXISTS` subqueries, `CASE`/`CAST`/JSON operators, `FILTER (WHERE ...)`, `INSERT ... ON CONFLICT DO UPDATE ... RETURNING`, `UPDATE ... FROM ... RETURNING`, `DELETE ... RETURNING`, `CREATE TABLE` with FK/CHECK/array types, partial `CREATE UNIQUE INDEX`, `ALTER TABLE`) × 2,000 rounds:

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `55 B` (`sha256:a65a4e5f68854393...`) | Input: `4828000 B` | Ops: `20000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_sqlparser) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 83.843 | 82.331 | 87.270 | 57.58 | 4192.12 | 2.34 MiB | **4.83x** |
| `rust_sqlparser` | 404.660 | 379.527 | 417.358 | 11.93 | 20232.99 | 3.22 MiB | 1.00x (baseline) |

### Workload 2: Large SQL Script Tokenize (10× 969.6 KB = 9.70 MB)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `45 B` (`sha256:f2f4b19293f241b0...`) | Input: `9696000 B` | Ops: `10`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_sqlparser) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 62.303 | 61.267 | 72.205 | 155.63 | 6230266.60 | 23.44 MiB | **3.99x** |
| `rust_sqlparser` | 248.595 | 241.422 | 294.234 | 39.00 | 24859520.80 | 38.64 MiB | 1.00x (baseline) |

### Workload 3: SQL Parse → `to_sql()` → Reparse Roundtrip (10,000 ops / 2.41 MB)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `75 B` (`sha256:7b645eeb0b2e6cef...`) | Input: `2414000 B` | Ops: `10000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_sqlparser) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 89.286 | 87.601 | 89.741 | 27.04 | 8928.61 | 2.55 MiB | **4.40x** |
| `rust_sqlparser` | 392.566 | 383.373 | 466.444 | 6.15 | 39256.60 | 3.55 MiB | 1.00x (baseline) |

## Design Boundaries & Honest Trade-offs

- **Scope vs `sqlparser-rs`**: `packages/sql` focuses on SQLite, PostgreSQL, and Generic core SQL (DML, DDL, TCL, CTEs, window functions, Pratt expressions, static analysis). `sqlparser-rs` supports 15+ dialects (MySQL, Snowflake, BigQuery, MSSQL, DuckDB, ClickHouse, Hive, etc.) with much larger AST enum variants and per-token spans/whitespace tokens, which is a primary contributor to `packages/sql`'s 4.0x–4.8x throughput advantage and lower peak RSS on the benchmarked PostgreSQL/SQLite workloads.
- **Unimplemented dialect extensions**: Stored procedures / `CREATE FUNCTION` / `DO $$ ... $$` PL/pgSQL blocks, triggers, `MERGE`, `GRANT`/`REVOKE`, `COPY`, and vendor-specific storage clauses (e.g. `TABLESPACE`, `PARTITION BY RANGE` DDL) are out of scope for `v0.1.0`.
- **Nesting depth**: Recursive descent is strictly bounded by `ParseOptions.max_depth` (default `128`). On `wasm32`, keep `max_depth <= 256` to stay well within Wasm stack limits during recursive AST teardown.

Reproduce:

```sh
sh packages/sql/bench/run_bench.sh
```
