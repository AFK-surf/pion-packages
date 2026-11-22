#!/usr/bin/env python3
"""Deterministic adversarial corpora for the csv red-team benchmarks.

  python3 gen_adversarial.py OUTDIR
writes
  heavy_quote.csv   200k rows x 8 fields, every field quoted and full of doubled quotes ("")
  wide_1000.csv     3,000 rows x 1,000 narrow columns
  trim_comment.csv  200k rows of space-padded fields + a '#' comment line every 3rd line (Trim::All + comment)
  semicolon.csv     1M rows of mixed data delimited with ';' (European CSV, decimal comma)
  escape.csv        400k rows of backslash-escaped quoted fields (escape '\\', double_quote = false)
  narrow.csv        2M rows x 10 one-byte fields (read_all memory amplification)
  many_rows.csv     10,000,001 one-byte rows (default Limits::max_records probe, not timed)
"""
import os
import sys


def q(s, d=","):
    if d in s or '"' in s or "\n" in s or "\r" in s:
        return '"' + s.replace('"', '""') + '"'
    return s


def main(out):
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "heavy_quote.csv"), "w", newline="") as f:
        f.write(",".join('"h%d"' % i for i in range(8)) + "\n")
        for i in range(200_000):
            row = []
            for j in range(8):
                s = 'say ""hi"" #%d ""%d"" ""x""' % (i, j)
                row.append('"' + s + '"')
            f.write(",".join(row) + "\n")
    with open(os.path.join(out, "wide_1000.csv"), "w", newline="") as f:
        f.write(",".join("c%d" % i for i in range(1000)) + "\n")
        for i in range(20000):
            f.write(",".join(str((i * 7 + j) % 100) for j in range(1000)) + "\n")
    with open(os.path.join(out, "trim_comment.csv"), "w", newline="") as f:
        f.write("  id , name , city , score \n")
        for i in range(1_000_000):
            if i % 3 == 0:
                f.write("# generated comment line %d, with, commas\n" % i)
            f.write("  %d ,  User_%06d  , \t Zürich \t,  %d.%02d  \n" % (i, i, i % 97, i % 100))
    cities = ["Tokyo", "San Francisco", "New York", "Zürich", "São Paulo"]
    notes = ["Active; account", "VIP, priority", 'Quoted "nick"', "Multi-line\nnote", "UTF-8 备注", "OK"]
    with open(os.path.join(out, "semicolon.csv"), "w", newline="") as f:
        f.write("id;name;city;salary;score;note\n")
        for i in range(1_000_000):
            row = [str(i + 1), "User_%06d" % i, cities[i % 5], str(65000 + (i * 37) % 140000),
                   "%d,%02d" % ((i * 13) % 100, (i * 7) % 100), notes[(i * 7) % 6]]
            f.write(";".join(q(x, ";") for x in row) + "\n")
    with open(os.path.join(out, "escape.csv"), "w", newline="") as f:
        f.write("a,b,c,d\n")
        for i in range(400_000):
            f.write('"say \\"hi\\" %d","x\\\\y","plain %d","\\"q\\", more"\n' % (i, i))
    with open(os.path.join(out, "narrow.csv"), "w", newline="") as f:
        f.write("a,b,c,d,e,f,g,h,i,j\n")
        f.write("1,2,3,4,5,6,7,8,9,0\n" * 2_000_000)
    with open(os.path.join(out, "many_rows.csv"), "w", newline="") as f:
        f.write("a\n" * 10_000_001)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-csv-audit/data")
