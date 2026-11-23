#!/usr/bin/env python3
"""Lexer / grammar / precedence differential: Pion vs Rust sqlparser 0.53 vs the real engines.

Ground truth for "is this valid SQL" is the real engine (PostgreSQL 16 for the postgres corpus,
SQLite 3 for the sqlite corpus): a statement is valid when the engine reports anything but a
syntax / tokenizer error. Each row is classified:

  GAP      engine accepts, upstream accepts, Pion rejects          (Pion strictly worse than upstream)
  GAP*     engine accepts, upstream rejects too, Pion rejects      (shared gap, listed for completeness)
  LAX      engine rejects, Pion accepts                            (over-acceptance)
  BREAK    Pion accepts, the engine runs the input, but the engine rejects / computes differently Pion's to_sql()
  LOSS~    upstream's AST differs after Pion's to_sql() but the engine computes the same (cosmetic: case, type alias)
  PREC     constant expression: PostgreSQL evaluates the input and Pion's fully parenthesised tree
           (driver `pexpr`) to different results - Pion built a different tree than PostgreSQL
  ok       everything agrees
"""
import sqlite3
import sys

from common import hexfile, pion, pion_probe, psql, psql_raw, rust_probe, rust_same, unhex

PG_SCHEMA = """
DROP TABLE IF EXISTS d, d2 CASCADE;
CREATE TABLE d(id int PRIMARY KEY, a int, b int, c int, x int, y int, s text, j jsonb, arr int[], v int,
  value int, type int, status int, data int, level int, action int, key int, name text, date date,
  time time, "timestamp" timestamp, count int, sum int, text text, result int, order_id int);
CREATE TABLE d2(id int, a int, b int);
"""

