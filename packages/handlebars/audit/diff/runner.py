"""Run one engine (Pion probe / Rust oracle / Handlebars.js oracle) over a JSONL case file.

A crash (signal, abort, non-zero exit) or timeout of the batch run falls back to one process per
remaining case, so a single stack overflow is attributed to its case (kind CRASH:<rc> / TIMEOUT)
instead of hiding every later result."""
import json
import os
import subprocess
import tempfile


def _parse(stdout):
    res = {}
    for line in stdout.splitlines():
        if line.startswith("{"):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            res[r["id"]] = r
    return res


def _run(cmd, path, timeout):
    try:
        p = subprocess.run(cmd + [path], capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode("utf-8", "replace")
        return "TIMEOUT", out, ""


def run_engine(cmd, cases, workdir, timeout=120, per_case_timeout=60):
    """cmd: argv prefix; the case file path is appended. Returns {id: result}."""
    os.makedirs(workdir, exist_ok=True)
    path = os.path.join(workdir, "batch.jsonl")
    with open(path, "w", encoding="utf-8") as f:
        for c in cases:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
    rc, out, _ = _run(cmd, path, timeout)
    res = _parse(out)
    if rc == 0 and all(c["id"] in res for c in cases):
        return res
    for c in cases:
        if c["id"] in res:
            continue
        fd, one = tempfile.mkstemp(suffix=".jsonl", dir=workdir)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
        rc1, out1, err1 = _run(cmd, one, per_case_timeout)
        r1 = _parse(out1)
        if c["id"] in r1 and rc1 == 0:
            res[c["id"]] = r1[c["id"]]
        else:
            kind = "TIMEOUT" if rc1 == "TIMEOUT" else "CRASH:%s" % rc1
            res[c["id"]] = {"id": c["id"], "ok": False, "kind": kind, "msg": err1.strip()[-200:]}
        os.unlink(one)
    return res


def show(r):
    if r is None:
        return "MISSING"
    if r["ok"]:
        return repr(r["out"]) if len(r["out"]) < 300 else "<%d bytes>" % len(r["out"])
    return "ERR(%s: %s)" % (r.get("kind", ""), r.get("msg", "")[:90])
