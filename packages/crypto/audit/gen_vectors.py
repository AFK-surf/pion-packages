"""Regenerate the reference-vector tail of packages/crypto/redteam_test.pion.

Usage: python3 packages/crypto/audit/gen_vectors.py > /tmp/vectors.pion
Needs python3 and node (Ed25519 vectors come from Node.js crypto).
"""
import hashlib, hmac, json, os, subprocess, sys
L = 2**252 + 27742317777372353535851937790883648493
def data(n, a, b): return bytes(((i*a+b) & 255) for i in range(n))
HL = [0,1,3,55,56,57,63,64,65,111,112,113,119,120,127,128,129,191,192,255,256,1000]
KL = [0,1,63,64,65,127,128,129,1024]
ML = [0,1,200]
def arr(name, xs):
    s = "///|\nfn %s() -> Array[String] {\n  [\n" % name
    for x in xs: s += '    "%s",\n' % x
    return s + "  ]\n}\n\n"
out = "///| Generated reference vectors (Python hashlib/hmac, Node.js crypto Ed25519). Do not edit by hand.\n\n"
out += "///|\nfn rt_hash_lengths() -> Array[Int] {\n  [%s]\n}\n\n" % ", ".join(map(str, HL))
for alg in ["sha1","sha256","sha384","sha512"]:
    out += arr("rt_%s_vectors" % alg, [hashlib.new(alg, data(n,7,3)).hexdigest() for n in HL])
out += "///|\nfn rt_hmac_key_lengths() -> Array[Int] {\n  [%s]\n}\n\n" % ", ".join(map(str, KL))
out += "///|\nfn rt_hmac_msg_lengths() -> Array[Int] {\n  [%s]\n}\n\n" % ", ".join(map(str, ML))
for alg in ["sha256","sha384","sha512"]:
    out += arr("rt_hmac_%s_vectors" % alg, [hmac.new(data(k,13,1), data(m,7,3), alg).hexdigest() for k in KL for m in ML])
def le(v, n): return v.to_bytes(n, "little").hex()
sc_in = [b"\xff"*64, le(L,64), le(L-1,64), le(2*L,64), le(2**256-1,64), le(L*(2**259)+5, 64), bytes(range(64)).hex()]
sc_in = [x.hex() if isinstance(x, bytes) else x for x in sc_in]
out += arr("rt_sc_reduce_inputs", sc_in)
out += arr("rt_sc_reduce_outputs", [le(int.from_bytes(bytes.fromhex(x), "little") % L, 32) for x in sc_in])
ed = json.loads(subprocess.check_output(["node", os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen_ed25519_vectors.js")]))
out += arr("rt_ed_seeds", [e[2] for e in ed])
out += "///|\nfn rt_ed_msg_lengths() -> Array[Int] {\n  [%s]\n}\n\n" % ", ".join(str(e[1]) for e in ed)
out += arr("rt_ed_pks", [e[3] for e in ed])
out += arr("rt_ed_sigs", [e[4] for e in ed])
sys.stdout.write(out.rstrip("\n") + "\n")