PG = [
    # --- lexical: E-strings
    r"SELECT E'\n\t\r\b\f\\\''", r"SELECT E'\x41'", r"SELECT E'A'", r"SELECT E'\101'", r"SELECT E'\\'",
    r"SELECT e'a\'b'",
    # --- dollar quotes / placeholders
    "SELECT $1", "SELECT $a$x$a$", "SELECT $$x$$", "SELECT $1a$", "SELECT $foo$bar$foo$", "SELECT $_$x$_$",
    "SELECT $a$ $b$ $a$",
    # --- comments
    "SELECT /* a /* b */ c */ 1", "SELECT 1 -- x", "SELECT 1 /* x */",
    # --- numbers
    "SELECT 1.e5", "SELECT .5", "SELECT 1e+5", "SELECT 1e-5", "SELECT 0x10", "SELECT 1..2", "SELECT 0.1.2",
    "SELECT 1_000", "SELECT 0b101", "SELECT 0o17",
    # --- identifiers
    "SELECT 1 AS été", "SELECT \"名前\" FROM d", "SELECT a$b FROM (SELECT 1 AS a$b) q",
    "SELECT value, type, status, data, level, action, key, name, date, time, timestamp, count, sum, text, result, order_id FROM d",
    "SELECT d.value, d.key FROM d", "SELECT a AS value, b AS key, c AS name FROM d", "SELECT * FROM d AS date",
    "SELECT * FROM d key", "SELECT user", "SELECT a FROM d ORDER BY key",
    # --- predicates and operators
    "SELECT a FROM d WHERE x BETWEEN 1 AND 10 AND y = 2", "SELECT a FROM d WHERE a IS NOT DISTINCT FROM b",
    "SELECT a FROM d WHERE a NOT IN (1, 2)", "SELECT a FROM d WHERE s NOT LIKE 'x%'",
    "SELECT a FROM d WHERE a NOT BETWEEN 1 AND 2", "SELECT a FROM d WHERE s SIMILAR TO 'x%'",
    "SELECT a FROM d WHERE a = ANY(ARRAY[1, 2])", "SELECT a FROM d WHERE a = ALL(SELECT a FROM d2)",
    "SELECT a FROM d WHERE a = SOME(SELECT a FROM d2)", "SELECT a FROM d WHERE a > ANY(arr)",
    "SELECT a FROM d WHERE s ~ 'x' AND s !~* 'y'", "SELECT j -> 'a' ->> 'b' FROM d", "SELECT j #>> '{a,b}' FROM d",
    "SELECT j @> '{}' FROM d", "SELECT a FROM d WHERE a ISNULL", "SELECT a FROM d WHERE a NOTNULL",
    "SELECT a FROM d WHERE s ILIKE 'x' ESCAPE '!'", "SELECT EXTRACT(YEAR FROM date) FROM d",
    "SELECT POSITION('a' IN s) FROM d", "SELECT SUBSTRING(s FROM 1 FOR 2) FROM d", "SELECT TRIM(BOTH ' ' FROM s) FROM d",
    "SELECT INTERVAL '1 day'", "SELECT DATE '2020-01-01'", "SELECT TIMESTAMP '2020-01-01 00:00'",
    "SELECT a::text, CAST(a AS bigint), a::numeric(10, 2), a::varchar(255), s::timestamp with time zone, a::double precision, arr::int[] FROM d",
    "SELECT ROW(1, 2)", "SELECT ARRAY(SELECT a FROM d)", "SELECT arr[1:2] FROM d", "SELECT COALESCE(a, b), NULLIF(a, b), GREATEST(a, b) FROM d",
    "SELECT count(*) FILTER (WHERE a > 1) FROM d", "SELECT string_agg(s, ',' ORDER BY s) FROM d",
    "SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY a) FROM d", "SELECT a FROM d WHERE (a, b) IN ((1, 2))",
    "SELECT a FROM d WHERE (a, b) = (1, 2)", "SELECT -a::int FROM d", "SELECT 2 ^ 3 ^ 2", "SELECT |/ 16", "SELECT @ -5",
    "SELECT a FROM d WHERE NOT a = 1 AND b = 2",
    # --- joins / projections
    "SELECT * FROM d LEFT JOIN LATERAL (SELECT a FROM d2 WHERE d2.id = d.id) q ON TRUE",
    "SELECT * FROM d NATURAL LEFT JOIN d2", "SELECT * FROM d CROSS JOIN d2", "SELECT * FROM d JOIN d2 USING (id, a)",
    "SELECT d.* FROM d", "SELECT DISTINCT ON (a, b) a, b FROM d ORDER BY a, b", "SELECT * FROM d JOIN d2 ON d.id = d2.id JOIN d2 AS e ON e.id = d.id",
    "SELECT * FROM (d JOIN d2 ON d.id = d2.id)", "SELECT * FROM d, d2 WHERE d.id = d2.id", "SELECT * FROM generate_series(1, 3) g",
    "SELECT * FROM d TABLESAMPLE SYSTEM (10)", "SELECT * FROM ONLY d", "SELECT * FROM d FULL OUTER JOIN d2 ON TRUE",
    # --- windows
    "SELECT count(*) OVER w FROM d WINDOW w AS (ORDER BY a)",
    "SELECT sum(a) OVER (ORDER BY a ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW EXCLUDE CURRENT ROW) FROM d",
    "SELECT sum(a) OVER (ORDER BY a ROWS 1 PRECEDING) FROM d", "SELECT sum(a) OVER (PARTITION BY b ORDER BY a RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM d",
    "SELECT sum(a) OVER (ORDER BY a GROUPS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) FROM d", "SELECT rank() OVER () FROM d",
    # --- set operations / query tail
    "SELECT 1 UNION SELECT 2 INTERSECT SELECT 3", "SELECT 1 EXCEPT SELECT 2 UNION SELECT 3",
    "(SELECT 1 UNION SELECT 2) LIMIT 1", "SELECT 1 UNION (SELECT 2 LIMIT 1)", "SELECT 1 UNION ALL SELECT 1 ORDER BY 1 LIMIT 1 OFFSET 0",
    "SELECT a FROM d FETCH FIRST 5 ROWS ONLY", "SELECT a FROM d OFFSET 1 ROWS FETCH NEXT 2 ROWS ONLY", "SELECT a FROM d LIMIT ALL",
    "SELECT a FROM d FOR UPDATE", "SELECT a FROM d FOR UPDATE SKIP LOCKED", "TABLE d", "VALUES (1, 2), (3, 4)",
    "SELECT * FROM (VALUES (1, 2)) AS v(a, b)", "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT n FROM r",
    "WITH m AS MATERIALIZED (SELECT 1) SELECT * FROM m", "SELECT a FROM d GROUP BY ROLLUP (a)", "SELECT a FROM d GROUP BY GROUPING SETS ((a), ())",
    # --- DML
    "INSERT INTO d (id, a) VALUES (1, 2) ON CONFLICT DO NOTHING", "INSERT INTO d (id, a) VALUES (1, 2) ON CONFLICT (id) WHERE a > 0 DO UPDATE SET a = EXCLUDED.a",
    "INSERT INTO d (id, a) VALUES (1, 2) ON CONFLICT ON CONSTRAINT d_pkey DO NOTHING", "INSERT INTO d (id) VALUES (DEFAULT)", "INSERT INTO d DEFAULT VALUES",
    "INSERT INTO d AS t (id) VALUES (1)", "UPDATE d SET (a, b) = (1, 2)", "UPDATE d AS t SET a = t.a + 1", "UPDATE d SET a = DEFAULT",
    "DELETE FROM d USING d2 WHERE d.id = d2.id", "DELETE FROM d AS t WHERE t.id = 1", "UPDATE d SET a = 1 WHERE CURRENT OF c",
    # --- DDL
    "CREATE TABLE d3 (a int, b int, PRIMARY KEY (a, b), UNIQUE (a, b), FOREIGN KEY (a) REFERENCES d(id))",
    "CREATE TABLE d3 (a numeric(10, 2), b varchar(255), c timestamp with time zone, e double precision, f int[], g text[][])",
    "CREATE TABLE d3 (a int, b int GENERATED ALWAYS AS (a * 2) STORED)", "CREATE TABLE d3 (a int GENERATED ALWAYS AS IDENTITY)",
    "CREATE TABLE d3 (a int CONSTRAINT pos CHECK (a > 0))", "CREATE TABLE d3 (LIKE d)", "CREATE TABLE d3 AS SELECT * FROM d",
    "CREATE UNLOGGED TABLE d3 (a int)", "CREATE TABLE d3 (a timestamptz DEFAULT now(), b bool, c smallserial)",
    "CREATE INDEX CONCURRENTLY i ON d (a)", "CREATE INDEX i ON d USING gin (j)", "CREATE INDEX i ON d ((lower(s)))",
    "ALTER TABLE d ADD COLUMN z int NOT NULL DEFAULT 0", "ALTER TABLE d ALTER COLUMN a TYPE bigint", "ALTER TABLE d ADD CONSTRAINT c1 UNIQUE (a)",
    "ALTER TABLE d DROP CONSTRAINT d_pkey", "DROP TABLE IF EXISTS d3, d4 CASCADE", "TRUNCATE d", "CREATE SCHEMA s1", "CREATE SEQUENCE sq",
    "COMMENT ON TABLE d IS 'x'", "GRANT SELECT ON d TO PUBLIC", "SET search_path = public", "SHOW search_path", "ANALYZE d",
    "BEGIN ISOLATION LEVEL SERIALIZABLE", "START TRANSACTION", "COMMIT", "ROLLBACK TO SAVEPOINT a", "EXPLAIN ANALYZE SELECT 1",
    "EXPLAIN (FORMAT JSON) SELECT 1", "PREPARE p AS SELECT $1::int", "DO $$BEGIN END$$",
]

