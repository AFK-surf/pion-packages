#!/usr/bin/env python3
"""Generate deterministic benchmark corpora for packages/mermaid in output dir."""

import os
import sys


def gen_parse_corpus() -> str:
    diagrams = []

    # 1. Medium flowchart (40 nodes, shapes, subgraphs)
    fc1 = ["flowchart TD"]
    fc1.append("  subgraph sg_in [Ingestion]")
    for i in range(10):
        fc1.append(f"    in{i}[Input {i}] --> proc{i}(Process {i})")
    fc1.append("  end")
    fc1.append("  subgraph sg_out [Storage]")
    for i in range(10):
        fc1.append(f"    proc{i} -->|ok| db{i}[(DB {i})]")
        if i + 1 < 10:
            fc1.append(f"    proc{i} -.-> proc{i+1}")
    fc1.append("  end")
    for i in range(10):
        fc1.append(f"  db{i} ==> out{i}((Sink {i}))")
    diagrams.append("\n".join(fc1))

    # 2. Large flowchart (320 nodes, 480+ edges)
    fc2 = ["flowchart LR"]
    for i in range(320):
        fc2.append(f"  N{i}[Node {i}]")
    for i in range(310):
        fc2.append(f"  N{i} --> N{i+1}")
        if i % 2 == 0 and i + 8 < 320:
            fc2.append(f"  N{i} -->|e{i}| N{i+8}")
        if i % 5 == 0 and i + 15 < 320:
            fc2.append(f"  N{i} -.-> N{i+15}")
    diagrams.append("\n".join(fc2))

    # 3. Sequence diagram (10 participants, 60 messages)
    seq = ["sequenceDiagram"]
    for i in range(10):
        seq.append(f"  participant P{i} as Service {i}")
    for i in range(60):
        a = i % 10
        b = (i + 1 + (i % 3)) % 10
        if a == b:
            b = (a + 1) % 10
        arrow = "->>" if i % 2 == 0 else "-->>"
        seq.append(f"  P{a}{arrow}P{b}: Message {i}")
    diagrams.append("\n".join(seq))

    # 4. State diagram (40 states, 55 transitions)
    st = ["stateDiagram-v2"]
    for i in range(39):
        st.append(f"  S{i} --> S{i+1} : step {i}")
        if i % 3 == 0 and i + 4 < 40:
            st.append(f"  S{i} --> S{i+4} : skip {i}")
    diagrams.append("\n".join(st))

    # 5. Class diagram (30 classes, 40 relations)
    cl = ["classDiagram"]
    for i in range(30):
        cl.append(f"  class C{i} {{")
        cl.append(f"    +int field{i}")
        cl.append(f"    +method{i}()")
        cl.append("  }")
    for i in range(29):
        op = "<|--" if i % 3 == 0 else ("*--" if i % 3 == 1 else "-->")
        cl.append(f"  C{i} {op} C{i+1} : rel{i}")
    diagrams.append("\n".join(cl))

    # 6. ER diagram (25 entities, 30 relations)
    er = ["erDiagram"]
    for i in range(25):
        er.append(f"  ENT_{i} {{")
        er.append(f"    int id PK")
        er.append(f"    string name_{i}")
        er.append("  }")
    for i in range(24):
        rel = "||--o{" if i % 2 == 0 else "|o..|{"
        er.append(f"  ENT_{i} {rel} ENT_{i+1} : has_{i}")
    diagrams.append("\n".join(er))

    return "\n===DIAGRAM===\n".join(diagrams) + "\n"


def gen_layout_graphs() -> str:
    """Format:
    GRAPH <name> <N> <E>
    N <id> <w> <h>
    E <from> <to>
    """
    lines = []
    for n in (50, 200, 500):
        edges = []
        stride = 5 if n == 50 else (10 if n == 200 else 16)
        for i in range(n):
            if i + stride < n:
                edges.append((i, i + stride))
            if i % 3 == 0 and i + stride + 1 < n:
                edges.append((i, i + stride + 1))
            if i % 7 == 0 and i + stride * 2 < n:
                edges.append((i, i + stride * 2))
            # Add deterministic back-edges (cycles) every 23 nodes
            if i >= stride and i % 23 == 0:
                edges.append((i, i - stride))
        lines.append(f"GRAPH g{n} {n} {len(edges)}")
        for i in range(n):
            w = 64 + (i % 5) * 12
            h = 32 + (i % 3) * 6
            lines.append(f"N v{i} {w} {h}")
        for u, v in edges:
            lines.append(f"E v{u} v{v}")
    return "\n".join(lines) + "\n"


def main() -> int:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mermaid-bench-data"
    os.makedirs(out_dir, exist_ok=True)
    p1 = os.path.join(out_dir, "parse_corpus.txt")
    p2 = os.path.join(out_dir, "layout_graphs.txt")
    with open(p1, "w", encoding="utf-8") as f:
        f.write(gen_parse_corpus())
    with open(p2, "w", encoding="utf-8") as f:
        f.write(gen_layout_graphs())
    print(f"generated {p1} ({os.path.getsize(p1)} B) and {p2} ({os.path.getsize(p2)} B)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
