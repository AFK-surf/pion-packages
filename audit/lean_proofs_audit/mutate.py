#!/usr/bin/env python3
"""Two-sided mutation experiment for the Lean proof gate.

For every entry in mutations.json:
  1. copy packages/<pkg> to $MUT_ROOT/<id>/<pkg> (the repository is never touched),
  2. apply exactly one textual mutation (old must occur exactly once),
  3. run `pionc test --json` on the copy (do ordinary unit tests notice?),
  4. run the package's own proofs/run_proofs.sh on the copy with LEAN_WORK pointing at
     an isolated Lean workspace (does the formal-proof gate notice?).

"positive" mutations hit a #verify function (the gate SHOULD fail);
"escape" mutations hit unverified production logic (shows what the gate cannot see).

Usage: python3 -I mutate.py --repo <checkout> --lean-work /private/tmp/rt-lean-audit-work
         [--mut-root /private/tmp/rt-lean-audit-mut] [--only id1,id2] [--skip-tests]
Writes $MUT_ROOT/results.json and prints a markdown table.
"""
import argparse, json, os, re, shutil, subprocess, sys, time

ap = argparse.ArgumentParser()
ap.add_argument('--repo', required=True)
ap.add_argument('--lean-work', required=True)
ap.add_argument('--mut-root', default='/private/tmp/rt-lean-audit-mut')
ap.add_argument('--spec', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mutations.json'))
ap.add_argument('--only', default='')
ap.add_argument('--skip-tests', action='store_true')
a = ap.parse_args()

env = dict(os.environ)
env['PATH'] = os.path.expanduser('~/.pion/bin') + ':' + os.path.expanduser('~/.elan/bin') + ':' + env['PATH']
env['LEAN_WORK'] = a.lean_work
specs = json.load(open(a.spec))
if a.only:
    keep = set(a.only.split(','))
    specs = [s for s in specs if s['id'] in keep]
os.makedirs(a.mut_root, exist_ok=True)
res_path = os.path.join(a.mut_root, 'results.json')
results = json.load(open(res_path)) if os.path.exists(res_path) else {}


def tail(s, n=12):
    return '\n'.join(s.strip().split('\n')[-n:])


for s in specs:
    d = os.path.join(a.mut_root, s['id'])
    shutil.rmtree(d, ignore_errors=True)
    pk = os.path.join(d, s['pkg'])
    shutil.copytree(os.path.join(a.repo, 'packages', s['pkg']), pk)
    r = dict(spec=s)
    if s.get('file'):
        p = os.path.join(pk, s['file'])
        txt = open(p, encoding='utf-8').read()
        c = txt.count(s['old'])
        if c != 1:
            r['error'] = f'old string occurs {c} times'
            results[s['id']] = r
            print(s['id'], r['error'], file=sys.stderr)
            continue
        open(p, 'w', encoding='utf-8').write(txt.replace(s['old'], s['new']))
    cache = os.path.join(d, 'pion-cache')
    tenv = dict(env, PION_CACHE_DIR=cache)
    if not a.skip_tests:
        t0 = time.time()
        t = subprocess.run(['pionc', 'test', '--json', pk], capture_output=True, text=True, env=tenv)
        out = t.stdout
        passed = len(re.findall(r'"status"\s*:\s*"pass"', out))
        failed = len(re.findall(r'"status"\s*:\s*"fail"', out))
        m = re.search(r'"passed"\s*:\s*(\d+).*?"failed"\s*:\s*(\d+)', out, re.S)
        if m:
            passed, failed = int(m.group(1)), int(m.group(2))
        r['unit_tests'] = dict(rc=t.returncode, passed=passed, failed=failed, secs=round(time.time() - t0, 1),
                               tail=tail(t.stderr or out, 4))
    t0 = time.time()
    pr = subprocess.run(['bash', os.path.join(pk, 'proofs', 'run_proofs.sh')], capture_output=True, text=True,
                        env=tenv, cwd=d)
    log = pr.stdout + '\n' + pr.stderr
    open(os.path.join(d, 'run_proofs.log'), 'w').write(log)
    errs = [l for l in log.split('\n') if re.search(r'error:|FAIL|ERROR', l)][:8]
    r['proof_gate'] = dict(rc=pr.returncode, verdict='PASS' if pr.returncode == 0 else 'FAIL',
                           secs=round(time.time() - t0, 1), first_errors=errs, tail=tail(log, 6))
    results[s['id']] = r
    json.dump(results, open(res_path, 'w'), indent=1)
    shutil.rmtree(cache, ignore_errors=True)
    ut = r.get('unit_tests', {})
    print(f"{s['id']}: unit_tests rc={ut.get('rc')} pass={ut.get('passed')} fail={ut.get('failed')} | proofs {r['proof_gate']['verdict']} ({r['proof_gate']['secs']}s)", flush=True)

print('| id | kind | mutation | unit tests | proof gate |')
print('|---|---|---|---|---|')
for s in json.load(open(a.spec)):
    r = results.get(s['id'])
    if not r:
        continue
    ut = r.get('unit_tests', {})
    utxt = f"{'FAIL' if ut.get('rc') else 'PASS'} ({ut.get('passed')}/{(ut.get('passed') or 0) + (ut.get('failed') or 0)})" if ut else '-'
    print(f"| {s['id']} | {s['kind']} | {s.get('what', 'unmodified')} | {utxt} | {r.get('proof_gate', {}).get('verdict', r.get('error'))} |")
