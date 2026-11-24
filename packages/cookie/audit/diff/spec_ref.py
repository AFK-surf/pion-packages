"""Reference model for packages/cookie/audit (stdlib only).

A transcription of draft-ietf-httpbis-rfc6265bis-22 (§5.1.1 dates, §5.1.3/§5.1.4 matching, §5.6 Set-Cookie parsing,
§5.7 storage, §5.8.3 retrieval), CHIPS partition keys (schemeful site of the top-level), the Mozilla PSL algorithm over
the pinned official list (psl/public_suffix_list.dat), the WHATWG URL Standard's host / path split for the URL shapes
the corpora use, and the package's documented policies where the spec leaves a choice (400-day cap, limits, eviction
order expired > non-Secure > least recently accessed, the stricter-than-§5.1.3 rule that an IP cookie domain never
suffix-matches, the case-insensitive __Http- / __Host-Http- prefixes).

Every function produces exactly the line format of the Pion CLI (audit/src/main.pion), so the two outputs compare
byte for byte. `flags` switch on emulations of the open findings (FLAG_IDS); compare.py uses them only to attribute a
divergence to a finding: on a fixed tree the Pion output equals the flag-free model and no flag is needed. Flags whose
id is "OK" are fail-closed alternatives a fix may legitimately choose (refusing a URL with a backslash, refusing a
host that is not UTS #46-canonical, refusing names over 253 octets / labels over 63 octets); they are not findings.
"""

import os
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
I64_MAX = (1 << 63) - 1
LIFETIME_CAP = 34560000

# flag -> finding id (REPORT.md)
FLAG_IDS = {
    "nameless_prefix": "P1-1",
    "secure_alone": "P1-2",
    "hostonly_identity": "P1-3",
    "xsite_set": "P1-4",
    "url_backslash": "P1-6",
    "samesite_keep": "P2-1",
    "lax_nonhttp": "P2-1",
    "path_keep": "P2-2",
    "domain_multidot": "P2-3",
    "ip_trailing": "P2-8",
    "no_uts46": "P2-8",
    # accepted alternatives (fail-closed choices a fix may make; not findings)
    "url_reject_backslash": "OK",
    "psl_reject_noncanonical": "OK",
    "psl_reject_long": "OK",
}


def esc(b):
    if isinstance(b, str):
        b = b.encode("utf-8", "surrogateescape")
    out = []
    for c in b:
        if 32 < c < 127 and c not in (37, 124, 92):
            out.append(chr(c))
        else:
            out.append("%%%02X" % c)
    return "".join(out)


def decode_input(s):
    """`hex:` form -> bytes, anything else -> its UTF-8 bytes."""
    if s.startswith("hex:"):
        return bytes.fromhex(s[4:])
    return s.encode("utf-8", "surrogateescape")


# ---------------------------------------------------------------------------------------------------------------
# §5.1.1 dates
# ---------------------------------------------------------------------------------------------------------------

def _is_delim(c):
    return c == 0x09 or 0x20 <= c <= 0x2F or 0x3B <= c <= 0x40 or 0x5B <= c <= 0x60 or 0x7B <= c <= 0x7E


def _digits(tok, lo, hi):
    """Match 'lo*hi DIGIT [ non-digit *OCTET ]', return the number or None."""
    n = 0
    while n < len(tok) and 48 <= tok[n] <= 57:
        n += 1
    if n < lo or n > hi:
        return None
    return int(tok[:n])


def _time(tok):
    parts = []
    i = 0
    for k in range(3):
        n = 0
        while i + n < len(tok) and 48 <= tok[i + n] <= 57:
            n += 1
        if n < 1 or n > 2:
            return None
        parts.append(int(tok[i:i + n]))
        i += n
        if k < 2:
            if i >= len(tok) or tok[i] != 58:
                return None
            i += 1
    return tuple(parts)


MONTHS = [b"jan", b"feb", b"mar", b"apr", b"may", b"jun", b"jul", b"aug", b"sep", b"oct", b"nov", b"dec"]


def days_from_civil(y, m, d):
    y -= m <= 2
    era = (y if y >= 0 else y - 399) // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _dim(y, m):
    if m == 2:
        return 29 if (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)) else 28
    return 30 if m in (4, 6, 9, 11) else 31


