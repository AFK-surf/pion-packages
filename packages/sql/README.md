# `sql`

Pure Pion **SQL Lexer**, **Pratt Recursive-Descent AST Parser**, **Canonical SQL Formatter**, and **Static Analyzer** supporting **SQLite**, **PostgreSQL**, and **Generic** dialects — modeled after Rust [`sqlparser-rs`](https://github.com/apache/datafusion-sqlparser-rs).

- **Zero external / C / `World` dependencies** — pure Pion, `Send`-safe immutable AST types, verified across **Native** and **`wasm32`** (`debug` & `release`, 4/4 smoke modes exit 0).
- **Rich Dialect-Aware SQLite + PostgreSQL Lexer**:
  - Case-insensitive ASCII keywords (zero-allocation static keyword matching; non-reserved keywords used as identifiers preserve original spelling).
  - Double-quoted (`"a""b"`), backtick (`` `a``b` ``, SQLite/Generic), and bracket (`[a b]`, SQLite/Generic) identifiers.
  - Single-quoted strings (`'it''s'`), PostgreSQL escaped strings (`E'...\n\t\xHH\uHHHH\UHHHHHHHH\ooo\\\''`, disabled in SQLite), dollar-quoted strings (`$$...$$`, `$tag$...$tag$`, disabled in SQLite), and SQLite hex blob literals (`X'0102'`).
  - Decimal, floating-point, scientific, underscore-separated (`1_000`), binary (`0b`), octal (`0o`), and hexadecimal (`0xFF`) numeric literals.
  - Line comments (`--`) and dialect-accurate block comments (nested `/* /* ... */ */` in PostgreSQL/Generic; non-nested `/* ... */` in SQLite).
  - Placeholders (`?`, `?1`, `$1`, `:name`, `@name`) and full operator set (`=`, `==` in SQLite, `!=`, `<>`, `<=`, `>=`, `||`, `->`, `->>`, `#>`, `#>>`, `::`, `@>`, `<@`, `~`, `~*`, `!~`, `!~*`, `@`, `|/`, bitwise/shift).
  - Precise 1-based `line`/`col` and 0-based byte `offset` diagnostics.
- **Complete Core DML / DDL / TCL AST**:
  - `SELECT` (`DISTINCT`, `ALL`, `DISTINCT ON (...)`, aliases, `FROM`, table functions `generate_series(...)`, `ONLY`, `TABLESAMPLE`, `INNER`/`LEFT`/`RIGHT`/`FULL`/`CROSS`/`NATURAL` `JOIN` with `ON`/`USING`, `WHERE`, `GROUP BY [ROLLUP|CUBE|GROUPING SETS]`, `HAVING`, `WINDOW w AS (...)`, `ORDER BY ASC/DESC NULLS FIRST/LAST`, `LIMIT`/`OFFSET`, SQLite `LIMIT offset, count`, `FETCH FIRST/NEXT ... ROWS ONLY`, `FOR UPDATE/SHARE [NOWAIT|SKIP LOCKED]`, `UNION`/`INTERSECT`/`EXCEPT [ALL]` with standard `INTERSECT > UNION/EXCEPT` precedence, `WITH [RECURSIVE]` CTEs, subqueries, `EXISTS`, window functions `OVER (PARTITION BY ... ORDER BY ... ROWS/RANGE/GROUPS BETWEEN ... [EXCLUDE ...])` and `OVER w`, `WITHIN GROUP (ORDER BY ...)`, `TABLE tbl`).
  - `INSERT [OR REPLACE|IGNORE|ABORT|FAIL|ROLLBACK] INTO ... VALUES / DEFAULT VALUES / SELECT ... [ON CONFLICT (...) DO NOTHING | DO UPDATE SET ... [WHERE ...]] [RETURNING ...]`, `REPLACE INTO ...`.
  - `UPDATE ... SET col = expr | (a, b) = (1, 2) ... [FROM ...] [WHERE ...] [RETURNING ...]`.
  - `DELETE FROM ... [USING ...] [WHERE ...] [RETURNING ...]`.
  - `CREATE [UNLOGGED] [TEMP] TABLE [IF NOT EXISTS]` (typed & SQLite type-less columns, `[]` arrays, `DOUBLE PRECISION`, `GENERATED ALWAYS AS (...) STORED` / `IDENTITY`, named `CONSTRAINT` column/table constraints, `PRIMARY KEY [AUTOINCREMENT]`, `NOT NULL`, `UNIQUE`, `DEFAULT`, `CHECK`, `REFERENCES ... ON DELETE/UPDATE ...`, `WITHOUT ROWID`, `STRICT`, `CREATE TABLE ... AS SELECT`, `CREATE TABLE ... (LIKE ...)`), `CREATE [UNIQUE] INDEX [CONCURRENTLY] [IF NOT EXISTS] ... [USING method] ... [WHERE ...]`, `CREATE [OR REPLACE] [TEMP] VIEW`, `CREATE SCHEMA/SEQUENCE`, `ALTER TABLE` (`ADD`/`DROP`/`RENAME COLUMN`, `ALTER COLUMN ... TYPE`, `ADD`/`DROP CONSTRAINT`, `RENAME TO`), `DROP TABLE/INDEX/VIEW [IF EXISTS] ... [CASCADE]`, `TRUNCATE`.
  - `BEGIN [ISOLATION LEVEL ...]`, `START TRANSACTION`, `COMMIT`, `ROLLBACK [TO SAVEPOINT]`, `SAVEPOINT`, `RELEASE SAVEPOINT`, `EXPLAIN [ANALYZE | (FORMAT ...)]`, `SET`, `SHOW`, `ANALYZE`, `PRAGMA`, `VACUUM`.
- **PostgreSQL-Aligned Pratt Expression Engine**:
  - Matches PostgreSQL operator precedence & associativity (`OR` < `AND` < `NOT` < `IS`/`ISNULL`/`NOTNULL` < non-associative comparisons `=`/`!=`/`<`/`>`/`<=`/`>=` < `IN`/`BETWEEN`/`LIKE`/`ILIKE`/`SIMILAR TO`/`GLOB`/`REGEXP` < general operators `||`/`~`/`@>`/`->`/`&`/`|`/`<<`/`>>` < `+`/`-` < `*`/`/`/`%` < `^` < unary `+`/`-`/`~`/`@`/`|/` < `COLLATE` < `::` cast / `[idx]` subscript / `[lo:hi]` slice).
  - `= ANY/SOME/ALL (...)`, `EXTRACT(... FROM ...)`, `POSITION(... IN ...)`, `SUBSTRING(... FROM ... FOR ...)`, `TRIM(... FROM ...)`, typed literals (`DATE '...'`, `INTERVAL '...'`, `TIMESTAMP '...'`), `CASE`, `CAST(x AS T)`, `x::T`, function calls with `DISTINCT`, `ORDER BY`, `WITHIN GROUP` & `FILTER (WHERE ...)`, `ARRAY[...]` & `ARRAY(SELECT ...)`, tuples.
- **Safe Formatting & O(N) Static Analysis**:
  - `to_sql()` / `statements_to_sql()` / `expr_to_sql()` with safe serialization (prevents `- -x` → `--` comment injection, escapes unsafe constructed bracket/dollar-quoted/identifier nodes) and true structural AST equality (`stmt_eq(stmt, parse_one(to_sql(stmt)))`).
  - `extract_tables(stmt)` — O(N) hash-indexed, SQL case-folding & quote-aware base table extraction covering all subquery, `DISTINCT ON`, `ON CONFLICT`, `RETURNING`, and table/column `FOREIGN KEY` positions (excluding shadowed CTE aliases).
  - `extract_placeholders(stmt)` — ordered parameter placeholder list preserving duplicates.
  - `split_statements(src)` / `split_statements_dialect(src, dialect)` / `split_statements_with_options(src, opts)` — streaming, dialect-aware top-level `;` splitter with no fixed token-count cap.
- **Red-Team Hardened Resource Guards**:
  - `ParseOptions.max_depth` (default `128`) strictly bounds **both** recursive nesting (parentheses, subqueries, CTEs, CASE, functions, joins) **and** left-deep operator/postfix/set-op chains (`+`, `OR`, `||`, `::T`, `[i]`, `IS NULL`, `COLLATE`, `UNION`), preventing stack overflows across Native and `wasm32`.
  - Explicit `max_tokens` (default `500,000`) and `max_nodes` (default `1,000,000`) budgets; unterminated strings, identifiers, block comments, and dollar-quotes fail fast with exact opening `line`/`col`.

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
pub fn split_statements_dialect(src : String, dialect : Dialect) -> Result[Array[String], SqlError]
pub fn split_statements_with_options(src : String, opts : ParseOptions) -> Result[Array[String], SqlError]
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

All benchmarks run via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, **mandatory stdout SHA-256 byte-for-byte verification** including FNV-1a statement-tag sequence hash and structural roundtrip equality `stmt_eq` / `PartialEq`) on `Darwin arm64` against:
- **Rust**: `sqlparser =0.53.0` (`--release`, `opt-level = 3`, `lto = true`, `codegen-units = 1`, `PostgreSqlDialect`, macOS system allocator)

