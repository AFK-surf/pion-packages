"""Shared helpers: batch requests through the Pion probe / feed-rs oracle and parse their dumps."""
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))


def write_requests(path, reqs):
    """reqs: iterable of (id, op, bytes)."""
    with open(path, "w") as f:
        for rid, op, data in reqs:
            if isinstance(data, str):
                data = data.encode("utf-8")
            f.write("%s\t%s\t%s\n" % (rid, op, data.hex()))


def parse_blocks(out):
    blocks, cur = {}, None
    for line in out.decode("utf-8", "replace").split("\n"):
        if line == "@@ end":
            cur = None
            continue
        if line.startswith("@@ "):
            cur = line[3:]
            blocks[cur] = {}
            continue
        if cur is not None and "\t" in line:
            k, v = line.split("\t", 1)
            blocks[cur][k] = v
    return blocks


def run_batch(cmd, req_path, timeout=600):
    """cmd: list (e.g. [probe] or ['node', rt, probe.wasm]). Returns (raw stdout bytes, blocks, returncode)."""
    p = subprocess.run(cmd + ["batch", req_path], capture_output=True, timeout=timeout)
    return p.stdout, parse_blocks(p.stdout), p.returncode, p.stderr
