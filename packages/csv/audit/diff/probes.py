#!/usr/bin/env python3
"""Hand-written adversarial probes (the attack list of the audit brief), Pion vs Rust csv =1.4.0.

  python3 probes.py            prints every probe with both outputs and SAME / DIFF
Each probe carries the REPORT.md id it is evidence for ("-" = parity control).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import caseio  # noqa: E402

BOM = b"\xef\xbb\xbf"
READ = [
    # id, cfg, input
    ("-", {}, b'a"b,c\n'),
    ("-", {}, b'"abc"def,g\n'),
    ("-", {}, b'foo "bar" baz,x\n'),
    ("-", {}, b'"a"b"c",d\n'),
    ("-", {}, b'"",""\n""""\n'),
    ("-", dict(dq=0), b'"a""b",c\n'),
    ("-", dict(esc=92), b'"a\\"b""c",d\n'),
    ("-", dict(esc=92, dq=0), b'"a\\"b""c",d\n'),
    ("-", dict(esc=92), b'"a\\'),
    ("-", dict(esc=92), b'a\\,b\\\n'),
    ("-", dict(esc=92), b'"a\\\nb",c\n'),
    ("-", dict(quoting=0), b'"a,b",c\n'),
    ("-", dict(trim=3), b' "hello" ,x\n'),
    ("-", dict(trim=3), b'" hello ",\t y \t\n'),
    ("D1", dict(trim=3, cmt=35), b'  #not a comment\n# comment\n a , b \n'),
    ("F6", dict(trim=3), "\x0ba\x0b, b ,　c　,\u0085d \n".encode()),
    ("D4", dict(trim=2), b' a , b \n c , d \n'),
    ("D3", dict(cmt=35), b'#c\rx,y\nz\n'),
    ("D3", dict(cmt=35), b'#'),
    ("D3", dict(cmt=35, term=0x1E), b'#x\x1ea\nb\x1ec\x1e'),
    ("D1", dict(cmt=35), b' #x\n#y\na#b,c\n"#q",z\n"a\n#b",c\n'),
    ("D2", dict(term=-2), b'a\rb\nc\n'),
    ("-", dict(term=0x1E), b'a,b\x1ec\nd,e\x1e\x1e'),
    ("D1", dict(term=13), b'a\r\nb\r'),
    ("F1", dict(hdr=0), b'\xff,b\na,b\n'),
    ("-", dict(hdr=1, flex=0), b'\xff,b\na,b\nc,d\n'),
    ("F9", dict(hdr=1, flex=0), b'\xff,b\nx\n'),
    ("D7", dict(hdr=0, flex=0), b'a,b\n\xff\n'),
    ("-", dict(hdr=0, flex=0), b'a,b\nc\nd,e\n'),
    ("-", {}, b'x,y\n' + b'ok,' + b'abc\xf4\x90\x80\x80' + b'\n'),
    ("-", {}, b'x,y\n' + b'ok,' + b'abcd\xe0\x80\xaf' + b'\n'),
    ("-", {}, b'x,y\n' + b'ok,a\xed\xbf\xbf\n'),
    ("-", {}, b'x,y\n' + b'ok,ab\x80\n'),
    ("-", {}, b'x,y\n' + b'ok,abcde\xf0\x9f\x98'),
    ("-", {}, b'a,b\nc,\xc0\xaf\n'),
    ("-", {}, BOM),
    ("D1", {}, BOM + b'"a",b\n'),
    ("D1", dict(hdr=1), BOM + b'"a",b\n1,2\n'),
    ("-", {}, b'a' + BOM + b',b\n'),
    ("D1", dict(cmt=35), b'"a"\r\n"b\r\nc"\r\n\r\n#x\r\nd\re\n'),
    ("D1", {}, b'a\n\n\nb\n'),
    ("F5", dict(term=0x1E), b'"abc\ndefghijk"\x1ec\x1e'),
]
WRITE = [
    ("F4", {}, [[b"a"], [], [b"b"]]),
    ("F8", dict(style=3), [[b"x"], [b""]]),
    ("F7", dict(style=2), [[b"NaN", b"inf", b"-inf", b"Infinity", b"1e5", b"-0.5", b".5", b"5.", b"+7", b"0x10", b"", b" 123"]]),
    ("-", dict(style=3), [[b"a,b", b"c\nd"]]),
    ("-", dict(style=1), [[b"", b"1"], [b""]]),
    ("-", dict(cmt=35), [[b"a#b", b"#"], [b"#x"]]),
    ("-", dict(dq=0), [[b'a"b\\c']]),
    ("-", dict(dq=0, esc=39), [[b"a\"b'c"]]),
    ("-", dict(term=0x1E), [[b"a\nb", b"c\x1ed"]]),
    ("-", dict(term=-2), [[b"a\rb"]]),
    ("-", dict(style=2, delim=46), [[b"1.5", b"x"]]),
]


def main():
    rl = [caseio.read_line("r%d" % i, caseio.cfg(**c), d) for i, (_, c, d) in enumerate(READ)]
    valid = {}
    for i, (_, c, d) in enumerate(READ):
        try:
            d.decode("utf-8")
            valid["r%d" % i] = True
        except UnicodeDecodeError:
            valid["r%d" % i] = False
    rr = caseio.rust(rl)
    pb = caseio.pion("read-bytes", rl)
    ps = caseio.pion("read-string", [ln for ln in rl if valid[ln.split()[0]]])
    ndiff = 0
    for i, (pid, c, d) in enumerate(READ):
        k = "r%d" % i
        same = rr[k] == pb[k] and (k not in ps or ps[k] == pb[k])
        ndiff += not same
        print("[%s] %-4s %s  input=%r" % ("SAME" if same else "DIFF", pid, caseio.describe(caseio.cfg(**c)), d))
        if not same:
            print("        rust        %s" % " | ".join(caseio.pretty(rr[k])))
            print("        pion bytes  %s" % " | ".join(caseio.pretty(pb[k])))
            if k in ps and ps[k] != pb[k]:
                print("        pion string %s" % " | ".join(caseio.pretty(ps[k])))
    wl = [caseio.write_line("w%d" % i, caseio.cfg(**c), recs) for i, (_, c, recs) in enumerate(WRITE)]
    wr = caseio.rust(wl)
    wp = caseio.pion("write", wl)
    for i, (pid, c, recs) in enumerate(WRITE):
        k = "w%d" % i
        same = wr[k] == wp[k]
        ndiff += not same
        print("[%s] %-4s writer %s  records=%r" % ("SAME" if same else "DIFF", pid, caseio.describe(caseio.cfg(**c)), recs))
        print("        rust  %s" % " | ".join(caseio.pretty(wr[k])))
        if not same:
            print("        pion  %s" % " | ".join(caseio.pretty(wp[k])))
    print("probes: %d read + %d write, %d differ" % (len(READ), len(WRITE), ndiff))


if __name__ == "__main__":
    main()