# pure-constant expressions: PostgreSQL evaluates the input and Pion's parenthesised tree
PREC = [
    "SELECT 'a' || 1 + 2", "SELECT 1 + 2 || 'a'", "SELECT 2 * '{\"6\": 1}'::jsonb -> 'x'", "SELECT 2 + 3 * 4 ^ 2",
    "SELECT -2 ^ 2", "SELECT 2 ^ 3 ^ 2", "SELECT NOT TRUE = FALSE", "SELECT 1 = 1 IS TRUE", "SELECT TRUE = 1 < 2",
    "SELECT 1 < 2 = TRUE", "SELECT 'ab' ~ 'a' = TRUE", "SELECT TRUE = 'ab' ~ 'a'", "SELECT 1 | 2 + 3", "SELECT 1 & 2 + 3",
    "SELECT 6 & 3 | 4", "SELECT 1 << 2 + 1", "SELECT 2 BETWEEN 1 AND 3 = TRUE", "SELECT 'a' LIKE 'a' = TRUE",
    "SELECT 5 % 3 * 2", "SELECT 7 - 2 - 1", "SELECT 8 / 2 / 2", "SELECT - 2 * 3", "SELECT 'x' || 'y' = 'xy'",
    "SELECT '{\"a\":{\"b\":1}}'::jsonb -> 'a' -> 'b' = '1'", "SELECT 1 IN (1) = TRUE", "SELECT NOT 1 IN (2)",
    "SELECT 3 > 2 > FALSE", "SELECT NULL IS NULL = TRUE", "SELECT 1 + 1 IS DISTINCT FROM 2 = FALSE",
]

