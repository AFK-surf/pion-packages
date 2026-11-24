#!/usr/bin/env python3
"""Independent RFC 8216 / draft-pantos-hls-rfc8216bis-17 reference model for packages/hls.

Written from the specification text (not from the Pion sources). It parses a playlist and prints the
same canonical dump as ../src/dump.pion so that the two can be compared byte for byte.

Where the specification leaves a representation choice open (e.g. HDCP-LEVEL values that are not
recognised are kept, unknown METHOD/TYPE values fail the playlist, DEFINE VALUEs are not themselves
subject to substitution, a UTF-8 BOM is tolerated), the model follows the behaviour the package
documents; REPORT.md lists these "accepted design choices". Everywhere else the model follows the
specification. Each place where the specification rule differs from the documented package behaviour
is tagged with the REPORT.md finding id it belongs to: when a rule tagged with an id fires on an input,
the id is printed on a `FLAGS` line, and compare.py may attribute a divergence on that input to it.

usage: model.py <corpus>   (corpus lines: <name>\\t<hex>)
"""

import re
import sys

I64 = (1 << 63) - 1
LIMITS = dict(max_input_bytes=16777216, max_lines=200000, max_segments=100000, max_variants=4096,
              max_attributes=256, max_line_bytes=65536, max_custom_tags=4096)

MASTER_TAGS = {b"#EXT-X-STREAM-INF", b"#EXT-X-I-FRAME-STREAM-INF", b"#EXT-X-MEDIA", b"#EXT-X-SESSION-DATA",
               b"#EXT-X-SESSION-KEY"}
MEDIA_TAGS = {b"#EXT-X-TARGETDURATION", b"#EXT-X-MEDIA-SEQUENCE", b"#EXT-X-DISCONTINUITY-SEQUENCE",
              b"#EXT-X-PLAYLIST-TYPE", b"#EXT-X-ENDLIST", b"#EXT-X-I-FRAMES-ONLY", b"#EXTINF", b"#EXT-X-BYTERANGE",
              b"#EXT-X-DISCONTINUITY", b"#EXT-X-GAP", b"#EXT-X-PROGRAM-DATE-TIME", b"#EXT-X-KEY", b"#EXT-X-MAP",
              b"#EXT-X-DATERANGE", b"#EXT-X-SERVER-CONTROL", b"#EXT-X-PART-INF", b"#EXT-X-PART",
              b"#EXT-X-PRELOAD-HINT", b"#EXT-X-RENDITION-REPORT", b"#EXT-X-SKIP"}


# An id with the suffix ":fmt" marks an input whose *formatter* line may legitimately change when that finding
# is fixed (e.g. a fix of P2-4 stops writing DEFINEs next to expanded values); such ids are printed on an
# FFLAGS line and explain a divergence of the FMT line only. All other ids (FLAGS) explain any divergence,
# including the ones a fix would introduce where the current data model cannot show the difference (P1-4
# several keys, P2-6 per-segment unknown tags, P2-11 part offsets).


class Fail(Exception):
    def __init__(self, kind):
        super().__init__(kind)
        self.kind = kind


def esc(b):
    out = []
    for c in b:
        if 32 < c < 127 and c not in (37, 124, 92, 34, 44):
            out.append(chr(c))
        else:
            out.append("%%%02X" % c)
    return "".join(out)


def qs(b):
    return '"' + esc(b)


def os_(o):
    return "-" if o is None else qs(o)


def oi(o):
    return "-" if o is None else str(o)


def b01(x):
    return "1" if x else "0"


# ---------------------------------------------------------------- lexical helpers (RFC 8216bis §4.2)

def dec_int(v):
    """decimal-integer, stored as a signed 64-bit value."""
    if not v or not all(48 <= c <= 57 for c in v):
        raise Fail("InvalidNumber")
    n = int(v)
    if n > I64:
        raise Fail("InvalidNumber")
    return n


DEC_RE = re.compile(rb"(-?)([0-9]+)(?:\.([0-9]+))?\Z")


def dec_scaled(v, digits, signed, flags):
    """decimal-floating-point (or signed-) as an exact integer scaled by 10**digits, rounded half-up."""
    m = DEC_RE.match(v)
    if not m or (m.group(1) and not signed):
        raise Fail("InvalidNumber")
    whole = int(m.group(2))
    frac = m.group(3) or b""
    f = int((frac[:digits]).ljust(digits, b"0"))
    total = whole * 10 ** digits + f + (1 if len(frac) > digits and frac[digits] >= 53 else 0)
    if whole > I64 // 10 ** digits:
        raise Fail("InvalidNumber")
    if total > I64:
        flags.add("P1-1")  # the package wraps this value around instead of rejecting it
        raise Fail("InvalidNumber")
    return -total if m.group(1) else total


def is_hex(c):
    return 48 <= c <= 57 or 65 <= c <= 70 or 97 <= c <= 102


def hexseq(v):
    return len(v) >= 3 and v[0] == 48 and v[1] in (120, 88) and all(is_hex(c) for c in v[2:])


def iv_ok(v):
    return len(v) == 34 and hexseq(v)


def days_in(y, m):
    if m == 2:
        return 29 if (y % 4 == 0 and y % 100 != 0) or y % 400 == 0 else 28
    return [31, 0, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]


DT_RE = re.compile(rb"([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?"
                   rb"([Zz]|[+-][0-9]{2}:[0-9]{2}|[+-][0-9]{4}|[+-][0-9]{2})?\Z")


