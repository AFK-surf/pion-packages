#!/usr/bin/env python3
"""Deterministic realistic design-system CSS corpus generator for packages/css benchmarks."""

import sys


def generate_css(blocks: int) -> str:
    parts = [
        "/* Design System Core Stylesheet */\n",
        "@font-face {\n  font-family: \"Inter\";\n  font-weight: 400;\n  src: url(https://cdn.example.com/inter.woff2);\n}\n\n",
    ]
    colors = ["#1a2b3c", "#2d3748", "#4a5568", "#e53e3e", "#3182ce", "#38a169", "#805ad5", "#d69e2e"]
    sizes = ["12px", "14px", "16px", "20px", "24px", "32px", "1.25rem", "1.5rem"]
    displays = ["flex", "grid", "block", "inline-flex"]

    for i in range(blocks):
        c1 = colors[i % len(colors)]
        c2 = colors[(i + 3) % len(colors)]
        sz = sizes[i % len(sizes)]
        disp = displays[i % len(displays)]
        imp = " !important" if (i % 7 == 0) else ""
        parts.append(
            f"/* Component block {i} */\n"
            f".ds-card-{i} > .ds-header-{i}, .ds-panel-{i} .ds-title-{i} {{\n"
            f"  display: {disp};\n"
            f"  color: {c1};\n"
            f"  background-color: {c2};\n"
            f"  font-size: {sz}{imp};\n"
            f"  padding: 12px 16px;\n"
            f"  margin: 8px 12px;\n"
            f"  width: calc(100% - 24px);\n"
            f"  border: 1px solid {c1};\n"
            f"  border-radius: 6px;\n"
            f"  --ds-gap-{i}: 12px;\n"
            f"}}\n\n"
        )
        if i % 4 == 0:
            parts.append(
                f"@media (min-width: 768px) {{\n"
                f"  .ds-card-{i} {{\n"
                f"    padding: 20px 24px;\n"
                f"    gap: 16px;\n"
                f"  }}\n"
                f"}}\n\n"
            )
    return "".join(parts)


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: gen_data.py <out_path> <num_blocks>", file=sys.stderr)
        return 1
    out_path = sys.argv[1]
    blocks = int(sys.argv[2])
    css = generate_css(blocks)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(css)
    return 0


if __name__ == "__main__":
    sys.exit(main())
