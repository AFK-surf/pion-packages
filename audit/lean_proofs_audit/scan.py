#!/usr/bin/env python3
"""Static red-team scanner for the Lean 4 proofs under packages/*/proofs.

Reproducible, read-only. Produces (in --out, default: a temp dir):
  theorems.csv     one row per public theorem (location, binders, hyps, targets,
                   heuristic C-pattern flags, auto grade, manual grade if any)
  packages.csv     per-package totals (A/B/C, C1..C5, coverage, axioms check)
  verify_fns.csv   every `#verify` item: LOC, production callers, wrapper flag
  summary.json     machine-readable totals + integrity findings
  summary.md       markdown tables used by REPORT.md

Usage: python3 -I scan.py --repo <pion-packages checkout> [--out DIR]
       [--grades manual_grades.tsv] [--no-pionc]
"""
import argparse, csv, json, os, re, subprocess, sys, collections

FORBIDDEN = ["sorry", "admit", "axiom", "unsafe", "implemented_by", "native_decide",
             "bv_decide", "extern", "opaque", "ofReduceBool", "trustCompiler",
             "decide +kernel", "Lean.Elab", "elab ", "macro ", "set_option debug"]

DECL_RE = re.compile(r'^(?P<mods>(?:@\[[^\]]*\]\s*)?(?:private\s+|protected\s+|noncomputable\s+)*)'
                     r'(?P<kind>theorem|lemma|def|abbrev|instance|example|axiom|opaque|structure|inductive)\b\s*(?P<name>[^\s:(\[{]*)')
TOP_RE = re.compile(r'^(?:@\[|private\s|protected\s|noncomputable\s|theorem\s|lemma\s|def\s|abbrev\s|instance\s|'
                    r'example\s|axiom\s|opaque\s|structure\s|inductive\s|namespace\s|end\s|end$|section|open\s|'
                    r'variable|/--|/-|--|#|set_option|attribute|import|mutual)')