def datetime_ok(v, flags):
    """ISO/IEC 8601:2004 date-time (RFC 8216bis §4.4.4.6: a time zone SHOULD be present)."""
    m = DT_RE.match(v)
    if not m:
        raise Fail("InvalidDateTime")
    y, mo, d, h, mi, s = (int(m.group(i)) for i in range(1, 7))
    if not (1 <= mo <= 12) or not (1 <= d <= days_in(y, mo)) or h > 23 or mi > 59 or s > 60:
        raise Fail("InvalidDateTime")
    tz = m.group(8)
    if tz is None or (tz[:1] in b"+-" and len(tz) != 6):
        flags.add("P2-9")  # valid ISO 8601 (no zone / basic or hour-only offset) rejected by the package
        if tz is not None and (int(tz[1:3]) > 23 or (len(tz) == 5 and int(tz[3:5]) > 59)):
            raise Fail("InvalidDateTime")
    elif tz[:1] in b"+-" and (int(tz[1:3]) > 23 or int(tz[4:6]) > 59):
        raise Fail("InvalidDateTime")


VARREF = re.compile(rb"\{\$([A-Za-z0-9_-]+)\}")


class Vars:
    def __init__(self, flags):
        self.values = {}
        self.order = []
        self.flags = flags

    def sub(self, s, max_len, field_scope=True):
        """Variable substitution (RFC 8216bis §4.3, §6.3.1); `field_scope` False marks a field the package
        does not substitute (finding P2-2)."""
        if b"{$" not in s:
            return s
        if not field_scope:
            self.flags.add("P2-2")
        if not self.values and not self.order:
            self.flags.add("P2-1")  # package: no EXT-X-DEFINE -> references are left unexpanded
        if re.search(rb"\{\$(?![A-Za-z0-9_-]+\})", s):
            self.flags.add("P2-1")  # "{$" that does not start a Variable Reference: package fails the playlist
        out = []
        pos = 0
        for m in VARREF.finditer(s):
            out.append(s[pos:m.start()])
            name = m.group(1)
            if name not in self.values:
                raise Fail("InvalidVariable")
            out.append(self.values[name])
            pos = m.end()
        out.append(s[pos:])
        r = b"".join(out)
        if r != s and b"{$" in r:
            self.flags.add("P2-4")  # formatter writes the expanded text next to the DEFINEs: re-expanded on re-parse
        if len(r) > max_len:
            raise Fail("LimitExceeded")
        return r


def attr_list(s, max_attrs):
    """RFC 8216bis §4.2 attribute-list: AttributeName=AttributeValue pairs separated by commas."""
    attrs = []
    seen = set()
    i, n = 0, len(s)
    while i < n:
        if len(attrs) >= max_attrs:
            raise Fail("LimitExceeded")
        j = i
        while j < n and (65 <= s[j] <= 90 or 48 <= s[j] <= 57 or s[j] == 45):
            j += 1
        if j == i or j >= n or s[j] != 61:
            raise Fail("InvalidAttribute")
        name = s[i:j]
        if name in seen:
            raise Fail("InvalidAttribute")
        seen.add(name)
        j += 1
        if j >= n:
            raise Fail("InvalidAttribute")
        if s[j] == 34:
            k = s.find(b'"', j + 1)
            if k < 0:
                raise Fail("InvalidAttribute")
            attrs.append((name, s[j + 1:k], True))
            i = k + 1
        else:
            k = s.find(b",", j)
            k = n if k < 0 else k
            if k == j or b'"' in s[j:k]:
                raise Fail("InvalidAttribute")
            attrs.append((name, s[j:k], False))
            i = k
        if i < n:
            if s[i] != 44 or i + 1 >= n:
                raise Fail("InvalidAttribute")
            i += 1
    return attrs


class Attrs:
    """Typed accessors; `flags` collects the ids of findings whose rule fires."""

    def __init__(self, raw, flags):
        self.d = {k: (v, q) for k, v, q in raw}
        self.raw = raw
        self.flags = flags

    def has(self, k):
        return k in self.d

    def quoted(self, k, required=False, allow_empty=True):
        if k not in self.d:
            if required:
                raise Fail("MissingRequiredAttribute")
            return None
        v, q = self.d[k]
        if not q:
            raise Fail("InvalidAttribute")
        if not v and not allow_empty:
            self.flags.add("P2-10")  # quoted-string MUST be non-empty (§4.2)
            raise Fail("InvalidAttribute")
        return v

    def enum(self, k, lax_quote=False):
        """enumerated-string (unquoted). `lax_quote`: the package also accepts a quoted value (P2-10)."""
        if k not in self.d:
            return None
        v, q = self.d[k]
        if q:
            if lax_quote:
                self.flags.add("P2-10")
            raise Fail("InvalidAttribute")
        return v

    def yes_no(self, k, lax_quote=True):
        v = self.enum(k, lax_quote)
        if v is None:
            return None
        if v not in (b"YES", b"NO"):
            raise Fail("InvalidAttribute")
        return v == b"YES"

    def integer(self, k, lax_quote=False):
        v = self.enum(k, lax_quote)
        return None if v is None else dec_int(v)

    def decimal(self, k, digits=6, signed=False, lax_quote=False):
        v = self.enum(k, lax_quote)
        return None if v is None else dec_scaled(v, digits, signed, self.flags)


def byterange(v, need_offset=False, flags=None):
    if b"@" in v:
        a, b = v.split(b"@", 1)
        return (dec_int(a), dec_int(b))
    if need_offset:
        flags.add("P2-8")  # EXT-X-MAP BYTERANGE: offset is REQUIRED (§4.4.4.5)
        raise Fail("InvalidByteRange")
    return (dec_int(v), None)