def parse_cookie_date(b):
    toks = []
    i = 0
    while i < len(b):
        while i < len(b) and _is_delim(b[i]):
            i += 1
        s = i
        while i < len(b) and not _is_delim(b[i]):
            i += 1
        if i > s:
            toks.append(b[s:i])
    ft = fd = fm = fy = False
    hh = mi = ss = day = mon = year = 0
    for t in toks:
        if not ft:
            r = _time(t)
            if r is not None:
                hh, mi, ss = r
                ft = True
                continue
        if not fd:
            r = _digits(t, 1, 2)
            if r is not None:
                day = r
                fd = True
                continue
        if not fm and len(t) >= 3 and t[:3].lower() in MONTHS:
            mon = MONTHS.index(t[:3].lower()) + 1
            fm = True
            continue
        if not fy:
            r = _digits(t, 2, 4)
            if r is not None:
                year = r
                fy = True
                continue
    if 70 <= year <= 99:
        year += 1900
    elif 0 <= year <= 69:
        year += 2000
    if not (ft and fd and fm and fy) or day < 1 or day > 31 or year < 1601 or hh > 23 or mi > 59 or ss > 59:
        return None
    if day > _dim(year, mon):
        return None
    return days_from_civil(year, mon, day) * 86400 + hh * 3600 + mi * 60 + ss


WDAYS = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"]
MNAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def format_cookie_date(t):
    """IMF-fixdate; defined for 1601..9999 (the only range the corpora format)."""
    days, rem = divmod(t, 86400)
    z = days + 719468
    era = (z if z >= 0 else z - 146096) // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + 3 if mp < 10 else mp - 9
    y += m <= 2
    return "%s, %02d %s %04d %02d:%02d:%02d GMT" % (WDAYS[days % 7], d, MNAMES[m - 1], y, rem // 3600, rem % 3600 // 60,
                                                  rem % 60)


def date_line(b):
    t = parse_cookie_date(b)
    if t is None:
        return "ERR"
    return "OK %d %s" % (t, esc(format_cookie_date(t)))


# ---------------------------------------------------------------------------------------------------------------
# §5.6 Set-Cookie parsing
# ---------------------------------------------------------------------------------------------------------------

def _ctl(c):
    return c <= 8 or 10 <= c <= 31 or c == 127


def _trim(b):
    return b.strip(b" \t")


def _lower(b):
    return bytes(c + 32 if 65 <= c <= 90 else c for c in b)


def _max_age(v):
    if not v or not (48 <= v[0] <= 57 or v[0] == 45):
        return None
    neg = v[0] == 45
    rest = v[1:] if neg else v
    if not rest or any(not 48 <= c <= 57 for c in rest):
        return None
    n = min(int(rest), I64_MAX)
    return -n if neg else n


def parse_set_cookie(b, flags=()):
    """-> dict (name, value, expires, max_age, domain, path, secure, http_only, same_site, partitioned) or None."""
    if any(_ctl(c) for c in b):
        return None
    semi = b.find(b";")
    nvp, attrs = (b, b"") if semi < 0 else (b[:semi], b[semi:])
    eq = nvp.find(b"=")
    name, value = (b"", _trim(nvp)) if eq < 0 else (_trim(nvp[:eq]), _trim(nvp[eq + 1:]))
    if not name and not value:
        return None
    if len(name) + len(value) > 4096:
        return None
    c = dict(name=name, value=value, expires=None, max_age=None, domain=None, path=None, secure=False,
             http_only=False, same_site=None, partitioned=False)
    for av in attrs.split(b";")[1:]:
        e = av.find(b"=")
        an, aval = (_trim(av), b"") if e < 0 else (_trim(av[:e]), _trim(av[e + 1:]))
        if len(aval) > 1024:
            continue
        k = _lower(an)
        if k == b"expires":
            t = parse_cookie_date(aval)
            if t is not None:
                c["expires"] = t
        elif k == b"max-age":
            m = _max_age(aval)
            if m is not None:
                c["max_age"] = m
        elif k == b"domain":
            # empty value: SHOULD ignore (§5.6.3). "Domain=." (empty after the dot) is left to the package's choice
            # (ignored); the corpora do not generate it.
            if aval:
                d = aval[1:] if aval[:1] == b"." else aval
                if d:
                    c["domain"] = _lower(d)
        elif k == b"path":
            if aval[:1] == b"/":
                c["path"] = aval
            elif "path_keep" not in flags:
                c["path"] = None  # default-path, and the last Path attribute wins (§5.6.4, §5.7 step 11)
        elif k == b"secure":
            c["secure"] = True
        elif k == b"httponly":
            c["http_only"] = True
        elif k == b"samesite":
            lv = _lower(aval)
            if lv in (b"strict", b"lax", b"none"):
                c["same_site"] = {b"strict": "Strict", b"lax": "Lax", b"none": "None"}[lv]
            elif "samesite_keep" not in flags:
                c["same_site"] = None  # (SameSite, "Default") is appended and the last one wins (§5.6.7)
        elif k == b"partitioned":
            c["partitioned"] = True
    return c