> **Allocator & Corpus Transparency**: On macOS, the default Rust system allocator adds allocation overhead relative to Pion's allocator. Against the identical `sqlparser =0.53.0` baseline linked with **`mimalloc`** (`packages/sql/audit/rust --features mimalloc`), Pion remains **~2.6× faster** on W1/W3 (vs ~4–8× against the macOS system allocator) and faster across all 11 adversarial workloads (`packages/sql/audit/REPORT.md`). All W1–W3 queries belong to the common PostgreSQL subset supported by both parsers.

### Workload 1: Complex Production SQL Parse (20,000 ops / 4.83 MB)

10 production-grade PostgreSQL statements (CTEs, recursive CTEs, multi-table `JOIN`s, window functions with `ROWS BETWEEN`, `EXISTS` subqueries, `CASE`/`CAST`/JSON operators, `FILTER (WHERE ...)`, `INSERT ... ON CONFLICT DO UPDATE ... RETURNING`, `UPDATE ... FROM ... RETURNING`, `DELETE ... RETURNING`, `CREATE TABLE` with FK/CHECK/array types, partial `CREATE UNIQUE INDEX`, `ALTER TABLE`) × 2,000 rounds:

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `85 B` (`sha256:f6751764383fb9cc...`) | Input: `4828000 B` | Ops: `20000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_sqlparser) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 136.493 | 130.175 | 154.151 | 35.37 | 6824.66 | 2.56 MiB | **8.72x** |
| `rust_sqlparser` | 1190.852 | 1116.332 | 1416.671 | 4.05 | 59542.60 | 3.33 MiB | 1.00x (baseline) |

### Workload 2: Large SQL Script Tokenize (10× 969.6 KB = 9.70 MB)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `45 B` (`sha256:f2f4b19293f241b0...`) | Input: `9696000 B` | Ops: `10`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_sqlparser) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 100.063 | 95.771 | 129.482 | 96.90 | 10006300.00 | 23.47 MiB | **7.94x** |
| `rust_sqlparser` | 794.741 | 772.797 | 819.762 | 12.20 | 79474091.70 | 38.66 MiB | 1.00x (baseline) |

### Workload 3: SQL Parse → `to_sql()` → Reparse + Structural `stmt_eq` Roundtrip (10,000 ops / 2.41 MB)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `105 B` (`sha256:e1463eb660ccacbc...`) | Input: `2414000 B` | Ops: `10000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_sqlparser) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 161.034 | 150.443 | 190.695 | 14.99 | 16103.44 | 2.81 MiB | **7.28x** |
| `rust_sqlparser` | 1172.362 | 756.640 | 1541.544 | 2.06 | 117236.16 | 3.61 MiB | 1.00x (baseline) |