def resolution(v):
    x = v.find(b"x")
    if x <= 0 or x + 1 >= len(v):
        raise Fail("InvalidAttribute")
    w, h = dec_int(v[:x]), dec_int(v[x + 1:])
    if w <= 0 or h <= 0:
        raise Fail("InvalidAttribute")
    return (w, h)


TOKEN = re.compile(rb"[A-Z0-9-]+\Z")
FLOAT = re.compile(rb"-?[0-9]+(\.[0-9]+)?\Z")


def key_attrs(a, vars_, session, flags):
    method = a.enum(b"METHOD")
    if method is None:
        raise Fail("MissingRequiredAttribute")
    if method not in (b"NONE", b"AES-128", b"SAMPLE-AES", b"SAMPLE-AES-CTR"):
        raise Fail("InvalidAttribute")
    if method == b"NONE" and session:
        raise Fail("InvalidAttribute")
    uri = a.quoted(b"URI")
    if uri is not None:
        uri = vars_.sub(uri, LIMITS["max_line_bytes"])
    iv = a.enum(b"IV")
    if iv is not None:
        if b"{$" in iv:
            flags.add("P2-2")
        if not iv_ok(iv):
            raise Fail("InvalidAttribute")
    kf = a.quoted(b"KEYFORMAT")
    kf = None if kf is None else vars_.sub(kf, LIMITS["max_line_bytes"])
    kfv = a.quoted(b"KEYFORMATVERSIONS")
    kfv = None if kfv is None else vars_.sub(kfv, LIMITS["max_line_bytes"])
    if method == b"NONE":
        if len(a.raw) > 1:
            flags.add("P2-8")  # METHOD=NONE: other attributes MUST NOT be present (§4.4.4.4)
            raise Fail("InvalidAttribute")
    elif not uri:
        raise Fail("MissingRequiredAttribute")
    return (method, uri, iv, kf, kfv)


def key_s(k):
    return "%s,%s,%s,%s,%s" % (k[0].decode(), os_(k[1]), os_(k[2]), os_(k[3]), os_(k[4]))


def br_s(b):
    return "-" if b is None else "%d@%s" % (b[0], oi(b[1]))


def map_s(m):
    return "-" if m is None else "%s,%s" % (qs(m[0]), br_s(m[1]))


def parse(data, flags):
    L = LIMITS
    if len(data) > L["max_input_bytes"]:
        raise Fail("LimitExceeded")
    pos = 3 if data[:3] == b"\xef\xbb\xbf" else 0  # BOM tolerated (accepted design choice, REPORT.md)
    if pos >= len(data):
        raise Fail("MissingHeader")
    body = data[pos:]
    lines = body.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    elif lines and lines[-1].endswith(b"\r"):
        flags.add("P2-10")  # a CR that is not followed by LF is not a line terminator (§4.1)
        raise Fail("InvalidSyntax")
    st = dict(master=False, media=False, version=None, indep=0, start=None, defines=[], custom=[], variants=[],
              iframes=[], media_r=[], sdata=[], skeys=[], pending_si=None, td=None, ms=None, ds=None,
              ptype=None, endlist=0, ifo=0, sc=None, pinf=None, skip=None, skips=0, segs=[], hints=[], rr=[],
              dr=[], p_inf=None, p_title=None, p_br=None, p_disc=False, p_gap=False, p_pdt=None, p_key=None,
              active_keys={}, p_map=None, p_parts=[], prev_uri=None, prev_end=None)
    vars_ = Vars(flags)
    for ln, line in enumerate(lines):
        if ln + 1 > L["max_lines"]:
            raise Fail("LimitExceeded")
        if line.endswith(b"\r"):
            line = line[:-1]
        if len(line) > L["max_line_bytes"]:
            raise Fail("LimitExceeded")
        if b"\r" in line or b"\x00" in line:
            raise Fail("InvalidSyntax")
        if re.search(rb"[\x01-\x08\x0a-\x1f\x7f]|\xc2[\x80-\x9f]", line):
            flags.add("P2-10")  # UTF-8 control characters MUST NOT appear (§4.1)
            raise Fail("InvalidSyntax")
        if ln == 0:
            if line != b"#EXTM3U":
                raise Fail("MissingHeader")
            continue
        if not line:
            continue
        if line[:1] == b"#":
            if line.startswith(b"#EXT"):
                tag_line(st, vars_, line, flags)
            continue
        uri_line(st, vars_, line, flags)
    if st["pending_si"] is not None or st["p_inf"] is not None:
        raise Fail("InvalidSyntax")
    if st["master"] and st["media"]:
        raise Fail("MixedPlaylistTags")
    if st["master"]:
        return finish_master(st, flags)
    if st["media"]:
        if st["td"] is None:
            raise Fail("MissingRequiredTag")
        return finish_media(st, flags)
    raise Fail("MissingRequiredTag")


def classify(st, name):
    if name in MASTER_TAGS:
        st["master"] = True
        if st["media"]:
            raise Fail("MixedPlaylistTags")
    elif name in MEDIA_TAGS:
        st["media"] = True
        if st["master"]:
            raise Fail("MixedPlaylistTags")