SQLITE_SCHEMA = [
    "CREATE TABLE d(id INTEGER PRIMARY KEY, a, b, c, x, y, s, value, type, status, data, key, name, date, time, count)",
    "CREATE TABLE d2(id, a, b)",
]

SQLITE = [
    "SELECT X'0102'", "SELECT x'ff'", "SELECT 1 LIMIT 1, 2", "SELECT a FROM d WHERE s GLOB 'x*'", "SELECT a FROM d WHERE s REGEXP 'x'",
    "SELECT a FROM d WHERE a ISNULL", "SELECT a FROM d WHERE a NOTNULL", "SELECT a FROM d WHERE a NOT NULL", "SELECT a FROM d WHERE a IS NOT 1",
    "INSERT OR REPLACE INTO d (id) VALUES (1)", "REPLACE INTO d (id) VALUES (1)", "INSERT OR IGNORE INTO d (id) VALUES (1)",
    "SELECT [a] FROM [d]", "SELECT `a` FROM `d`", "SELECT \"a\" FROM \"d\"", "SELECT :name, @name, $name, ?1, ?",
    "SELECT /* a /* b */ 1", "SELECT 1 /* unterminated", "SELECT $a$ x $a$", "SELECT e'\\'' ",
    "CREATE TABLE d3 (a INTEGER PRIMARY KEY AUTOINCREMENT, b TEXT) WITHOUT ROWID", "CREATE TABLE d3 (a, b)",
    "CREATE TABLE d3 (a INT) STRICT", "PRAGMA table_info(d)", "ATTACH ':memory:' AS x", "VACUUM", "SELECT CAST(a AS TEXT) FROM d",
    "SELECT a FROM d INDEXED BY i", "SELECT a FROM d WHERE a IN d2", "SELECT * FROM d NATURAL JOIN d2",
    "UPDATE d SET a = 1 FROM d2 WHERE d.id = d2.id", "SELECT a FROM d ORDER BY a NULLS FIRST", "SELECT 1 -- x",
    "SELECT a, count(*) FILTER (WHERE a > 1) OVER (PARTITION BY b) FROM d", "SELECT json_extract(s, '$.a') FROM d",
    "SELECT s -> '$.a', s ->> '$.a' FROM d", "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT n FROM r",
    "SELECT 0x10", "SELECT 1e5", "SELECT .5", "SELECT 1_000",
    "SELECT value, type, status, data, key, name, date, time, count FROM d",
    "CREATE INDEX i ON d (a) WHERE a > 0", "CREATE TRIGGER tr AFTER INSERT ON d BEGIN SELECT 1; END", "SELECT a FROM d WHERE a == 1",
    "SELECT a FROM d WHERE a <> 1 AND b != 2", "SELECT CASE a WHEN 1 THEN 'x' END FROM d",
]


def pg_valid(sqls):
    psql_raw(["-q"], stdin=PG_SCHEMA)
    out = []
    for s in sqls:
        rc, _, err = psql(s)
        bad = any(k in err for k in ("syntax error", "unterminated", "invalid hexadecimal", "trailing junk", "invalid Unicode"))
        out.append(rc == 0 or not bad)
    return out


def sqlite_valid(sqls):
    out = []
    for s in sqls:
        con = sqlite3.connect(":memory:")
        for x in SQLITE_SCHEMA:
            con.execute(x)
        try:
            con.executescript("BEGIN;" + s + ";ROLLBACK;") if s.upper().startswith(("CREATE TRIGGER",)) else con.execute(s)
            out.append(True)
        except sqlite3.Warning:
            out.append(True)
        except sqlite3.Error as e:
            m = str(e)
            out.append(not ("syntax error" in m or "unrecognized token" in m or "incomplete input" in m))
    return out


