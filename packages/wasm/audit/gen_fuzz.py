#!/usr/bin/env python3
"""Deterministic red-team fuzz corpus generator for packages/wasm.

usage: gen_fuzz.py <out_dir> <count> [--seed N]

Families (round-robin):
  typed   : stack-type-aware random function bodies (mostly valid, every operator family
            incl. SIMD 0xFD 0..255, bulk 0xFC, ref types, multi-value blocks, br_table,
            polymorphic `unreachable` regions) inside a rich module context
  raw     : uniformly random opcode/immediate soup in the same context
  mutate  : byte-level mutations (flip / insert / delete / LEB-stretch / truncate) of
            typed-valid bodies and of the hand-written targeted vectors
  struct  : random module structure (limits flags, elem flags & items, data modes,
            const exprs, imports/exports/start) with trivial code
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wasmgen import *  # noqa: E402,F401,F403
from targeted import cases as targeted_cases  # noqa: E402

NUM = [I32, I64, F32, F64]
ALLV = [I32, I64, F32, F64, V128, FUNCREF, EXTERNREF]

# ----------------------------------------------------------------------------- context
CTX_TYPES = [
    ([], []),
    ([I32], [I32]),
    ([I32, I32], [I32, I64]),
    ([], [V128]),
    ([FUNCREF], []),
    ([I32], []),
    ([], [I32]),
    ([I64, F32], [F64]),
    ([V128, V128], [V128]),
    ([EXTERNREF], [EXTERNREF]),
]
IMPORTS = [
    import_func("env", "f", 1),
    import_global("env", "gi", I32, False),
    import_global("env", "gf", FUNCREF, False),
    import_global("env", "gm", I64, True),
]
# globals: 0 gi(i32 imm) 1 gf(funcref imm) 2 gm(i64 mut) 3 (i32 mut) 4 (v128 imm) 5 (externref mut)
GLOBAL_TYPES = [(I32, False), (FUNCREF, False), (I64, True), (I32, True), (V128, False), (EXTERNREF, True)]
DEF_GLOBALS = [
    global_entry(I32, True, i32c(5) + b"\x0b"),
    global_entry(V128, False, v128c() + b"\x0b"),
    global_entry(EXTERNREF, True, b"\xd0\x6f\x0b"),
]
TABLES = [table_type(FUNCREF, 2), table_type(EXTERNREF, 1)]
TABLE_TYPES = [FUNCREF, EXTERNREF]
ELEMS = [u32(1) + b"\x00" + vec([u32(0)]),            # passive funcref [0]
         u32(3) + b"\x00" + vec([u32(1), u32(2)]),    # declare func 1 2
         u32(5) + bytes([EXTERNREF]) + vec([b"\xd0\x6f\x0b"])]  # passive externref
NUM_FUNCS = 3  # import 0, defined 1 (fuzz body), defined 2 (helper)


def ctx_module(body_type, body, locals_=()):
    return module(
        types=CTX_TYPES,
        imports=IMPORTS,
        funcs=[body_type, 0],
        tables=TABLES,
        mems=[limits(1, 2)],
        globals_=DEF_GLOBALS,
        exports=[export("fuzz", 0, 1), export("mem", 2, 0)],
        elems=ELEMS,
        datacount=1,
        codes=[code_entry(body, locals_), code_entry(b"\x0b")],
        data=[b"\x01" + vec([b"x", b"y"])],
    )


# ----------------------------------------------------------------------------- SIMD signature table
def simd_sigs():
    """sub -> (params, results) for plain (no-immediate) 0xFD ops per the SIMD spec."""
    v = V128
    un, bi = ([v], [v]), ([v, v], [v])
    sig = {}
    sig[14] = bi
    for s, t in zip(range(15, 21), [I32, I32, I32, I64, F32, F64]):
        sig[s] = ([t], [v])
    for s in range(0x23, 0x4D):
        sig[s] = bi
    sig[0x4D] = un
    for s in range(0x4E, 0x52):
        sig[s] = bi
    sig[0x52] = ([v, v, v], [v])
    sig[0x53] = ([v], [I32])
    for s in (0x5E, 0x5F, 0x60, 0x61, 0x62, 0x67, 0x68, 0x69, 0x6A, 0x74, 0x75, 0x7A,
              0x7C, 0x7D, 0x7E, 0x7F, 0x80, 0x81, 0x87, 0x88, 0x89, 0x8A, 0x94,
              0xA0, 0xA1, 0xA7, 0xA8, 0xA9, 0xAA, 0xC0, 0xC1, 0xC7, 0xC8, 0xC9, 0xCA,
              0xE0, 0xE1, 0xE3, 0xEC, 0xED, 0xEF) + tuple(range(0xF8, 0x100)):
        sig[s] = un
    for s in (0x63, 0x64, 0x83, 0x84, 0xA3, 0xA4, 0xC3, 0xC4):
        sig[s] = ([v], [I32])
    for s in (0x6B, 0x6C, 0x6D, 0x8B, 0x8C, 0x8D, 0xAB, 0xAC, 0xAD, 0xCB, 0xCC, 0xCD):
        sig[s] = ([v, I32], [v])
    for s in (0x65, 0x66, 0x6E, 0x6F, 0x70, 0x71, 0x72, 0x73, 0x76, 0x77, 0x78, 0x79, 0x7B,
              0x82, 0x85, 0x86, 0x8E, 0x8F, 0x90, 0x91, 0x92, 0x93, 0x95, 0x96, 0x97, 0x98, 0x99,
              0x9B, 0x9C, 0x9D, 0x9E, 0x9F, 0xAE, 0xB1, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA,
              0xBC, 0xBD, 0xBE, 0xBF, 0xCE, 0xD1, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xDB,
              0xDC, 0xDD, 0xDE, 0xDF) + tuple(range(0xE4, 0xEC)) + tuple(range(0xF0, 0xF8)):
        sig[s] = bi
    return sig


SIMD = simd_sigs()
SIMD_ALL = list(range(0, 256))

# plain numeric ops: opcode -> (params, results)
NUMOPS = {}
for op in [0x45]:
    NUMOPS[op] = ([I32], [I32])
for op in range(0x46, 0x50):
    NUMOPS[op] = ([I32, I32], [I32])
NUMOPS[0x50] = ([I64], [I32])
for op in range(0x51, 0x5B):
    NUMOPS[op] = ([I64, I64], [I32])
for op in range(0x5B, 0x61):
    NUMOPS[op] = ([F32, F32], [I32])
for op in range(0x61, 0x67):
    NUMOPS[op] = ([F64, F64], [I32])
for op in range(0x67, 0x6A):
    NUMOPS[op] = ([I32], [I32])
for op in range(0x6A, 0x79):
    NUMOPS[op] = ([I32, I32], [I32])
for op in range(0x79, 0x7C):
    NUMOPS[op] = ([I64], [I64])
for op in range(0x7C, 0x8B):
    NUMOPS[op] = ([I64, I64], [I64])
for op in range(0x8B, 0x92):
    NUMOPS[op] = ([F32], [F32])
for op in range(0x92, 0x99):
    NUMOPS[op] = ([F32, F32], [F32])
for op in range(0x99, 0xA0):
    NUMOPS[op] = ([F64], [F64])
for op in range(0xA0, 0xA7):
    NUMOPS[op] = ([F64, F64], [F64])
CONV = {0xA7: (I64, I32), 0xA8: (F32, I32), 0xA9: (F32, I32), 0xAA: (F64, I32), 0xAB: (F64, I32),
        0xAC: (I32, I64), 0xAD: (I32, I64), 0xAE: (F32, I64), 0xAF: (F32, I64), 0xB0: (F64, I64),
        0xB1: (F64, I64), 0xB2: (I32, F32), 0xB3: (I32, F32), 0xB4: (I64, F32), 0xB5: (I64, F32),
        0xB6: (F64, F32), 0xB7: (I32, F64), 0xB8: (I32, F64), 0xB9: (I64, F64), 0xBA: (I64, F64),
        0xBB: (F32, F64), 0xBC: (F32, I32), 0xBD: (F64, I64), 0xBE: (I32, F32), 0xBF: (I64, F64),
        0xC0: (I32, I32), 0xC1: (I32, I32), 0xC2: (I64, I64), 0xC3: (I64, I64), 0xC4: (I64, I64)}
for op, (a, b) in CONV.items():
    NUMOPS[op] = ([a], [b])
SAT = {0: (F32, I32), 1: (F32, I32), 2: (F64, I32), 3: (F64, I32), 4: (F32, I64), 5: (F32, I64),
       6: (F64, I64), 7: (F64, I64)}
LOADS = {0x28: (I32, 2), 0x29: (I64, 3), 0x2A: (F32, 2), 0x2B: (F64, 3), 0x2C: (I32, 0), 0x2D: (I32, 0),
         0x2E: (I32, 1), 0x2F: (I32, 1), 0x30: (I64, 0), 0x31: (I64, 0), 0x32: (I64, 1), 0x33: (I64, 1),
         0x34: (I64, 2), 0x35: (I64, 2)}
STORES = {0x36: (I32, 2), 0x37: (I64, 3), 0x38: (F32, 2), 0x39: (F64, 3), 0x3A: (I32, 0), 0x3B: (I32, 1),
          0x3C: (I64, 0), 0x3D: (I64, 1), 0x3E: (I64, 2)}
SIMD_MEM_NAT = {0: 4, 1: 3, 2: 3, 3: 3, 4: 3, 5: 3, 6: 3, 7: 0, 8: 1, 9: 2, 10: 3, 11: 4, 92: 2, 93: 3}
SIMD_LANE = {21: (16, None, I32), 22: (16, None, I32), 23: (16, I32, None), 24: (8, None, I32),
             25: (8, None, I32), 26: (8, I32, None), 27: (4, None, I32), 28: (4, I32, None),
             29: (2, None, I64), 30: (2, I64, None), 31: (4, None, F32), 32: (4, F32, None),
             33: (2, None, F64), 34: (2, F64, None)}
SIMD_MEMLANE = {84: (0, 16), 85: (1, 8), 86: (2, 4), 87: (3, 2), 88: (0, 16), 89: (1, 8), 90: (2, 4), 91: (3, 2)}


def const_of(t, r):
    if t == I32:
        return i32c(r.choice([0, 1, -1, 0x7FFFFFFF, -0x80000000, r.randrange(-1000, 1000)]))
    if t == I64:
        return i64c(r.choice([0, -1, 1 << 63 - 1, -(1 << 63), r.randrange(-10**12, 10**12)]))
    if t == F32:
        return f32c(r.choice([0, 0x80000000, 0x7F800000, 0xFF800000, 0x7FC00000, 0x7F800001,
                              0xFFFFFFFF, 0x00000001, 0x3F800000, r.getrandbits(32)]))
    if t == F64:
        return f64c(r.choice([0, 1 << 63, 0x7FF0000000000000, 0x7FF8000000000000, 0x7FF0000000000001,
                              0xFFFFFFFFFFFFFFFF, 1, 0x3FF0000000000000, r.getrandbits(64)]))
    if t == V128:
        return v128c(bytes(r.getrandbits(8) for _ in range(16)))
    if t == FUNCREF:
        return r.choice([b"\xd0\x70", b"\xd2\x01", b"\xd2\x02", b"\x23\x01"])
    if t == EXTERNREF:
        return b"\xd0\x6f"
    return b"\x01"


class Typed:
    """Stack-aware body generator.  Keeps an approximate operand-type stack."""

    def __init__(self, r, params, results, locals_types):
        self.r = r
        self.locals = list(params) + list(locals_types)
        self.stack = []
        self.frames = [("func", [], list(results), 0, False)]  # kind, params, results, height, unreachable
        self.out = bytearray()

    def label_types(self, depth):
        f = self.frames[-1 - depth]
        return f[1] if f[0] == "loop" else f[2]

    def ensure(self, types):
        """Push constants so the stack top matches `types`."""
        for t in types:
            self.out += const_of(t, self.r)
            self.stack.append(t)

    def take(self, types):
        h = self.frames[-1][3]
        n = len(types)
        if len(self.stack) - h >= n and self.stack[len(self.stack) - n:] == list(types):
            del self.stack[len(self.stack) - n:]
            return
        # make operands available: drop whatever is above the frame then push fresh
        while len(self.stack) > h:
            self.out += b"\x1a"
            self.stack.pop()
        self.ensure(types)
        del self.stack[len(self.stack) - n:]

    def op(self, code, params, results, imm=b""):
        self.take(params)
        self.out += code + imm
        self.stack += results

    def close_frame(self):
        kind, params, results, h, _ = self.frames[-1]
        self.take_exact(results)
        self.out += b"\x0b"
        self.frames.pop()
        self.stack += results

    def take_exact(self, results):
        h = self.frames[-1][3]
        cur = self.stack[h:]
        if cur == list(results):
            del self.stack[h:]
            return
        while len(self.stack) > h:
            self.out += b"\x1a"
            self.stack.pop()
        self.ensure(results)
        del self.stack[h:]

    def step(self):
        r = self.r
        k = r.random()
        if k < 0.05 and len(self.frames) < 6:
            bt_choice = r.random()
            if bt_choice < 0.3:
                bt, ps, rs = b"\x40", [], []
            elif bt_choice < 0.6:
                t = r.choice(ALLV)
                bt, ps, rs = bytes([t]), [], [t]
            else:
                ti = r.randrange(len(CTX_TYPES))
                bt, ps, rs = u32(ti), CTX_TYPES[ti][0], CTX_TYPES[ti][1]
            kind = r.choice(["block", "loop", "if"])
            if kind == "if":
                self.take(list(ps) + [I32])
                self.out += b"\x04" + bt
            else:
                self.take(list(ps))
                self.out += (b"\x02" if kind == "block" else b"\x03") + bt
            self.frames.append((kind, list(ps), list(rs), len(self.stack), False))
            self.stack += list(ps)
            return
        if k < 0.09 and len(self.frames) > 1:
            kind, ps, rs, h, _ = self.frames[-1]
            if kind == "if" and r.random() < 0.5:
                self.take_exact(rs)
                self.out += b"\x05"
                self.frames[-1] = ("else", ps, rs, h, False)
                self.stack += list(ps)
                return
            self.close_frame()
            return
        if k < 0.12:
            d = r.randrange(len(self.frames))
            lt = self.label_types(d)
            which = r.random()
            if which < 0.3:
                self.take(lt)
                self.out += b"\x0c" + u32(d)
                self.unreach()
            elif which < 0.6:
                self.take(list(lt) + [I32])
                self.out += b"\x0d" + u32(d)
                self.stack += list(lt)
            else:
                ar = len(lt)
                tg = [x for x in range(len(self.frames)) if len(self.label_types(x)) == ar]
                if r.random() < 0.15:
                    tg = list(range(len(self.frames)))
                ts = [r.choice(tg) for _ in range(r.randrange(0, 4))]
                self.take(list(lt) + [I32])
                self.out += b"\x0e" + vec(u32(x) for x in ts) + u32(d)
                self.unreach()
            return
        if k < 0.14:
            self.out += b"\x00"
            self.unreach()
            # ops on a bottom stack: pop nothing explicitly
            for _ in range(r.randrange(0, 3)):
                c = r.choice([b"\x1b", b"\x1a", b"\x6a", b"\xd1", simd(0x7B), simd(0x94), b"\x1c\x01\x70",
                              b"\x0e\x01\x00\x00", b"\x45"])
                self.out += c
            return
        if k < 0.16:
            self.take(self.frames[0][2])
            self.out += b"\x0f"
            self.unreach()
            return
        family = r.random()
        if family < 0.25:
            op = r.choice(list(NUMOPS))
            ps, rs = NUMOPS[op]
            self.op(bytes([op]), ps, rs)
        elif family < 0.33:
            t = r.choice(ALLV)
            self.out += const_of(t, r)
            self.stack.append(t)
        elif family < 0.40:
            if not self.locals:
                return
            li = r.randrange(len(self.locals))
            t = self.locals[li]
            c = r.choice([b"\x20", b"\x21", b"\x22"])
            if c == b"\x20":
                self.op(c, [], [t], u32(li))
            elif c == b"\x21":
                self.op(c, [t], [], u32(li))
            else:
                self.op(c, [t], [t], u32(li))
        elif family < 0.45:
            gi = r.randrange(len(GLOBAL_TYPES))
            t, mut = GLOBAL_TYPES[gi]
            if mut and r.random() < 0.5:
                self.op(b"\x24", [t], [], u32(gi))
            else:
                self.op(b"\x23", [], [t], u32(gi))
        elif family < 0.52:
            if r.random() < 0.5:
                op = r.choice(list(LOADS))
                t, nat = LOADS[op]
                self.op(bytes([op]), [I32], [t], memarg(r.choice([nat, nat, r.randrange(0, nat + 1)]), r.randrange(0, 70000)))
            else:
                op = r.choice(list(STORES))
                t, nat = STORES[op]
                self.op(bytes([op]), [I32, t], [], memarg(r.randrange(0, nat + 1), r.randrange(0, 70)))
        elif family < 0.60:
            sub = r.choice(SIMD_ALL)
            if sub in SIMD:
                ps, rs = SIMD[sub]
                self.op(simd(sub), ps, rs)
            elif sub in SIMD_MEM_NAT:
                nat = SIMD_MEM_NAT[sub]
                if sub == 11:
                    self.op(simd(sub), [I32, V128], [], memarg(r.randrange(0, nat + 1)))
                else:
                    self.op(simd(sub), [I32], [V128], memarg(r.randrange(0, nat + 1)))
            elif sub == 12:
                self.op(simd(12), [], [V128], bytes(r.getrandbits(8) for _ in range(16)))
            elif sub == 13:
                self.op(simd(13), [V128, V128], [V128], bytes(r.randrange(32) for _ in range(16)))
            elif sub in SIMD_LANE:
                n, pin, pout = SIMD_LANE[sub]
                if pin is None:
                    self.op(simd(sub), [V128], [pout], bytes([r.randrange(n)]))
                else:
                    self.op(simd(sub), [V128, pin], [V128], bytes([r.randrange(n)]))
            elif sub in SIMD_MEMLANE:
                nat, n = SIMD_MEMLANE[sub]
                if sub >= 88:
                    self.op(simd(sub), [I32, V128], [], memarg(nat) + bytes([r.randrange(n)]))
                else:
                    self.op(simd(sub), [I32, V128], [V128], memarg(nat) + bytes([r.randrange(n)]))
            else:  # unassigned opcode -- give it two v128 operands
                self.op(simd(sub), [V128, V128], [V128])
        elif family < 0.66:
            s = r.randrange(0, 8)
            a, b = SAT[s]
            self.op(b"\xfc" + u32(s), [a], [b])
        elif family < 0.74:
            c = r.randrange(8, 18)
            if c == 8:
                self.op(b"\xfc\x08\x00\x00", [I32, I32, I32], [])
            elif c == 9:
                self.op(b"\xfc\x09\x00", [], [])
            elif c == 10:
                self.op(b"\xfc\x0a\x00\x00", [I32, I32, I32], [])
            elif c == 11:
                self.op(b"\xfc\x0b\x00", [I32, I32, I32], [])
            elif c == 12:
                e, t = r.choice([(0, 0), (2, 1), (0, 1), (2, 0)])
                self.op(b"\xfc\x0c" + u32(e) + u32(t), [I32, I32, I32], [])
            elif c == 13:
                self.op(b"\xfc\x0d" + u32(r.randrange(3)), [], [])
            elif c == 14:
                a, b = r.choice([(0, 0), (1, 1), (0, 1)])
                self.op(b"\xfc\x0e" + u32(a) + u32(b), [I32, I32, I32], [])
            else:
                t = r.randrange(2)
                et = TABLE_TYPES[t]
                if c == 15:
                    self.op(b"\xfc\x0f" + u32(t), [et, I32], [I32])
                elif c == 16:
                    self.op(b"\xfc\x10" + u32(t), [], [I32])
                else:
                    self.op(b"\xfc\x11" + u32(t), [I32, et, I32], [])
        elif family < 0.80:
            t = r.randrange(2)
            et = TABLE_TYPES[t]
            if r.random() < 0.5:
                self.op(b"\x25" + u32(t), [I32], [et])
            else:
                self.op(b"\x26" + u32(t), [I32, et], [])
        elif family < 0.86:
            w = r.random()
            if w < 0.3:
                t = r.choice(ALLV)
                self.op(b"\x1c\x01" + bytes([t]), [t, t, I32], [t])
            elif w < 0.6:
                t = r.choice(NUM + [V128])
                self.op(b"\x1b", [t, t, I32], [t])
            elif w < 0.8:
                t = r.choice([FUNCREF, EXTERNREF])
                self.op(b"\xd1", [t], [I32])
            else:
                self.op(b"\xd2" + u32(r.randrange(NUM_FUNCS)), [], [FUNCREF])
        elif family < 0.93:
            fi = r.randrange(NUM_FUNCS)
            ti = [1, CTX_BODY_TYPE[0], 0][fi]
            ps, rs = CTX_TYPES[ti]
            self.op(b"\x10" + u32(fi), ps, rs)
        else:
            ti = r.randrange(len(CTX_TYPES))
            ps, rs = CTX_TYPES[ti]
            self.op(b"\x11" + u32(ti) + u32(0 if r.random() < 0.95 else 1), list(ps) + [I32], rs)

    def unreach(self):
        f = self.frames[-1]
        del self.stack[f[3]:]
        self.frames[-1] = (f[0], f[1], f[2], f[3], True)

    def finish(self):
        while len(self.frames) > 1:
            kind = self.frames[-1][0]
            if kind == "if" and self.frames[-1][1] != self.frames[-1][2]:
                self.take_exact(self.frames[-1][2])
                self.out += b"\x05"
                f = self.frames[-1]
                self.frames[-1] = ("else", f[1], f[2], f[3], False)
                self.stack += list(f[1])
            self.close_frame()
        self.take_exact(self.frames[0][2])
        self.out += b"\x0b"
        return bytes(self.out)


CTX_BODY_TYPE = [0]


def gen_typed(r):
    ti = r.randrange(len(CTX_TYPES))
    CTX_BODY_TYPE[0] = ti
    ps, rs = CTX_TYPES[ti]
    loc = [(r.randrange(1, 3), r.choice(ALLV)) for _ in range(r.randrange(0, 3))]
    lt = [t for c, t in loc for _ in range(c)]
    g = Typed(r, ps, rs, lt)
    for _ in range(r.randrange(1, 40)):
        g.step()
    return ctx_module(ti, g.finish(), loc)


def gen_raw(r):
    ti = r.randrange(len(CTX_TYPES))
    body = bytearray()
    depth = 0
    for _ in range(r.randrange(1, 20)):
        c = r.random()
        if c < 0.15:
            body += bytes([r.choice([2, 3, 4])]) + bytes([r.choice([0x40, I32, I64, F32, F64, V128, FUNCREF, EXTERNREF, 0, 1, 3, 9, 11])])
            depth += 1
        elif c < 0.2 and depth:
            body += b"\x0b"
            depth -= 1
        elif c < 0.5:
            sub = r.randrange(0, 256)
            body += simd(sub)
            if sub in SIMD_MEM_NAT or sub in SIMD_MEMLANE:
                body += memarg(r.randrange(0, 6), r.randrange(0, 4))
                if sub in SIMD_MEMLANE:
                    body += bytes([r.randrange(20)])
            elif sub in (12, 13):
                body += bytes(r.randrange(40) for _ in range(16))
            elif sub in SIMD_LANE:
                body += bytes([r.randrange(20)])
        elif c < 0.6:
            body += b"\xfc" + u32(r.randrange(0, 19)) + u32(r.randrange(3)) + u32(r.randrange(2))
        else:
            op = r.randrange(0, 0xD3)
            body += bytes([op])
            if op in (0x0C, 0x0D, 0x10, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x3F, 0x40, 0xD2):
                body += u32(r.randrange(0, 6))
            elif 0x28 <= op <= 0x3E:
                body += memarg(r.randrange(0, 5), r.randrange(0, 3))
            elif op in (0x41, 0x42):
                body += s64(r.randrange(-200, 200))
            elif op == 0x43:
                body += bytes(r.getrandbits(8) for _ in range(4))
            elif op == 0x44:
                body += bytes(r.getrandbits(8) for _ in range(8))
            elif op == 0x0E:
                body += vec(u32(r.randrange(3)) for _ in range(r.randrange(3))) + u32(r.randrange(3))
            elif op == 0x11:
                body += u32(r.randrange(11)) + u32(r.randrange(3))
            elif op == 0x1C:
                body += u32(r.choice([0, 1, 1, 2])) + bytes([r.choice(ALLV)])
            elif op == 0xD0:
                body += bytes([r.choice([FUNCREF, EXTERNREF, 0x40])])
    body += b"\x0b" * (depth + 1)
    return ctx_module(ti, bytes(body))


def mutate(r, data):
    b = bytearray(data)
    for _ in range(r.randrange(1, 4)):
        if not b:
            break
        m = r.random()
        p = r.randrange(8, len(b)) if len(b) > 8 else 0
        if m < 0.35:
            b[p] = r.getrandbits(8)
        elif m < 0.5:
            b[p] ^= 1 << r.randrange(8)
        elif m < 0.65:
            b.insert(p, r.choice([0x00, 0x0B, 0x1A, 0x80, 0xFD, 0xFC, r.getrandbits(8)]))
        elif m < 0.8 and len(b) > 9:
            del b[p]
        elif m < 0.9:
            # LEB stretch: x -> x|0x80, 0x00 (non-minimal) -- keeps value, grows length
            if b[p] < 0x80:
                b[p:p + 1] = bytes([b[p] | 0x80, 0x00])
        else:
            b = b[: r.randrange(8, len(b) + 1)]
    return bytes(b)


def gen_struct(r):
    types = [([], []), ([I32], [])]
    tables, mems, imports, globals_, exports, elems, data = [], [], [], [], [], None, None
    for _ in range(r.randrange(0, 3)):
        fl = r.choice([0, 1, 1, 2, 3, 4, 5, 7, 8])
        mn = r.choice([0, 1, 2, 65536, 65537, 0xFFFFFFFF])
        mx = r.choice([0, 1, 3, 65536, 65537, 0xFFFFFFFF])
        lim = bytes([fl]) + (s64(mn) if fl & 4 else u32(mn)) + ((s64(mx) if fl & 4 else u32(mx)) if fl & 1 else b"")
        if r.random() < 0.5:
            mems.append(lim)
        else:
            tables.append(bytes([r.choice([FUNCREF, EXTERNREF, I32])]) + lim)
    for _ in range(r.randrange(0, 3)):
        k = r.randrange(4)
        if k == 0:
            imports.append(import_func("m", "f%d" % len(imports), r.randrange(3)))
        elif k == 1:
            imports.append(import_global("m", "g%d" % len(imports), r.choice(ALLV), r.random() < 0.3))
        elif k == 2:
            imports.append(import_mem("m", "m%d" % len(imports), limits(1, r.choice([None, 2]))))
        else:
            imports.append(import_table("m", "t%d" % len(imports), table_type(r.choice([FUNCREF, EXTERNREF]), 1)))
    nimp_g = sum(1 for i in imports if i[-2] in ALLV and i[-3] == 3) if imports else 0
    for _ in range(r.randrange(0, 3)):
        t = r.choice(ALLV)
        init = r.choice([const_of(t, r), const_of(r.choice(ALLV), r), b"\x23" + u32(r.randrange(4)),
                         i32c(1) + i32c(2) + b"\x6a", b"\x01", b"\xd2" + u32(r.randrange(3))])
        globals_.append(global_entry(t, r.random() < 0.5, init + b"\x0b"))
    if r.random() < 0.6:
        elems = []
        for _ in range(r.randrange(0, 3)):
            fl = r.randrange(0, 9)
            seg = u32(fl)
            if fl in (0, 4):
                seg += i32c(r.choice([0, 1])) + b"\x0b"
            if fl in (2, 6):
                seg += u32(r.randrange(2)) + i32c(0) + b"\x0b"
            if fl in (1, 2, 3):
                seg += bytes([r.choice([0, 0, 1])])
            if fl in (5, 6, 7):
                seg += bytes([r.choice([FUNCREF, EXTERNREF])])
            if fl < 4:
                seg += vec(u32(r.randrange(3)) for _ in range(r.randrange(0, 3)))
            else:
                seg += vec(r.choice([b"\xd0\x70\x0b", b"\xd0\x6f\x0b", b"\xd2\x00\x0b", b"\x23\x00\x0b", b"\x41\x00\x0b"])
                           for _ in range(r.randrange(0, 3)))
            elems.append(seg)
    if r.random() < 0.5:
        data = []
        for _ in range(r.randrange(0, 3)):
            md = r.choice([0, 1, 2, 3])
            seg = u32(md)
            if md == 2:
                seg += u32(r.randrange(2))
            if md in (0, 2):
                seg += r.choice([i32c(0), i64c(0), b"\x23\x00"]) + b"\x0b"
            seg += vec([b"a"] * r.randrange(0, 3))
            data.append(seg)
    nf = r.randrange(0, 3)
    for _ in range(r.randrange(0, 3)):
        exports.append(export(r.choice(["a", "b", "é", "a\u0000b", "\"q\"", "\\"]), r.randrange(4), r.randrange(3)))
    body = r.choice([b"\x0b", b"\xd2\x00\x1a\x0b", b"\x00\x0b"])
    dc = None
    if data is not None and r.random() < 0.5:
        dc = len(data) + r.choice([0, 0, 0, 1])
    return module(types=types, imports=imports, funcs=[0] * nf, tables=tables, mems=mems,
                  globals_=globals_, exports=exports,
                  start=r.choice([None, None, 0, 1]), elems=elems, datacount=dc,
                  codes=[code_entry(body)] * nf if nf else None, data=data)


def main():
    out = sys.argv[1]
    count = int(sys.argv[2])
    seed = int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 20261123
    r = random.Random(seed)
    os.makedirs(out, exist_ok=True)
    seeds = [b for _, e, b, _ in targeted_cases() if len(b) < 4096]
    valid_pool = []
    with open(os.path.join(out, "manifest.tsv"), "w") as man:
        for i in range(count):
            fam = ["typed", "typed", "raw", "mutate", "struct"][i % 5]
            if fam == "typed":
                b = gen_typed(r)
                if len(valid_pool) < 2000:
                    valid_pool.append(b)
            elif fam == "raw":
                b = gen_raw(r)
            elif fam == "mutate":
                src = r.choice(valid_pool if valid_pool and r.random() < 0.7 else seeds)
                b = mutate(r, src)
            else:
                b = gen_struct(r)
            with open(os.path.join(out, f"{i}.wasm"), "wb") as f:
                f.write(b)
            man.write(f"{i}\t{fam}\t?\n")
    print(f"wrote {count} fuzz modules to {out} (seed {seed})")


if __name__ == "__main__":
    main()