def read(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def strip_comments(s):
    s = re.sub(r'/-.*?-/', lambda m: '\n' * m.group(0).count('\n'), s, flags=re.S)
    return re.sub(r'--[^\n]*', '', s)


def split_binders(sig):
    """Return list of (group_kind, names, type) for leading binders of a statement."""
    out, i, n = [], 0, len(sig)
    pairs = {'(': ')', '{': '}', '[': ']', '⦃': '⦄'}
    while i < n:
        while i < n and sig[i].isspace():
            i += 1
        if i >= n or sig[i] not in pairs:
            break
        open_c, close_c, depth, j = sig[i], pairs[sig[i]], 0, i
        while j < n:
            if sig[j] == open_c:
                depth += 1
            elif sig[j] == close_c:
                depth -= 1
                if depth == 0:
                    break
            j += 1
        body = sig[i + 1:j]
        if ':' in body and open_c != '[':
            names, ty = body.split(':', 1)
            out.append((open_c, names.split(), ty.strip()))
        else:
            out.append((open_c, [], body.strip()))
        i = j + 1
    return out, sig[i:].lstrip()


HYP_TY = re.compile(r'(≤|<|≥|>|=|≠|∧|∨|↔|¬|→|∈|∉|\bTrue\b|\bFalse\b)')
VALUE_TY = re.compile(r'\b(Std\.)?(I8|I16|I32|I64|U8|U16|U32|U64|Usize|Isize|Int|Nat|Bool|Char|String|List|Array|FixedArray|Bytes|Option|Fe)\b|^[A-Z]\w*(\s|$)')
NUM = re.compile(r'(?<![\w.])-?(0x[0-9A-Fa-f]+|\d+)(#[iu]\d+)?')


def parse_lean_file(path, rel):
    raw = read(path)
    lines = raw.split('\n')
    text = strip_comments(raw)
    tl = text.split('\n')
    decls, ns_stack = [], []
    cur = None
    doc_buf = []
    for idx, line in enumerate(tl):
        rline = lines[idx]
        if rline.startswith('/--'):
            doc_buf = [rline]
        m_ns = re.match(r'^namespace\s+(\S+)', line)
        if m_ns:
            ns_stack.append(m_ns.group(1))
        elif re.match(r'^end\s+(\S+)', line) and ns_stack:
            ns_stack.pop()
        m = DECL_RE.match(line)
        if m and m.group('kind'):
            if cur:
                decls.append(cur)
            cur = dict(kind=m.group('kind'), name=m.group('name'), private='private' in m.group('mods'),
                       ns='.'.join(ns_stack), file=rel, line=idx + 1, body=[line],
                       doc=' '.join(d.strip() for d in doc_buf))
            doc_buf = []
            continue
        if cur is not None:
            if line and not line[0].isspace() and TOP_RE.match(line):
                decls.append(cur)
                cur = None
            else:
                cur['body'].append(line)
    if cur:
        decls.append(cur)
    for d in decls:
        full = '\n'.join(d['body'])
        k = full.find(':=')
        stmt = full[:k] if k >= 0 else full
        proof = full[k + 2:] if k >= 0 else ''
        stmt = re.sub(r'^\s*(?:@\[[^\]]*\]\s*)?(?:private\s+|protected\s+)*(theorem|lemma|def|abbrev)\s+\S+', '', stmt, count=1)
        binders, rest = split_binders(stmt)
        if rest.startswith(':'):
            rest = rest[1:]
        d['stmt'] = ' '.join(stmt.split())
        d['concl'] = ' '.join(rest.split())
        d['proof'] = proof
        vals, hyps = [], []
        for kind, names, ty in binders:
            if kind in '[':
                continue
            if HYP_TY.search(ty) or (names and all(nm.startswith('h') for nm in names) and not VALUE_TY.search(ty)):
                hyps.append(ty)
            elif kind in '({⦃':
                vals += names if names else ['_']
        d['vals'] = vals
        d['hyps'] = hyps
    return decls


def find_matching_brace(src, start):
    depth, i = 0, start
    in_str = False
    while i < len(src):
        c = src[i]
        if in_str:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == '/' and src.startswith('//', i):
            j = src.find('\n', i)
            i = len(src) if j < 0 else j
            continue
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(src) - 1


def pion_items(pkg_dir):
    """All top-level fn/struct/enum items in src/*.pion with #verify flag, LOC and body text."""
    items = []
    src_dir = os.path.join(pkg_dir, 'src')
    total_loc = 0
    for fn in sorted(os.listdir(src_dir)):
        if not fn.endswith('.pion') or fn.endswith('_test.pion'):
            continue
        p = os.path.join(src_dir, fn)
        src = read(p)
        lines = src.split('\n')
        total_loc += sum(1 for l in lines if l.strip() and not l.strip().startswith('//'))
        pending_verify = False
        offs = [0]
        for l in lines:
            offs.append(offs[-1] + len(l) + 1)
        for i, l in enumerate(lines):
            s = l.strip()
            if s == '#verify' or s.startswith('#verify '):
                pending_verify = True
                continue
            m = re.match(r'^(pub\s+)?(val\s+)?(fn|struct|enum|const)\s+([A-Za-z_][\w:]*)', l)
            if m:
                name = m.group(4)
                kind = m.group(3)
                start = offs[i]
                if kind == 'const':
                    end_line = i
                else:
                    b = src.find('{', start)
                    e = find_matching_brace(src, b)
                    end_line = src.count('\n', 0, e)
                body = '\n'.join(lines[i:end_line + 1])
                loc = sum(1 for x in lines[i:end_line + 1] if x.strip() and not x.strip().startswith('//'))
                # body expression lines (excluding signature + closing brace)
                sig_end = i
                while sig_end <= end_line and '{' not in lines[sig_end]:
                    sig_end += 1
                inner = [x for x in lines[sig_end + 1:end_line] if x.strip() and not x.strip().startswith('//')]
                items.append(dict(name=name, kind=kind, verify=pending_verify, file=f'src/{fn}', line=i + 1,
                                  loc=loc, body_lines=len(inner), body=body,
                                  one_liner=(kind == 'fn' and len(inner) <= 1)))
                pending_verify = False
            elif s and not s.startswith('//') and not s.startswith('#'):
                pending_verify = pending_verify and s.startswith('@')
    return items, total_loc


def production_refs(pkg_dir, items):
    """Count call sites of each item in non-test src code outside its own body (word match)."""
    srcs = {}
    for fn in os.listdir(os.path.join(pkg_dir, 'src')):
        if fn.endswith('.pion') and not fn.endswith('_test.pion'):
            srcs[f'src/{fn}'] = read(os.path.join(pkg_dir, 'src', fn))
    refs = {}
    by_file = collections.defaultdict(list)
    for it in items:
        by_file[it['file']].append(it)
    for it in items:
        short = it['name'].split('::')[-1]
        pat = re.compile(r'(?<![\w])' + re.escape(short) + r'\s*[\(\[{:]' if it['kind'] != 'fn' else
                         r'(?<![\w])' + re.escape(short) + r'\s*\(')
        cnt, verify_only = 0, 0
        callers = set()
        for f, s in srcs.items():
            for m in pat.finditer(s):
                pos = m.start()
                ln = s.count('\n', 0, pos) + 1
                if f == it['file'] and it['line'] <= ln <= it['line'] + it['loc'] + 200 and ln == it['line']:
                    continue
                owner = None
                for o in by_file[f]:
                    if o['line'] <= ln and ln < o['line'] + len(o['body'].split('\n')):
                        owner = o
                if owner is it:
                    continue
                if owner is not None and re.match(r'^\s*(pub\s+)?(val\s+)?(fn|struct|enum)\s', s.split('\n')[ln - 1]) and owner['line'] == ln:
                    continue
                cnt += 1
                if owner is not None:
                    callers.add(owner['name'])
                    if owner['verify']:
                        verify_only += 1
        refs[it['name']] = dict(sites=cnt, nonverify_sites=cnt - verify_only, callers=sorted(callers))
    return refs


def test_refs(pkg_dir, name):
    short = name.split('::')[-1]
    pat = re.compile(r'(?<![\w])' + re.escape(short) + r'\b')
    n = 0
    for root, _, files in os.walk(pkg_dir):
        if '/proofs' in root or '/bench' in root:
            continue
        for fn in files:
            if fn.endswith('_test.pion') or (fn.endswith('.pion') and '/tests' in root):
                n += len(pat.findall(read(os.path.join(root, fn))))
    return n


def normalize_shape(s):
    s = NUM.sub('N', s)
    s = re.sub(r'\b\w*?(\d+)\w*\b', lambda m: re.sub(r'\d+', 'N', m.group(0)), s)
    return ' '.join(s.split())


def classify(t, verify_index):
    """Heuristic C-pattern flags. A/B are never auto-assigned beyond 'candidate'."""
    flags = []
    concl, stmt, proof = t['concl'], t['stmt'], t['proof']
    has_forall = '∀' in concl
    targets = [n for n in verify_index if re.search(r'(?<![\w.])' + re.escape(n.split('::')[-1].replace('::', '.')) + r'(?![\w])', stmt)
               or re.search(r'(?<![\w.])' + re.escape(n.replace('::', '.')) + r'(?![\w])', stmt)]
    t['targets'] = targets
    if not t['vals'] and not has_forall:
        flags.append('C1')
    pr = ' '.join(proof.split())
    if re.fullmatch(r'(by\s+)?(rfl|decide|simp|native_decide|by decide|by rfl)?\s*(<;>\s*\w+)?', pr.replace('by ', '', 1).strip()) and not t['vals']:
        if 'C1' not in flags:
            flags.append('C1')
    if targets:
        tgt = [verify_index[n] for n in targets]
        if all(x['one_liner'] for x in tgt) and len(targets) == 1 and t['vals'] and not has_forall:
            # one-line body restated as iff/eq of a closed formula
            if re.search(r'↔|= ok (true|false)|= ok \(', concl) and len(t['hyps']) <= 1:
                body_expr = ' '.join(x.strip() for x in tgt[0]['body'].split('\n')[1:-1])
                if len(body_expr) <= 80 and not re.search(r'\b(for|while|loop|match)\b', body_expr):
                    flags.append('C2?')
    if t['hyps']:
        flags.append('HYP')
    return flags


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', required=True)
    ap.add_argument('--out', default=None)
    ap.add_argument('--grades', default=None)
    ap.add_argument('--no-pionc', action='store_true')
    a = ap.parse_args()
    repo = os.path.abspath(a.repo)
    out = a.out or os.path.join(os.environ.get('TMPDIR', '/tmp'), 'lean_audit_out')
    os.makedirs(out, exist_ok=True)
    manual = {}
    if a.grades and os.path.exists(a.grades):
        with open(a.grades, encoding='utf-8') as f:
            for row in csv.reader(f, delimiter='\t'):
                if not row or row[0].startswith('#') or len(row) < 3:
                    continue
                manual[(row[0], row[1])] = (row[2], row[3] if len(row) > 3 else '')
    pkgs = sorted(d for d in os.listdir(os.path.join(repo, 'packages'))
                  if os.path.isdir(os.path.join(repo, 'packages', d, 'proofs')))
    all_thms, pkg_rows, verify_rows, integrity = [], [], [], []
    for pkg in pkgs:
        pdir = os.path.join(repo, 'packages', pkg)
        prd = os.path.join(pdir, 'proofs')
        lean_files = []
        for root, _, files in os.walk(prd):
            for fn in files:
                if fn.endswith('.lean'):
                    lean_files.append(os.path.join(root, fn))
        decls = []
        forbidden_hits = []
        for lf in sorted(lean_files):
            rel = os.path.relpath(lf, repo)
            txt = strip_comments(read(lf))
            for tok in FORBIDDEN:
                pat = r'(?<![\w])' + re.escape(tok) + (r'(?![\w])' if tok[-1].isalnum() else '')
                for m in re.finditer(pat, txt):
                    ln = txt.count('\n', 0, m.start()) + 1
                    line = txt.split('\n')[ln - 1].strip()
                    # `#print axioms` is the check itself, not an axiom declaration
                    if tok == 'axiom' and ('#print axioms' in line or 'axioms' in line):
                        continue
                    forbidden_hits.append(f'{rel}:{ln}: {tok}: {line[:100]}')
            if os.path.basename(lf) in ('CheckAxioms.lean', 'EvalDiff.lean'):
                continue
            decls += parse_lean_file(lf, rel)
        ca = read(os.path.join(prd, 'CheckAxioms.lean')) if os.path.exists(os.path.join(prd, 'CheckAxioms.lean')) else ''
        printed = re.findall(r'#print\s+axioms\s+(\S+)', strip_comments(ca))
        pshort = {p.split('.')[-1] for p in printed}
        pub = [d for d in decls if d['kind'] == 'theorem' and not d['private']]
        # The audited ("counted") theorem set is what CheckAxioms prints; other public
        # theorems are helper lemmas declared without `private`.
        thms = [d for d in pub if d['name'].split('.')[-1] in pshort]
        public_helpers = [d for d in pub if d['name'].split('.')[-1] not in pshort]
        helpers = [d for d in decls if d['kind'] in ('lemma', 'theorem') and d not in thms]
        fq = {(t['ns'] + '.' if t['ns'] else '') + t['name'] for t in pub}
        short = {t['name'] for t in thms}
        printed_set = set(printed)
        missing = []  # by construction; public helpers are reported separately
        # files under proofs/ that the root module never imports are never built
        root_mod = None
        for lf in lean_files:
            b = os.path.basename(lf)
            if b.endswith('Proofs.lean') and os.path.dirname(lf) == prd:
                root_mod = lf
        unbuilt = []
        if root_mod:
            imports = set(re.findall(r'^import\s+(\S+)', read(root_mod), flags=re.M))
            for lf in lean_files:
                rel_mod = os.path.relpath(lf, prd)[:-5].replace('/', '.')
                if os.path.dirname(lf) != prd and rel_mod not in imports:
                    unbuilt.append(rel_mod)
        extra = sorted(p for p in printed_set if p not in fq and p.split('.')[-1] not in short)
        dup_printed = [p for p, c in collections.Counter(printed).items() if c > 1]
        # run_proofs.sh checks
        rp = read(os.path.join(prd, 'run_proofs.sh')) if os.path.exists(os.path.join(prd, 'run_proofs.sh')) else ''
        rp_nc = '\n'.join(l for l in rp.split('\n') if not l.strip().startswith('#'))
        live_extract = bool(re.search(r'pionc"?\s+extract-lean', rp_nc) or 'extract-lean' in rp_nc)
        thr = re.findall(r'THM_COUNT\S*\s*-(lt|ne)\s*"?(\d+)', rp_nc) or re.findall(r'-(lt|ne)\s+(\d+)\s*\]', rp_nc)
        native_self_judged = bool(re.search(r'got\s*==\s*exp', rp_nc)) and ': PASS' in rp_nc
        scans_subdir = bool(re.search(r'Proofs/"', rp_nc))
        scan_tokens = re.findall(r"grep -rnE '([^']*)'", rp_nc)
        ed = read(os.path.join(prd, 'EvalDiff.lean')) if os.path.exists(os.path.join(prd, 'EvalDiff.lean')) else ''
        ed_nc = strip_comments(ed)
        ed_cases = len(re.findall(r'(?:^|[\[,(])\s*(?!def\b)[A-Za-z_]\w*\s+"[^"{}]+"\s+[(\w]', ed_nc, flags=re.M))
        neg_lits = len(re.findall(r'\(-\d+\)#i|-\d+#i|\(-\d', ed))
        extreme = len(re.findall(r'2147483647|2147483648|4294967295|9223372036854775807|0x7[fF]{7}|0xFFFFFFFF|0x80000000', ed))
        # pion side
        items, total_loc = pion_items(pdir)
        vitems = [x for x in items if x['verify']]
        vfns = [x for x in vitems if x['kind'] == 'fn']
        refs = production_refs(pdir, items)
        vindex = {x['name']: x for x in vitems}
        for x in vitems:
            r = refs.get(x['name'], dict(sites=0, nonverify_sites=0, callers=[]))
            x['prod_sites'] = r['sites']
            x['prod_nonverify_sites'] = r['nonverify_sites']
            x['callers'] = r['callers']
            x['test_sites'] = test_refs(pdir, x['name'])
            x['dead'] = x['kind'] == 'fn' and r['sites'] == 0
            x['const_fn'] = x['kind'] == 'fn' and bool(re.search(r'fn\s+[\w:]+\(\s*\)', x['body'])) and x['body_lines'] <= 1
            verify_rows.append(dict(pkg=pkg, name=x['name'], kind=x['kind'], file=f"packages/{pkg}/{x['file']}", line=x['line'],
                                    loc=x['loc'], body_lines=x['body_lines'], one_liner=x['one_liner'], const_fn=x['const_fn'],
                                    prod_sites=x['prod_sites'], prod_nonverify_sites=x['prod_nonverify_sites'],
                                    test_sites=x['test_sites'], dead=x['dead'], callers=';'.join(x['callers'][:6])))
        verify_loc = sum(x['loc'] for x in vfns)
        # theorem classification
        shapes = collections.Counter()
        for t in thms:
            t['shape'] = normalize_shape(t['concl'] + ' | ' + ' '.join(t['hyps']))
            shapes[t['shape']] += 1
        seen_shape = collections.Counter()
        targeted = collections.Counter()
        for t in thms:
            t['flags'] = classify(t, vindex)
            for tg in t['targets']:
                targeted[tg] += 1
        for t in thms:
            if shapes[t['shape']] > 1:
                seen_shape[t['shape']] += 1
                if seen_shape[t['shape']] > 1:
                    t['flags'].append('C3')
            if any(vindex[x]['const_fn'] for x in t['targets']) and 'C1' not in t['flags']:
                t['flags'].append('C1')
            if any(vindex[x]['dead'] for x in t['targets']):
                t['flags'].append('DEAD-TARGET')
            # many theorems about the same tiny function -> split corollaries
            if t['targets'] and all(vindex[x]['one_liner'] and targeted[x] >= 3 for x in t['targets']) and 'C3' not in t['flags']:
                t['flags'].append('C3?')
            auto = 'C' if any(f in ('C1', 'C3') for f in t['flags']) else ('C?' if 'C2?' in t['flags'] or 'C3?' in t['flags'] else 'AB?')
            key = (pkg, t['name'])
            g, note = manual.get(key, ('', ''))
            row = dict(pkg=pkg, name=t['name'], file=t['file'], line=t['line'], vals=len(t['vals']), hyps=len(t['hyps']),
                       targets=';'.join(t['targets']), target_loc=sum(vindex[x]['loc'] for x in t['targets']),
                       flags=','.join(t['flags']), auto=auto, manual=g, note=note,
                       proof_lines=len([l for l in t['proof'].split('\n') if l.strip()]),
                       concl=t['concl'][:300])
            all_thms.append(row)
        prows = [r for r in all_thms if r['pkg'] == pkg]
        grade = lambda r: (r['manual'] or r['auto'])
        cnt = collections.Counter(grade(r)[0] if grade(r)[0] in 'ABC' else '?' for r in prows)
        sub = collections.Counter()
        for r in prows:
            g = grade(r)
            if g.startswith('C') and len(g) > 1 and g[1].isdigit():
                for part in g.split('+'):
                    sub[part] += 1
        pkg_rows.append(dict(pkg=pkg, theorems=len(thms), helper_lemmas=len(helpers), public_helpers=len(public_helpers), unbuilt=';'.join(unbuilt), printed=len(printed),
                             missing_in_checkaxioms=';'.join(missing), extra_in_checkaxioms=';'.join(extra),
                             dup_printed=';'.join(dup_printed), forbidden=len(forbidden_hits),
                             live_extract=live_extract, threshold=';'.join(f'{x}{y}' for x, y in thr),
                             native_diff_self_judged=native_self_judged, scan_tokens=';'.join(sorted(set(scan_tokens))),
                             evaldiff_cases=ed_cases, evaldiff_neg_literals=neg_lits, evaldiff_extreme_literals=extreme,
                             src_loc=total_loc, verify_items=len(vitems), verify_fns=len(vfns), verify_loc=verify_loc,
                             verify_pct=round(100.0 * verify_loc / max(total_loc, 1), 2),
                             one_liner_fns=sum(1 for x in vfns if x['one_liner']), const_fns=sum(1 for x in vfns if x['const_fn']),
                             dead_fns=sum(1 for x in vfns if x['dead']),
                             A=cnt.get('A', 0), B=cnt.get('B', 0), C=cnt.get('C', 0), unk=cnt.get('?', 0),
                             C1=sub.get('C1', 0), C2=sub.get('C2', 0), C3=sub.get('C3', 0), C4=sub.get('C4', 0), C5=sub.get('C5', 0),
                             auto_C1=sum(1 for r in prows if 'C1' in r['flags'].split(',')),
                             auto_C3=sum(1 for r in prows if 'C3' in r['flags'].split(',')),
                             auto_C2q=sum(1 for r in prows if 'C2?' in r['flags'].split(',')),
                             auto_hyp=sum(1 for r in prows if 'HYP' in r['flags'].split(','))))
        for h in forbidden_hits:
            integrity.append(f'{pkg}: flagged token (review; decide +kernel is kernel-checked and sound) {h}')
        if unbuilt:
            integrity.append(f'{pkg}: proof modules not imported by root (never built): {unbuilt}')
        if public_helpers:
            integrity.append(f'{pkg}: {len(public_helpers)} non-private helper theorems not listed in CheckAxioms (checked only transitively)')
        if extra:
            integrity.append(f'{pkg}: CheckAxioms prints unknown names: {extra}')
        if not live_extract:
            integrity.append(f'{pkg}: run_proofs.sh does not run pionc extract-lean')
    def wcsv(name, rows):
        if not rows:
            return
        with open(os.path.join(out, name), 'w', newline='', encoding='utf-8') as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
    wcsv('theorems.csv', all_thms)
    wcsv('packages.csv', pkg_rows)
    wcsv('verify_fns.csv', verify_rows)
    tot = collections.Counter()
    for r in pkg_rows:
        for k in ('theorems', 'helper_lemmas', 'public_helpers', 'printed', 'A', 'B', 'C', 'unk', 'C1', 'C2', 'C3', 'C4', 'C5', 'src_loc',
                  'verify_loc', 'verify_fns', 'one_liner_fns', 'const_fns', 'dead_fns', 'auto_C1', 'auto_C3', 'auto_C2q', 'auto_hyp',
                  'evaldiff_cases', 'evaldiff_neg_literals', 'evaldiff_extreme_literals'):
            tot[k] += r[k]
    summary = dict(packages=len(pkg_rows), totals=dict(tot), integrity=integrity,
                   threshold_values=collections.Counter(r['threshold'] for r in pkg_rows),
                   self_judged_native_diff=sum(1 for r in pkg_rows if r['native_diff_self_judged']))
    with open(os.path.join(out, 'summary.json'), 'w', encoding='utf-8') as f:
        json.dump(summary, f, indent=1, ensure_ascii=False, default=str)
    # markdown
    md = ['| 包 | 定理 | A | B | C | C1 | C2 | C3 | C4 | C5 | 有效率(A+B) | A 率 | #verify fn | 单行 fn | 零参常量 fn | 无生产调用 fn | #verify LOC / src LOC | 覆盖% |',
          '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
    for r in pkg_rows:
        n = max(r['theorems'], 1)
        md.append(f"| {r['pkg']} | {r['theorems']} | {r['A']} | {r['B']} | {r['C']} | {r['C1']} | {r['C2']} | {r['C3']} | {r['C4']} | {r['C5']} | "
                  f"{100*(r['A']+r['B'])/n:.0f}% | {100*r['A']/n:.0f}% | {r['verify_fns']} | {r['one_liner_fns']} | {r['const_fns']} | {r['dead_fns']} | "
                  f"{r['verify_loc']} / {r['src_loc']} | {r['verify_pct']:.2f}% |")
        tn = max(tot['theorems'], 1)
    md.append(f"| **合计** | **{tot['theorems']}** | **{tot['A']}** | **{tot['B']}** | **{tot['C']}** | {tot['C1']} | {tot['C2']} | {tot['C3']} | {tot['C4']} | {tot['C5']} | "
              f"**{100*(tot['A']+tot['B'])/tn:.1f}%** | **{100*tot['A']/tn:.1f}%** | {tot['verify_fns']} | {tot['one_liner_fns']} | {tot['const_fns']} | {tot['dead_fns']} | "
              f"{tot['verify_loc']} / {tot['src_loc']} | {100*tot['verify_loc']/max(tot['src_loc'],1):.2f}% |")
    with open(os.path.join(out, 'summary.md'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(md) + '\n')
    print(json.dumps(summary, indent=1, ensure_ascii=False, default=str))
    print('out:', out)


if __name__ == '__main__':
    main()
