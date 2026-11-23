#!/usr/bin/env python3
"""Generate the red-team differential corpus for packages/cli.

Writes <out>/cases.tsv  (spec \t envhex \t arghex...)   -> probe / rust oracle / go oracle `diff`
       <out>/typed.txt  (one hex string per line)       -> `typed` (get_int / get_int64 / get_double)
       <out>/cases.json (readable copy used by compare.py)
"""
import json, os, sys

E = "é"  # é (2 UTF-8 bytes)
BIG = "\U0001F600"  # 😀 (4 UTF-8 bytes)

CASES = [
    # --- negative numbers vs short flags (P1) ---
    ("basic", {}, ["-5"]), ("basic", {}, ["-3"]), ("basic", {}, ["-3.14"]), ("basic", {}, ["-1e5"]),
    ("basic", {}, ["-.5"]), ("basic", {}, ["-0x10"]), ("basic", {}, ["-a5"]), ("basic", {}, ["--", "-5"]),
    ("basic", {}, ["-foo"]), ("basic", {}, ["x", "-3"]),
    # --- option values that start with '-' / allow_hyphen_values ---
    ("basic", {}, ["--pattern", "-v"]), ("basic", {}, ["--pattern=-v"]), ("basic", {}, ["-p", "-v"]),
    ("basic", {}, ["-p-v"]), ("basic", {}, ["--output", "-v"]), ("basic", {}, ["--output", "--flag"]),
    ("basic", {}, ["-o", "--help"]), ("basic", {}, ["--output", "--"]), ("basic", {}, ["--num", "-5"]),
    ("basic", {}, ["--num", "-x"]), ("basic", {}, ["-n", "-5"]), ("basic", {}, ["-o", "-"]),
    # --- short clusters, UTF-8 ---
    ("basic", {}, ["-" + E]), ("basic", {}, ["-v" + E]), ("basic", {}, ["-x" + E]), ("basic", {}, ["-" + BIG]),
    ("basic", {}, ["-o", E]), ("basic", {}, ["-o" + E]), ("basic", {}, ["-o" + BIG]),
    ("basic", {}, ["-o="]), ("basic", {}, ["-o", ""]), ("basic", {}, ["-o=x"]), ("basic", {}, ["-vh"]),
    ("basic", {}, ["-hv"]), ("basic", {}, ["-ov"]), ("basic", {}, ["-vv"]), ("basic", {}, ["-vvv", "--verbose"]),
    ("basic", {}, ["-ff"]), ("basic", {}, ["-vf5"]),
    # --- long flags & values ---
    ("basic", {}, ["--"]), ("basic", {}, ["--", "a", "--flag"]), ("basic", {}, ["--="]), ("basic", {}, ["--=x"]),
    ("basic", {}, ["--output"]), ("basic", {}, ["--output", "a", "--output", "b"]), ("basic", {}, ["-o", "a", "-o", "b"]),
    ("basic", {}, ["--flag", "--flag"]), ("basic", {}, ["--flag=true"]), ("basic", {}, ["--flag=false"]),
    ("basic", {}, ["--flag=yes"]), ("basic", {}, ["--flag=1"]), ("basic", {}, ["--flag="]),
    ("basic", {}, ["--verbose=3"]), ("basic", {}, ["--verbose=garbage"]), ("basic", {}, ["--help=foo"]),
    ("basic", {}, ["--secret=no"]),
    # --- value_delimiter ---
    ("basic", {}, ["--list", ""]), ("basic", {}, ["--list", "a,"]), ("basic", {}, ["--list", "a,,b"]),
    ("basic", {}, ["--list=a,b", "--list", "c"]), ("basic", {}, ["-l", "x,y"]), ("basic", {}, ["--list", ","]),
    # --- possible values / typos / hidden ---
    ("basic", {}, ["--mode", "fast"]), ("basic", {}, ["--mode", "FAST"]), ("basic", {}, ["--mode", "medium"]),
    ("basic", {}, ["--mode="]), ("basic", {}, ["--mod", "fast"]), ("basic", {}, ["--verbos"]),
    ("basic", {}, ["--outptu", "x"]), ("basic", {}, ["--ouput", "x"]), ("basic", {}, ["--Output", "x"]),
    ("basic", {}, ["--secret"]), ("basic", {}, ["--secre"]), ("basic", {}, ["--" + E + "utput"]),
    ("basic", {}, ["--outpüt"]), ("basic", {}, ["--fla"]), ("basic", {}, ["--x"]),
    # --- misc positionals / help ---
    ("basic", {}, ["-"]), ("basic", {}, ["a", "-", "b"]), ("basic", {}, ["a", "-v", "b"]), ("basic", {}, ["-h"]),
    ("basic", {}, ["--help"]), ("basic", {}, ["-V"]), ("basic", {}, ["--version"]),
    # --- env / defaults / constraints (P1) ---
    ("env", {}, []), ("env", {"APP_NAME": ""}, []), ("env", {"APP_NAME": "n"}, []),
    ("env", {"APP_NAME": "n"}, ["--name", "c"]), ("env", {"APP_NAME": ""}, ["--e", "1"]),
] + [("env", {"APP_COLOR": v}, []) for v in
     ["true", "1", "false", "0", "yes", "no", "on", "off", "invalid", "", "TRUE", "y", "n", "t", "f", "Yes", "oN"]
] + [
    ("env", {"APP_TAGS": "a,b"}, []), ("env", {"APP_TAGS": ""}, []), ("env", {"APP_TAGS": "a,,b"}, []),
    ("env", {"APP_TAGS": "a,b"}, ["--tags", "x"]),
    ("env", {}, ["--a"]), ("env", {}, ["--a", "--b", "q"]), ("env", {}, ["--e", "1"]),
    ("env", {}, ["--c", "--d"]), ("env", {"APP_D": "true"}, ["--c"]), ("env", {"APP_D": "false"}, ["--c"]),
    ("env", {"APP_D": "1"}, []), ("env", {}, ["--color=false"]), ("env", {"APP_COLOR": "true"}, ["--color"]),
    # --- globals / subcommands / help & version scoping ---
    ("sub", {}, []), ("sub", {}, ["run"]), ("sub", {}, ["-v", "run", "-v"]), ("sub", {}, ["run", "-v", "-v"]),
    ("sub", {}, ["--cfg", "a", "run", "--cfg", "b"]), ("sub", {}, ["run", "--x"]),
    ("sub", {}, ["run", "--x", "--cfg", "c"]), ("sub", {}, ["--cfg", "c", "run", "--x"]),
    ("sub", {}, ["deep", "a", "b", "-v", "--z"]), ("sub", {}, ["-v", "deep", "-v", "a", "-v", "b", "-v"]),
    ("sub", {}, ["deep", "a", "b", "--cfg", "k"]),
    ("sub", {}, ["run", "--help"]), ("sub", {}, ["run", "-h"]), ("sub", {}, ["deep", "a", "b", "--help"]),
    ("sub", {}, ["help"]), ("sub", {}, ["help", "run"]), ("sub", {}, ["--version"]), ("sub", {}, ["-V"]),
    ("sub", {}, ["run", "--version"]), ("sub", {}, ["-vV"]),
    ("sub", {}, ["sub"]), ("sub", {}, ["foo", "run"]), ("sub", {}, ["--", "run"]), ("sub", {}, ["rn"]),
    ("sub", {}, ["p1", "rnu"]), ("sub", {}, ["p1", "run"]), ("sub", {}, ["run", "extra"]),
    ("sub", {}, ["deep", "zz"]), ("sub", {}, ["deep"]), ("sub", {}, ["run", "-o"]),
]

