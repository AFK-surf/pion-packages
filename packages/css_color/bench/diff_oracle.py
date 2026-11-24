#!/usr/bin/env python3
"""Differential accuracy comparator: Pion `packages/css_color` vs Rust Linebender `color 0.3.3`."""
import sys

def load_records(path):
    p_recs, m_recs, g_recs = {}, {}, {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split("|")
            tag = parts[0]
            idx = int(parts[1])
            if tag == "P":
                p_recs[idx] = ([float(x) for x in parts[2:12]], [int(x) for x in parts[12:16]])
            elif tag == "M":
                m_recs[idx] = ([float(x) for x in parts[2:6]], [int(x) for x in parts[6:10]])
            elif tag == "G":
                g_recs[idx] = (int(parts[2]), float(parts[3]), float(parts[4]), [float(x) for x in parts[5:8]])
    return p_recs, m_recs, g_recs

def hue_diff(h1, h2):
    d = abs(h1 - h2) % 360.0
    return min(d, 360.0 - d)

def main():
    pion_path, rust_path = sys.argv[1], sys.argv[2]
    pp, pm, pg = load_records(pion_path)
    rp, rm, _ = load_records(rust_path)

    assert len(pp) == len(rp) and len(pp) >= 2000, f"parse count mismatch: {len(pp)} vs {len(rp)}"
    assert len(pm) == len(rm) and len(pm) >= 300, f"mix count mismatch: {len(pm)} vs {len(rm)}"

    max_float_err = 0.0
    max_lsb_err = 0
    exact_u8 = 0
    le1_u8 = 0
    total_u8 = 0
    worst_parse = None

    for idx in sorted(pp.keys()):
        pf, pu = pp[idx]
        rf, ru = rp[idx]
        for k in range(len(pf)):
            d = abs(pf[k] - rf[k])
            if d > max_float_err:
                max_float_err = d
                worst_parse = (idx, k, pf[k], rf[k])
        for k in range(4):
            d = abs(pu[k] - ru[k])
            total_u8 += 1
            if d > max_lsb_err:
                max_lsb_err = d
            if d == 0:
                exact_u8 += 1
            if d <= 1:
                le1_u8 += 1

    max_mix_err = 0.0
    max_mix_lsb = 0
    worst_mix = None
    for idx in sorted(pm.keys()):
        pf, pu = pm[idx]
        rf, ru = rm[idx]
        for k in range(4):
            d = abs(pf[k] - rf[k])
            if d > max_mix_err:
                max_mix_err = d
                worst_mix = (idx, k, pf[k], rf[k])
            dl = abs(pu[k] - ru[k])
            if dl > max_mix_lsb:
                max_mix_lsb = dl

    gamut_ok = 0
    max_hue_shift = 0.0
    for idx, (in_g, h0, h1, rgb) in pg.items():
        if in_g == 1 and all(-1e-6 <= v <= 1.0 + 1e-6 for v in rgb):
            gamut_ok += 1
        hd = hue_diff(h0, h1)
        if hd > max_hue_shift:
            max_hue_shift = hd

    total_cases = len(pp) + len(pm) + len(pg)
    print(f"Differential Oracle Summary ({total_cases} total cases vs Rust Linebender color 0.3.3):")
    print(f"  Parse + Space Convert ({len(pp)} cases): max_float_err={max_float_err:.7f}, max_u8_err={max_lsb_err} LSB, exact={exact_u8*100.0/total_u8:.2f}%, <=1LSB={le1_u8*100.0/total_u8:.4f}%")
    if worst_parse:
        print(f"    worst parse channel: idx={worst_parse[0]} ch={worst_parse[1]} pion={worst_parse[2]:.6f} rust={worst_parse[3]:.6f}")
    print(f"  color-mix() ({len(pm)} cases, 14 spaces + 4 hue modes): max_float_err={max_mix_err:.7f}, max_u8_err={max_mix_lsb} LSB")
    if worst_mix:
        print(f"    worst mix channel: idx={worst_mix[0]} ch={worst_mix[1]} pion={worst_mix[2]:.6f} rust={worst_mix[3]:.6f}")
    print(f"  Oklch Gamut Mapping ({len(pg)} wide-gamut cases): in_gamut={gamut_ok}/{len(pg)} (100.0%), max_hue_shift={max_hue_shift:.2f} deg")

    assert max_float_err < 1e-4, f"parse/convert float err {max_float_err} >= 1e-4"
    assert max_lsb_err <= 1, f"parse/convert u8 err {max_lsb_err} > 1 LSB"
    assert max_mix_err < 1e-4, f"color-mix float err {max_mix_err} >= 1e-4"
    assert max_mix_lsb <= 1, f"color-mix u8 err {max_mix_lsb} > 1 LSB"
    assert gamut_ok == len(pg), f"gamut mapping failed on {len(pg) - gamut_ok} cases"
    print("PASS: all differential accuracy gates satisfied!")

if __name__ == "__main__":
    main()
