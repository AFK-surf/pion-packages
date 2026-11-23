#!/usr/bin/env python3
"""P0 security exhibits for packages/sql, each judged by a *real* engine, not by Pion itself.

  A. to_sql() round trip: Pion's output re-parsed by upstream sqlparser 0.53 (AST ==, spans ignored)
     must be the same statement as the input; the injection case is also executed in real PostgreSQL 16.
  B. extract_tables() vs PostgreSQL's own privilege check: role `rt_app` may use t/u only; a statement
     that PostgreSQL refuses with "permission denied for table secret" while extract_tables() does not
     list `secret` is an authorisation bypass.
  C. Dialect-blind lexing vs real SQLite 3 (python sqlite3.executescript = sqlite3_prepare's splitter):
     a script after which `secret` is gone while split_statements() / parse_sqlite() + extract_tables()
     never show a DROP of `secret`.
  D. split_statements() vs psql's own splitter (psql -e echoes every statement it sends).
"""
import os
import re
import subprocess
import sys
import time

from common import OUT, PG_PORT, PG_SOCK, pion_probe, pion_split, psql, psql_raw, rust_probe, rust_same, sqlite_effect

SETUP = """
DO $$BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rt_app') THEN EXECUTE 'DROP OWNED BY rt_app'; END IF; END$$;
DROP TABLE IF EXISTS x_fk, t, u, secret, "SECRET" CASCADE;
DROP ROLE IF EXISTS rt_app;
CREATE ROLE rt_app NOLOGIN;
CREATE TABLE secret(id int PRIMARY KEY, pw text);
CREATE TABLE "SECRET"(id int);
CREATE TABLE t(id int PRIMARY KEY, a int, b text);
CREATE TABLE u(id int, a int);
INSERT INTO secret VALUES (1, 'hunter2');
INSERT INTO t VALUES (1, 1, 'x');
GRANT SELECT, INSERT, UPDATE, DELETE ON t, u, "SECRET" TO rt_app;
GRANT CREATE ON SCHEMA public TO rt_app;
"""

fails = 0


def exhibit(tag, bad, msg):
    global fails
    fails += bad
    print(f"  {'FAIL' if bad else 'pass'} [{tag}] {msg}")


def part_a():
    print("\n== A. to_sql() round trip judged by upstream sqlparser 0.53 (PostgreSqlDialect) ==")
    cases = [
        "SELECT - -1, '\n1; DROP TABLE secret; --'",
        "SELECT - -a FROM t",
        "SELECT a FROM t WHERE b = - -1 OR a = 2",
        "SELECT E'\\x41', E'\\u0041', E'\\101'",
        # controls: parentheses kept as Nested, quoting / escaping round-trips
        "SELECT (a OR b) AND c, NOT (a AND b), (a - b) - c, a - (b - c), (a / b) / c, a / (b / c) FROM t",
        "SELECT -(a - b), (-a)::INTEGER, -(a::INTEGER), (a || b) || c, a || (b || c) FROM t",
        "SELECT a FROM t WHERE a BETWEEN 1 AND 2 AND b = 'x'",
        "(SELECT 1 UNION SELECT 2) LIMIT 1",
        "SELECT 1 UNION (SELECT 2 LIMIT 1)",
        "SELECT \"a\"\"b\", \"x;y\", \"--c\", \"/*d\", \"e\"\"; DROP TABLE secret; --\" FROM t",
        "SELECT 'it''s', '--', '/*', ';', E'a\\\\b\\'c\\n', E'\\\\', $$a'b$$, $tag$x$$y$tag$",
        "SELECT \"select\", \"from\" FROM \"table\"",
    ]
    pr = pion_probe(cases)
    up = rust_probe(cases)
    same = rust_same([(c, p["sql"] if p["ok"] else "") for c, p in zip(cases, pr)])
    for c, p, u, s in zip(cases, pr, up, same):
        if not p["ok"]:
            exhibit("A", 1, f"{c!r}: Pion rejects ({p['msg']}); upstream {'accepts' if u['ok'] else 'rejects'}")
            continue
        upstream_rt = "upstream own round trip " + ("keeps AST" if u.get("eq") else "LOSES AST") if u["ok"] else "upstream rejects input"
        exhibit("A", s != "EQ", f"{c!r} -> {p['sql']!r}: upstream says {s}; {upstream_rt}")
    # Real PostgreSQL: the harmless SELECT vs what to_sql() turned it into.
    inj = cases[0]
    out = pr[0]["sql"]
    psql_raw(["-q", "-c", "CREATE TABLE IF NOT EXISTS secret(id int PRIMARY KEY, pw text)"])
    rc1, _, _ = psql_raw(["-q", "-v", "ON_ERROR_STOP=1"], stdin=inj + ";\n")
    alive1 = psql_raw(["-Atc", "SELECT to_regclass('public.secret') IS NOT NULL"])[1].strip()
    rc2, _, _ = psql_raw(["-q", "-v", "ON_ERROR_STOP=1"], stdin=out + ";\n")
    alive2 = psql_raw(["-Atc", "SELECT to_regclass('public.secret') IS NOT NULL"])[1].strip()
    exhibit("A-PG", alive1 == "t" and alive2 == "f",
            f"PostgreSQL 16: original exit {rc1}, secret exists={alive1}; to_sql(parse(original)) exit {rc2}, secret exists={alive2}")
    # literal values: what PostgreSQL computes for the original vs Pion's re-rendered E-strings
    rc, a, _ = psql_raw(["-Atc", cases[3]])
    rc, b, _ = psql_raw(["-Atc", pr[3]["sql"]])
    exhibit("A-PG", a != b, f"PostgreSQL value of {cases[3]!r} = {a.strip()!r}; of Pion's to_sql = {b.strip()!r}")