TYPED = [
    "0", "-0", "+1", "01", "007", " 1", "1 ", "", "-", "+", "2147483647", "2147483648", "-2147483648",
    "-2147483649", "9223372036854775807", "9223372036854775808", "-9223372036854775808",
    "-9223372036854775809", "0x10", "0o17", "0b11", "1_000", "1e3",
    "1.5", ".5", "5.", "-.5", "1e400", "-1e400", "1e-400", "NaN", "nan", "inf", "-inf", "infinity", "Infinity",
    "0.1", "0.3", "1.7976931348623157e308", "2.2250738585072014e-308", "4.9e-324", "9007199254740993",
    "123456789012345678901234567890", "0.1234567890123456789", "3.141592653589793", "1e23", "8.98846567431158e307",
    "2.5e-8", "1.e5", "1e+5", "1E5", "e5", "1e", "1e+", "0x1p3",
]


def hx(s):
    return s.encode("utf-8").hex()


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "cases.tsv"), "w") as f:
        for spec, env, argv in CASES:
            envs = "\x1f".join(f"{k}={v}" for k, v in env.items())
            f.write("\t".join([spec, hx(envs)] + [hx(a) for a in argv]) + "\n")
    with open(os.path.join(out, "typed.txt"), "w") as f:
        for t in TYPED:
            f.write((hx(t) if t else "") + "\n")
    with open(os.path.join(out, "cases.json"), "w") as f:
        json.dump(CASES, f, ensure_ascii=False)
    print(f"{len(CASES)} parse cases, {len(TYPED)} typed values -> {out}")


main()
