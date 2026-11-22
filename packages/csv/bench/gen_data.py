#!/usr/bin/env python3
"""Deterministic realistic mixed CSV corpus generator for packages/csv benchmarks."""

import os
import sys


def generate(out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    read_path = os.path.join(out_dir, "mixed_200k.csv")

    cities = [
        "Tokyo", "San Francisco", "New York", "London", "Paris",
        "Berlin", "Shanghai", "Zürich", "São Paulo", "München",
    ]
    depts = [
        "Engineering", "Research & Dev", "Sales, EMEA", "Product \"Core\"",
        "Operations", "Finance", "Security", "Design",
    ]
    notes = [
        "Active account",
        "VIP, priority support",
        "Quoted \"nickname\" inside",
        "Multi-line\naddress note",
        "UTF-8 备注：东京分部",
        "Standard tier 2026",
        "Needs review, Q4",
        "OK",
    ]

    lines = ["id,name,city,department,salary,score,active,note\n"]
    n_rows = 200_000
    for i in range(n_rows):
        city = cities[i % len(cities)]
        dept = depts[(i * 3) % len(depts)]
        note = notes[(i * 7) % len(notes)]
        salary = 65000 + (i * 37) % 140000
        score = f"{(i * 13) % 100}.{(i * 7) % 100:02d}"
        active = "true" if (i % 3 != 0) else "false"
        name = f"User_{i:06d}"

        # RFC 4180 necessary quoting
        def q(s: str) -> str:
            if "," in s or '"' in s or "\n" in s or "\r" in s:
                return '"' + s.replace('"', '""') + '"'
            return s

        lines.append(
            f"{i + 1},{name},{q(city)},{q(dept)},{salary},{score},{active},{q(note)}\n"
        )

    with open(read_path, "w", encoding="utf-8", newline="") as f:
        f.writelines(lines)


if __name__ == "__main__":
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-csv-bench"
    generate(out_dir)