def tag_line(st, vars_, line, flags):
    L = LIMITS
    c = line.find(b":")
    name = line if c < 0 else line[:c]
    value = None if c < 0 else line[c + 1:]
    classify(st, name)

    def need():
        if value is None:
            raise Fail("InvalidTag")
        return value

    def attrs():
        return Attrs(attr_list(need(), L["max_attributes"]), flags)

    sub = lambda v: None if v is None else vars_.sub(v, L["max_line_bytes"])
    if name == b"#EXT-X-VERSION":
        v = need()
        if st["version"] is not None:
            raise Fail("InvalidTag")
        n = dec_int(v)
        if n < 1 or n > 2147483647:
            raise Fail("InvalidNumber")
        st["version"] = n
    elif name == b"#EXT-X-INDEPENDENT-SEGMENTS":
        st["indep"] += 1
        if st["indep"] > 1:
            flags.add("P2-7")  # tags of §4.4.2 MUST NOT appear more than once
            raise Fail("InvalidTag")
    elif name == b"#EXT-X-START":
        need()
        if st["start"] is not None:
            raise Fail("InvalidTag")
        a = attrs()
        to = a.decimal(b"TIME-OFFSET", signed=True)
        pr = a.yes_no(b"PRECISE", lax_quote=False)
        if to is None:
            raise Fail("MissingRequiredAttribute")
        st["start"] = (to, bool(pr))
    elif name == b"#EXT-X-DEFINE":
        a = attrs()
        nm, vl, im, qp = (a.quoted(k) for k in (b"NAME", b"VALUE", b"IMPORT", b"QUERYPARAM"))
        if nm is not None and vl is not None and im is None and qp is None:
            ent = (nm, "VALUE", vl)
        elif nm is None and vl is None and im is not None and qp is None:
            ent = (im, "IMPORT", None)
        elif nm is None and vl is None and im is None and qp is not None:
            ent = (qp, "QUERYPARAM", None)
        else:
            raise Fail("InvalidVariable")
        if not ent[0] or not re.fullmatch(rb"[A-Za-z0-9_-]+", ent[0]):
            raise Fail("InvalidVariable")
        if ent[0] in vars_.order:
            raise Fail("InvalidVariable")
        if ent[1] != "VALUE":
            # IMPORT needs the Multivariant Playlist, QUERYPARAM the Playlist URI: a standalone parse MUST fail
            # (§4.4.2.3); IMPORT MUST NOT occur in a Multivariant Playlist. The package accepts the
            # declaration and fails only on use (P2-3).
            flags.add("P2-3")
            raise Fail("InvalidVariable")
        vars_.order.append(ent[0])
        vars_.values[ent[0]] = ent[2]
        flags.add("P2-4:fmt")  # a fix of P2-4 may stop writing NAME/VALUE DEFINEs next to expanded values
        st["defines"].append(ent)
    elif name == b"#EXT-X-STREAM-INF":
        if st["pending_si"] is not None:
            raise Fail("InvalidSyntax")
        a = attrs()
        bw = a.integer(b"BANDWIDTH")
        if bw is None:
            raise Fail("MissingRequiredAttribute")
        if bw <= 0:
            raise Fail("InvalidNumber")
        abw = a.integer(b"AVERAGE-BANDWIDTH")
        if abw is not None and abw <= 0:
            raise Fail("InvalidNumber")
        codecs = sub(a.quoted(b"CODECS"))
        res = a.enum(b"RESOLUTION")
        res = None if res is None else resolution(res)
        fps = a.decimal(b"FRAME-RATE", digits=3)
        if fps is not None and fps <= 0:
            raise Fail("InvalidNumber")
        hd = hdcp(a, flags)
        audio, video, subs = (sub(a.quoted(k)) for k in (b"AUDIO", b"VIDEO", b"SUBTITLES"))
        cc = None
        if a.has(b"CLOSED-CAPTIONS"):
            v, q = a.d[b"CLOSED-CAPTIONS"]
            if not q and v == b"NONE":
                cc = "NONE"
            elif q:
                cc = qs(sub(v))
            else:
                raise Fail("InvalidAttribute")
        score = a.decimal(b"SCORE")
        path = sub(a.quoted(b"PATHWAY-ID"))
        st["pending_si"] = dict(bw=bw, abw=abw, codecs=codecs, res=res, fps=fps, hdcp=hd, audio=audio,
                                video=video, subs=subs, cc=cc, score=score, path=path)
    elif name == b"#EXT-X-I-FRAME-STREAM-INF":
        need()
        if len(st["iframes"]) >= L["max_variants"]:
            raise Fail("LimitExceeded")
        a = attrs()
        bw = a.integer(b"BANDWIDTH")
        if bw is None:
            raise Fail("MissingRequiredAttribute")
        if bw <= 0:
            raise Fail("InvalidNumber")
        abw = a.integer(b"AVERAGE-BANDWIDTH")
        uri = sub(a.quoted(b"URI"))
        codecs = sub(a.quoted(b"CODECS"))
        res = a.enum(b"RESOLUTION")
        res = None if res is None else resolution(res)
        hd = hdcp(a, flags)
        video = sub(a.quoted(b"VIDEO"))
        score = a.decimal(b"SCORE")
        path = sub(a.quoted(b"PATHWAY-ID"))
        if not uri:
            raise Fail("MissingRequiredAttribute")
        st["iframes"].append("I|%s|%d|%s|%s|%s|%s|%s|%s|%s" % (
            qs(uri), bw, oi(abw), os_(codecs), "-" if res is None else "%dx%d" % res, hd, os_(video), oi(score),
            os_(path)))
    elif name == b"#EXT-X-MEDIA":
        a = attrs()
        t = a.enum(b"TYPE")
        if t is not None and t not in (b"AUDIO", b"VIDEO", b"SUBTITLES", b"CLOSED-CAPTIONS"):
            raise Fail("InvalidAttribute")
        gid = sub(a.quoted(b"GROUP-ID"))
        nm = sub(a.quoted(b"NAME"))
        uri = sub(a.quoted(b"URI"))
        lang, alang, inst, chars, chans = (a.quoted(k) for k in (b"LANGUAGE", b"ASSOC-LANGUAGE", b"INSTREAM-ID",
                                                                 b"CHARACTERISTICS", b"CHANNELS"))
        lang, alang, inst, chars, chans = (None if v is None else vars_.sub(v, L["max_line_bytes"], False)
                                           for v in (lang, alang, inst, chars, chans))
        de, au, fo = a.yes_no(b"DEFAULT"), a.yes_no(b"AUTOSELECT"), a.yes_no(b"FORCED")
        if t is None or gid is None or nm is None:
            raise Fail("MissingRequiredAttribute")
        if de and au is False:
            raise Fail("InvalidAttribute")
        if (fo is not None and t != b"SUBTITLES") or (inst is not None and t != b"CLOSED-CAPTIONS") or \
                (chans is not None and t != b"AUDIO"):
            flags.add("P2-7")  # FORCED only for SUBTITLES, INSTREAM-ID only for CC, CHANNELS only for AUDIO (§4.4.6.1)
            raise Fail("InvalidAttribute")
        if t == b"CLOSED-CAPTIONS":
            if uri is not None:
                raise Fail("InvalidAttribute")
            if inst is None:
                raise Fail("MissingRequiredAttribute")
        st["media_r"].append((t, gid, nm, uri, lang, alang, bool(de), bool(au), bool(fo), inst, chars, chans))
    elif name == b"#EXT-X-SESSION-DATA":
        a = attrs()
        did = a.quoted(b"DATA-ID")
        did = None if did is None else vars_.sub(did, L["max_line_bytes"], False)
        val = sub(a.quoted(b"VALUE"))
        uri = sub(a.quoted(b"URI"))
        lang = a.quoted(b"LANGUAGE")
        lang = None if lang is None else vars_.sub(lang, L["max_line_bytes"], False)
        fmt = a.enum(b"FORMAT")
        if fmt is not None and fmt not in (b"JSON", b"RAW"):
            flags.add("P2-10")  # enumerated-string: JSON or RAW (§4.4.6.4); formatter cannot write others
            raise Fail("InvalidAttribute")
        if did is None:
            raise Fail("MissingRequiredAttribute")
        if (val is None) == (uri is None):
            raise Fail("InvalidAttribute")
        st["sdata"].append("SD|%s|%s|%s|%s|%s" % (qs(did), os_(val), os_(uri), os_(lang), os_(fmt)))
    elif name == b"#EXT-X-SESSION-KEY":
        st["skeys"].append(key_attrs(attrs(), vars_, True, flags))
    elif name == b"#EXT-X-TARGETDURATION":
        v = need()
        if st["td"] is not None:
            raise Fail("InvalidTag")
        n = dec_int(v)
        if n <= 0:
            raise Fail("InvalidNumber")
        st["td"] = n
    elif name in (b"#EXT-X-MEDIA-SEQUENCE", b"#EXT-X-DISCONTINUITY-SEQUENCE"):
        v = need()
        k = "ms" if name == b"#EXT-X-MEDIA-SEQUENCE" else "ds"
        if st[k] is not None:
            raise Fail("InvalidTag")
        st[k] = dec_int(v)
        if st["segs"] or st["p_inf"] is not None:
            flags.add("P2-7")  # MUST appear before the first Media Segment (§4.4.3.2, §4.4.3.3)
            raise Fail("InvalidTag")
    elif name == b"#EXT-X-PLAYLIST-TYPE":
        v = need()
        if st["ptype"] is not None:
            raise Fail("InvalidTag")
        if v not in (b"EVENT", b"VOD"):
            raise Fail("InvalidTag")
        st["ptype"] = v.decode()
    elif name in (b"#EXT-X-ENDLIST", b"#EXT-X-I-FRAMES-ONLY"):
        k = "endlist" if name == b"#EXT-X-ENDLIST" else "ifo"
        st[k] += 1
        if st[k] > 1:
            flags.add("P2-7")  # no more than one Media Playlist tag of each type (§4.4.3)
            raise Fail("InvalidTag")
    elif name == b"#EXTINF":
        if st["p_inf"] is not None:
            raise Fail("InvalidSyntax")
        v = need()
        cm = v.find(b",")
        if cm < 0:
            raise Fail("InvalidTag")
        st["p_inf"] = dec_scaled(v[:cm], 6, False, flags)
        st["p_title"] = v[cm + 1:] if cm + 1 < len(v) else None
    elif name == b"#EXT-X-BYTERANGE":
        if value is None:
            raise Fail("InvalidByteRange")
        st["p_br"] = byterange(value)
    elif name == b"#EXT-X-DISCONTINUITY":
        st["p_disc"] = True
    elif name == b"#EXT-X-GAP":
        st["p_gap"] = True
    elif name == b"#EXT-X-PROGRAM-DATE-TIME":
        if value is None:
            raise Fail("InvalidDateTime")
        datetime_ok(value, flags)
        st["p_pdt"] = value
    elif name == b"#EXT-X-KEY":
        k = key_attrs(attrs(), vars_, False, flags)
        act = st["active_keys"]
        if k[0] == b"NONE":
            act.clear()
        else:
            kf = k[3] if k[3] not in (None, b"identity") else b"identity"
            if any(f != kf for f in act):
                flags.add("P1-4")  # keys of several KEYFORMATs apply to one segment (§4.4.4.4); package keeps one
            act[kf] = k
        st["p_key"] = k
    elif name == b"#EXT-X-MAP":
        a = attrs()
        uri = sub(a.quoted(b"URI"))
        br = a.quoted(b"BYTERANGE")
        if br is not None:
            if b"{$" in br:
                flags.add("P2-2")
            br = byterange(br, need_offset=True, flags=flags)
        if not uri:
            raise Fail("MissingRequiredAttribute")
        st["p_map"] = (uri, br)
    elif name == b"#EXT-X-DATERANGE":
        a = attrs()
        q = lambda k: None if a.quoted(k) is None else vars_.sub(a.quoted(k), L["max_line_bytes"], False)
        did, cls, sd, ed = q(b"ID"), q(b"CLASS"), q(b"START-DATE"), q(b"END-DATE")
        if sd is not None:
            datetime_ok(sd, flags)
        if ed is not None:
            datetime_ok(ed, flags)
        dur, pdur = a.decimal(b"DURATION"), a.decimal(b"PLANNED-DURATION")
        eon = a.yes_no(b"END-ON-NEXT")
        sc = []
        for k in (b"SCTE35-CMD", b"SCTE35-OUT", b"SCTE35-IN"):
            if a.has(k):
                v, qd = a.d[k]
                if qd:
                    flags.add("P2-10")  # hexadecimal-sequence is unquoted
                if b"{$" in v:
                    flags.add("P2-2")
                if not hexseq(v) or qd:
                    raise Fail("InvalidAttribute")
                sc.append(v)
            else:
                sc.append(None)
        xs = []
        for k, v, qd in a.raw:
            if k.startswith(b"X-"):
                if qd:
                    v = vars_.sub(v, L["max_line_bytes"], False)
                elif not (hexseq(v) or FLOAT.match(v)):
                    flags.add("P2-10")  # unquoted client attribute: hexadecimal-sequence or decimal-float
                    raise Fail("InvalidAttribute")
                xs.append("%s=%s%s" % (esc(k), b01(qd), qs(v)))
        if did is None or sd is None:
            raise Fail("MissingRequiredAttribute")
        if eon and cls is None:
            raise Fail("MissingRequiredAttribute")
        if eon and (dur is not None or ed is not None):
            flags.add("P2-7")  # END-ON-NEXT=YES MUST NOT carry DURATION or END-DATE (§4.4.5.1)
            raise Fail("InvalidAttribute")
        st["dr"].append("DR|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s" % (
            qs(did), os_(cls), qs(sd), os_(ed), oi(dur), oi(pdur), b01(eon), os_(sc[0]), os_(sc[1]), os_(sc[2]),
            ",".join(xs)))
    elif name == b"#EXT-X-SERVER-CONTROL":
        need()
        if st["sc"] is not None:
            raise Fail("InvalidTag")
        a = attrs()
        st["sc"] = (a.decimal(b"CAN-SKIP-UNTIL", lax_quote=True), bool(a.yes_no(b"CAN-SKIP-DATERANGES")),
                    a.decimal(b"HOLD-BACK", lax_quote=True), a.decimal(b"PART-HOLD-BACK", lax_quote=True),
                    bool(a.yes_no(b"CAN-BLOCK-RELOAD")))
    elif name == b"#EXT-X-PART-INF":
        need()
        if st["pinf"] is not None:
            raise Fail("InvalidTag")
        a = attrs()
        pt = a.decimal(b"PART-TARGET", lax_quote=True)
        if pt is None:
            raise Fail("MissingRequiredAttribute")
        if pt <= 0:
            raise Fail("InvalidNumber")
        st["pinf"] = pt
    elif name == b"#EXT-X-PART":
        a = attrs()
        uri = sub(a.quoted(b"URI"))
        dur = a.decimal(b"DURATION", lax_quote=True)
        ind = a.yes_no(b"INDEPENDENT")
        br = a.quoted(b"BYTERANGE")
        if br is not None:
            if b"{$" in br:
                flags.add("P2-2")
            br = byterange(br)
            if br[1] is None:
                flags.add("P2-11")  # implicit part offset (§4.4.4.9) is not resolved by the package
        gap = a.yes_no(b"GAP")
        if uri is None:
            raise Fail("MissingRequiredAttribute")
        if dur is None:
            raise Fail("MissingRequiredAttribute")
        st["p_parts"].append("|%s|%d|%s|%s|%s" % (qs(uri), dur, b01(ind), br_s(br), b01(gap)))
        st.setdefault("part_durs", []).append(dur)
    elif name == b"#EXT-X-PRELOAD-HINT":
        a = attrs()
        t = a.enum(b"TYPE", lax_quote=True)
        if t is not None and t not in (b"PART", b"MAP"):
            raise Fail("InvalidAttribute")
        uri = sub(a.quoted(b"URI"))
        bs, bl = a.integer(b"BYTERANGE-START", True), a.integer(b"BYTERANGE-LENGTH", True)
        if t is None or uri is None:
            raise Fail("MissingRequiredAttribute")
        st["hints"].append("PH|%s|%s|%s|%s" % (t.decode(), qs(uri), oi(bs), oi(bl)))
    elif name == b"#EXT-X-RENDITION-REPORT":
        a = attrs()
        uri = sub(a.quoted(b"URI"))
        lm, lp = a.integer(b"LAST-MSN", True), a.integer(b"LAST-PART", True)
        if uri is None:
            raise Fail("MissingRequiredAttribute")
        st["rr"].append("RR|%s|%s|%s" % (qs(uri), oi(lm), oi(lp)))
    elif name == b"#EXT-X-SKIP":
        a = attrs()
        n = a.integer(b"SKIPPED-SEGMENTS", True)
        rem = a.quoted(b"RECENTLY-REMOVED-DATERANGES")
        if rem is not None:
            rem = vars_.sub(rem, L["max_line_bytes"], False)
        if n is None:
            raise Fail("MissingRequiredAttribute")
        st["skips"] += 1
        if st["skips"] > 1:
            flags.add("P2-7")  # EXT-X-SKIP MUST NOT appear more than once (§4.4.5.2)
            raise Fail("InvalidTag")
        st["skip"] = (n, rem)
    else:
        if len(st["custom"]) >= L["max_custom_tags"]:
            raise Fail("LimitExceeded")
        st["custom"].append((name, value))
        if st["media"] or st["segs"] or st["p_inf"] is not None:
            flags.add("P2-6")  # a fix of P2-6 keeps unknown tags with their segment (playlist-level list changes)
        if name == b"#EXTM3U" or not re.fullmatch(rb"#EXT[A-Z0-9-]*", name):
            flags.add("P1-6:fmt")  # a fix of P1-6 may refuse to write this tag name
        if name in (b"#EXT-X-CUE-OUT", b"#EXT-X-CUE-IN", b"#EXT-X-CUE-OUT-CONT", b"#EXT-OATCLS-SCTE35",
                    b"#EXT-X-SCTE35", b"#EXT-X-CUE", b"#EXT-X-BITRATE") and st["media"]:
            flags.add("P2-6")  # positional tag: the formatter moves it after the last segment