def engine_run(dialect, sql):
    if dialect == "postgres":
        rc, out, err = psql(sql)
        return out.strip() if rc == 0 else "ERROR " + (err.strip().splitlines() or [""])[0][:70]
    con = sqlite3.connect(":memory:")
    for x in SQLITE_SCHEMA:
        con.execute(x)
    try:
        return repr(con.execute(sql).fetchall())
    except sqlite3.Error as e:
        return "ERROR " + str(e)


def classify(corpus, dialect, valid):
    pr = pion_probe(corpus, dialect)
    up = rust_probe(corpus, dialect)
    same = rust_same([(c, p["sql"] if p["ok"] else "") for c, p in zip(corpus, pr)], dialect)
    counts = {}
    rows = []
    for c, v, p, u, s in zip(corpus, valid, pr, up, same):
        if v and not p["ok"]:
            k = "GAP" if u["ok"] else "GAP*"
            note = f"Pion: {p['msg']}" + ("" if u["ok"] else f" | upstream: {u['msg'][:60]}")
        elif not v and p["ok"]:
            k, note = "LAX", f"Pion -> {p['sql']!r}"
        elif p["ok"] and u["ok"] and s in ("NE", "ERRB"):
            a, b = engine_run(dialect, c), engine_run(dialect, p["sql"])
            k = "LOSS~" if a == b else "BREAK"
            note = f"Pion to_sql -> {p['sql']!r}" + ("" if a == b else f"; engine: input -> {a!r}, Pion to_sql -> {b!r}")
        else:
            k, note = "ok", ""
        counts[k] = counts.get(k, 0) + 1
        rows.append((k, c, v, p["ok"], u["ok"], note))
    return counts, rows


def precedence():
    pe = pion(["pexpr", "postgres", hexfile(PREC)])
    up = rust_probe(PREC)
    n = bad = 0
    print("\n== PREC: PostgreSQL value of input vs of Pion's fully parenthesised tree ==")
    for c, line, u in zip(PREC, pe, up):
        if not line.startswith("OK"):
            print(f"  GAP  {c!r}: Pion rejects")
            continue
        tree = "SELECT " + unhex(line[3:])
        rc1, a, e1 = psql_raw(["-Atc", c])
        rc2, b, e2 = psql_raw(["-Atc", tree])
        ra = a.strip() if rc1 == 0 else "ERROR " + e1.strip().splitlines()[0][:60]
        rb = b.strip() if rc2 == 0 else "ERROR " + e2.strip().splitlines()[0][:60]
        n += 1
        if ra != rb:
            lax = "syntax error" in ra
            bad += not lax
            print(f"  {'LAX ' if lax else 'PREC'} {c!r}: PostgreSQL={ra!r}; Pion tree {tree!r} -> {rb!r}")
    print(f"  {bad}/{n} valid constant expressions evaluate differently under Pion's tree (LAX rows: PostgreSQL rejects, Pion accepts)")
    return bad


def main():
    total = {}
    for name, corpus, dialect, valid in (("postgres", PG, "postgres", pg_valid(PG)), ("sqlite", SQLITE, "sqlite", sqlite_valid(SQLITE))):
        counts, rows = classify(corpus, dialect, valid)
        print(f"\n== {name}: {len(corpus)} statements vs real {'PostgreSQL 16' if name == 'postgres' else 'SQLite 3'} + sqlparser 0.53 ==")
        for k, c, v, po, uo, note in rows:
            if k != "ok":
                print(f"  {k:5} {c!r}: engine={'valid' if v else 'INVALID'} pion={'ok' if po else 'ERR'} upstream={'ok' if uo else 'ERR'}  {note}")
        print("  summary: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
        for k, v in counts.items():
            total[f"{name}.{k}"] = v
    total["prec"] = precedence()
    print("\nTOTAL " + " ".join(f"{k}={v}" for k, v in sorted(total.items())))


if __name__ == "__main__":
    main()
    sys.exit(0)
