#!/usr/bin/env python3
"""Generate deterministic CSS Color 4/5 corpus for differential testing and benchmarks."""
import os
import random
import sys

NAMED_149 = [
    "transparent", "aliceblue", "antiquewhite", "aqua", "aquamarine", "azure",
    "beige", "bisque", "black", "blanchedalmond", "blue", "blueviolet", "brown",
    "burlywood", "cadetblue", "chartreuse", "chocolate", "coral", "cornflowerblue",
    "cornsilk", "crimson", "cyan", "darkblue", "darkcyan", "darkgoldenrod",
    "darkgray", "darkgreen", "darkgrey", "darkkhaki", "darkmagenta", "darkolivegreen",
    "darkorange", "darkorchid", "darkred", "darksalmon", "darkseagreen",
    "darkslateblue", "darkslategray", "darkslategrey", "darkturquoise", "darkviolet",
    "deeppink", "deepskyblue", "dimgray", "dimgrey", "dodgerblue", "firebrick",
    "floralwhite", "forestgreen", "fuchsia", "gainsboro", "ghostwhite", "gold",
    "goldenrod", "gray", "green", "greenyellow", "grey", "honeydew", "hotpink",
    "indianred", "indigo", "ivory", "khaki", "lavender", "lavenderblush",
    "lawngreen", "lemonchiffon", "lightblue", "lightcoral", "lightcyan",
    "lightgoldenrodyellow", "lightgray", "lightgreen", "lightgrey", "lightpink",
    "lightsalmon", "lightseagreen", "lightskyblue", "lightslategray", "lightslategrey",
    "lightsteelblue", "lightyellow", "lime", "limegreen", "linen", "magenta",
    "maroon", "mediumaquamarine", "mediumblue", "mediumorchid", "mediumpurple",
    "mediumseagreen", "mediumslateblue", "mediumspringgreen", "mediumturquoise",
    "mediumvioletred", "midnightblue", "mintcream", "mistyrose", "moccasin",
    "navajowhite", "navy", "oldlace", "olive", "olivedrab", "orange", "orangered",
    "orchid", "palegoldenrod", "palegreen", "paleturquoise", "palevioletred",
    "papayawhip", "peachpuff", "peru", "pink", "plum", "powderblue", "purple",
    "rebeccapurple", "red", "rosybrown", "royalblue", "saddlebrown", "salmon",
    "sandybrown", "seagreen", "seashell", "sienna", "silver", "skyblue", "slateblue",
    "slategray", "slategrey", "snow", "springgreen", "steelblue", "tan", "teal",
    "thistle", "tomato", "turquoise", "violet", "wheat", "white", "whitesmoke",
    "yellow", "yellowgreen",
]

