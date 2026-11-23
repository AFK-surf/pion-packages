#!/usr/bin/env python3
"""Head-to-head SQLite FTS5 (Python sqlite3) baseline for packages/fts."""

import sqlite3
import sys


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write("usage: bench.py <fts5_tsv> <q_fts5> [reps]\n")
        return 2
    corpus_path = sys.argv[1]
    q_path = sys.argv[2]
    reps = int(sys.argv[3]) if len(sys.argv) >= 4 else 1

    with open(corpus_path, "r", encoding="utf-8") as f:
        docs = []
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            tab = line.find("\t")
            if tab > 0:
                docs.append((int(line[:tab]), line[tab + 1 :]))

    with open(q_path, "r", encoding="utf-8") as f:
        queries = [line.rstrip("\n") for line in f if line.rstrip("\n")]

    con = sqlite3.connect(":memory:")
    con.execute(
        "CREATE VIRTUAL TABLE docs USING fts5(body, tokenize=\"unicode61 tokenchars '_'\")"
    )
    with con:
        con.executemany("INSERT INTO docs(rowid, body) VALUES (?, ?)", docs)

    out_lines = []
    total_hits = 0
    sql = "SELECT rowid FROM docs WHERE docs MATCH ? ORDER BY bm25(docs), rowid ASC LIMIT 20"
    for r in range(reps):
        for qi, q in enumerate(queries):
            rows = con.execute(sql, (q,)).fetchall()
            n_hits = len(rows)
            total_hits += n_hits
            if r == 0:
                if n_hits > 0:
                    ids_s = ",".join(str(row[0]) for row in rows)
                    out_lines.append(f"q{qi}:{n_hits} {ids_s}")
                else:
                    out_lines.append(f"q{qi}:0")

    out_lines.append(f"total_hits={total_hits} docs={len(docs)} reps={reps}")
    sys.stdout.write("\n".join(out_lines) + "\n")
    con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
