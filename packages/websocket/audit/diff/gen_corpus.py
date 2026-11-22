#!/usr/bin/env python3
"""Generate the red-team differential corpus shared by the Pion / Rust tungstenite /
Go coder/websocket decoders.

Line format (one case per line, space separated):
    <name> <role:s|c> <max_message_size> <chunk:0=whole|N bytes> <hex wire bytes>

Every runner prints one canonical line per case:
    <name> <event> <event> ... <terminal>
events:   T<len>:<fnv32> text, B<len>:<fnv32> binary, C<code>/C- close
terminal: END (input exhausted, no error) or ERR<close-code it would send>
Ping/Pong are deliberately not printed: coder/websocket never surfaces them.
"""
import struct, sys

MASK = b"\x37\xfa\x21\x3d"

def frame(op, payload=b"", fin=True, rsv=0, mask=True, len_override=None, ext=None):
    b0 = (0x80 if fin else 0) | (rsv << 4) | op
    mbit = 0x80 if mask else 0
    n = len(payload) if len_override is None else len_override
    if ext == 16 or (ext is None and 126 <= n <= 0xFFFF):
        hdr = bytes([b0, mbit | 126]) + struct.pack(">H", n)
    elif ext == 64 or (ext is None and n > 0xFFFF):
        hdr = bytes([b0, mbit | 127]) + struct.pack(">Q", n)
    else:
        hdr = bytes([b0, mbit | n])
    if mask:
        body = bytes(p ^ MASK[i & 3] for i, p in enumerate(payload))
        return hdr + MASK + body
    return hdr + payload

T, B, C, P, O, CONT = 1, 2, 8, 9, 10, 0
def text(s, **k): return frame(T, s if isinstance(s, bytes) else s.encode(), **k)
def close(code=None, reason=b"", **k):
    return frame(C, b"" if code is None else struct.pack(">H", code) + reason, **k)

cases = []
def add(name, wire, role="s", maxsz=65536, chunks=(0, 1, 3)):
    for ch in chunks:
        cases.append((f"{name}@{ch}", role, maxsz, ch, wire))

# --- sanity -----------------------------------------------------------------
add("basic_text", text("Hello"))
add("basic_binary", frame(B, bytes(range(200))))
add("basic_empty_text", text(""))
add("text_65536", text("a" * 65536), maxsz=1 << 20, chunks=(0, 4096))
add("ping_then_text", frame(P, b"hi") + text("x"))

# --- §6 UTF-8 fail-fast (Autobahn 6.4.x) -----------------------------------
kosme = "κόσμε".encode()
# 6.4.1: valid | invalid F4 90 80 80 | valid; we drop the last fragment so a
# fail-fast implementation must error and a fail-late one keeps waiting (END).
add("utf8_6_4_1_failfast_no_final",
    text(kosme, fin=False) + frame(CONT, b"\xf4\x90\x80\x80", fin=False))
add("utf8_6_4_1_full",
    text(kosme, fin=False) + frame(CONT, b"\xf4\x90\x80\x80", fin=False) + frame(CONT, b"edited"))
add("utf8_6_4_2_failfast_no_final",
    text(kosme + b"\xf4", fin=False) + frame(CONT, b"\x90\x80\x80", fin=False))
add("utf8_firstfrag_ff_no_final", text(b"abc\xff", fin=False))
add("utf8_firstfrag_overlong_no_final", text(b"\xc0\x80", fin=False))
add("utf8_firstfrag_surrogate_no_final", text(b"\xed\xa0\x80", fin=False))
add("utf8_firstfrag_bad_prefix_no_final", text(b"a\xf4\x90", fin=False))
add("utf8_split_valid_4byte", text(b"\xf0\x9f", fin=False) + frame(CONT, b"\x8c\x8d"))
add("utf8_split_valid_3byte_1_1_1",
    text(b"\xe4", fin=False) + frame(CONT, b"\xb8", fin=False) + frame(CONT, b"\x96"))
add("utf8_valid_prefix_incomplete_at_fin", text(b"\xe4\xb8", fin=False) + frame(CONT, b""))
# close then data
add("close_reason_bad_utf8", close(1000, b"\xff"))

# --- control frames ----------------------------------------------------------
add("ping_0", frame(P) + text("ok"))
add("ping_125", frame(P, b"p" * 125) + text("ok"))
add("ping_126_ext16", frame(P, b"p" * 126))
add("ping_fin0", frame(P, b"x", fin=False))
add("close_1byte", frame(C, b"\x03"))
add("close_empty", close())
add("close_1000", close(1000, b"bye"))
add("close_1005", close(1005))
add("close_1006", close(1006))
add("close_2999", close(2999))
add("close_3000", close(3000))
add("ping_in_fragments",
    text("ab", fin=False) + frame(P, b"x") + frame(CONT, b"cd", fin=False) + frame(O, b"") + frame(CONT, b"ef"))
add("close_in_fragments", text("ab", fin=False) + close(1000))
add("data_after_close", close(1000) + text("after"))
add("close_after_close", close(1000) + close(1001))

# --- framing / lengths --------------------------------------------------------
add("len64_msb_set", frame(B, b"", len_override=0x8000000000000000, ext=64)[:14])
add("len64_max_positive", frame(B, b"", len_override=0x7FFFFFFFFFFFFFFF, ext=64)[:14])
add("len64_4gb", frame(B, b"", len_override=1 << 32, ext=64)[:14])
add("len16_nonminimal_5", frame(B, b"hello", ext=16))
add("len64_nonminimal_5", frame(B, b"hello", ext=64))
add("rsv1", text("x", rsv=4))
add("rsv2", text("x", rsv=2))
add("rsv3", text("x", rsv=1))
add("opcode_3", frame(3, b""))
add("opcode_11", frame(11, b""))
add("unmasked_from_client", text("x", mask=False))
add("masked_from_server", text("x"), role="c")
add("server_unmasked_ok", text("hi", mask=False) + frame(B, b"\x00\x01", mask=False), role="c")
add("orphan_continuation", frame(CONT, b"x"))
add("text_during_fragment", text("a", fin=False) + text("b"))
add("empty_fragments", text("", fin=False) + frame(CONT, b"", fin=False) + frame(CONT, b""))

# --- size limits --------------------------------------------------------------
add("limit_exact", frame(B, b"z" * 1024), maxsz=1024)
add("limit_over_single", frame(B, b"z" * 1025), maxsz=1024)
add("limit_over_fragments", frame(B, b"z" * 600, fin=False) + frame(CONT, b"z" * 600), maxsz=1024)
add("limit_header_only_huge", frame(B, b"", len_override=1 << 30, ext=64)[:14], maxsz=1024)

# --- fragment storm (10,000 x 10 bytes) -------------------------------------
storm = text(b"0123456789", fin=False) + b"".join(
    frame(CONT, b"0123456789", fin=False) for _ in range(9998)) + frame(CONT, b"0123456789")
add("fragment_storm_10k", storm, maxsz=1 << 20, chunks=(0, 4096))

with open(sys.argv[1], "w") as f:
    for name, role, mx, ch, wire in cases:
        f.write(f"{name} {role} {mx} {ch} {wire.hex()}\n")
print(f"wrote {len(cases)} cases to {sys.argv[1]}", file=sys.stderr)