def cookie_line(c):
    o = lambda v: "-" if v is None else esc(v)
    oi = lambda v: "-" if v is None else str(v)
    return "n=%s v=%s e=%s m=%s d=%s p=%s s=%d h=%d ss=%s pt=%d" % (
        esc(c["name"]), esc(c["value"]), oi(c["expires"]), oi(c["max_age"]), o(c["domain"]), o(c["path"]),
        c["secure"], c["http_only"], c["same_site"] or "-", c["partitioned"])


def format_set_cookie(c):
    s = (c["name"] + b"=" + c["value"]) if c["name"] else c["value"]
    if c["expires"] is not None:
        s += b"; Expires=" + format_cookie_date(c["expires"]).encode()
    if c["max_age"] is not None:
        s += b"; Max-Age=" + str(c["max_age"]).encode()
    if c["domain"] is not None:
        s += b"; Domain=" + c["domain"]
    if c["path"] is not None:
        s += b"; Path=" + c["path"]
    if c["secure"]:
        s += b"; Secure"
    if c["http_only"]:
        s += b"; HttpOnly"
    if c["same_site"]:
        s += b"; SameSite=" + c["same_site"].encode()
    if c["partitioned"]:
        s += b"; Partitioned"
    return s


def parse_line(b, flags=()):
    c = parse_set_cookie(b, flags)
    if c is None:
        return "ERR"
    base = cookie_line(c)
    f = format_set_cookie(c)
    c2 = parse_set_cookie(f, flags)
    r = "E" if c2 is None else ("1" if cookie_line(c2) == base else "0")
    return "OK %s F=%s R=%s" % (base, esc(f), r)


# ---------------------------------------------------------------------------------------------------------------
# Public Suffix List
# ---------------------------------------------------------------------------------------------------------------

def _puny(label):
    return label if label.isascii() else "xn--" + label.encode("punycode").decode("ascii")


_RULES = None


def rules():
    """{rule (lower-case, Punycode): 'I' | 'P'} from the pinned official list, or, when SPEC_PSL names the package's
    psl_data.pion (run_audit.sh does that only if the embedded table is a different snapshot), from that table."""
    global _RULES
    if _RULES is None:
        src = os.environ.get("SPEC_PSL", "")
        r, sec = {}, None
        if src.endswith(".pion"):
            import re
            lit = re.search(r'"(.*)"', open(src, encoding="utf-8").read(), re.S).group(1)
            for l in lit.encode("utf-8").decode("unicode_escape").split("\n"):
                if l:
                    k, v = l.rsplit("\t", 1)
                    r[k] = v
            _RULES = r
            return r
        for line in open(os.path.join(HERE, "..", "psl", "public_suffix_list.dat"), encoding="utf-8"):
            s = line.strip()
            if "===BEGIN ICANN" in s:
                sec = "I"
            elif "===BEGIN PRIVATE" in s:
                sec = "P"
            elif "===END" in s:
                sec = None
            if not s or s.startswith("//"):
                continue
            rule = s.split()[0]
            r[".".join(_puny(x) for x in rule.lower().split("."))] = sec
        _RULES = r
    return _RULES


def is_ip_literal(s):
    """The package's IP test (bracketed / containing ':' / strict dotted quad), on a str."""
    if not s:
        return False
    if (s[0] == "[" and s[-1] == "]") or ":" in s:
        return True
    parts = s.split(".")
    if len(parts) != 4:
        return False
    for p in parts:
        if not p or not p.isascii() or not p.isdigit() or len(p) > 3 or int(p) > 255 or (len(p) > 1 and p[0] == "0"):
            return False
    return True