def main():
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    rng = random.Random(20261124)

    parse_cases = []
    # 1. Named colors + transparent (exclude 7 *grey aliases unsupported by Linebender color 0.3.3;
    #    all 148 + transparent are tested in css_color_test.pion)
    parse_cases.extend([c for c in NAMED_149 if "grey" not in c])

    # 2. Hex #RGB, #RGBA, #RRGGBB, #RRGGBBAA (200)
    for _ in range(50):
        parse_cases.append(f"#{rng.randrange(16):x}{rng.randrange(16):x}{rng.randrange(16):x}")
        parse_cases.append(f"#{rng.randrange(16):x}{rng.randrange(16):x}{rng.randrange(16):x}{rng.randrange(16):x}")
        parse_cases.append(f"#{rng.randrange(256):02x}{rng.randrange(256):02x}{rng.randrange(256):02x}")
        parse_cases.append(f"#{rng.randrange(256):02x}{rng.randrange(256):02x}{rng.randrange(256):02x}{rng.randrange(256):02x}")

    # 3. rgb() / rgba() legacy & modern (260)
    for _ in range(65):
        r, g, b = rng.randint(0, 255), rng.randint(0, 255), rng.randint(0, 255)
        a = round(rng.random(), 3)
        parse_cases.append(f"rgb({r}, {g}, {b})")
        parse_cases.append(f"rgba({r}, {g}, {b}, {a})")
        parse_cases.append(f"rgb({r} {g} {b} / {a})")
        parse_cases.append(f"rgb({round(r*100/255,1)}% {round(g*100/255,1)}% {round(b*100/255,1)}% / {round(a*100,1)}%)")

    # 4. hsl() / hsla() with deg/rad/grad/turn (240)
    for _ in range(60):
        h = round(rng.uniform(-360, 720), 2)
        s = round(rng.uniform(0, 100), 2)
        l = round(rng.uniform(0, 100), 2)
        a = round(rng.random(), 3)
        parse_cases.append(f"hsl({h}, {s}%, {l}%)")
        parse_cases.append(f"hsla({h}deg, {s}%, {l}%, {a})")
        parse_cases.append(f"hsl({round(h/360.0, 4)}turn {s}% {l}% / {a})")
        parse_cases.append(f"hsl({round(h*10.0/9.0, 2)}grad {s}% {l}%)")

    # 5. hwb() (150)
    for _ in range(150):
        h = round(rng.uniform(0, 360), 2)
        w = round(rng.uniform(0, 80), 2)
        b = round(rng.uniform(0, 80), 2)
        a = round(rng.random(), 3)
        parse_cases.append(f"hwb({h} {w}% {b}% / {a})")

    # 6. lab() & lch() (300)
    for _ in range(150):
        l = round(rng.uniform(5, 95), 2)
        a = round(rng.uniform(-80, 80), 2)
        b = round(rng.uniform(-80, 80), 2)
        al = round(rng.random(), 3)
        parse_cases.append(f"lab({l}% {a} {b} / {al})")
        c = round(rng.uniform(0, 110), 2)
        h = round(rng.uniform(0, 360), 2)
        parse_cases.append(f"lch({l}% {c} {h} / {al})")

    # 7. oklab() & oklch() (300)
    for _ in range(150):
        l = round(rng.uniform(0.1, 0.95), 4)
        a = round(rng.uniform(-0.25, 0.25), 4)
        b = round(rng.uniform(-0.25, 0.25), 4)
        al = round(rng.random(), 3)
        parse_cases.append(f"oklab({l} {a} {b} / {al})")
        c = round(rng.uniform(0.0, 0.25), 4)
        h = round(rng.uniform(0.0, 360.0), 2)
        parse_cases.append(f"oklch({l} {c} {h} / {al})")

    # 8. color() across all 9 predefined spaces (450)
    color_spaces = [
        "srgb", "srgb-linear", "display-p3", "a98-rgb",
        "prophoto-rgb", "rec2020", "xyz", "xyz-d50", "xyz-d65",
    ]
    for sp in color_spaces:
        for _ in range(50):
            c0 = round(rng.uniform(0.02, 0.98), 4)
            c1 = round(rng.uniform(0.02, 0.98), 4)
            c2 = round(rng.uniform(0.02, 0.98), 4)
            al = round(rng.random(), 3)
            parse_cases.append(f"color({sp} {c0} {c1} {c2} / {al})")

    # 9. color-mix() corpus (360 cases: rectangular + polar with 4 hue modes + alpha scaling)
    mix_cases = []
    rect_spaces = ["srgb", "srgb-linear", "display-p3", "a98-rgb", "prophoto-rgb", "rec2020", "lab", "oklab", "xyz-d50", "xyz-d65"]
    polar_spaces = ["hsl", "hwb", "lch", "oklch"]
    hue_modes = ["shorter", "longer", "increasing", "decreasing"]
    base_colors = [
        "rgb(240 40 30 / 1)", "rgb(20 120 240 / 0.8)", "rgb(40 210 90 / 0.6)",
        "rgb(230 190 20 / 0.9)", "rgb(180 50 220 / 0.7)", "rgb(30 190 200 / 1)",
        "oklch(0.65 0.18 35 / 0.85)", "oklch(0.72 0.14 250 / 0.95)",
        "color(display-p3 0.9 0.2 0.1 / 0.75)", "hsl(30 90% 50% / 1)", "hsl(330 90% 50% / 1)",
    ]
    for sp in rect_spaces:
        for _ in range(20):
            c1 = rng.choice(base_colors)
            c2 = rng.choice(base_colors)
            p1 = round(rng.uniform(10.0, 90.0), 1)
            p2 = round(rng.uniform(10.0, 90.0), 1)
            expr = f"color-mix(in {sp}, {c1} {p1}%, {c2} {p2}%)"
            mix_cases.append(f"{sp}|shorter|{c1}|{p1}|{c2}|{p2}|{expr}")
    for sp in polar_spaces:
        for hm in hue_modes:
            for _ in range(10):
                c1 = rng.choice(base_colors)
                c2 = rng.choice(base_colors)
                p1 = round(rng.uniform(15.0, 85.0), 1)
                p2 = round(rng.uniform(15.0, 85.0), 1)
                expr = f"color-mix(in {sp} {hm} hue, {c1} {p1}%, {c2} {p2}%)"
                mix_cases.append(f"{sp}|{hm}|{c1}|{p1}|{c2}|{p2}|{expr}")

    # 10. Wide-gamut corpus for gamut mapping (160 cases)
    gamut_cases = []
    for i in range(160):
        l = round(rng.uniform(0.15, 0.92), 4)
        c = round(rng.uniform(0.18, 0.40), 4)
        h = round((i * 2.25) % 360.0, 2)
        gamut_cases.append(f"oklch({l} {c} {h})")

    parse_path = os.path.join(out_dir, "parse_corpus.txt")
    mix_path = os.path.join(out_dir, "mix_corpus.txt")
    gamut_path = os.path.join(out_dir, "gamut_corpus.txt")

    with open(parse_path, "w", encoding="utf-8") as f:
        for line in parse_cases:
            f.write(line + "\n")
    with open(mix_path, "w", encoding="utf-8") as f:
        for line in mix_cases:
            f.write(line + "\n")
    with open(gamut_path, "w", encoding="utf-8") as f:
        for line in gamut_cases:
            f.write(line + "\n")

    print(f"{len(parse_cases)} {len(mix_cases)} {len(gamut_cases)}")

if __name__ == "__main__":
    main()
