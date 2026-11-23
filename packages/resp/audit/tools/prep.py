#!/usr/bin/env python3
"""Convert human-readable audit case tables (cases/*.tsv) into `id<TAB>hex` files for the probes.

Inputs use Python bytes-literal escapes (\\r \\n \\t \\xHH \\\\). Usage: prep.py <cases.tsv> <out.hex.tsv>
"""
import ast
import sys


def unescape(s: str) -> bytes:
    # Python bytes literal semantics; tabs in the TSV can never appear raw, so `\t` is an escape.
    return ast.literal_eval("b'" + s.replace("'", "\\'") + "'")


def rows(path):
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            yield line.split("\t")


def random_keys(dst: str, n: int = 20000) -> None:
    """Deterministic key corpus biased towards `{`/`}` hash-tag edge cases and high bytes."""
    state = 0x2545F491
    alphabet = b"{}{}ab:\x00\xff\x80xyz019"
    with open(dst, "w", encoding="ascii") as out:
        for i in range(n):
            state = (state * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
            length = (state >> 33) % 24
            key = bytearray()
            for _ in range(length):
                state = (state * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
                key.append(alphabet[(state >> 40) % len(alphabet)])
            out.write("r%05d\t%s\n" % (i, key.hex()))


def main() -> None:
    if sys.argv[1] == "--random-keys":
        random_keys(sys.argv[2])
        return
    src, dst = sys.argv[1], sys.argv[2]
    with open(dst, "w", encoding="ascii") as out:
        for cols in rows(src):
            # decode/inline/redirect/slots: id, finding, input, expect ; keys: id, input
            data = cols[1] if len(cols) == 2 else cols[2]
            out.write(cols[0] + "\t" + unescape(data).hex() + "\n")


if __name__ == "__main__":
    main()
