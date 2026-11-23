#!/usr/bin/env python3
"""Large-sample differential driver for packages/mime (red-team RT-mime).

Generates deterministic adversarial corpora per mode, runs
  Pion native debug / native release / wasm32 debug / wasm32 release (node),
  Go 1.27 stdlib (mime, mime/multipart, mime/quotedprintable, net/http sniffing) and
  Rust mime 0.3.18 / infer 0.16.0,
then (1) asserts the four Pion modes are byte-identical with no trap and (2) buckets every Pion-vs-reference
divergence into a named class so REDTEAM_REPORT.md can cite counts and minimal samples.

usage: diff.py <out_dir> <bin_dir> [--n N] [--modes mt,cd,...]
"""
import os
import random
import subprocess
import sys
from collections import Counter, defaultdict

OUT = sys.argv[1]
BIN = sys.argv[2]
N = 5000
MODES = "mt,cd,fmt,qpdec,qpenc,qpencb,ewdec,ewq,ewb,sniff,mp".split(",")
for i, a in enumerate(sys.argv):
    if a == "--n":
        N = int(sys.argv[i + 1])
    if a == "--modes":
        MODES = sys.argv[i + 1].split(",")
WASM_RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")
R = random.Random(20261123)


def enc(*fields):
    return " ".join("." + f.hex() for f in fields)


# ---------------------------------------------------------------- media type / disposition corpus
TYPES = [b"text/plain", b"TEXT/HTML", b"application/json", b"multipart/form-data", b"image/svg+xml",
         b"application/vnd.ms-excel", b"x-custom/x.y-z_1", b"*/*", b"text/*", b"a/b"]
DISPS = [b"attachment", b"inline", b"form-data", b"ATTACHMENT", b"x-token"]
NAMES = [b"charset", b"CHARSET", b"Charset", b"filename", b"name", b"boundary", b"title", b"q", b"a", b"x-y"]
CHARSETS = [b"utf-8", b"UTF-8", b"us-ascii", b"iso-8859-1", b"ISO-8859-1", b"windows-1252", b"", b"utf8",
            b"latin1", b"koi8-r", b"bogus"]
TOKVALS = [b"utf-8", b"abc", b"x.y", b"1", b"A_B", b"{x}", b"a+b", b"%41", b"*", b"'"]
QUOTEDVALS = [b'"plain"', b'"with space"', b'"esc\\"q"', b'"back\\\\slash"', b'"\\x\\y"', b'"C:\\dev\\go\\x.txt"',
              b'"semi;colon"', b'"tab\there"', b'"\xc3\xa9t\xc3\xa9"', b'"\xff\xfe"', b'"nul\x00"', b'""',
              b'"unterminated', b'"a\\', b'"cr\rx"', b'"lf\nx"', b'"del\x7f"']
PCT = [b"%41%42", b"%e2%82%ac", b"%E2%82%AC", b"%4", b"%zz", b"%", b"%ff", b"abc", b"%c3%a9", b"%00", b"%25"]


def rand_param(names=NAMES):
    k = R.choice(names)
    r = R.random()
    if r < 0.35:
        v = R.choice(TOKVALS)
    elif r < 0.6:
        v = R.choice(QUOTEDVALS)
    elif r < 0.75:
        k = k + b"*"
        v = R.choice(CHARSETS) + b"'" + R.choice([b"", b"en", b"en-us"]) + b"'" + R.choice(PCT)
    else:
        # RFC 2231 continuation section (possibly shuffled / sparse / non-zero start)
        idx = R.choice([0, 0, 1, 2, 3, 10, "00", "01"])
        star = R.random() < 0.5
        k = k + b"*" + str(idx).encode() + (b"*" if star else b"")
        if star and idx == 0:
            v = R.choice(CHARSETS) + b"''" + R.choice(PCT)
        elif star:
            v = R.choice(PCT)
        else:
            v = R.choice(TOKVALS + QUOTEDVALS[:6])
    sp1 = R.choice([b"", b" ", b"  ", b"\t"])
    sp2 = R.choice([b"", b"", b" "])
    return b";" + sp1 + k + sp2 + b"=" + sp2 + v


