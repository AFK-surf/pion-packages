"""Third-party tie-breaker: ICU4C `ubidi` (macOS /usr/lib/libicucore.dylib via ctypes).
Prints per-UTF-16-unit resolved levels (before L1) for `<dir><text>` records given on argv.
ICU applies the same UAX #9 rules (incl. BD16) and is used only to adjudicate Pion-vs-Rust splits."""
import ctypes, sys

icu = ctypes.CDLL("/usr/lib/libicucore.dylib")
icu.ubidi_open.restype = ctypes.c_void_p
icu.ubidi_getLevels.restype = ctypes.POINTER(ctypes.c_uint8)
icu.ubidi_setPara.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32, ctypes.c_uint8, ctypes.c_void_p,
                              ctypes.POINTER(ctypes.c_int)]
icu.ubidi_getLevels.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
icu.ubidi_getParaLevel.argtypes = [ctypes.c_void_p]
icu.ubidi_close.argtypes = [ctypes.c_void_p]
icu.ubidi_setReorderingOptions.argtypes = [ctypes.c_void_p, ctypes.c_uint32]


def levels(rec):
    d, text = rec[0], rec[1:]
    u16 = text.encode("utf-16-le")
    n = len(u16) // 2
    err = ctypes.c_int(0)
    b = icu.ubidi_open()
    lvl = {"0": 0, "1": 1}.get(d, 0xFE)  # UBIDI_DEFAULT_LTR
    icu.ubidi_setPara(b, u16, n, lvl, None, ctypes.byref(err))
    p = icu.ubidi_getLevels(b, ctypes.byref(err))  # NB: getLevels applies L1 for trailing WS
    out = [p[i] for i in range(n)]
    pl = icu.ubidi_getParaLevel(b)
    icu.ubidi_close(b)
    # collapse to one level per scalar value
    res, i = [], 0
    for ch in text:
        res.append(out[i]); i += 2 if ord(ch) > 0xFFFF else 1
    return pl, res


if __name__ == "__main__":
    for rec in sys.argv[1:]:
        rec = rec.encode("ascii", "backslashreplace").decode("unicode_escape")
        print(repr(rec), levels(rec))
