"""RT-vcard differential corpus with spec-derived expectations (RFC 6350 / 2426 / 6868 / 2045 / 2397).

Every case is (id, raw bytes, expected canonical dump, rfc note). The expected dump uses exactly the
format of `audit/driver` `dump` mode:

  * `<id> ERR <VCardErrorKind>` for documents that must be rejected, or
  * `<id> OK {prop prop ...}{...}` where each prop is `[group.]NAME[;PARAM=v,v...]|value-view`,
    properties sorted by name (stable), parameters sorted by name with repeated ones merged,
    every byte < 0x20, DEL and the metacharacters `\\;,=|{}^":` and SP shown as `\\xHH`.
  * value-view: N / ADR = components joined by `;`, list items by `,`; ORG = units joined by `;`;
    PHOTO/LOGO/KEY/SOUND = `uri:<text>` | `bin:<decoded length>` | `!ERR`; everything else is
    `decoded_text()` (RFC 6350 unescape or Quoted-Printable decode) or `!ERR`.

The same expectation is used for `rt` mode (parse -> format_stream -> reparse): a canonical
serializer must be idempotent on every accepted case and never print FOLD!/UTF8! flags.
`python3 cases.py <out>` writes `<id> <hex>` lines for the drivers.
"""

import sys

META = set(b'\\;,=|{}^":') | {32}


def vis(s):
    b = s.encode() if isinstance(s, str) else s
    out = bytearray()
    for c in b:
        if c < 32 or c == 127 or c in META:
            out += b"\\x%02x" % c
        else:
            out.append(c)
    return out.decode()


def lst(*items):
    return ",".join(vis(i) for i in items)


def comps(*cs):
    """Each component is a list of items (or a single string)."""
    return ";".join(lst(*c) if isinstance(c, (list, tuple)) else lst(c) if c != "" else "" for c in cs)


def prop(name, view, params=(), group=None):
    """`view` is the raw decoded text, except for N/ADR/ORG (pre-rendered with comps/vis) and media."""
    if name not in ("N", "ADR", "ORG", "PHOTO", "LOGO", "KEY", "SOUND"):
        view = vis(view)
    s = (vis(group) + "." if group else "") + vis(name)
    for pn, vals in sorted(params, key=lambda x: x[0]):
        s += ";" + vis(pn) + "=" + lst(*vals)
    return (name, s + "|" + view)


def card(*props):
    ps = sorted(props, key=lambda p: p[0])
    return "{" + " ".join(p[1] for p in ps) + "}"


def ok(*cards):
    return "OK " + "".join(cards)


V4 = prop("VERSION", "4.0")
V3 = prop("VERSION", "3.0")
V21 = prop("VERSION", "2.1")
FNX = prop("FN", "x")


def doc(*lines, nl=b"\r\n", ver=b"VERSION:4.0", fn=b"FN:x"):
    body = [b"BEGIN:VCARD", ver] + ([fn] if fn else []) + list(lines) + [b"END:VCARD"]
    return nl.join(body) + nl