def continuation_family(base):
    """Structured RFC 2231 scenarios: ordered, reversed, gaps, mixed with plain and `*`."""
    secs = [b"%s*0*=utf-8''%%e4%%b8" % base, b"%s*1*=%%ad" % base, b"%s*2=tail" % base]
    sc = R.randrange(8)
    if sc == 0:
        pass
    elif sc == 1:
        secs.reverse()
    elif sc == 2:
        secs = [secs[0], secs[2]]
    elif sc == 3:
        secs = secs[1:]
    elif sc == 4:
        secs = [b'%s="fallback.txt"' % base] + secs
    elif sc == 5:
        secs = secs + [b"%s*=utf-8''star" % base]
    elif sc == 6:
        secs = [b"%s*0=a" % base, b"%s*1=b" % base, b"%s*0=a" % base]
    else:
        secs = [b'%s="fb"' % base, b"%s*=windows-1252''na%%EFve.txt" % base]
    R.shuffle(secs) if R.random() < 0.3 else None
    return b"".join(b"; " + s for s in secs)


def mutate(b):
    b = bytearray(b)
    for _ in range(R.randint(1, 3)):
        op = R.randrange(4)
        pos = R.randrange(len(b) + 1)
        ch = R.choice(b'";=\\ \t\r\n\x00\x7f\xff(),/*%\'{}@?[]')
        if op == 0:
            b[pos:pos] = bytes([ch])
        elif op == 1 and len(b) > 1:
            del b[min(pos, len(b) - 1)]
        elif op == 2 and len(b) > 0:
            b[min(pos, len(b) - 1)] = ch
        else:
            b[pos:pos] = b[pos:pos + R.randint(1, 8)]
    return bytes(b)


CURATED_MT = [
    b"text/plain", b"text/plain;", b"text/plain; ;", b"text/plain;;charset=x", b" text/plain ; charset = utf-8 ",
    b"text/plain; charset=utf-8; CHARSET=latin1", b"text/plain; charset=utf-8; charset=utf-8",
    b"text/plain (comment)", b"text/plain; charset=utf-8 (comment)", b"text/plain; a=b c",
    b'text/plain; a="x\\"y"', b'text/plain; a="x\\\\y"', b'text/plain; a="\\a\\b"', b"text/plain; a=",
    b"text/plain; =b", b"text/plain; a", b"text/", b"/plain", b"text", b"", b"text/plain/x", b"text/pl@in",
    b"text/plain;\r\n charset=x", b"text/plain; a*0=x; a*1=y", b"text/plain; a*1=y; a*0=x",
    b"text/plain; a*0=x; a*2=z", b"text/plain; a*1=y", b"text/plain; a=1; a*0=2", b"text/plain; a*=utf-8''x; a*0=y",
    b"text/plain; a*=utf-8''%ff", b"text/plain; a*=''x", b"text/plain; a*=utf-8'x", b"text/plain; a*=x",
    b"text/plain; a*=UTF-8''%e2%82%ac; a=fallback", b"text/plain; a*0*=utf-8''%e2%82; a*1*=%ac",
    b"text/plain; a*00=x", b"text/plain; a*01=x", b"text/plain; a*b=x", b"text/plain; *=x", b"text/plain; a**=x",
    b"text/plain; a={x}", b"text/plain; a=[x]", b"text/plain; a=x\x00", b"text/plain; a=\xc3\xa9",
    b"text/plain; a=1;", b"text/plain; a=1 ;", b"text/plain; a=1; ", b"text/plain\x00", b"\x00text/plain",
]
CURATED_CD = [
    b'attachment; filename="../../etc/passwd"', b'attachment; filename="C:\\dev\\go\\foo.txt"',
    b"attachment; filename=\"fallback.txt\"; filename*=windows-1252''na%EFve.txt",
    b"attachment; filename=\"fallback.txt\"; filename*=UTF-8''%ff.txt",
    b"attachment; filename=\"fallback.txt\"; filename*=UTF-8''%zz.txt",
    b"attachment; filename=\"fallback.txt\"; filename*=''x.txt",
    b"attachment; filename*=UTF-8''%e2%82%ac%20rates.txt", b"attachment; filename*=utf-8'en'x.txt",
    b"attachment; filename*0*=utf-8''a%20; filename*1=b.txt", b"attachment; filename=a; filename=a",
    b"attachment; filename=a; FILENAME=b", b"inline", b"inline;", b"form-data; name=x; filename=\"\"",
    b"attachment; filename=\"a\\\"b\"", b"attachment/x", b"attachment x", b"",
    b'form-data; name="f"; filename="\xe2\x80\xaetxt.exe"',
]


