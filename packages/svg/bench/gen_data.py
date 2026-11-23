#!/usr/bin/env python3
"""Deterministic SVG benchmark corpus generator for packages/svg.

Generates:
- W1: 50,000 complex SVG Path `d` strings (Arc, Cubic, Quadratic, Smooth, compact arc flags, concatenated decimals)
- W2/W3: 2,000 multi-group nested Lucide/Heroicons/Material-style SVG icons
"""
import os
import sys


def gen_paths(out_path: str, count: int) -> None:
    templates = [
        "M{a}.{b} -{c}.5L{d} {e}C{a} {e} {d} {a} {f} {b}S{g} -{b} {h} {c}Q{a} {f} {d} {b}T{f} {e}a12.5 8.5 30 01{c} {b}a6 6 0 10-4.5 3.25Z",
        "M0 10A10 10 0 1020 10A10 10 0 100 10ZM{a} {b}h{c}.25v{d}.75h-{c}.25z",
        "m{a} {b}l{c} {d} {e} -{a}c1.5 2.5 3.5-4.5 6.5 1.5s2.5 3.5 5-2q2-4 5 0t5 0a15 10 -15 0112 8z",
        "M1.2.3-4e-1+.5e1H{a}.5V{b}.25C{c} 0 {d} {e} {f} {g}A25 25 0 0150 25L{h} {a}Z",
    ]
    with open(out_path, "w", encoding="utf-8") as f:
        for i in range(count):
            t = templates[i % len(templates)]
            a = (i % 17) + 1
            b = ((i * 3) % 13) + 1
            c = ((i * 7) % 19) + 2
            d = ((i * 5) % 23) + 3
            e = ((i * 11) % 29) + 1
            fv = ((i * 13) % 31) + 4
            g = ((i * 17) % 37) + 2
            h = ((i * 19) % 41) + 5
            f.write(t.format(a=a, b=b, c=c, d=d, e=e, f=fv, g=g, h=h) + "\n")


def gen_icons(out_path: str, count: int) -> None:
    colors = ["#ffffff", "#000000", "#ff0000", "#1a2b3c", "#336699", "#22cc88"]
    with open(out_path, "w", encoding="utf-8") as f:
        for i in range(count):
            if i > 0:
                f.write("\n---SVG---\n")
            c1 = colors[i % len(colors)]
            c2 = colors[(i + 2) % len(colors)]
            tx = (i % 10) + 1
            ty = ((i * 3) % 10) + 1
            rx = (i % 4) + 1
            r = (i % 5) + 3
            cx = (i % 8) + 8
            cy = ((i * 5) % 8) + 8
            icon = (
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                f"<!-- icon #{i} generated for W14-svg benchmark -->\n"
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">\n'
                "  <metadata><source>lucide-style</source></metadata>\n"
                "  <defs><path id=\"clip0\" d=\"M0 0H24V24H0Z\"/></defs>\n"
                "  <g></g>\n"
                f'  <g transform="translate({tx}, {ty})" fill="{c1}" stroke="{c2}">\n'
                f'    <g><rect x="2" y="3" width="12" height="10" rx="{rx}" style="stroke-width: 1.5; fill: {c2}"/></g>\n'
                f'    <g transform="scale(0.5)">\n'
                f'      <circle cx="{cx}" cy="{cy}" r="{r}"/>\n'
                f'      <ellipse cx="12" cy="12" rx="6" ry="3"/>\n'
                f'      <line x1="1" y1="2" x2="22" y2="20"/>\n'
                f'      <polyline points="2,2 8,12 16,6 22,18"/>\n'
                f'      <polygon points="12,2 22,20 2,20"/>\n'
                f'      <path fill="{c1}" d="M 0.5000 -0.2500 L 10.0000 15.0000 C 12.000 18.000 18.000 18.000 20.000 12.000 A 5 5 0 0 1 22 14 Z"/>\n'
                "    </g>\n"
                "  </g>\n"
                "</svg>"
            )
            f.write(icon)


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: gen_data.py <paths_out> <icons_out> [num_paths=50000] [num_icons=2000]", file=sys.stderr)
        return 1
    paths_out = sys.argv[1]
    icons_out = sys.argv[2]
    num_paths = int(sys.argv[3]) if len(sys.argv) > 3 else 50000
    num_icons = int(sys.argv[4]) if len(sys.argv) > 4 else 2000
    os.makedirs(os.path.dirname(os.path.abspath(paths_out)), exist_ok=True)
    os.makedirs(os.path.dirname(os.path.abspath(icons_out)), exist_ok=True)
    gen_paths(paths_out, num_paths)
    gen_icons(icons_out, num_icons)
    return 0


if __name__ == "__main__":
    sys.exit(main())