def _labels(b, flags):
    """-> (display labels, ascii labels) or None (the package's input contract)."""
    try:
        s = b.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if "psl_reject_noncanonical" in flags:
        if any(ch in s for ch in "\u3002\uff0e\uff61") or any(not ch.isascii() and ch != ch.lower() for ch in s):
            return None
    if "no_uts46" not in flags:
        s = s.replace("。", ".").replace("．", ".").replace("｡", ".")
    if not s or s[0] == ".":
        return None
    raw_ip = is_ip_literal(s)
    if s[-1] == ".":
        s = s[:-1]
    if not s:
        return None
    if raw_ip if "ip_trailing" in flags else is_ip_literal(s):
        return None
    if "psl_reject_long" in flags and len(s.encode("utf-8")) > 253:
        return None
    disp = []
    for lab in s.split("."):
        if not lab:
            return None
        if "no_uts46" in flags:
            lab = "".join(ch.lower() if ch.isascii() else ch for ch in lab)
        else:
            lab = unicodedata.normalize("NFC", lab.lower())
        disp.append(lab)
    asc = [_puny(x) for x in disp]
    if "psl_reject_long" in flags and (any(len(x) > 63 for x in asc) or len(".".join(asc)) > 253):
        return None
    return disp, asc


def psl_match(b, include_private, flags=()):
    """-> (display labels, suffix label count, section, is_exception, is_wildcard) or None."""
    lab = _labels(b, flags)
    if lab is None:
        return None
    disp, asc = lab
    R = rules()
    ok = lambda key: key in R and (include_private or R[key] == "I")
    best = (1, "U", False, False)
    n = len(asc)
    for k in range(1, n + 1):
        suffix = ".".join(asc[n - k:])
        if ok("!" + suffix):
            return disp, k - 1, R["!" + suffix], True, False
        exact = ok(suffix)
        if exact:
            best = (k, R[suffix], False, False)
        if k >= 2:
            w = "*." + ".".join(asc[n - k + 1:])
            if ok(w) and (k > best[0] or not exact):
                best = (k, R[w], False, True)
    return (disp,) + best


def _join(labels):
    return ".".join(labels)


def psl_line(b, flags=()):
    def ps(priv):
        m = psl_match(b, priv, flags)
        return None if m is None else _join(m[0][len(m[0]) - m[1]:])

    def rd(priv):
        m = psl_match(b, priv, flags)
        if m is None or len(m[0]) <= m[1]:
            return None
        return _join(m[0][len(m[0]) - m[1] - 1:])

    def isps(priv):
        m = psl_match(b, priv, flags)
        return m is not None and len(m[0]) <= m[1]

    def info(priv):
        m = psl_match(b, priv, flags)
        if m is None:
            return "-"
        return "%s,%s%d%d" % (esc(_join(m[0][len(m[0]) - m[1]:])), m[2], m[3], m[4])

    o = lambda v: "-" if v is None else esc(v)
    return "%s|%s|%s|%s|%d%d|%s|%s" % (o(ps(True)), o(ps(False)), o(rd(True)), o(rd(False)), isps(True), isps(False),
                                       info(True), info(False))


def registrable_domain(host, include_private):
    m = psl_match(host.encode("utf-8", "surrogateescape"), include_private)
    if m is None or len(m[0]) <= m[1]:
        return None
    return _join(m[0][len(m[0]) - m[1] - 1:])


def is_public_suffix(host, include_private):
    m = psl_match(host.encode("utf-8", "surrogateescape"), include_private)
    return m is not None and len(m[0]) <= m[1]


# ---------------------------------------------------------------------------------------------------------------
# URL split (WHATWG for the corpus' shapes), matching
# ---------------------------------------------------------------------------------------------------------------

SPECIAL = ("http", "https", "ws", "wss", "ftp")


