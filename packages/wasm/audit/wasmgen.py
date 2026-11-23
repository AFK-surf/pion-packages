"""Tiny WebAssembly binary builder used by the red-team corpus generator.

Zero dependencies (Python 3 stdlib only). Every helper returns `bytes`.
"""

I32, I64, F32, F64, V128, FUNCREF, EXTERNREF = 0x7F, 0x7E, 0x7D, 0x7C, 0x7B, 0x70, 0x6F
EMPTY = 0x40


def u32(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def s64(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if (n == 0 and not (b & 0x40)) or (n == -1 and (b & 0x40)):
            out.append(b)
            return bytes(out)
        out.append(b | 0x80)


s32 = s64


def vec(items):
    items = list(items)
    return u32(len(items)) + b"".join(items)


def name(s):
    if isinstance(s, str):
        s = s.encode("utf-8")
    return u32(len(s)) + s


def section(sid, payload):
    return bytes([sid]) + u32(len(payload)) + payload


def functype(params, results):
    return b"\x60" + vec(bytes([p]) for p in params) + vec(bytes([r]) for r in results)


def limits(mn, mx=None, flags=None):
    if flags is None:
        flags = 0 if mx is None else 1
    out = bytes([flags]) + u32(mn)
    if mx is not None:
        out += u32(mx)
    return out


def code_entry(body, locals_=()):
    """`body` must include the final 0x0B."""
    loc = vec(u32(c) + bytes([t]) for c, t in locals_)
    payload = loc + body
    return u32(len(payload)) + payload


def module(
    types=(),
    imports=(),
    funcs=(),
    tables=(),
    mems=(),
    globals_=(),
    exports=(),
    start=None,
    elems=None,
    datacount=None,
    codes=None,
    data=None,
    customs=(),
    raw_sections=(),
):
    """Assemble a module.  Each list element is already-encoded entry bytes,
    except `types` (list of (params, results)) and `funcs` (list of type idx)."""
    out = b"\x00asm\x01\x00\x00\x00"
    if types:
        out += section(1, vec(functype(p, r) for p, r in types))
    if imports:
        out += section(2, vec(imports))
    if funcs:
        out += section(3, vec(u32(t) for t in funcs))
    if tables:
        out += section(4, vec(tables))
    if mems:
        out += section(5, vec(mems))
    if globals_:
        out += section(6, vec(globals_))
    if exports:
        out += section(7, vec(exports))
    if start is not None:
        out += section(8, u32(start))
    if elems is not None:
        out += section(9, vec(elems))
    if datacount is not None:
        out += section(12, u32(datacount))
    if codes is not None:
        out += section(10, vec(codes))
    if data is not None:
        out += section(11, vec(data))
    for cname, cdata in customs:
        out += section(0, name(cname) + cdata)
    for sid, payload in raw_sections:
        out += section(sid, payload)
    return out


def table_type(et, mn, mx=None, flags=None):
    return bytes([et]) + limits(mn, mx, flags)


def global_entry(vt, mut, init):
    return bytes([vt, 1 if mut else 0]) + init


def export(nm, kind, idx):
    return name(nm) + bytes([kind]) + u32(idx)


def import_func(mod, nm, tidx):
    return name(mod) + name(nm) + b"\x00" + u32(tidx)


def import_global(mod, nm, vt, mut):
    return name(mod) + name(nm) + b"\x03" + bytes([vt, 1 if mut else 0])


def import_mem(mod, nm, lim):
    return name(mod) + name(nm) + b"\x02" + lim


def import_table(mod, nm, tt):
    return name(mod) + name(nm) + b"\x01" + tt


def i32c(v):
    return b"\x41" + s32(v)


def i64c(v):
    return b"\x42" + s64(v)


def f32c(bits):
    return b"\x43" + bits.to_bytes(4, "little")


def f64c(bits):
    return b"\x44" + bits.to_bytes(8, "little")


def memarg(align, offset=0):
    return u32(align) + u32(offset)


def simd(sub):
    return b"\xfd" + u32(sub)


def v128c(bs=bytes(16)):
    return simd(12) + bytes(bs)


def single_func(body, params=(), results=(), locals_=(), mem=False, tables=(), globals_=(),
                elems=None, datacount=None, data=None, extra_types=(), exports=()):
    """Module with one function of type (params)->(results) at type index 0."""
    types = [(list(params), list(results))] + list(extra_types)
    return module(
        types=types,
        funcs=[0],
        tables=tables,
        mems=[limits(1)] if mem else (),
        globals_=globals_,
        exports=exports,
        elems=elems,
        datacount=datacount,
        codes=[code_entry(body, locals_)],
        data=data,
    )
