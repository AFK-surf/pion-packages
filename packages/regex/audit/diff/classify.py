#!/usr/bin/env python3
"""Bucket run_diff.py mismatches into root-cause classes.
usage: classify.py <x.mismatch.txt> [--examples N]"""
import sys

CORE = ("is_match", "find", "find_at", "captures")


def spans(s):
    if not s:
        return []
    return [tuple(map(int, x.split("-"))) for x in s.split(",")]


def drop_abutting_empty(sp):
    out, last = [], None
    for s, e in sp:
        if s == e and last is not None and s == last:
            continue
        out.append((s, e))
        last = e
    return out


def classify(rust, pion):
    if "set_matches" in rust or "set" in rust or "set" in pion:
        if rust.get("set") == "ERR" or pion.get("set") == "ERR":
            return "set: compile acceptance differs"
        return "set: matches differ"
    rc, pc = rust.get("compile"), pion.get("compile")
    if rc == "ERR" and pc != "ERR":
        return "compile: Pion accepts pattern Rust rejects"
    if rc != "ERR" and pc == "ERR":
        return "compile: Pion rejects pattern Rust accepts"
    if rc != pc:
        if all(rust.get(k) == pion.get(k) for k in ("is_match", "find", "find_at")):
            return "compile: capture-group count differs"
    if rust.get("is_match") != pion.get("is_match"):
        return "core: is_match differs"
    if rust.get("find") != pion.get("find"):
        return "core: find() span differs"
    if rust.get("find_at") != pion.get("find_at"):
        return "core: find_at()/is_match_at() differs (start>0)"
    if rust.get("captures") != pion.get("captures"):
        return "core: capture group spans differ"
    ri, pi = spans(rust.get("find_iter")), spans(pion.get("find_iter"))
    if ri != pi:
        if drop_abutting_empty(pi) == ri:
            return "iter: empty match abutting previous match not skipped"
        return "iter: find_iter differs (other)"
    if rust.get("captures_iter") != pion.get("captures_iter"):
        return "iter: captures_iter group spans differ"
    return "replace/split only: " + ",".join(k for k in rust if rust.get(k) != pion.get(k))


def main():
    path = sys.argv[1]
    nex = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[2] == "--examples" else 2
    buckets = {}
    crashes = []
    for blk in ("\n" + open(path, encoding="utf-8").read()).split("\n== ")[1:]:
        lines = blk.split("\n")
        head = lines[0]
        rust = dict(l[8:].split("=", 1) for l in lines if l.startswith("   rust ") and "=" in l)
        pion = dict(l[8:].split("=", 1) for l in lines if l.startswith("   pion ") and "=" in l)
        if not pion:
            crashes.append(head)
            continue
        c = classify(rust, pion)
        buckets.setdefault(c, []).append((head, rust, pion))
    for l in open(path, encoding="utf-8"):
        if l.startswith("!! "):
            crashes.append(l.strip())
    if crashes:
        print(f"[{len(crashes)}] CRASH/HANG")
        for c in crashes[:nex]:
            print("     " + c[:300])
    for c, items in sorted(buckets.items(), key=lambda kv: -len(kv[1])):
        print(f"[{len(items)}] {c}")
        items = sorted(items, key=lambda it: len(it[0]))
        for head, rust, pion in items[:nex]:
            print("     " + head[:260])
            for k in rust:
                if rust.get(k) != pion.get(k) and k in CORE + ("compile", "find_iter", "captures_iter", "set_matches"):
                    print(f"        {k}: rust={rust.get(k)!s:.150} pion={pion.get(k)!s:.150}")


if __name__ == "__main__":
    main()