def hdcp(a, flags):
    if not a.has(b"HDCP-LEVEL"):
        return "-"
    v, q = a.d[b"HDCP-LEVEL"]
    if q:
        raise Fail("InvalidAttribute")
    if v in (b"NONE", b"TYPE-0", b"TYPE-1"):
        return v.decode()
    if not TOKEN.match(v):
        flags.add("P2-10")  # enumerated-string never contains whitespace / '=' (§4.2); formatter refuses it
        raise Fail("InvalidAttribute")
    return qs(v)


def uri_line(st, vars_, line, flags):
    L = LIMITS
    uri = vars_.sub(line, L["max_line_bytes"])
    if (not uri or uri[:1] == b"#") and uri != line:
        flags.add("P2-5:fmt")  # a substituted URI line the formatter cannot write back
    si = st["pending_si"]
    if si is not None:
        if len(st["variants"]) >= L["max_variants"]:
            raise Fail("LimitExceeded")
        st["variants"].append((uri, si))
        st["pending_si"] = None
        return
    if st["p_inf"] is None:
        raise Fail("InvalidSyntax")
    if len(st["segs"]) >= L["max_segments"]:
        raise Fail("LimitExceeded")
    br = st["p_br"]
    if br is not None:
        off = br[1]
        if off is None:
            if st["prev_uri"] is None or st["prev_end"] is None or st["prev_uri"] != uri:
                raise Fail("InvalidByteRange")
            off = st["prev_end"]
        if off + br[0] > I64:
            raise Fail("InvalidByteRange")
        br = (br[0], off)
        st["prev_end"] = off + br[0]
    else:
        st["prev_end"] = None
    st["prev_uri"] = uri
    st["segs"].append(dict(uri=uri, dur=st["p_inf"], title=st["p_title"], br=br, disc=st["p_disc"],
                           gap=st["p_gap"], pdt=st["p_pdt"], key=st["p_key"], map=st["p_map"],
                           parts=st["p_parts"]))
    st.update(p_inf=None, p_title=None, p_br=None, p_disc=False, p_gap=False, p_pdt=None, p_key=None, p_map=None,
              p_parts=[])


