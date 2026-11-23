#!/usr/bin/env python3
"""Adversarial benchmark inputs for packages/cron (usage: gen_bench.py <out_dir>).

One case per line: opts<TAB>expr. Every file is only used with implementations that agree on its
semantics (the runner checks stdout SHA-256 equality before timing).
"""
import os
import sys

FILES = {
    # Pion vs croner 2.1.0 vs Quartz 2.3.2: Quartz day features all three implement identically.
    "b_quartz3.txt": [
        "0 0 0 L * ?", "0 0 0 15W * ?", "0 30 9 ? * FRI#3", "0 0 18 ? * FRIL", "0 15 10 ? * MON-FRI",
        "0 0/5 14,18 * * ?", "0 0 12 ? * SUN#1", "0 0 0 ? * SATL",
    ],
    # Pion vs Quartz only (croner has no LW / L-n / year field)
    "b_quartz_ext.txt": [
        "0 0 0 LW * ?", "0 0 0 L-3 * ?", "0 0 9 L-1 * ?", "0 0 0 LW 2 ?", "0 0 12 L-15 * ?",
    ],
    "b_years.txt": [
        "0 0 12 1 * ? 2024-2120", "0 0 0 29 2 ? 2024-2120", "0 30 6 ? * MON 2024-2120/3",
        "0 0 0 1 1 ? 2024,2030,2040,2050,2060,2070,2080,2090,2100,2110,2120",
        "0 0 0 ? * FRI#5 2024-2120",
    ],
    # F4 DoS: impossible date + a 157-item year list (every Quartz-legal year 1970..2126).
    "b_yearlist_dos.txt": [
        "0 0 0 31 2,4,6,9,11 ? " + ",".join(str(y) for y in range(1970, 2127)),
    ],
    # Malformed input every implementation rejects (opts std, fed to Pion/croner/robfig)
    "b_invalid.txt": [
        "0-59/99999999999999999999 * * * *", "*/0 * * * *", "60 * * * *", "0 24 * * *", "0 0 0 * *",
        "0 0 32 * *", "0 0 * 0 *", "0 0 * 13 *", "0 0 * * 8", "-1 * * * *", "1- * * * *",
        "1-2-3 * * * *", "1//2 * * * *", "* * * * * * * *", "1.0 * * * *", "0x1 * * * *", "@reboot",
        "@daily x", "0 0 1 1", "", "a b c d e",
    ],
    # Long explicit lists (opts std)
    "b_longlist.txt": [
        " ".join([",".join(map(str, range(60))), ",".join(map(str, range(24))),
                  ",".join(map(str, range(1, 32))), ",".join(map(str, range(1, 13))),
                  ",".join(map(str, range(7)))]),
        ",".join(["7"] * 1000) + " * * * *",
        " ".join([",".join("%d-%d" % (i, i) for i in range(60)), "*/1", "1-31/1", "*", "*"]),
    ],
}
OPTS = {"b_invalid.txt": "std", "b_longlist.txt": "std"}


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name, exprs in FILES.items():
        opt = OPTS.get(name, "q")
        with open(os.path.join(out, name), "w") as f:
            for e in exprs:
                f.write("%s\t%s\n" % (opt, e if e else " "))
    print("bench inputs -> %s" % out)


if __name__ == "__main__":
    main()