def gen_header(kind):
    out = list(CURATED_MT if kind == "mt" else CURATED_CD)
    head = TYPES if kind == "mt" else DISPS
    while len(out) < N:
        h = R.choice(head)
        r = R.random()
        if r < 0.5:
            h += b"".join(rand_param() for _ in range(R.randint(0, 4)))
            if R.random() < 0.15:
                h += R.choice([b";", b"; ", b";;", b" ;"])
        elif r < 0.75:
            h += continuation_family(R.choice([b"filename", b"title", b"a"]))
        else:
            h = mutate(h + b"".join(rand_param() for _ in range(R.randint(1, 3))))
        out.append(h)
    return [enc(x) for x in out]


def gen_fmt():
    out = []
    vals = [b"", b"x", b"a b", b"tab\there", b'q"uote', b"back\\slash", b"\xc3\xa9", b"\xe4\xb8\xad\xe6\x96\x87", b"\x01",
            b"\x7f", b"{x}", b"a;b", b"=", b"%41", b"*", b"'"]
    names = [b"charset", b"A", b"a", b"x-y", b"title*", b"a'b", b"%", b"sp ace", b"", b"\xc3\xa9", b"q"]
    while len(out) < max(1000, N // 5):
        t = R.choice([b"text/plain", b"TEXT/Plain", b"a/b", b"bad", b"a/b/c", b"a /b", b"/b", b"a/"])
        f = [t]
        used = set()
        for _ in range(R.randint(0, 3)):
            k = R.choice(names)
            if k.lower() in used:
                continue
            used.add(k.lower())
            f += [k, R.choice(vals) + (R.choice(vals) if R.random() < 0.3 else b"")]
        out.append(enc(*f))
    return out


# ---------------------------------------------------------------- QP corpus
def gen_qpdec():
    atoms = [b"abc", b"=41", b"=4a", b"=4A", b"=ZZ", b"=4", b"=", b"= ", b"=\r\n", b"=\n", b"=  \r\n", b"=\t\n",
             b" ", b"\t", b"  \r\n", b"\r\n", b"\n", b"\r", b"\x00", b"\x01", b"\x80\xff", b"\x7f", b"=0D=0A", b"==41",
             b"=\r", b"=3D", b"=3d", b"x" * 80, b"=e9", b"=E9"]
    out = [enc(b"")]
    while len(out) < N:
        out.append(enc(b"".join(R.choice(atoms) for _ in range(R.randint(1, 10)))))
    return out


def gen_qpenc():
    atoms = [b"a", b"=", b" ", b"\t", b"\r\n", b"\n", b"\r", b"\x00", b"\xc3\xa9", b"\xff", b"x" * 73, b"x" * 74,
             b"x" * 75, b"x" * 76, b"y" * 150, b" \r\n", b"\t\n", b"~", b"!"]
    out = []
    while len(out) < N:
        out.append(enc(b"".join(R.choice(atoms) for _ in range(R.randint(1, 8)))))
    return out


# ---------------------------------------------------------------- RFC 2047 corpus
def b64(s):
    import base64
    return base64.b64encode(s)


def gen_ewdec():
    words = [b"=?utf-8?q?caf=C3=A9?=", b"=?UTF-8?Q?a_b?=", b"=?utf-8?b?" + b64("中文".encode()) + b"?=",
             b"=?iso-8859-1?q?caf=E9?=", b"=?us-ascii?q?caf=E9?=", b"=?windows-1252?q?=80?=", b"=?bogus?q?x?=",
             b"=?utf-8?b?5Lit5paH?=", b"=?utf-8?b?5Lit5pa?=", b"=?utf-8?b?5Lit5paH=?=", b"=?utf-8?b?!!!!?=",
             b"=?utf-8?q?a b?=", b"=?utf-8?q?=ZZ?=", b"=?utf-8?q?=4?=", b"=?utf-8?x?abc?=", b"=?utf-8*en?q?x?=",
             b"=?utf-8?q?\x00?=", b"=?utf-8?q?=FF?=", b"=??q?x?=", b"=?utf-8?q??=", b"=?utf-8?q?a?b?=",
             b'"=?utf-8?q?quoted?="', b"(=?utf-8?q?comment?=)", b"=?utf-8?Q?=E2=82?= =?utf-8?Q?=AC?="]
    seps = [b" ", b"  ", b"\t", b"\r\n ", b" x ", b"", b"plain", b", "]
    out = []
    while len(out) < N:
        parts = []
        for _ in range(R.randint(1, 4)):
            parts.append(R.choice(words) if R.random() < 0.8 else R.choice([b"text", b"=?", b"?=", b"=?utf-8?q?"]))
            parts.append(R.choice(seps))
        out.append(enc(b"".join(parts)))
    return out


def gen_ewenc():
    chars = ["a", " ", "_", "=", "?", "\t", "é", "中", "😀", "\u202e", "x" * 40, "\x01", "~"]
    out = []
    while len(out) < max(1000, N // 5):
        s = "".join(R.choice(chars) for _ in range(R.randint(1, 40)))
        out.append(enc(s.encode()))
    return out


# ---------------------------------------------------------------- sniff corpus
def sniff_samples():
    S = {
        "png": b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR", "jpeg": b"\xff\xd8\xff\xe0\x00\x10JFIF\x00",
        "gif87": b"GIF87a\x01\x00", "gif89": b"GIF89a\x01\x00", "webp": b"RIFF\x24\x00\x00\x00WEBPVP8 ",
        "wav": b"RIFF\x24\x00\x00\x00WAVEfmt ", "avi": b"RIFF\x24\x00\x00\x00AVI LIST", "bmp": b"BM\x36\x00\x00\x00\x00\x00",
        "bmw_text": b"BMW is a car maker\n", "pdf": b"%PDF-1.7\n%\xe2\xe3", "pdf_ws": b"\n %PDF-1.4\n",
        "zip": b"PK\x03\x04\x14\x00\x00\x00\x08\x00", "zip_empty": b"PK\x05\x06" + b"\x00" * 18,
        "docx": b"PK\x03\x04\x14\x00\x06\x00\x08\x00\x00\x00!\x00" + b"\x00" * 16 + b"[Content_Types].xml" + b"\x00" * 40 + b"word/document.xml",
        "epub": b"PK\x03\x04\x14\x00\x00\x00\x00\x00" + b"\x00" * 20 + b"mimetypeapplication/epub+zip",
        "jar": b"PK\x03\x04\x14\x00\x08\x08\x08\x00" + b"\x00" * 20 + b"META-INF/MANIFEST.MF",
        "gzip": b"\x1f\x8b\x08\x00\x00\x00\x00\x00", "zstd": b"\x28\xb5\x2f\xfd\x00", "bz2": b"BZh91AY&SY",
        "xz": b"\xfd7zXZ\x00\x00", "7z": b"7z\xbc\xaf\x27\x1c\x00\x04", "rar": b"Rar!\x1a\x07\x01\x00",
        "elf": b"\x7fELF\x02\x01\x01\x00", "macho": b"\xcf\xfa\xed\xfe\x07\x00\x00\x01", "pe": b"MZ\x90\x00\x03\x00",
        "wasm": b"\x00asm\x01\x00\x00\x00", "ico": b"\x00\x00\x01\x00\x01\x00", "ttf": b"\x00\x01\x00\x00\x00\x0c",
        "otf": b"OTTO\x00\x0c", "woff": b"wOFF\x00\x01", "woff2": b"wOF2\x00\x01",
        "mp4_isom": b"\x00\x00\x00\x20ftypisom\x00\x00\x02\x00", "mp4_mp41": b"\x00\x00\x00\x20ftypmp41\x00\x00\x00\x00",
        "mp4_mp42": b"\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00", "mp4_iso5": b"\x00\x00\x00\x18ftypiso5\x00\x00\x00\x00",
        "mp4_iso6": b"\x00\x00\x00\x18ftypiso6\x00\x00\x00\x00", "mp4_mmp4": b"\x00\x00\x00\x18ftypmmp4\x00\x00\x00\x00",
        "m4a": b"\x00\x00\x00\x20ftypM4A \x00\x00\x00\x00", "m4v": b"\x00\x00\x00\x20ftypM4V \x00\x00\x00\x00",
        "mov_qt": b"\x00\x00\x00\x14ftypqt  \x00\x00\x00\x00", "3gp": b"\x00\x00\x00\x14ftyp3gp5\x00\x00\x00\x00",
        "avif": b"\x00\x00\x00\x1cftypavif\x00\x00\x00\x00", "heic": b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00",
        "mif1": b"\x00\x00\x00\x18ftypmif1\x00\x00\x00\x00",
        "webm": b"\x1aE\xdf\xa3\x9fB\x86\x81\x01B\xf7\x81\x01B\xf2\x81\x04B\xf3\x81\x08B\x82\x84webmB\x87",
        "mkv": b"\x1aE\xdf\xa3\x93B\x82\x88matroskaB\x87\x81\x04",
        "ogg_opus": b"OggS\x00\x02" + b"\x00" * 22 + b"OpusHead", "ogg_vorbis": b"OggS\x00\x02" + b"\x00" * 22 + b"\x01vorbis",
        "ogg_theora": b"OggS\x00\x02" + b"\x00" * 22 + b"\x80theora",
        "flac": b"fLaC\x00\x00\x00\x22", "mp3_id3": b"ID3\x03\x00\x00\x00", "mp3_frame": b"\xff\xfb\x90\x00",
        "aac_adts": b"\xff\xf1\x50\x80", "midi": b"MThd\x00\x00\x00\x06", "sqlite": b"SQLite format 3\x00\x10\x00",
        "tar": b"a.txt" + b"\x00" * 252 + b"ustar\x0000", "psd": b"8BPS\x00\x01", "tiff": b"II*\x00\x08\x00",
        "svg": b"<svg xmlns='http://www.w3.org/2000/svg'/>", "svg_xml": b"<?xml version='1.0'?>\n<svg/>",
        "xml": b"<?xml version='1.0'?><root/>", "html": b"<!DOCTYPE html><html>", "html_b": b"<b>bold</b>",
        "html_br": b"<br>", "html_p_sp": b"<p class=x>hi</p>", "html_a_gt": b"<a>link</a>", "html_bom": b"\xef\xbb\xbf<html>",
        "htmlfoo": b"<htmlfoo>", "json": b'{"a": 1}', "json_arr": b"[1,2,3]\n", "not_json": b"{not json}",
        "text": b"hello world\n", "text_utf8": "héllo 中文\n".encode(), "utf8_bom": b"\xef\xbb\xbfhello",
        "utf16le_bom": b"\xff\xfeh\x00i\x00", "utf16be_bom": b"\xfe\xff\x00h\x00i", "bad_utf8": b"abc\xff\xfedef",
        "nul_text": b"abc\x00def", "ps": b"%!PS-Adobe-3.0", "rtf": b"{\\rtf1\\ansi", "class": b"\xca\xfe\xba\xbe\x00\x00\x00\x34",
        "macho_fat": b"\xca\xfe\xba\xbe\x00\x00\x00\x02", "lz4": b"\x04\x22\x4d\x18", "cab": b"MSCF\x00\x00",
        "deb": b"!<arch>\ndebian", "swf": b"FWS\x0a", "crx": b"Cr24\x02\x00", "jxl": b"\xff\x0a", "dcm": b"\x00" * 128 + b"DICM",
    }
    return S


def gen_sniff():
    S = sniff_samples()
    out, names = [], []
    for k, v in S.items():
        full = v + bytes(R.randrange(256) for _ in range(64)) if R.random() < 0 else v
        out.append(enc(full))
        names.append(k)
        for t in (1, 2, 3, 4, 8, 11, 12, 16, 32, 63, 64):
            if t < len(v):
                out.append(enc(v[:t]))
                names.append(k + "[:%d]" % t)
    while len(out) < max(2000, N // 2):
        n = R.choice([0, 1, 2, 3, 4, 7, 8, 12, 16, 64, 300, 600])
        out.append(enc(bytes(R.randrange(256) for _ in range(n)) if R.random() < 0.5 else
                       bytes(R.choice(b"abc {}[]<>\n\t\xc3\xa9") for _ in range(n))))
        names.append("rand")
    return out, names


# ---------------------------------------------------------------- multipart corpus
def gen_mp():
    out = []
    bnds = [b"b", b"abc", b"----WebKitFormBoundary7MA4YWxkTrZu0gW", b"a" * 70, b"with space", b"x'()+_,-./:=?"]
    for _ in range(N):
        bd = R.choice(bnds)
        nl = R.choice([b"\r\n", b"\r\n", b"\n"])
        parts = []
        for i in range(R.randint(0, 4)):
            hdrs = []
            if R.random() < 0.9:
                hdrs.append(b'Content-Disposition: form-data; name="f%d"' % i)
            if R.random() < 0.3:
                hdrs.append(b"Content-Type: text/plain")
            r = R.random()
            if r < 0.05:
                hdrs.append(b" folded-continuation")
            elif r < 0.1:
                hdrs.append(b"Bad Name: x")
            elif r < 0.13:
                hdrs.append(b"NoColon")
            elif r < 0.16:
                hdrs.append(b"Content-Disposition: form-data; name=\"dup\"")
            body = R.choice([b"", b"v", b"line1" + nl + b"line2", b"\r", b"\n", b"x\r\n--" + bd + b"x",
                             b"x\n--" + bd + nl + b"smuggled", b"--" + bd, b"tail\r", b"--" + bd + b"--junk",
                             b"x\r\n--" + bd + b" \t", b"\x00\xff" * 4])
            hsep = R.choice([nl, nl, nl, b"\r\n" if nl == b"\n" else b"\n"])
            parts.append(hsep.join(hdrs) + hsep + hsep + body)
        pre = R.choice([b"", b"", b"preamble" + nl, b"junk--" + bd + nl, b"--" + bd + b"X" + nl])
        delim_pad = R.choice([b"", b"", b" ", b"\t ", b"x"])
        msg = pre
        for i, p in enumerate(parts):
            msg += (nl if i > 0 else b"") + b"--" + bd + delim_pad + nl + p
        close = R.choice([nl + b"--" + bd + b"--", nl + b"--" + bd + b"--" + nl, nl + b"--" + bd + b"-- \r\n",
                          nl + b"--" + bd + b"--garbage" + nl, b"", nl + b"--" + bd + nl])
        if not parts:
            close = close.lstrip(b"\r\n")
        msg += close + R.choice([b"", b"epilogue", nl + b"--" + bd + nl + b"\r\n\r\nfake"])
        out.append(enc(bd, msg))
    return out


# ---------------------------------------------------------------- runner / classifier
def run(binname, mode, path, wasm=False):
    cmd = (["node", WASM_RT, os.path.join(BIN, binname)] if wasm else [os.path.join(BIN, binname)]) + [mode, path]
    p = subprocess.run(cmd, capture_output=True, timeout=1800)
    if p.returncode != 0:
        return None, "exit=%d %s" % (p.returncode, p.stderr.decode(errors="replace")[-300:])
    return p.stdout.decode(errors="replace").split("\n")[:-1], None


def unhex(f):
    return bytes.fromhex(f[1:]) if f.startswith(".") else f.encode()


def classify(mode, inp, pion, ref):
    """Return a bucket name for a Pion-vs-reference divergence."""
    raw = unhex(inp.split(" ")[0]) if inp else b""
    pe, re_ = pion.startswith("ERR"), ref.startswith("ERR")
    if mode in ("mt", "cd"):
        low = raw.lower()
        if not pe and re_:
            if b"\\" in raw:
                return "pion_ok_go_err:escape"
            return "pion_ok_go_err:other"
        if pe and not re_:
            kind = pion.split(" ")[1] if " " in pion else ""
            if kind == "DuplicateParameter":
                return "pion_err_go_ok:duplicate(equal-value or a*/a*0 mix)"
            if kind in ("InvalidCharset", "InvalidPercentEncoding") or (kind == "InvalidParameterValue" and b"*=" in raw):
                return "P1:pion_err_go_ok:bad_ext_value_kills_whole_header(%s)" % kind
            if kind == "InvalidParameterName" and b"*" in raw:
                return "pion_err_go_ok:rfc2231_section_name(%s)" % kind
            if b"{" in raw or b"}" in raw:
                return "pion_err_go_ok:brace_token"
            return "pion_err_go_ok:%s" % kind
        if b"\\" in raw:
            return "value_diff:backslash_escape(MSIE path)"
        if b"*" in raw:
            return "value_diff:rfc2231"
        return "value_diff:other(mostly Go laxness: ? inside text, gives up after a malformed word)"
    if mode == "qpdec":
        if pe and not re_:
            if b"=" in raw:
                return "pion_err_go_ok:qp_equals(=XX invalid / trailing =)"
            return "pion_err_go_ok:other"
        if not pe and re_:
            return "pion_ok_go_err:" + ref.split(" ")[1][:40]
        return "bytes_diff"
    if mode == "ewdec":
        if re_ and not pe:
            return "pion_ok_go_err(Go fails whole header):" + ref.split(" ")[1][:40]
        for needle, label in ((b"?q?a b?=", "go_decodes_SP_inside_encoded_word(RFC 2047 sec.2 forbids; Pion literal)"),
                              (b"=E2=82?=", "P2:utf8_char_split_across_adjacent_words(Go joins, Pion literal)"),
                              (b"?q?\x00?=", "q_payload_with_CTL(Go rejects word, Pion decodes NUL)"),
                              (b"=FF?=", "invalid_utf8_payload(Go emits raw bytes, Pion literal)"),
                              (b"us-ascii?q?caf=E9", "us-ascii_8bit(Go U+FFFD, Pion literal)")):
            if needle in raw:
                return label
        return "value_diff:other(mostly Go laxness: ? inside text, gives up after a malformed word)"
    if mode == "mp":
        pe, re_ = pion.endswith("END") is False, ref.endswith("END") is False
        bd, msg = [unhex(x) for x in inp.split(" ")[:2]]
        pparts = [x for x in pion.split(" | ") if x.startswith("P ")]
        gparts = [x for x in ref.split(" | ") if x.startswith("P ")]
        bare_lf = (b"\n--" + bd) in msg.replace(b"\r\n--" + bd, b"")
        if len(pparts) > len(gparts):
            return "P1:pion_sees_MORE_parts" + (":bare_LF_delimiter_in_CRLF_body" if bare_lf else ":other")
        if len(pparts) < len(gparts):
            return "pion_fewer_parts:" + ("bare_LF_split_then_header_error" if bare_lf else
                                          "header_strictness(obs-fold/space-before-colon/no-colon)")
        if pparts == gparts:
            if b"--" + bd + b"--" in msg and pe != re_ and not pe:
                return "end_state:pion_END_go_ERR(close_delimiter_followed_by_garbage / unexpected line)"
            return "end_state:pion %s / go %s" % ("ERR" if pe else "END", "ERR" if re_ else "END")
        for a, b in zip(pparts, gparts):
            if a != b:
                ba, bb = unhex(a.split(" ")[3]), unhex(b.split(" ")[3])
                if bb == ba + b"\r":
                    return "body:go_keeps_trailing_CR(LF-mode message, CRLF before delimiter)"
                if bb.startswith(ba) and (b"\n--" + bd) in bb:
                    return "body:pion_splits_at_bare_LF_delimiter"
                return "body:other"
        return "body:other"
    return "diff"


def main():
    os.makedirs(OUT, exist_ok=True)
    gens = {"mt": lambda: gen_header("mt"), "cd": lambda: gen_header("cd"), "fmt": gen_fmt, "qpdec": gen_qpdec,
            "qpenc": gen_qpenc, "qpencb": gen_qpenc, "ewdec": gen_ewdec, "ewq": gen_ewenc, "ewb": gen_ewenc,
            "mp": gen_mp}
    report = open(os.path.join(OUT, "diff_report.txt"), "w")
    rc = 0
    for mode in MODES:
        names = None
        if mode == "sniff":
            cases, names = gen_sniff()
        else:
            cases = gens[mode]()
        path = os.path.join(OUT, "cases_%s.txt" % mode)
        with open(path, "w") as fh:
            fh.write("\n".join(cases) + "\n")
        outs = {}
        for tag, b, w in (("native_dbg", "pion_dbg", False), ("native_rel", "pion_rel", False),
                          ("wasm_dbg", "pion_dbg.wasm", True), ("wasm_rel", "pion_rel.wasm", True)):
            o, err = run(b, mode, path, w)
            if err:
                print("  [%s] %s TRAP/FAIL: %s" % (mode, tag, err))
                rc = 1
            outs[tag] = o
        base = outs["native_dbg"]
        consistent = all(outs[t] == base for t in outs)
        go, _ = run("go_audit", mode, path)
        rs = run("rust_audit", mode, path)[0] if mode in ("mt", "sniff") else None
        print("== %-6s cases=%-6d 4-mode pion identical=%s" % (mode, len(cases), consistent))
        if not consistent:
            rc = 1
            for t in outs:
                if outs[t] != base:
                    first = next((i for i in range(len(base)) if outs[t] is None or outs[t][i] != base[i]), -1)
                    print("     %s differs from native_dbg at case %d" % (t, first))
        if mode == "sniff":
            report.write("\n### sniff (pion | infer 0.16 | go http.DetectContentType)\n")
            disagree = 0
            for i, nm in enumerate(names):
                if nm == "rand" or "[:" in nm:
                    continue
                report.write("%-14s pion=%-28s infer=%-34s go=%s\n" % (nm, base[i], rs[i], go[i]))
            for i, nm in enumerate(names):
                if base[i].split(";")[0] != rs[i] and rs[i] != "NONE":
                    disagree += 1
            print("     pion vs infer: %d/%d non-NONE infer verdicts differ (see diff_report.txt)" % (disagree, len(names)))
            continue
        buckets = Counter()
        samples = defaultdict(list)
        def norm(x):
            # Error texts differ by implementation; only "an error happened here" is compared.
            i = x.find("ERR")
            return x if i < 0 or (i > 0 and x[i - 1] != " ") else x[:i] + "ERR"
        for i, c in enumerate(cases):
            if norm(base[i]) != norm(go[i]):
                if mode in ("qpenc", "qpencb", "ewq", "ewb", "fmt"):
                    k = "output_diff" if not mode == "fmt" else (
                        "fmt:" + ("pion_err" if base[i].startswith("ERR") else "pion_ok") + "/" +
                        ("go_empty" if go[i].startswith("ERR") else "go_ok"))
                else:
                    k = classify(mode, c, base[i], go[i])
                buckets[k] += 1
                if len(samples[k]) < 4:
                    samples[k].append((c, base[i], go[i]))
        if mode == "fmt":
            for i, c in enumerate(cases):
                if "RT=" in base[i] and "RT=same" not in base[i]:
                    buckets["fmt:pion_roundtrip_broken"] += 1
                    if len(samples["fmt:pion_roundtrip_broken"]) < 4:
                        samples["fmt:pion_roundtrip_broken"].append((c, base[i], go[i]))
        agree = sum(1 for i in range(len(cases)) if norm(base[i]) == norm(go[i]))
        print("     pion==go on %d/%d" % (agree, len(cases)))
        report.write("\n### %s: pion==go %d/%d\n" % (mode, agree, len(cases)))
        for k, v in buckets.most_common():
            print("     %6d  %s" % (v, k))
            report.write("  %6d  %s\n" % (v, k))
            for c, pv, gv in samples[k]:
                inp = " ".join(repr(unhex(x))[:160] for x in c.split(" "))
                report.write("         in  : %s\n         pion: %s\n         go  : %s\n" % (inp, pv[:200], gv[:200]))
        if rs is not None:
            ra = sum(1 for i in range(len(cases)) if (base[i].startswith("ERR")) == (rs[i].startswith("ERR")))
            print("     pion/rust-mime accept-reject agreement %d/%d" % (ra, len(cases)))
            report.write("  pion/rust-mime accept-reject agreement %d/%d\n" % (ra, len(cases)))
    report.close()
    print("details: %s" % os.path.join(OUT, "diff_report.txt"))
    return rc


if __name__ == "__main__":
    sys.exit(main())
