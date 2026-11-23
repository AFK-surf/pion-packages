# Red-team audit: `packages/sql` @ `1425a54` (`feat/pkg-sql`)

Auditor's brief: find reproducible evidence that the pure-Pion SQL package is worse than the reference it
models (Rust `sqlparser =0.53.0`) and than the real SQL semantics it claims (PostgreSQL / SQLite).
Every claim below comes from one command, `sh packages/sql/audit/run_audit.sh` (about 25 minutes; stages
can be run alone), and every verdict is made by a real engine or by upstream, never by Pion itself:

| Oracle | Used for |
|---|---|
| PostgreSQL 16.15 (throw-away cluster on a Unix socket under `$OUT`) | executes Pion's `to_sql()` output, privilege check of a role without rights on `secret`, `log_statement=all` for psql's statement splitting, validity of 156 statements, values of 29 constant expressions |
| SQLite 3.54.0 (`python3 -m sqlite3`, `executescript` = SQLite's own splitter) | statement smuggling, validity of 47 statements |
| Rust `sqlparser =0.53.0` (`audit/rust`, `PostgreSqlDialect` / `SQLiteDialect`) | AST equality (`==`, spans ignored) of the input vs Pion's `to_sql()` output; acceptance differential; same deep inputs; benchmark baseline |

Environment: Darwin arm64 (Apple M-series), `pionc 0.1.0` (`AFK-surf/pion@81b8fb0`), cargo 1.100.0,
node v24.22.2. Build products live in `/private/tmp/pion-sql-audit`; the worktree stays clean.

## Scoreboard

| | |
|---|---|
| `redteam_test.pion` | **32 / 32 `p*_` exhibits FAIL**, 5 / 5 `ctl_*` controls pass (package's own 31 tests still pass) |
| security stage | **20 exhibits** confirmed by PostgreSQL / SQLite / sqlparser (0 false alarms in the controls) |
| PostgreSQL corpus (156) | ok 83, **GAP 48** (PostgreSQL and upstream parse, Pion rejects), GAP* 10 (both reject), **BREAK 4** (Pion's `to_sql` changes the result or no longer runs), LAX 1, LOSS~ 10 (cosmetic) |
| SQLite corpus (47) | ok 21, **GAP 11**, GAP* 12, **LAX 2**, LOSS~ 1 |
| precedence (29 constant expressions run by PostgreSQL) | **3 evaluate differently** under Pion's tree, 3 more are syntax errors in PostgreSQL that Pion accepts |
| 4 build modes | 7 / 7 differential runs byte-identical across native debug / release and wasm32 debug / release, 0 traps on ordinary inputs |
| crash depth with **default** `ParseOptions` | wasm32: **1,093-term** `SELECT 1 + 1 + …` (4.4 KB) kills `to_sql` / `stmt_eq`; 4,140 terms kill parse + drop. Native: ~88,000 terms SIGSEGV in `extract_tables` |
| time complexity | `extract_tables` is **quadratic** (8× input → 61× / 118× time); everything else linear |
| benchmarks | Pion faster on all 11 workloads, but the README's 4.4–4.8× is 2.6–2.7× against an allocator-matched Rust baseline |

## P0 findings

### F1. `to_sql()` turns `- -x` into a `--` comment: a harmless SELECT round-trips into `DROP TABLE` (shared output with sqlparser 0.53)

```
input           SELECT - -1, '<LF>1; DROP TABLE secret; --'
to_sql(parse()) SELECT --1, '<LF>1; DROP TABLE secret; --'
```

`write_expr` prints `UnaryOp(Minus, UnaryOp(Minus, x))` as `-` immediately followed by `-x`
(`src/format.pion`, `Expr::UnaryOp`). The two minus signs become a line comment; the raw newline that
`write_single_quoted` keeps inside the literal ends the comment and the rest of the literal is SQL.
PostgreSQL 16 runs the input as a two-column SELECT and runs `to_sql(parse(input))` as
`SELECT 1; DROP TABLE secret;` — **the table is really dropped** (security exhibit A-PG). Every
`- -x` in a WHERE / DEFAULT / projection breaks the round trip (`WHERE b = - -1 OR a = 2` →
`WHERE b = --1 OR a = 2`, which does not parse). sqlparser 0.53's `Display` prints the same text, so this
is not worse than upstream's printer, but the package documents `stmt_eq(stmt, parse_one(to_sql(stmt)))`
as its round-trip guarantee, and its own `stmt_eq` (F9) cannot see the breakage.
Tests: `p0_to_sql_double_minus_turns_into_comment_and_smuggles_drop_table`, `p0_to_sql_double_minus_in_where_breaks_round_trip`.

### F2. `extract_tables()` misses 9 table reads that PostgreSQL enforces privileges on (Pion-only API)

Role `rt_app` has rights on `t`, `u`, `"SECRET"` only. PostgreSQL answers each statement with
**`permission denied for table secret`**; `extract_tables` returns only `t` (or nothing):

| Statement | `extract_tables` | Root cause (`src/analysis.pion`) |
|---|---|---|
| `INSERT … ON CONFLICT (id) DO UPDATE SET a = (SELECT max(id) FROM secret)` | `[t]` | `collect_tables_stmt` Insert ignores `on_conflict` |
| `INSERT … ON CONFLICT (id) DO UPDATE SET a = 2 WHERE EXISTS (SELECT 1 FROM secret)` | `[t]` | same |
| `INSERT … RETURNING (SELECT pw FROM secret LIMIT 1)` | `[t]` | `returning` never visited (Insert / Update / Delete) |
| `UPDATE t SET a = 2 WHERE id = 1 RETURNING (SELECT pw FROM secret LIMIT 1)` | `[t]` | same |
| `DELETE FROM t WHERE id = 1 RETURNING (SELECT pw FROM secret LIMIT 1)` | `[t]` | same |
| `SELECT DISTINCT ON ((SELECT max(id) FROM secret)) a FROM t` | `[t]` | `DistinctKind::DistinctOn` exprs not visited |
| `CREATE TABLE x_fk (a int, FOREIGN KEY (a) REFERENCES secret (id))` | `[x_fk]` | only column-level `REFERENCES` is visited, not `TableConstraint::ForeignKey` |
| `WITH "SECRET" AS (SELECT 1 AS id) SELECT * FROM SECRET` | `[]` | CTE shadowing compares raw strings: unquoted `SECRET` folds to `secret` in PostgreSQL and is **not** the CTE `"SECRET"` |
| `WITH "Secret" AS (SELECT 1 AS id) SELECT * FROM Secret` | `[]` | same |

The 16 positions the package does cover (IN / scalar / EXISTS / CASE subqueries, INSERT … SELECT,
UPDATE … FROM, DELETE … IN, derived tables, LATERAL, UNION branches, ORDER BY subquery, CTE bodies,
`WITH secret AS (SELECT * FROM secret)`, `public.secret`, `"secret"`, column-level REFERENCES) are
controls and pass. The README sells `extract_tables` for exactly this use; any gate built on it can be
bypassed by moving the read into RETURNING / ON CONFLICT / DISTINCT ON or by a case-folding CTE.
Tests: the nine `p0_extract_tables_*`.

### F3. SQLite statement smuggling: `parse_sqlite` / `split_statements` see one harmless SELECT, SQLite runs `DROP TABLE`

The lexer applies PostgreSQL rules in every dialect (`tokenize_impl` never looks at `opts.dialect`
except for `[`). Real SQLite 3 executes the hidden statement in all three scripts (security exhibit C):

| Script | SQLite | Pion (`parse_sqlite`, `split_statements`) | sqlparser 0.53 `SQLiteDialect` |
|---|---|---|---|
| `SELECT 1 /* /* */; DROP TABLE secret; -- */` | block comments do not nest → runs `DROP TABLE secret` | 1 statement `SELECT 1`, tables `[]` | 1 statement (same bug) |
| `SELECT $a$; DROP TABLE secret; SELECT $a$` | `$a$` is a bind parameter → runs the DROP | 1 statement (dollar-quoted string) | 1 statement (same bug) |
| `SELECT e'\' FROM (SELECT 1 AS e); DROP TABLE secret; --'` | no `E''` strings: `'\'` is a complete literal → runs the DROP | 1 statement | **rejects** (fails closed) |

Tests: `p0_parse_sqlite_nested_comment_hides_drop_table`, `p0_parse_sqlite_dollar_quote_hides_drop_table`, `p0_parse_sqlite_escape_string_hides_drop_table`.

### F4. `split_statements()` has no dialect: PostgreSQL scripts are split with SQLite bracket rules

`split_statements_impl` always tokenizes with `ParseOptions::default()` (Generic: `[...]` is a quoted
identifier, nested comments, `$tag$`, `E''`). psql (`log_statement=all`) sends
`SELECT 1 AS [x;` / `DROP TABLE secret;` / `SELECT 2 AS y]` — the DROP runs — while Pion returns one
piece. Same for back-ticks. And no dialect can be passed, so F3's SQLite smuggling also applies to the
splitter. The splitter is right on everything PostgreSQL actually quotes (`'a;b'`, `E'a\';b'`,
`E'\\'`, `$$;$$`, `$t$ $u$; $t$`, `-- ;`, nested `/* /* ; */ ; */`, `"a;b"` — control passes).
Tests: `p0_split_statements_has_no_dialect_postgres_bracket`, `p0_split_statements_has_no_dialect_sqlite_nested_comment`.

### F5. `max_depth` does not bound the tree: default options crash wasm32 on a 4.4 KB query, natively on ~350 KB

The README promises "Recursive descent is strictly bounded by `ParseOptions.max_depth` (default 128)"
and "keep `max_depth <= 256` on wasm32". The iterative Pratt loop (`parse_subexpr`) and the set-operation
loop (`parse_set_expr`) build **left-deep** trees whose depth equals the chain length without ever
calling `enter_depth`; the same holds for `::T`, `[i]`, `IS NULL` and `COLLATE` postfix chains. Every
consumer of the AST (`to_sql`, `extract_tables`, `extract_placeholders`, `stmt_eq`, and the drop of the
AST itself) is recursive. `max_tokens` (500,000) and `max_nodes` (1,000,000) are far above the crash
points. Crash length per consumer (`run_audit.sh deep`, bisected to 2 %, default `max_depth=128`):

| chain | consumer | native release / debug | wasm32 release / debug |
|---|---|---|---|
| `SELECT 1 + 1 + …` (also `OR`, `\|\|`, `::INT`, `[1]`, `IS NULL`, `COLLATE`) | parse + drop | ~106,000 (SIGSEGV) | ~4,140 (`RangeError: Maximum call stack size exceeded`) |
| same | `to_sql` / `stmt_eq` | ~106,000 | **~1,057–1,093** |
| same | `extract_tables` | ~88,000 | ~1,491 |
| same | `extract_placeholders` | ~106,000 | ~1,515 |
| `SELECT 1 UNION SELECT 1 …` | parse + drop / `to_sql` / `extract_tables` | ~106,000 / ~106,000 / ~88,000 | ~4,100 / ~3,671 / ~2,500 |

sqlparser 0.53 on the very same inputs (native release, default recursion limit 50): `plus` 110,000 terms
parse **and drop fine** (only `to_string` overflows), `cast` 110,000 parse + drop fine, `union` 110,000
overflows. So natively Pion is at parity or slightly worse; on wasm32 a 4.4 KB / 1,093-term query kills
the process with the package's default options.

The README's wasm32 advice is also wrong for depth-guarded shapes: with `max_depth = 256`, nesting
255 subqueries, derived tables, CASE or function calls crashes wasm32 already in parse + drop (all
stages); of the settings tested (128, 256, 1024) only `max_depth = 128` survived all 9 guarded shapes in all 4 modes.
Tests: `p0_left_deep_chain_depth_is_not_bounded_by_max_depth` (default options accept a depth-1001
tree), `p0_cast_and_subscript_chains_ignore_max_depth` (`max_depth = 8` accepts depth 501).

## P1 findings

### F6. Operator precedence differs from PostgreSQL (and from the SQL standard for set operations)

`get_infix_prec` puts `||` with `+`/`-` (50), regex / containment operators and `IS` with comparisons (30),
and `parse_set_expr` folds `UNION` / `INTERSECT` / `EXCEPT` strictly left to right. PostgreSQL places
"any other operator" (`||`, `~`, `@>`, `->`, …) **below** `+`/`-` and **above** comparisons, `IS` below
comparisons, comparisons non-associative, and `INTERSECT` above `UNION`/`EXCEPT`. PostgreSQL evaluating the
input vs Pion's fully parenthesised tree (`driver pexpr`):

| Input | PostgreSQL | Pion's tree → PostgreSQL |
|---|---|---|
| `SELECT 'a' \|\| 1 + 2` | `a3` | `(('a' \|\| 1) + 2)` → ERROR operator does not exist: text + integer |
| `SELECT TRUE = 'ab' ~ 'a'` | `t` | `((TRUE = 'ab') ~ 'a')` → ERROR invalid input syntax for type boolean |
| `SELECT 1 + 1 IS DISTINCT FROM 2 = FALSE` | ERROR integer = boolean | `(((1 + 1) IS DISTINCT FROM 2) = FALSE)` → `t` |
| `SELECT 3 > 2 > FALSE`, `SELECT 1 < 2 = TRUE`, `SELECT TRUE = 1 < 2` | syntax error | accepted |
| `SELECT 1 UNION SELECT 2 INTERSECT SELECT 3` | `{1}` | tree `(1 UNION 2) INTERSECT 3` = `{}` |

`to_sql` prints the set operation flat, so the *text* round trip hides the wrong tree; anything that
walks or rewrites the AST (the point of a parser) computes the wrong query.
Tests: `p1_intersect_does_not_bind_tighter_than_union`, `p1_concat_binds_as_tight_as_plus`,
`p1_regex_match_binds_as_loose_as_eq`, `p1_is_distinct_from_binds_tighter_than_eq`, `p1_chained_comparison_accepted`.

### F7. `E'\x41'`, `E'A'`, `E'\101'` silently become `x41`, `u0041`, `101`

The escape-string lexer knows `\n \t \r \b \f` and otherwise drops the backslash. PostgreSQL (and
sqlparser 0.53's `Unescape`) decode hex, octal, `\u` and `\U`: `SELECT E'\x41'` is `A` in PostgreSQL and
`x41` after Pion's `to_sql` (diff stage BREAK, security exhibit A-PG). Silent value corruption, Pion-only.
Test: `p1_escape_string_hex_unicode_octal_escapes_dropped`.

### F8. `to_sql` writes `double precision` as `DOUBLE`, which PostgreSQL rejects

`CREATE TABLE … (e double precision)` and `a::double precision` come back as `DOUBLE`
(`type "double" does not exist` in PostgreSQL; diff stage BREAK ×2). sqlparser keeps `DOUBLE PRECISION`.
Test: `p1_to_sql_double_precision_is_not_postgres`.

### F9. `stmt_eq` is text equality, not "structural AST equality"

`stmt_eq_impl` compares `format_stmt(a) == format_stmt(b)` and only additionally serialises the
projection of a plain SELECT. Any two trees that print alike are "equal": `(a OR b) AND c` vs
`a OR (b AND c)` in a WHERE clause built without `Nested`, `Number("1")` vs `Identifier("1")`, and the
whole of F1 / F6. The package's own round-trip tests (`format_roundtrip_ast_equivalence`, `wasm_smoke`)
use it as their oracle, so they cannot detect a round-trip bug. Test: `p1_stmt_eq_is_text_equality_not_structural`.

### F10. Table names come back without quoting or case folding

`object_name_to_string` joins `Ident.value`s: `SECRET` and `"SECRET"` (two different PostgreSQL tables)
both give `SECRET`; `"a.b"` and `a.b` both give `a.b`; keyword-spelled names are upper-cased (F11). No
allow / deny list written against this output can be correct (F2's CTE bypass is one consequence).
Test: `p1_extract_tables_conflates_quoted_and_unquoted_names`.

### F11. Identifiers that are keywords are upper-cased in the AST

`parse_ident` / `parse_optional_alias` / `parse_prefix` build `Ident::new(k)` from the *canonical keyword*,
so `key`, `date`, `time`, `action`, `timestamp`, `text` (but not `value`, `name`, `status`) become `KEY`,
`DATE`, … in `to_sql`, aliases and `extract_tables` (`FROM key` → `[KEY]`). PostgreSQL folds them back,
so it is cosmetic for execution (diff stage LOSS~ ×11), but it changes user-visible names, breaks
case-sensitive consumers and differs from upstream, which keeps `key`. Test: `p1_keyword_identifiers_are_uppercased`.

## P2 findings

- **F12 coverage**: 48 PostgreSQL and 11 SQLite statements that the engine *and* sqlparser 0.53 parse are
  rejected (fail-closed), among them `SIMILAR TO`, `= ALL/SOME (subquery)`, `EXTRACT`, `SUBSTRING … FROM … FOR`,
  `INTERVAL '…'` / `DATE '…'`, `ARRAY(SELECT …)`, slices `a[1:2]`, `string_agg(… ORDER BY …)`, `WITHIN GROUP`,
  `WINDOW w AS`, `FETCH FIRST`, `FOR UPDATE`, table functions in FROM, `GROUPING SETS`, `INSERT … DEFAULT VALUES`,
  `UPDATE … SET (a, b) =`, `DELETE … USING`, `GENERATED … AS`, named column constraints, `ALTER COLUMN TYPE`,
  `TRUNCATE`, `SET`, `SHOW`, `BEGIN ISOLATION LEVEL`, `EXPLAIN (…)`, SQLite `X'..'` blobs, `LIMIT a, b`,
  `INSERT OR REPLACE`, `REPLACE INTO`, type-less columns, `==`, `REGEXP`. Full list: `run_audit.sh diff`.
  Tests: `p2_postgres_statements_upstream_parses_pion_rejects`, `p2_sqlite_statements_upstream_parses_pion_rejects`.
- **F13 `extract_tables` is O(n²)**: `push_unique_table` / CTE lookup scan arrays linearly. 8× input →
  61× time for distinct tables, 118× for CTEs (80,000 distinct tables ≈ 4.3 s, 80,000 CTEs ≈ 10 s, vs 23 ms to parse). Everything else
  measured (IN lists, OR chains, `''` escapes, splitting, multi-statement scripts) is linear (`run_audit.sh scale`).
- **F14 `split_statements` refuses big scripts**: it runs the full tokenizer with the fixed default
  `max_tokens = 500,000` and takes no options; a 1.2 MB `INSERT … VALUES (1),(2),…` is an error.
  Test: `p2_split_statements_rejects_large_scripts`.
- **F15 constructed-AST footguns** (shared with sqlparser 0.53): bracket identifiers are printed without
  escaping `]`, dollar-quoted bodies are printed verbatim even when they contain their own delimiter,
  `Ident::new` values are never quoted, and `BinaryOp` without `Nested` prints without parentheses —
  `to_sql` of a programmatically built AST can smuggle statements.
  Tests: `p2_to_sql_bracket_identifier_not_escaped`, `p2_to_sql_dollar_body_can_close_its_own_quote`.
- **F16 over-acceptance**: `SELECT $1a$` (PostgreSQL: trailing junk) is accepted as `$1 AS a$`; in the
  SQLite dialect `$a$ x $a$` and `e'\''` are accepted (SQLite: syntax error) — the root of F3.

## Benchmark fairness (`packages/sql/bench`, README W1–W3)

Verdict: **the speed claim survives, but it is inflated about 1.7× by the Rust allocator, and the corpus
and the SHA gate are weaker than they look.** Pion wins every workload below; it loses none.

1. **Allocator.** The Rust baseline runs on the macOS system allocator. The same oracle rebuilt with
   `mimalloc` (`audit/rust`, feature `mimalloc`, identical code) is 1.5–2.1× faster. Against that baseline the
   README's W1 / W3 "4.83× / 4.40×" becomes **2.55× / 2.67×** (re-measured on the package's own `gen_data.py`
   corpus, same round counts).
2. **Corpus selection.** The 10 W1–W3 queries all fall inside the subset Pion parses. On a 156-statement
   PostgreSQL corpus Pion rejects 58 statements, 48 of which upstream parses (F12), so those inputs could not
   be benchmarked at all. That is not a lie, but it is the "favourable input selection" AGENTS.md §1.3 forbids,
   unless the README states the subset next to the numbers.
3. **The SHA-256 gate checks almost nothing.** W1 / W3 print only statement counts and a statement-kind sum.
   Pion's wrong trees (F6 `'a' || 1 + 2`, F7 `E'\x41'`, F1 `- -1`) produce the same digest as upstream, so a
   parser that builds wrong ASTs passes the gate. W2 compares token counts only.
4. **Unequal work.** sqlparser builds per-token spans, keeps whitespace / comment tokens and allocates
   a far larger AST (15+ dialects). The README says so; with point 1 it explains the gap.

Adversarial workloads (`run_audit.sh bench`, `bench_compare.py`, warmup 1, 5 interleaved rounds, stdout
SHA-256 identical across all three implementations; median ms, × = speed-up vs system-allocator Rust):

| Workload (input × rounds) | Pion | sqlparser | sqlparser + mimalloc | Pion vs mimalloc |
|---|---:|---:|---:|---:|
| package W1 corpus, parse (10 queries × 2000) | 92.3 | 411.5 | 234.8 | **2.55×** |
| package W3 corpus, parse → to_sql → reparse (× 1000) | 95.6 | 423.3 | 255.1 | **2.67×** |
| 200 × (400-term `+` chain + 400-term `OR` chain), parse (1.26 MB × 5) | 199.0 | 923.4 | 602.0 | 3.03× |
| same, round trip | 355.0 | 1688.3 | 1077.5 | 3.04× |
| 20 × `IN (10,000 numbers)`, parse (1.18 MB × 5) | 88.6 | 434.8 | 265.7 | 3.00× |
| same, round trip | 191.4 | 951.6 | 574.1 | 3.00× |
| quote-heavy literals (`''`, `E'\''`, `$q$`, `""`), parse (1.68 MB × 5) | 30.0 | 66.5 | 31.9 | **1.07×** |
| same, round trip | 49.3 | 126.4 | 74.9 | 1.52× |
| 30,000 malformed statements, error path (× 20) | 268.5 | 1078.3 | 695.5 | 2.59× |
| `split_statements` of a 1.45 MB script (× 10) | 88.3 | 275.7 | 181.3 | 2.05× |
| whole-script parse, 18,000 statements (× 5) | 169.0 | 547.6 | 349.5 | 2.07× |

Peak RSS: Pion is lower everywhere except the quote-heavy literal file (6.3 MiB vs 4.7 MiB) and the
operator chains (6.4 MiB vs 5.3 MiB, system allocator). The Rust "split" baseline is an emulation
(tokenize + depth-0 `;`), since upstream has no splitter.

## Controls (attacks the package survives)

- Quoted identifiers / strings / dollar bodies with `"`, `'`, `\`, `;`, `--`, `/*`, keywords as quoted
  names round-trip exactly and upstream agrees (`ctl_quoted_identifiers_and_strings_round_trip`, security A).
- Explicit parentheses survive: `(a OR b) AND c`, `NOT (a AND b)`, `(a - b) - c` vs `a - (b - c)`, `(a / b) / c`,
  `-(a - b)`, `(-a)::INTEGER`, `(a || b) || c`, `BETWEEN … AND … AND`, `(SELECT 1 UNION SELECT 2) LIMIT 1` vs
  `SELECT 1 UNION (SELECT 2 LIMIT 1)` (`ctl_parenthesised_precedence_round_trips`).
- `split_statements` handles every PostgreSQL quoting form in the brief, including `E'\\'; SELECT 1` and
  `$a$ $b$; $a$` (`ctl_split_statements_quotes_comments_dollars`).
- `extract_tables` covers 16 subquery / DML positions (`ctl_extract_tables_subquery_positions`).
- Depth guard: 400 parentheses / 200 subqueries are rejected cleanly; with `max_depth = 128` all 9 guarded
  shapes survive all stages in all 4 build modes (`ctl_depth_guard_rejects_deep_parens_and_subqueries`, deep Part 2).
- Native and wasm32 (debug / release) produce byte-identical results on all differential inputs.

## Reproduce

```sh
sh packages/sql/audit/run_audit.sh                          # all stages
sh packages/sql/audit/run_audit.sh tests security diff      # the fast part (~1 min)
OUT=/some/tmp PG_PORT=55440 sh packages/sql/audit/run_audit.sh deep
```

Layout: `redteam_test.pion` (exhibits + controls), `driver/` (Pion probe / pexpr / split / deep / adv
driver, 4 build modes), `rust/` (sqlparser 0.53 oracle, optional `mimalloc` feature), `scripts/`
(`security.py`, `differential.py`, `wasm4.py`, `depth.py`, `scale.py`, `gen_adv.py`, `common.py`).