CASES = [
    # ---- lexical / unfolding (RFC 6350 §3.2) ----
    ("L01_fold_crlf_sp", doc(b"NOTE:ab\r\n cd"), ok(card(V4, FNX, prop("NOTE", "abcd"))), "§3.2 CRLF SP"),
    ("L02_fold_crlf_htab", doc(b"NOTE:ab\r\n\tcd"), ok(card(V4, FNX, prop("NOTE", "abcd"))), "§3.2 CRLF HTAB"),
    ("L03_fold_lf_sp", doc(b"NOTE:ab\n cd", nl=b"\n"), ok(card(V4, FNX, prop("NOTE", "abcd"))), "LF line ends"),
    ("L04_fold_multi", doc(b"NOTE:a\r\n b\r\n c\r\n  d"), ok(card(V4, FNX, prop("NOTE", "abc d"))), "only 1 WSP removed"),
    ("L05_fold_empty_cont", doc(b"NOTE:ab\r\n \r\n c"), ok(card(V4, FNX, prop("NOTE", "abc"))), "CRLF SP CRLF"),
    ("L06_no_final_eol", doc()[:-2], ok(card(V4, FNX)), "EOF without CRLF"),
    ("L07_lowercase_begin_end", b"begin:vcard\r\nversion:4.0\r\nfn:x\r\nend:vcard\r\n", ok(card(V4, FNX)), "names are case-insensitive"),
    ("L08_bom", b"\xef\xbb\xbf" + doc(), ok(card(V4, FNX)), "UTF-8 BOM"),
    ("L09_blank_lines_between", doc() + b"\r\n\r\n" + doc(), ok(card(V4, FNX), card(V4, FNX)), "lenient blank lines"),
    ("L10_nested_begin", b"BEGIN:VCARD\r\nBEGIN:VCARD\r\nEND:VCARD\r\nEND:VCARD\r\n", "ERR InvalidSyntax", "no nesting in vCard"),
    ("L11_unclosed", b"BEGIN:VCARD\r\nVERSION:4.0\r\nFN:x\r\n", "ERR InvalidSyntax", "missing END"),
    ("L12_fold_inside_utf8", doc(b"NOTE:\xe4\xb8\r\n \xad"), ok(card(V4, FNX, prop("NOTE", "中"))), "fold may split octets (§3.2)"),
    ("L13_group", doc(b"item1.EMAIL;TYPE=work:a@b"), ok(card(V4, FNX, prop("EMAIL", "a@b", [("TYPE", ["work"])], "item1"))), "group"),
    # ---- parameters (RFC 6350 §5, RFC 6868, RFC 2426 bare params) ----
    ("P01_quoted_meta", doc(b'ADR;LABEL="a:b;c,d":;;s;;;;'), ok(card(V4, FNX, prop("ADR", comps("", "", "s", "", "", "", ""), [("LABEL", ["a:b;c,d"])]))), "quoted param-value"),
    ("P02_rfc6868_known", doc(b"ADR;LABEL=\"x^ny^'z^^\":;;;;;;"), ok(card(V4, FNX, prop("ADR", ";;;;;;", [("LABEL", ['x\ny"z^'])]))), "RFC 6868 §3"),
    ("P03_rfc6868_unknown", doc(b"X-A;X-P=a^xb^:v"), ok(card(V4, FNX, prop("X-A", "v", [("X-P", ["a^xb^"])]))), "unknown ^x kept"),
    ("P04_param_case", doc(b"TEL;type=WORK:1"), ok(card(V4, FNX, prop("TEL", "1", [("TYPE", ["WORK"])]))), "param names case-insensitive"),
    ("P05_param_repeat", doc(b"TEL;TYPE=work;TYPE=voice:1"), ok(card(V4, FNX, prop("TEL", "1", [("TYPE", ["work", "voice"])]))), "repeated params"),
    ("P06_bare_v21", doc(b"TEL;WORK;VOICE:+1", ver=b"VERSION:2.1"), ok(card(V21, FNX, prop("TEL", "+1", [("TYPE", ["work", "voice"])]))), "2.1 bare TYPE"),
    ("P07_multivalue", doc(b"TEL;TYPE=work,voice:1"), ok(card(V4, FNX, prop("TEL", "1", [("TYPE", ["work", "voice"])]))), "§5 param list"),
    ("P08_unclosed_quote", doc(b'TEL;TYPE="work:1'), "ERR InvalidParameter", "unterminated DQUOTE"),
    ("P09_equals_in_value", doc(b"X-A;X-P=a=b:v"), ok(card(V4, FNX, prop("X-A", "v", [("X-P", ["a=b"])]))), "'=' is SAFE-CHAR"),
    # ---- Quoted-Printable (RFC 2045 §6.7 via vCard 2.1) ----
    ("Q01_qp_utf8_split_soft_break", doc(b"NOTE;ENCODING=QUOTED-PRINTABLE:=E4=B8=\r\n=AD", ver=b"VERSION:2.1"),
     ok(card(V21, FNX, prop("NOTE", "中", [("ENCODING", ["QUOTED-PRINTABLE"])]))), "multi-byte across soft break"),
    ("Q02_qp_lf_soft_break", doc(b"NOTE;QUOTED-PRINTABLE:abc=\ndef", ver=b"VERSION:2.1", nl=b"\n"),
     ok(card(V21, FNX, prop("NOTE", "abcdef", [("ENCODING", ["QUOTED-PRINTABLE"])]))), "=LF soft break"),
    ("Q03_qp_marker_in_foreign_param", doc(b"NOTE;X-HINT=QUOTED-PRINTABLE:a=", b"TEL:1"),
     ok(card(V4, FNX, prop("NOTE", "a=", [("X-HINT", ["QUOTED-PRINTABLE"])]), prop("TEL", "1"))),
     "only ENCODING=QUOTED-PRINTABLE enables QP soft breaks"),
    ("Q04_qp_hard_newline", doc(b"NOTE;ENCODING=QUOTED-PRINTABLE:a=0D=0Ab", ver=b"VERSION:2.1"),
     ok(card(V21, FNX, prop("NOTE", "a\r\nb", [("ENCODING", ["QUOTED-PRINTABLE"])]))), "encoded CRLF"),
    # ---- structured values (RFC 6350 §3.4, §6.2.2, §6.3.1, §6.6.4) ----
    ("S01_escaped_backslash_then_sep", doc(b"N:a\\\\;b;;;"), ok(card(V4, FNX, prop("N", comps("a\\", "b", "", "", "")))), "\\\\; = backslash + separator"),
    ("S02_escaped_comma_in_list", doc(b"N:Doe\\,Jr;John,Johnny;;;"), ok(card(V4, FNX, prop("N", comps("Doe,Jr", ["John", "Johnny"], "", "", "")))), "\\, inside component"),
    ("S03_org_escapes", doc(b"ORG:A\\;B;C\\\\;D"), ok(card(V4, FNX, prop("ORG", vis("A;B") + ";" + vis("C\\") + ";" + vis("D")))), "ORG units"),
    ("S04_adr_sparse", doc(b"ADR:;;123 Main;;;;"), ok(card(V4, FNX, prop("ADR", comps("", "", "123 Main", "", "", "", "")))), "empty components"),
    ("S05_n_too_few", doc(b"N:Doe"), ok(card(V4, FNX, prop("N", comps("Doe", "", "", "", "")))), "missing components = empty"),
    ("S06_n_empty", doc(b"N:;;;;"), ok(card(V4, FNX, prop("N", ";;;;"))), "all empty"),
    ("S07_upper_N_newline", doc(b"NOTE:a\\Nb\\nc"), ok(card(V4, FNX, prop("NOTE", "a\nb\nc"))), "\\N and \\n"),
    ("S08_unknown_escape_kept", doc(b"NOTE:a\\:b"), ok(card(V4, FNX, prop("NOTE", "a\\:b"))), "unknown escape preserved"),
    ("S09_trailing_backslash", doc(b"NOTE:a\\"), ok(card(V4, FNX, prop("NOTE", "a\\"))), "dangling backslash"),
    # ---- media (RFC 6350 §6.2.4, RFC 2397, RFC 2426 ENCODING=b) ----
    ("M01_data_base64", doc(b"PHOTO:data:image/png;base64,QUJD"), ok(card(V4, FNX, prop("PHOTO", "bin:3"))), "RFC 2397"),
    ("M02_data_upper_scheme", doc(b"PHOTO:DATA:image/png;BASE64,QUJD"), ok(card(V4, FNX, prop("PHOTO", "bin:3"))), "scheme case-insensitive"),
    ("M03_data_percent", doc(b"PHOTO:data:,Hello%2C%20W"), ok(card(V4, FNX, prop("PHOTO", "bin:8"))), "RFC 2397 non-base64 data is %-encoded"),
    ("M04_encoding_b", doc(b"PHOTO;ENCODING=b;TYPE=JPEG:QUJD", ver=b"VERSION:3.0"),
     ok(card(V3, FNX, prop("PHOTO", "bin:3", [("ENCODING", ["b"]), ("TYPE", ["JPEG"])]))), "RFC 2426 §5.8.4"),
    ("M05_data_bad_base64", doc(b"PHOTO:data:image/png;base64,@@@@"), ok(card(V4, FNX, prop("PHOTO", "!ERR"))), "reject invalid base64"),
    ("M06_data_no_comma", doc(b"PHOTO:data:image/png;base64"), ok(card(V4, FNX, prop("PHOTO", "!ERR"))), "malformed data: URI"),
    ("M07_http_uri", doc(b"PHOTO:http://e.x/a.png"), ok(card(V4, FNX, prop("PHOTO", "uri:" + vis("http://e.x/a.png")))), "URI reference"),
    # ---- UTF-8 (RFC 3629; parse_bytes) ----
    ("U01_overlong", doc(b"NOTE:\xc0\xaf"), "ERR InvalidUtf8", "overlong"),
    ("U02_surrogate", doc(b"NOTE:\xed\xa0\x80"), "ERR InvalidUtf8", "UTF-16 surrogate"),
    ("U03_truncated", doc(b"NOTE:\xe4\xb8"), "ERR InvalidUtf8", "truncated sequence"),
    ("U04_above_10ffff", doc(b"NOTE:\xf4\x90\x80\x80"), "ERR InvalidUtf8", "> U+10FFFF"),
    ("U05_emoji_zwj", doc("NOTE:\U0001F468‍\U0001F469‍\U0001F467".encode()), ok(card(V4, FNX, prop("NOTE", "\U0001F468‍\U0001F469‍\U0001F467"))), "4-byte + ZWJ"),
]


def fold_cases():
    """Long values whose 75-octet fold boundary lands on every byte of 2/3/4-byte sequences."""
    out = []
    glyphs = [("2b", "é"), ("3b", "中"), ("4b", "\U0001F600"), ("zwj", "\U0001F469‍\U0001F4BB"), ("comb", "é")]
    for tag, g in glyphs:
        for pad in range(68, 80):
            val = "a" * (pad - 5) + g * 30
            raw = doc(b"NOTE:" + val.encode())
            out.append(("F_%s_%d" % (tag, pad), raw, ok(card(V4, FNX, prop("NOTE", val))), "fold boundary"))
    return out


ALL = CASES + fold_cases()

if __name__ == "__main__":
    with open(sys.argv[1], "w") as fh:
        for cid, raw, _exp, _note in ALL:
            fh.write("%s %s\n" % (cid, raw.hex()))
