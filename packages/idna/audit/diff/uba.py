"""UAX #9 (Unicode 16.0.0) display reordering for UTS #39 16.0 bidiSkeleton(LTR, X), written from the UAX #9
text for the reference model: X1-X10 (explicit embeddings / overrides / isolates), W1-W7, N0 (paired
brackets), N1-N2, I1-I2, L1, L2, then UTS #39's L3 (combining marks after their base) and L4 (Bidi_Mirroring_Glyph).

  visual(cps, full=True)  -> reordered + mirrored code points (X1-X10 incl. isolates X5a-X5c / X6a / BD13,
                             W1-W7, N0, N1-N2, I1-I2, L1, L2, L3, L4). Paragraph separators split paragraphs (P1);
                             BN is removed by X9 and retained at the level of the preceding character (§5.2).
  visual(cps, full=False) -> the reduced algorithm (no X rules, no N0, no L1, no L3, no L4), used only to
                             recognise an implementation of that reduced algorithm (REPORT.md P2-7).
"""
from ucd import data

D = data()
STRONG_R = ("R", "AN", "EN")
EXPLICIT = ("LRE", "RLE", "LRO", "RLO", "PDF")


def _seq_rules(types, idx, levels, sos, eos, full, cps, orig):
    """W1-W7, N0, N1, N2 on one isolating run sequence (positions idx)."""
    t = [types[i] for i in idx]
    n = len(t)
    # W1 (the reduced variant mirrors the shape under test: starts from ON and skips BN)
    prev = sos if full else "ON"
    for k in range(n):
        if t[k] == "NSM":
            t[k] = "ON" if (full and k > 0 and orig[idx[k - 1]] in ("LRI", "RLI", "FSI", "PDI")) else prev
        if full or t[k] != "BN":
            prev = t[k]
    # W2 / W3
    last = sos
    for k in range(n):
        if t[k] in ("L", "R", "AL"):
            last = t[k]
        elif t[k] == "EN" and last == "AL":
            t[k] = "AN"
    for k in range(n):
        if t[k] == "AL":
            t[k] = "R"
    # W4
    for k in range(1, n - 1):
        if t[k] == "ES" and t[k - 1] == "EN" and t[k + 1] == "EN":
            t[k] = "EN"
        elif t[k] == "CS" and t[k - 1] == t[k + 1] and t[k - 1] in ("EN", "AN"):
            t[k] = t[k - 1]
    # W5
    k = 0
    while k < n:
        if t[k] == "ET":
            j = k
            while j < n and t[j] == "ET":
                j += 1
            if (k > 0 and t[k - 1] == "EN") or (j < n and t[j] == "EN"):
                for q in range(k, j):
                    t[q] = "EN"
            k = j
        else:
            k += 1
    # W6
    for k in range(n):
        if t[k] in ("ES", "ET", "CS"):
            t[k] = "ON"
    # W7
    last = sos
    for k in range(n):
        if t[k] in ("L", "R"):
            last = t[k]
        elif t[k] == "EN" and last == "L":
            t[k] = "L"
    e = "R" if levels[idx[0]] % 2 else "L"
    if full:
        # N0: paired brackets (BD16), canonical equivalents U+2329/U+232A ~ U+3008/U+3009
        canon = {0x2329: 0x3008, 0x232A: 0x3009}
        stack = []
        pairs = []
        for k in range(n):
            c = cps[idx[k]]
            if t[k] != "ON" or c not in D.brackets:
                continue
            other, kind = D.brackets[c]
            if kind == "o":
                if len(stack) >= 63:
                    break
                stack.append((canon.get(other, other), k))
            else:
                cc = canon.get(c, c)
                for s in range(len(stack) - 1, -1, -1):
                    if stack[s][0] == cc:
                        pairs.append((stack[s][1], k))
                        del stack[s:]
                        break
        pairs.sort()

        def strong(x):
            return "L" if x == "L" else ("R" if x in STRONG_R else None)
        for (o, c) in pairs:
            inside = [strong(t[q]) for q in range(o + 1, c)]
            newt = None
            if e in inside:
                newt = e
            elif (("R" if e == "L" else "L") in inside):
                before = sos
                for q in range(o - 1, -1, -1):
                    s = strong(t[q])
                    if s:
                        before = s
                        break
                before = "R" if before in STRONG_R else before
                newt = before if before != e else e
            if newt:
                for q in (o, c):
                    t[q] = newt
                    r = q + 1
                    while r < n and orig[idx[r]] == "NSM":
                        t[r] = newt
                        r += 1
    # N1 / N2
    ni = ("B", "S", "WS", "ON", "BN", "LRI", "RLI", "FSI", "PDI", "LRE", "RLE", "LRO", "RLO", "PDF")
    k = 0
    while k < n:
        if t[k] in ni:
            j = k
            while j < n and t[j] in ni:
                j += 1
            left = sos if k == 0 else ("R" if t[k - 1] in STRONG_R else t[k - 1])
            right = eos if j == n else ("R" if t[j] in STRONG_R else t[j])
            v = left if left == right else e
            for q in range(k, j):
                t[q] = v
            k = j
        else:
            k += 1
    for k in range(n):
        types[idx[k]] = t[k]


