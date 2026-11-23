#!/usr/bin/env python3
"""Run the vendored upstream WPT `webvtt/parsing/cue-text-parsing/dat/*.dat` suite against `packages/webvtt`.

    python3 run_cue_text.py <probe-binary> <work-dir> [--verbose]

Each `#data` block is read exactly like upstream `buildtests.py` (line-wise `unicode-escape` decoding),
wrapped exactly like upstream `common.js` (`WEBVTT\\n\\n00:00.000 --> 00:01.000\\n` + input, UTF-8),
parsed with `probe cuetext` (`parse_lenient` -> `cues[0].parse_payload()`), and the resulting node tree is
serialized in the `test_serializer` layout of `common.js`, then compared byte-for-byte with
`#document-fragment`.

Additionally checks the package's own invariant `plain_text(payload) == nodes_to_plain_text(parse_payload(payload))`
on every case. Exit status 0 only if everything passes.
"""

import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DAT = os.path.join(HERE, "cue-text-parsing", "dat")
PREFIX = "WEBVTT\n\n00:00.000 --> 00:01.000\n"


def load_dat(path):
    """Port of upstream buildtests.py parsing loop (returns list of (input, expected))."""
    tests = []
    inp = ""
    exp = ""
    state = ""
    with open(path, "r", encoding="utf-8") as f:
        while True:
            line = f.readline()
            if not line:
                if state != "":
                    tests.append((inp[:-1], exp[:-1]))
                break
            if line[0] == "#":
                state = line
                if line == "#document-fragment\n":
                    exp += bytes(line, "UTF-8").decode("unicode-escape")
            elif state == "#data\n":
                inp += bytes(line, "UTF-8").decode("unicode-escape")
            elif state == "#errors\n":
                pass
            elif state == "#document-fragment\n":
                if line == "\n":
                    tests.append((inp[:-1], exp[:-1]))
                    inp = ""
                    exp = ""
                    state = ""
                else:
                    exp += bytes(line, "UTF-8").decode("unicode-escape")
            else:
                raise SystemExit("failed to parse %s: %r" % (path, line))
    return tests


def main():
    probe, work = sys.argv[1], sys.argv[2]
    verbose = "--verbose" in sys.argv
    os.makedirs(work, exist_ok=True)
    cases = []
    for name in sorted(os.listdir(DAT)):
        if not name.endswith(".dat"):
            continue
        for i, (inp, exp) in enumerate(load_dat(os.path.join(DAT, name))):
            fn = os.path.join(work, "%s_%03d.vtt" % (name[:-4], i))
            with open(fn, "wb") as f:
                # JS Blob encodes lone surrogates as U+FFFD; none of the vendored inputs contain them.
                f.write((PREFIX + inp).encode("utf-8"))
            cases.append((name, i, inp, exp, fn))
    out = subprocess.run([probe, "cuetext"] + [c[4] for c in cases], check=True, capture_output=True).stdout
    got = {}
    for line in out.decode("utf-8", "replace").splitlines():
        if line.strip():
            j = json.loads(line)
            got[j["file"]] = j
    fails = 0
    inv_fails = 0
    for name, i, inp, exp, fn in cases:
        j = got.get(fn)
        if j is None or not j.get("ok"):
            actual = "<error: %s>" % (j or {}).get("err")
        else:
            actual = j["tree"]
            if j["plain"] != j["tree_plain"]:
                inv_fails += 1
                print("INVARIANT %s#%d input=%r plain=%r tree_plain=%r" % (name, i, inp, j["plain"], j["tree_plain"]))
        ok = actual == exp
        if not ok:
            fails += 1
        if not ok or verbose:
            print("%s %s#%d input=%r" % ("PASS" if ok else "FAIL", name, i, inp))
            if not ok:
                print("    expected: %r" % exp)
                print("    actual:   %r" % actual)
    total = len(cases)
    print("WPT cue-text-parsing: %d pass, %d fail (of %d); plain_text invariant violations: %d"
          % (total - fails, fails, total, inv_fails))
    ok = fails == 0 and inv_fails == 0
    print("RESULT: PASS" if ok else "RESULT: FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
