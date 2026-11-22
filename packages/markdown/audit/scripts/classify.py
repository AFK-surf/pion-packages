#!/usr/bin/env python3
"""Cluster minimized divergences (min.json) into root-cause classes. usage: classify.py <min.json> [--show CLASS]"""
import json, sys, collections


def classes(r):
    s, R, P, E = r["src"], r["rust"], r["pion_direct"], r["pion_events"]
    out = []
    if P != E or r["pion_to_html"] != r["pion_render_html_parse"]:
        out.append("PATHS_DIVERGE(direct!=parse)")
    if P == R:
        return out or ["events_only"]
    if not s.endswith("\n") and (P.replace("\n</code>", "</code>") == R or P[:-1] == R or P == R + "\n"):
        return out + ["parity:eof_without_newline(pion=cmark)"]
    if (r["mask"] & 16) and set(P) ^ set(R) <= set("“”‘’") and len(P) == len(R):
        return out + ["smart_quote_direction"]
    if "~" in s and ("<del>" in P) != ("<del>" in R) or P.count("<del>") != R.count("<del>"):
        return out + ["strikethrough_rules"]
    if "|" in s and (("<table>" in P) != ("<table>" in R) or P.count("<tr>") != R.count("<tr>") or P.count("<td") != R.count("<td")):
        return out + ["table_structure"]
    if "|" in s and "<table>" in P:
        return out + ["table_cell_content"]
    if "[" in s and "checkbox" in (P + R):
        return out + ["tasklist_marker"]
    if P.replace("<li>\n<", "<li><") == R.replace("<li>\n<", "<li><"):
        return out + ["pulldown_fmt:li_newline_before_block"]
    if "\t" in s:
        return out + ["tab_handling"]
    if "\r" in s:
        return out + ["cr_handling"]
    return out + ["other"]


def main():
    data = json.load(open(sys.argv[1]))
    show = sys.argv[sys.argv.index("--show") + 1] if "--show" in sys.argv else None
    cnt = collections.Counter()
    ex = collections.defaultdict(list)
    for r in data:
        for c in classes(r):
            cnt[c] += 1
            ex[c].append(r)
    for c, n in cnt.most_common():
        print(f"{n:5d}  {c}")
        for r in ex[c][: (60 if show == c else 3)]:
            print(f"        m={r['mask']} {r['src']!r}\n          R={r['rust']!r}\n          P={r['pion_direct']!r}" +
                  (f"\n          E={r['pion_events']!r}" if r['pion_events'] != r['pion_direct'] else ""))


main()