def parse_request_url(u, flags=()):
    """-> (scheme, host, path, secure) or None. Shapes: scheme://[userinfo@]host[:port][/path][?q][#f] with ASCII
    hosts, optional `\\` / TAB / LF / CR noise."""
    if "url_reject_backslash" in flags and b"\\" in u:
        return None
    if "url_backslash" not in flags:
        u = u.replace(b"\t", b"").replace(b"\n", b"").replace(b"\r", b"")
    sep = u.find(b"://")
    if sep <= 0:
        return None
    scheme = _lower(u[:sep]).decode("latin-1")
    rest = u[sep + 3:]
    bs = "url_backslash" not in flags and scheme in SPECIAL
    end = 0
    while end < len(rest) and rest[end] not in b"/?#" and not (bs and rest[end] == 92):
        end += 1
    auth = rest[:end]
    if not auth:
        return None
    hs = auth.rfind(b"@") + 1
    host = auth[hs:]
    if not host:
        return None
    if host[:1] == b"[":
        rb = host.find(b"]")
        if rb < 0:
            return None
        host = host[:rb + 1]
    else:
        colon = host.find(b":")
        if colon >= 0:
            host = host[:colon]
    if not host:
        return None
    host = _lower(host)
    if len(host) > 1 and host[-1:] == b".":
        host = host[:-1]
    tail = rest[end:]
    if tail[:1] == b"/" or (bs and tail[:1] == b"\\"):
        pe = 0
        while pe < len(tail) and tail[pe] not in b"?#":
            pe += 1
        path = tail[:pe]
        if bs:
            path = path.replace(b"\\", b"/")
    else:
        path = b"/"
    return scheme, host, path, scheme in ("https", "wss")


def default_path(p):
    if not p or p[:1] != b"/":
        return b"/"
    i = p.rfind(b"/")
    return b"/" if i <= 0 else p[:i]


def is_ip_b(h):
    return is_ip_literal(h.decode("utf-8", "surrogateescape"))


def domain_matches(h, d):
    h, d = _lower(h), _lower(d)
    if h == d:
        return True
    if is_ip_b(h) or is_ip_b(d):
        return False
    return len(h) > len(d) and h.endswith(d) and h[len(h) - len(d) - 1] == 46


def path_matches(r, c):
    if r == c:
        return True
    if not c or not r.startswith(c):
        return False
    return c[-1:] == b"/" or r[len(c):len(c) + 1] == b"/"


def match_line(fields, flags=()):
    k = fields[0]
    if k == b"dm":
        return "dm %d" % domain_matches(fields[1], fields[2])
    if k == b"pm":
        return "pm %d" % path_matches(fields[1], fields[2])
    if k == b"url":
        u = parse_request_url(fields[1], flags)
        if u is None:
            return "url ERR InvalidUrl"
        return "url %s %s %s %d dp=%s" % (esc(u[0]), esc(u[1]), esc(u[2]), u[3], esc(default_path(u[2])))
    if k == b"chdr":
        h = fields[1]
        if any(_ctl(c) for c in h):
            return "chdr ERR InvalidHeader"
        pairs = []
        for part in h.split(b";"):
            part = _trim(part)
            if not part:
                continue
            e = part.find(b"=")
            pairs.append((b"", part) if e < 0 else (_trim(part[:e]), _trim(part[e + 1:])))
        out = "chdr OK %d" % len(pairs) + "".join(" %s=%s" % (esc(a), esc(b)) for a, b in pairs)
        return out + " F=" + esc(b"; ".join((a + b"=" + b) if a else b for a, b in pairs))
    return "bad"


# ---------------------------------------------------------------------------------------------------------------
# §5.7 storage / §5.8.3 retrieval
# ---------------------------------------------------------------------------------------------------------------

def _istarts(b, prefix):
    return _lower(b[:len(prefix)]) == prefix