def finish_master(st, flags):
    out = ["MASTER|%s|%s|%s" % (oi(st["version"]), b01(st["indep"]),
                                "-" if st["start"] is None else "%d,%s" % (st["start"][0], b01(st["start"][1])))]
    out += defines_s(st)
    groups = {}
    for r in st["media_r"]:
        groups.setdefault((r[0], r[1]), []).append(r[2])
    for k, names in groups.items():
        if len(set(names)) != len(names):
            flags.add("P2-7")  # all EXT-X-MEDIA tags in a Group MUST have different NAMEs (§4.4.6.2.1)
            raise Fail("InvalidAttribute")
    ccs = []
    for uri, si in st["variants"]:
        for key, t in (("audio", b"AUDIO"), ("video", b"VIDEO"), ("subs", b"SUBTITLES")):
            if si[key] is not None and (t, si[key]) not in groups:
                flags.add("P2-7")  # group reference MUST match an EXT-X-MEDIA GROUP-ID of that TYPE (§4.4.6.2)
                raise Fail("InvalidAttribute")
        ccs.append(si["cc"])
        if si["cc"] not in (None, "NONE") and not any(t == b"CLOSED-CAPTIONS" and qs(g) == si["cc"]
                                                      for (t, g) in groups):
            flags.add("P2-7")
            raise Fail("InvalidAttribute")
        out.append("V|%s|%d|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s" % (
            qs(uri), si["bw"], oi(si["abw"]), os_(si["codecs"]), "-" if si["res"] is None else "%dx%d" % si["res"],
            oi(si["fps"]), si["hdcp"], os_(si["audio"]), os_(si["video"]), os_(si["subs"]),
            "-" if si["cc"] is None else si["cc"], oi(si["score"]), os_(si["path"])))
    if "NONE" in ccs and any(c != "NONE" for c in ccs):
        flags.add("P2-7")  # CLOSED-CAPTIONS=NONE: all EXT-X-STREAM-INF tags MUST carry NONE (§4.4.6.2)
        raise Fail("InvalidAttribute")
    out += st["iframes"]
    for r in st["media_r"]:
        out.append("M|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s" % (
            r[0].decode(), qs(r[1]), qs(r[2]), os_(r[3]), os_(r[4]), os_(r[5]), b01(r[6]), b01(r[7]), b01(r[8]),
            os_(r[9]), os_(r[10]), os_(r[11])))
    out += st["sdata"]
    out += ["SK|" + key_s(k) for k in st["skeys"]]
    out += custom_s(st)
    return out