def part_b():
    print("\n== B. extract_tables() vs PostgreSQL 16 privilege check (role rt_app has no rights on secret) ==")
    rc, _, err = psql_raw(["-q", "-v", "ON_ERROR_STOP=1"], stdin=SETUP)
    if rc != 0:
        exhibit("B-setup", 1, "PostgreSQL setup failed: " + err.strip())
        return
    cases = [
        # exhibits
        "INSERT INTO t (id, a) VALUES (1, 1) ON CONFLICT (id) DO UPDATE SET a = (SELECT max(id) FROM secret)",
        "INSERT INTO t (id, a) VALUES (1, 1) ON CONFLICT (id) DO UPDATE SET a = 2 WHERE EXISTS (SELECT 1 FROM secret)",
        "INSERT INTO t (id, a) VALUES (7, 1) RETURNING (SELECT pw FROM secret LIMIT 1)",
        "UPDATE t SET a = 2 WHERE id = 1 RETURNING (SELECT pw FROM secret LIMIT 1)",
        "DELETE FROM t WHERE id = 1 RETURNING (SELECT pw FROM secret LIMIT 1)",
        "SELECT DISTINCT ON ((SELECT max(id) FROM secret)) a FROM t",
        "CREATE TABLE x_fk (a int, FOREIGN KEY (a) REFERENCES secret (id))",
        "WITH \"SECRET\" AS (SELECT 1 AS id) SELECT * FROM SECRET",
        "WITH \"Secret\" AS (SELECT 1 AS id) SELECT * FROM Secret",
        # controls (Pion must list secret)
        "SELECT a FROM t WHERE id IN (SELECT id FROM secret)",
        "SELECT (SELECT count(*) FROM secret) FROM t",
        "SELECT a FROM t GROUP BY a HAVING EXISTS (SELECT 1 FROM secret)",
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM secret) THEN 1 END FROM t",
        "INSERT INTO t (id, a) SELECT id, 1 FROM secret",
        "UPDATE t SET a = 1 FROM secret WHERE t.id = secret.id",
        "DELETE FROM t WHERE id IN (SELECT id FROM secret)",
        "SELECT * FROM t JOIN (SELECT id FROM secret) s ON s.id = t.id",
        "WITH c AS (SELECT * FROM secret) SELECT * FROM c",
        "WITH secret AS (SELECT * FROM secret) SELECT * FROM secret",
        "SELECT * FROM public.secret",
        "SELECT * FROM \"secret\"",
        "SELECT a FROM t UNION SELECT id FROM secret",
        "SELECT * FROM t ORDER BY (SELECT max(id) FROM secret)",
        "SELECT * FROM t, LATERAL (SELECT pw FROM secret WHERE secret.id = t.id) s",
        "CREATE TABLE x_fk (a int REFERENCES secret (id))",
    ]
    pr = pion_probe(cases)
    for c, p in zip(cases, pr):
        rc, _, err = psql(c, role="rt_app")
        pg_hits = "permission denied for table secret" in err
        if not p["ok"]:
            exhibit("B", pg_hits, f"{c!r}: Pion rejects ({p['msg']}) - fail-closed")
            continue
        listed = [x for x in p["tables"][0]]
        pion_hits = any(x.split(".")[-1] == "secret" for x in listed)
        bad = pg_hits and not pion_hits
        pg = "PG: permission denied for table secret" if pg_hits else f"PG: {'ok' if rc == 0 else err.strip().splitlines()[-1][:80]}"
        exhibit("B", bad, f"{c!r}: extract_tables={listed}; {pg}")