## Design Boundaries & Honest Trade-offs

- **Scope vs `sqlparser-rs`**: `packages/sql` focuses on SQLite, PostgreSQL, and Generic core SQL (DML, DDL, TCL, CTEs, window functions, Pratt expressions, static analysis). `sqlparser-rs` supports 15+ dialects (MySQL, Snowflake, BigQuery, MSSQL, DuckDB, ClickHouse, Hive, etc.) with much larger AST enum variants and per-token spans/whitespace tokens, which together with allocator differences explains Pion's throughput and peak RSS advantage on the benchmarked PostgreSQL/SQLite workloads.
- **Unimplemented dialect extensions**: Stored procedures / `CREATE FUNCTION` / `DO $$ ... $$` PL/pgSQL blocks, triggers, `MERGE`, `GRANT`/`REVOKE`, `COMMENT ON`, `PREPARE`, `ATTACH`, `COPY`, and vendor-specific storage clauses (e.g. `TABLESPACE`, `PARTITION BY RANGE` DDL) are out of scope for `v0.1.0`.
- **Nesting depth & Wasm32 measured limit**: Both recursive nesting and left-deep operator/postfix/set-operation chains are strictly bounded by `ParseOptions.max_depth` (default `128`). On `wasm32` (Node.js V8 Wasm stack), **keep `max_depth <= 128`** — empirically verified with 0 crashes across all 9 nested shapes (`paren`, `not`, `neg`, `subq`, `from`, `case`, `func`, `join`, `cte`) and all 8 left-deep chains (`plus`, `or`, `concat`, `cast`, `subscript`, `isnull`, `collate`, `union`) in both `wasm32` debug and release builds (`max_depth >= 256` can hit V8's Wasm call stack limit on deeply nested subqueries/expressions).

Reproduce:

```sh
sh packages/sql/bench/run_bench.sh
```
