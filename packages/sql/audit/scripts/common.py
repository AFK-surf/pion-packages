"""Shared helpers for the packages/sql red-team scripts (drivers, real PostgreSQL 16, real SQLite)."""
import os
import sqlite3
import subprocess
import tempfile

OUT = os.environ.get("OUT", "/private/tmp/pion-sql-audit")
BIN = os.path.join(OUT, "bin")
RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")
PG_SOCK = os.environ.get("PG_SOCK", OUT)
PG_PORT = os.environ.get("PG_PORT", "55439")

MODES = {
    "native-release": [f"{BIN}/drv"],
    "native-debug": [f"{BIN}/drv_dbg"],
    "wasm32-release": ["node", RT, f"{BIN}/drv.wasm"],
    "wasm32-debug": ["node", RT, f"{BIN}/drv_dbg.wasm"],
}


def hexfile(items):
    f = tempfile.NamedTemporaryFile("w", delete=False, dir=OUT, suffix=".hex")
    f.write("".join(s.encode().hex() + "\n" for s in items))
    f.close()
    return f.name


def unhex(h):
    return bytes.fromhex(h).decode("utf-8", "replace")


def pion(args, mode="native-release"):
    r = subprocess.run(MODES[mode] + args, capture_output=True, text=True)
    return r.stdout.split("\n")


def rust(args):
    r = subprocess.run([f"{BIN}/rust_oracle"] + args, capture_output=True, text=True)
    return r.stdout.split("\n")


def pion_probe(sqls, dialect="postgres", mode="native-release"):
    """-> list of dicts: ok, msg, n, sql, rp, stable, tables (list per stmt), ph."""
    out = pion(["probe", dialect, hexfile(sqls)], mode)
    res = []
    for line in out[: len(sqls)]:
        p = line.split(" ")
        if p[0] != "OK":
            res.append({"ok": False, "msg": line[4:], "raw": line})
            continue
        tables = p[5] if len(p) > 5 else ""
        res.append({
            "ok": True, "n": int(p[1]), "sql": unhex(p[2]), "rp": p[3] == "RP_OK", "stable": p[4] == "1",
            "tables": [t.split("|") if t else [] for t in tables.split(";")],
            "ph": p[6] if len(p) > 6 else "", "raw": line,
        })
    return res


def rust_probe(sqls, dialect="postgres"):
    out = rust(["probe", dialect, hexfile(sqls)])
    res = []
    for line in out[: len(sqls)]:
        p = line.split(" ")
        if p[0] != "OK":
            res.append({"ok": False, "msg": line[4:]})
        else:
            res.append({"ok": True, "n": int(p[1]), "sql": unhex(p[2]), "rp": p[3] == "RP_OK", "eq": p[4] == "1"})
    return res


def rust_same(pairs, dialect="postgres"):
    f = tempfile.NamedTemporaryFile("w", delete=False, dir=OUT, suffix=".hex")
    f.write("".join(a.encode().hex() + " " + b.encode().hex() + "\n" for a, b in pairs))
    f.close()
    return rust(["same", dialect, f.name])[: len(pairs)]


def pion_split(scripts, mode="native-release"):
    out = pion(["split", hexfile(scripts)], mode)
    res = []
    for line in out[: len(scripts)]:
        if line.startswith("OK"):
            body = line[3:]
            res.append([unhex(x) for x in body.split(",")] if body else [])
        else:
            res.append(None)
    return res


def psql(sql, role=None, db="postgres"):
    """Run `sql` in a rolled-back transaction (optionally as `role`). -> (rc, stdout, stderr)."""
    body = "BEGIN;\n" + (f"SET LOCAL ROLE {role};\n" if role else "") + sql + "\n;ROLLBACK;\n"
    r = subprocess.run(
        ["psql", "-h", PG_SOCK, "-p", PG_PORT, "-U", "postgres", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", db],
        input=body, capture_output=True, text=True,
    )
    return r.returncode, r.stdout, r.stderr


def psql_raw(args, stdin=None):
    r = subprocess.run(["psql", "-h", PG_SOCK, "-p", PG_PORT, "-U", "postgres", "-X"] + args,
                       input=stdin, capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def sqlite_effect(script):
    """Execute `script` with sqlite3's own statement splitter on a fresh DB holding table `secret`.
    -> (secret_still_exists, error or None)."""
    con = sqlite3.connect(":memory:")
    con.execute("CREATE TABLE secret(id INTEGER PRIMARY KEY, pw TEXT)")
    con.execute("CREATE TABLE t(id INTEGER PRIMARY KEY, a INT)")
    err = None
    try:
        con.executescript(script)
    except sqlite3.Error as e:
        err = str(e)
    alive = con.execute("SELECT count(*) FROM sqlite_master WHERE name='secret'").fetchone()[0] == 1
    return alive, err