class Jar:
    def __init__(self, flags=(), max_cookies=3000, per_domain=180, lifetime=LIFETIME_CAP, private=True):
        self.flags = set(flags)
        self.max, self.per, self.life, self.priv = max_cookies, per_domain, lifetime, private
        self.cookies = []  # dicts, in insertion order

    def _site(self, scheme, host):
        reg = registrable_domain(host.decode("utf-8", "surrogateescape"), self.priv)
        return scheme.encode() + b"://" + (reg.encode("utf-8", "surrogateescape") if reg is not None else host)

    def _pkey(self, ctx, u):
        if ctx["top"] is None:
            return self._site(u[0], u[1])
        t = parse_request_url(ctx["top"], self.flags)
        if t is None:
            return _lower(ctx["top"])
        return self._site(t[0], t[1])

    def set(self, header, ctx):
        """-> 'OK1' (stored) or 'NO' (rejected / not stored); compare.py maps the package's OK0 and ERR to NO."""
        u = parse_request_url(ctx["url"], self.flags)
        if u is None:
            return "NO"
        scheme, host, rpath, secure_req = u
        c = parse_set_cookie(header, self.flags)
        if c is None:
            return "NO"
        now = ctx["now"]
        fl = self.flags
        if c["http_only"] and not ctx["http"]:
            return "NO"
        if c["secure"] and not secure_req:
            return "NO"
        if c["partitioned"] and not c["secure"]:
            return "NO"
        name = c["name"]
        # prefixes (case-insensitive); the package also requires an HTTP API for __Http- / __Host-Http-
        has_dom = c["domain"] is not None and len(c["domain"]) > 0
        root = c["path"] == b"/"
        if _istarts(name, b"__host-http-"):
            if not (c["secure"] and secure_req and c["http_only"] and not has_dom and root and ctx["http"]):
                return "NO"
        elif _istarts(name, b"__http-"):
            if not (c["secure"] and secure_req and c["http_only"] and ctx["http"]):
                return "NO"
        elif _istarts(name, b"__host-"):
            if not (c["secure"] and secure_req and not has_dom and root):
                return "NO"
        elif _istarts(name, b"__secure-"):
            if not (c["secure"] and secure_req):
                return "NO"
        if not name and "nameless_prefix" not in fl:  # step 22
            if _istarts(c["value"], b"__secure-") or _istarts(c["value"], b"__host-"):
                return "NO"
        ss = c["same_site"] or "Lax"
        if ss == "None" and not c["secure"]:
            return "NO"
        if ss != "None" and "xsite_set" not in fl and not ctx["same"]:  # step 18
            if not ctx["http"] or not ctx["nav"]:
                return "NO"
        # Domain + PSL (steps 7-10)
        if c["domain"] is not None:
            d = c["domain"]
            if "domain_multidot" in fl and d[:1] == b".":
                d = d[1:]
            if not d:
                domain, host_only = host, True
            elif is_public_suffix(d.decode("utf-8", "surrogateescape"), self.priv):
                if d != host:
                    return "NO"
                domain, host_only = host, True
            elif not domain_matches(host, d):
                return "NO"
            else:
                domain, host_only = d, False
        else:
            domain, host_only = host, True
        path = c["path"] if c["path"] is not None else default_path(rpath)
        pkey = self._pkey(ctx, u) if c["partitioned"] else None
        if c["max_age"] is not None:
            ma = c["max_age"]
            if ma <= 0:
                expiry = now - 1
            else:
                expiry = now + (min(ma, self.life) if self.life is not None else ma)
            persistent = True
        elif c["expires"] is not None:
            expiry = c["expires"] if self.life is None else min(c["expires"], now + self.life)
            persistent = True
        else:
            expiry, persistent = None, False
        # step 16: leave secure cookies alone
        if not c["secure"] and not secure_req:
            if "secure_alone" in fl:
                pass  # checked on the exact identity below
            else:
                for o in self.cookies:
                    if o["name"] == name and o["secure"] and (domain_matches(o["domain"], domain) or
                                                              domain_matches(domain, o["domain"])) \
                            and path_matches(path, o["path"]):
                        return "NO"
        # step 23: identity (name, domain, host-only-flag, path) + CHIPS partition key
        idx = None
        for i, o in enumerate(self.cookies):
            if o["name"] == name and o["domain"] == domain and o["path"] == path and o["pkey"] == pkey and \
                    ("hostonly_identity" in fl or o["host_only"] == host_only):
                idx = i
                break
        creation = now
        if idx is not None:
            old = self.cookies[idx]
            if old["http_only"] and not ctx["http"]:
                return "NO"
            if old["secure"] and not secure_req:
                return "NO"
            creation = old["creation"]
            del self.cookies[idx]
        if expiry is not None and expiry <= now:
            return "NO"
        if self.per <= 0 or self.max <= 0:
            return "NO"
        while sum(1 for o in self.cookies if o["domain"] == domain) >= self.per:
            v = self._victim(domain, now)
            if v is None:
                break
            del self.cookies[v]
        while len(self.cookies) >= self.max:
            v = self._victim(None, now)
            if v is None:
                break
            del self.cookies[v]
        self.cookies.append(dict(name=name, value=c["value"], domain=domain, host_only=host_only, path=path,
                                 secure=c["secure"], http_only=c["http_only"], ss=ss, partitioned=c["partitioned"],
                                 pkey=pkey, creation=creation, access=now, expiry=expiry, persistent=persistent))
        return "OK1"

    def _victim(self, domain, now):
        best, key = None, None
        for i, o in enumerate(self.cookies):
            if domain is not None and o["domain"] != domain:
                continue
            k = (0 if (o["expiry"] is not None and o["expiry"] <= now) else 1, 0 if not o["secure"] else 1,
                 o["access"], o["creation"])
            if key is None or k < key:
                best, key = i, k
        return best

    def get(self, ctx):
        u = parse_request_url(ctx["url"], self.flags)
        if u is None:
            return "ERR"
        scheme, host, rpath, secure_req = u
        now = ctx["now"]
        req_pkey = self._pkey(ctx, u)
        out = []
        for o in self.cookies:
            if o["expiry"] is not None and o["expiry"] <= now:
                continue
            if not (host == o["domain"] if o["host_only"] else domain_matches(host, o["domain"])):
                continue
            if not path_matches(rpath, o["path"]):
                continue
            if o["secure"] and not secure_req:
                continue
            if o["http_only"] and not ctx["http"]:
                continue
            if not ctx["same"]:
                if o["ss"] == "Strict":
                    continue
                if o["ss"] == "Lax" and not (ctx["nav"] and ctx["safe"] and
                                             (ctx["http"] or "lax_nonhttp" in self.flags)):
                    continue
            if o["pkey"] is not None and o["pkey"] != req_pkey:
                continue
            o["access"] = now
            out.append(o)
        out.sort(key=lambda o: (-len(o["path"]), o["creation"]))  # stable
        if not out:
            return "<none>"
        return esc(b"; ".join((o["name"] + b"=" + o["value"]) if o["name"] else o["value"] for o in out))

    def dump(self):
        oi = lambda v: "-" if v is None else str(v)
        lines = []
        for o in self.cookies:
            lines.append("c %s %s %s ho=%d %s s=%d h=%d ss=%s pt=%d pk=%s ct=%d la=%d ex=%s pe=%d" % (
                esc(o["name"]), esc(o["value"]), esc(o["domain"]), o["host_only"], esc(o["path"]), o["secure"],
                o["http_only"], o["ss"], o["partitioned"], "-" if o["pkey"] is None else esc(o["pkey"]),
                o["creation"], o["access"], oi(o["expiry"]), o["persistent"]))
        return lines

    def purge(self, now):
        n = len(self.cookies)
        self.cookies = [o for o in self.cookies if not (o["expiry"] is not None and o["expiry"] <= now)]
        return n - len(self.cookies)

    def clear_domain(self, d):
        d = _lower(d)
        n = len(self.cookies)
        self.cookies = [o for o in self.cookies if o["domain"] != d]
        return n - len(self.cookies)