def visual(cps, full=True):
    n = len(cps)
    orig = [D.bidi_class(c) for c in cps]
    if not any(x in ("R", "AL", "AN", "RLE", "RLO", "RLI") for x in orig):
        return list(cps)
    if full and "B" in orig:
        # P1: one paragraph per paragraph separator, each at paragraph level 0 (HL1), the separator
        # itself stays at level 0 (L1) at the end of its paragraph
        out = []
        start = 0
        for i, x in enumerate(orig + ["B"]):
            if x == "B":
                out.extend(visual(cps[start:i], True) or [])
                if i < n:
                    out.append(cps[i])
                start = i + 1
        return out
    levels = [0] * n
    types = list(orig)
    removed = [False] * n
    iso = ("LRI", "RLI", "FSI")
    match = {}
    if full:
        # BD9: matching PDI of each isolate initiator
        st = []
        for i, x in enumerate(orig):
            if x in iso:
                st.append(i)
            elif x == "PDI" and st:
                match[st.pop()] = i
        stack = [(0, None, False)]
        over_iso = over_emb = valid_iso = 0
        for i, x in enumerate(orig):
            if x in ("RLE", "LRE", "RLO", "LRO"):
                cur = stack[-1][0]
                lvl = (cur + 1) | 1 if x in ("RLE", "RLO") else (cur + 2) & ~1
                if lvl <= 125 and over_iso == 0 and over_emb == 0:
                    stack.append((lvl, {"RLO": "R", "LRO": "L"}.get(x), False))
                elif over_iso == 0:
                    over_emb += 1
                removed[i] = True
                levels[i] = stack[-1][0]
            elif x == "PDF":
                if over_iso > 0:
                    pass
                elif over_emb > 0:
                    over_emb -= 1
                elif not stack[-1][2] and len(stack) >= 2:
                    stack.pop()
                removed[i] = True
                levels[i] = stack[-1][0]
            elif x == "BN":
                removed[i] = True
                levels[i] = stack[-1][0]
            elif x in iso:
                levels[i] = stack[-1][0]
                if stack[-1][1]:
                    types[i] = stack[-1][1]
                rtl = x == "RLI"
                if x == "FSI":  # P2 / P3 on the text up to the matching PDI, skipping nested isolates
                    end = match.get(i, n)
                    depth = 0
                    for q in range(i + 1, end):
                        y = orig[q]
                        if y in iso:
                            depth += 1
                        elif y == "PDI" and depth:
                            depth -= 1
                        elif depth == 0 and y in ("L", "R", "AL"):
                            rtl = y != "L"
                            break
                cur = stack[-1][0]
                lvl = (cur + 1) | 1 if rtl else (cur + 2) & ~1
                if lvl <= 125 and over_iso == 0 and over_emb == 0:
                    valid_iso += 1
                    stack.append((lvl, None, True))
                else:
                    over_iso += 1
            elif x == "PDI":
                if over_iso > 0:
                    over_iso -= 1
                elif valid_iso > 0:
                    over_emb = 0
                    while not stack[-1][2]:
                        stack.pop()
                    stack.pop()
                    valid_iso -= 1
                levels[i] = stack[-1][0]
                if stack[-1][1]:
                    types[i] = stack[-1][1]
            else:
                levels[i] = stack[-1][0]
                if stack[-1][1]:
                    types[i] = stack[-1][1]
    keep = [i for i in range(n) if not removed[i]]
    # X10 / BD13: level runs, chained into isolating run sequences across matched isolate initiator / PDI
    runs = []
    for i in keep:
        if runs and levels[runs[-1][-1]] == levels[i]:
            runs[-1].append(i)
        else:
            runs.append([i])
    seqs = []
    if full:
        start_of = {r[0]: k for k, r in enumerate(runs)}
        used = set()
        for k, r in enumerate(runs):
            if k in used:
                continue
            seq = list(r)
            used.add(k)
            while orig[seq[-1]] in iso and seq[-1] in match and match[seq[-1]] in start_of:
                k2 = start_of[match[seq[-1]]]
                used.add(k2)
                seq.extend(runs[k2])
            seqs.append(seq)
    else:
        seqs = runs
    pos = {i: p for p, i in enumerate(keep)}
    for idx in seqs:
        lv = levels[idx[0]]
        p0 = pos[idx[0]]
        pv = levels[keep[p0 - 1]] if p0 > 0 else 0
        p1 = pos[idx[-1]]
        if full and orig[idx[-1]] in iso and idx[-1] not in match:
            nv = 0
        else:
            nv = levels[keep[p1 + 1]] if p1 + 1 < len(keep) else 0
        if full and orig[idx[-1]] in iso:
            nv = 0
        sos = "R" if max(lv, pv) % 2 else "L"
        eos = "R" if max(lv, nv) % 2 else "L"
        if not full:
            sos, eos = "L", "L"
        _seq_rules(types, idx, levels, sos, eos, full, cps, orig)
    # I1 / I2
    for i in keep:
        lv = levels[i]
        if lv % 2 == 0:
            if types[i] == "R":
                levels[i] = lv + 1
            elif types[i] in ("AN", "EN"):
                levels[i] = lv + 2
        elif types[i] in ("L", "EN", "AN"):
            levels[i] = lv + 1
    # removed characters take the level of the preceding character (UAX #9 §5.2)
    for i in range(n):
        if removed[i]:
            levels[i] = levels[i - 1] if i > 0 else 0
    if full:
        # L1: trailing whitespace (and whitespace / ignorable before S) resets to the paragraph level
        j = n - 1
        while j >= 0 and (orig[j] in ("WS", "BN", "LRI", "RLI", "FSI", "PDI") or removed[j]):
            levels[j] = 0
            j -= 1
        for i in range(n):
            if orig[i] == "S":
                levels[i] = 0
                j = i - 1
                while j >= 0 and (orig[j] in ("WS", "BN", "LRI", "RLI", "FSI", "PDI") or removed[j]):
                    levels[j] = 0
                    j -= 1
    # L2
    order = list(range(n))
    hi = max(levels)
    lo_odd = min([lv for lv in levels if lv % 2] or [1])
    for lv in range(hi, lo_odd - 1, -1):
        i = 0
        while i < n:
            if levels[order[i]] >= lv:
                j = i
                while j < n and levels[order[j]] >= lv:
                    j += 1
                order[i:j] = order[i:j][::-1]
                i = j
            else:
                i += 1
    if not full:
        return [cps[i] for i in order]
    # L3: combining marks of an RTL run now precede their base: move them after it
    out = list(order)
    i = 0
    while i < n:
        if D.is_mark(cps[out[i]]) and levels[out[i]] % 2:
            j = i
            while j < n and D.is_mark(cps[out[j]]) and levels[out[j]] % 2:
                j += 1
            if j < n and levels[out[j]] % 2:
                out[i:j + 1] = [out[j]] + out[i:j][::-1]
                i = j + 1
                continue
            i = j
        else:
            i += 1
    # L4: mirrored glyphs at odd levels
    res = []
    for p in out:
        c = cps[p]
        res.append(D.mirror.get(c, c) if levels[p] % 2 else c)
    return res
