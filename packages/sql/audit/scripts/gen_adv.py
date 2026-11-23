#!/usr/bin/env python3
"""Adversarial benchmark inputs for `driver adv` / `rust_oracle adv` (all inside both parsers' common subset,
so the SHA-256-gated stdout digests agree).

usage: gen_adv.py <out dir>
"""
import os
import sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)


def w(name, text):
    with open(os.path.join(out, name), "w") as f:
        f.write(text)
    print(f"{name} {len(text.encode())}")


# A1 long left-deep arithmetic / boolean chains (Pratt loop + every recursive consumer)
w("chain.sql", "".join(
    "SELECT " + " + ".join(f"c{i % 7}" for i in range(400)) + " FROM t WHERE " +
    " OR ".join(f"a = {j}" for j in range(400)) + "\n" for _ in range(200)))
# A2 huge IN lists
w("inlist.sql", "".join("SELECT * FROM t WHERE x IN (" + ", ".join(str(k) for k in range(10000)) + ")\n" for _ in range(20)))
# A3 quote-heavy literals: '' escapes, E'' escapes, dollar quotes, double-quoted identifiers with ""
lit = "SELECT '" + "it''s " * 2000 + "', E'" + "a\\'b\\\\c " * 2000 + "', $q$" + "x;'\"$ " * 2000 + "$q$, \"" + "c\"\"d" * 500 + "\" FROM t\n"
w("quotes.sql", lit * 40)
# A4 rejection path: malformed statements of every kind
bad = ["SELECT FROM WHERE", "SELECT (1", "SELECT 1 +", "INSERT INTO", "UPDATE t SET", "SELECT * FROM t WHERE a IN (",
       "CREATE TABLE t (a", "SELECT CASE WHEN 1", "DELETE FROM", "SELECT 1 1 1 1"]
w("errors.sql", "".join(b + "\n" for _ in range(3000) for b in bad))
# A5 multi-statement script: split_statements / whole-script parse (stays under Pion's fixed 500k-token budget)
stmt = ("INSERT INTO events (id, kind, payload, note) VALUES (1, 'click', $j${\"a\": \"x;y\"}$j$, 'it''s; fine'); "
        "/* block ; comment */ UPDATE events SET kind = 'k;' WHERE id = 2; -- trailing ; comment\n"
        "SELECT \"a;b\", E'\\';' FROM events WHERE note <> ';';\n")
w("script.sql", stmt * 6000)