def _ctx(f, k):
    return dict(now=int(f[k]), url=f[k + 1], top=None if f[k + 2] == b"-" else f[k + 2], http=f[k + 3] == b"1",
                same=f[k + 4] == b"1", nav=f[k + 5] == b"1", safe=f[k + 6] == b"1")


def run_jar_block(lines, flags=()):
    """Run one scenario block (list of raw protocol lines) -> list of output lines (dump lines sorted)."""
    jar = Jar(flags)
    out = []
    for line in lines:
        if line.startswith("==="):
            jar = Jar(flags)
            out.append(line)
            continue
        f = [decode_input(x) for x in line.split("\t")]
        op = f[0]
        if op == b"limits":
            life = None if f[3] == b"-" else int(f[3])
            jar = Jar(flags, int(f[1]), int(f[2]), life, f[4] == b"1")
            out.append("limits")
        elif op == b"set":
            out.append("set " + jar.set(f[8], _ctx(f, 1)))
        elif op == b"get":
            out.append("get " + jar.get(_ctx(f, 1)))
        elif op == b"dump":
            d = jar.dump()
            out.append("dump %d" % len(d))
            out.extend(sorted(d))
        elif op == b"rt":
            out.append("rt %d 1" % len(jar.cookies))
        elif op == b"purge":
            out.append("purge %d" % jar.purge(int(f[1])))
        elif op == b"cleardom":
            out.append("cleardom %d" % jar.clear_domain(f[1]))
        else:
            out.append("bad")
    return out