def defines_s(st):
    return ["DEF|%s|%s|%s" % (qs(n), k, "-" if v is None else qs(v)) for n, k, v in st["defines"]]


def custom_s(st):
    return ["CT|%s|%s" % (qs(n), os_(v)) for n, v in st["custom"]]


def finish_media(st, flags):
    td = st["td"]
    segs = st["segs"]
    for s in segs:
        if (s["dur"] + 500000) // 1000000 > td:
            flags.add("P2-7")  # rounded EXTINF duration MUST be <= target duration (§4.4.3.1)
            raise Fail("InvalidNumber")
    parts = st.get("part_durs", [])
    if parts and st["pinf"] is None:
        flags.add("P2-7")  # EXT-X-PART-INF is REQUIRED with EXT-X-PART (§4.4.3.7)
        raise Fail("MissingRequiredTag")
    if st["pinf"] is not None:
        if any(d > st["pinf"] for d in parts):
            flags.add("P2-7")  # part duration MUST be <= Part Target Duration (§4.4.4.9)
            raise Fail("InvalidNumber")
        sc = st["sc"]
        if sc is None or sc[3] is None or sc[3] < 2 * st["pinf"]:
            flags.add("P2-7")  # PART-HOLD-BACK REQUIRED with PART-INF and >= 2 x PART-TARGET (§4.4.3.8)
            raise Fail("MissingRequiredAttribute")
    sc = st["sc"]
    if sc is not None:
        if (sc[1] and sc[0] is None) or (sc[0] is not None and sc[0] < 6 * td * 1000000) or \
                (sc[2] is not None and sc[2] < 3 * td * 1000000):
            flags.add("P2-7")  # CAN-SKIP-UNTIL >= 6 TD, HOLD-BACK >= 3 TD, CAN-SKIP-DATERANGES needs CAN-SKIP-UNTIL
            raise Fail("InvalidAttribute")
    ms, ds = st["ms"] or 0, st["ds"] or 0
    out = ["MEDIA|%s|%d|%d|%d|%s|%s|%s|%s|%s" % (
        oi(st["version"]), td, ms, ds, st["ptype"] or "-", b01(st["endlist"]), b01(st["ifo"]), b01(st["indep"]),
        "-" if st["start"] is None else "%d,%s" % (st["start"][0], b01(st["start"][1])))]
    out += defines_s(st)
    if sc is not None:
        out.append("SC|%s|%s|%s|%s|%s" % (oi(sc[0]), b01(sc[1]), oi(sc[2]), oi(sc[3]), b01(sc[4])))
    if st["pinf"] is not None:
        out.append("PI|%d" % st["pinf"])
    if st["skip"] is not None:
        out.append("SKIP|%d|%s" % (st["skip"][0], os_(st["skip"][1])))
    for s in segs:
        out.append("S|%s|%d|%s|%s|%s|%s|%s|%s|%s" % (
            qs(s["uri"]), s["dur"], os_(s["title"]), br_s(s["br"]), b01(s["disc"]), b01(s["gap"]), os_(s["pdt"]),
            "-" if s["key"] is None else key_s(s["key"]), map_s(s["map"])))
        out += ["P" + p for p in s["parts"]]
    out += ["TP" + p for p in st["p_parts"]]
    out += st["hints"] + st["rr"] + st["dr"]
    out += custom_s(st)
    # resolution (RFC 8216bis §3, §4.4.3.2, §4.4.3.3, §4.4.5.2)
    skipped = st["skip"][0] if st["skip"] is not None else 0
    if skipped:
        flags.add("P1-5")  # MSN of the first segment after EXT-X-SKIP is MEDIA-SEQUENCE + SKIPPED-SEGMENTS
    msn, dsn, cur = ms + skipped, ds, 0
    key = mp = None
    for s in segs:
        if s["disc"]:
            dsn += 1
        if s["key"] is not None:
            key = None if s["key"][0] == b"NONE" else s["key"]
        if s["map"] is not None:
            mp = s["map"]
        end = cur + s["dur"]
        vals = []
        for v in (msn, dsn, cur, end):
            if v > I64:
                flags.add("P1-2")  # exceeds Int64: the package wraps around
                vals.append("OVF")
            else:
                vals.append(str(v))
        out.append("R|%s|%s|%s|%s|%s|%s" % (vals[0], vals[1], vals[2], vals[3],
                                             "-" if key is None else key_s(key), map_s(mp)))
        cur = end
        msn += 1
    if cur > I64:
        flags.add("P1-2")
        out.append("TOT|OVF|OVF")
    else:
        out.append("TOT|%d|%d" % (cur, cur // 1000))
    return out


def run(data):
    flags = set()
    try:
        lines = parse(data, flags)
        lines.append("FMT|ok|same")
        return lines, flags
    except Fail as e:
        return ["ERR|" + e.kind], flags


def main():
    out = sys.stdout
    with open(sys.argv[1], "rb") as f:
        for raw in f.read().split(b"\n"):
            if b"\t" not in raw:
                continue
            name, hx = raw.split(b"\t", 1)
            lines, flags = run(bytes.fromhex(hx.decode()))
            out.write("=" + name.decode() + "\n")
            out.write("\n".join(lines) + "\n")
            fmt = {f[:-4] for f in flags if f.endswith(":fmt")}
            flags = {f for f in flags if not f.endswith(":fmt")}
            if flags:
                out.write("FLAGS|" + ",".join(sorted(flags)) + "\n")
            if fmt:
                out.write("FFLAGS|" + ",".join(sorted(fmt)) + "\n")


if __name__ == "__main__":
    main()