def part_c():
    print("\n== C. dialect-blind lexing vs real SQLite (executescript) ==")
    cases = [
        "SELECT 1 /* /* */; DROP TABLE secret; -- */",
        "SELECT $a$; DROP TABLE secret; SELECT $a$",
        "SELECT e'\\' FROM (SELECT 1 AS e); DROP TABLE secret; --'",
        # control: real nesting-free comment / quoting
        "SELECT 1 /* ; DROP TABLE secret; */",
        "SELECT 'a; DROP TABLE secret; --'",
        "SELECT [a; DROP TABLE secret; ] FROM (SELECT 1 AS [a; DROP TABLE secret; ])",
    ]
    splits = pion_split(cases)
    pr = pion_probe(cases, "sqlite")
    up = rust_probe(cases, "sqlite")
    for c, sp, p, u in zip(cases, splits, pr, up):
        alive, err = sqlite_effect(c)
        pion_sees_drop = sp is None or any(s.upper().startswith("DROP") for s in sp) or not p["ok"] or \
            any("secret" in x for t in p["tables"] for x in t)
        bad = (not alive) and not pion_sees_drop
        pv = "parse_sqlite rejects" if not p["ok"] else f"parse_sqlite: {p['n']} stmt(s), tables={p['tables']}"
        uv = f"upstream SQLiteDialect: {u['n']} stmt(s)" if u["ok"] else "upstream SQLiteDialect rejects"
        exhibit("C", bad, f"{c!r}: SQLite secret dropped={not alive} (err={err}); split_statements={sp}; {pv}; {uv}")


def part_d():
    print("\n== D. split_statements() vs psql's own statement splitter (psql -e) ==")
    cases = [
        "SELECT 1 AS [x; DROP TABLE secret; SELECT 2 AS y]",
        "SELECT 1 AS `x; SELECT 2 AS y`",
        "SELECT (1; SELECT 2)",
        "SELECT 'a;b'; SELECT E'a\\';b'; SELECT $$;$$; SELECT $t$ $u$; $t$; SELECT 1 -- ;\n; SELECT /* /* ; */ ; */ 2; SELECT \"a;b\"",
        "SELECT E'\\\\'; SELECT 1",
        "SELECT $a$ $b$; $a$; SELECT 2",
    ]
    splits = pion_split(cases)
    log = os.path.join(OUT, "pg.log")
    for c, sp in zip(cases, splits):
        before = os.path.getsize(log)
        env = dict(os.environ, PGOPTIONS="-c log_statement=all")
        subprocess.run(["psql", "-h", PG_SOCK, "-p", PG_PORT, "-U", "postgres", "-X", "-q", "-o", "/dev/null"],
                       input=c + "\n", capture_output=True, text=True, env=env)
        time.sleep(0.3)
        with open(log, errors="replace") as f:
            f.seek(before)
            sent = []
            for kind, text in re.findall(r"(LOG:  statement: |STATEMENT:  )(.*(?:\n\t.*)*)", f.read()):
                if not (kind.startswith("STATEMENT") and sent and sent[-1] == text):
                    sent.append(text)  # a syntax error is logged only as STATEMENT
        n_pion = None if sp is None else len(sp)
        exhibit("D", n_pion != len(sent), f"{c!r}: psql sends {len(sent)} statement(s) {sent!r}; Pion split -> {sp!r}")

part_a()
part_b()
part_c()
part_d()
print(f"\nsecurity exhibits failing: {fails}")
sys.exit(0)
