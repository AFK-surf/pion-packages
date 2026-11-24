"""Unicode 16.0.0 data for the independent reference model (stdlib only, no `unicodedata`).

Reads the gzip-compressed UCD / IDNA / security files vendored in ../ucd (Unicode-3.0, see ../ucd/LICENSE).
"""
import gzip
import os

UCD = os.environ.get("IDNA_AUDIT_UCD") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ucd")


def _lines(name):
    path = os.path.join(UCD, name + ".gz")
    with gzip.open(path, "rt", encoding="utf-8-sig") as f:
        for line in f:
            yield line


def _rng(s):
    s = s.strip()
    if ".." in s:
        a, b = s.split("..")
        return int(a, 16), int(b, 16)
    return int(s, 16), int(s, 16)


def _records(name):
    for line in _lines(name):
        body = line.split("#", 1)[0].strip()
        if body:
            yield [p.strip() for p in body.split(";")]


class Data:
    def __init__(self):
        # --- UnicodeData: gc, ccc, canonical decompositions, Nd digit values
        self.gc = {}
        self.ccc = {}
        self.decomp = {}
        self.digit_zero = {}
        first = None
        for line in _lines("UnicodeData.txt"):
            f = line.rstrip("\n").split(";")
            cp = int(f[0], 16)
            name = f[1]
            if name.endswith(", First>"):
                first = cp
                continue
            lo = first if name.endswith(", Last>") else cp
            first = None
            for c in range(lo, cp + 1):
                self.gc[c] = f[2]
                if f[3] != "0":
                    self.ccc[c] = int(f[3])
            if f[5] and not f[5].startswith("<"):
                self.decomp[cp] = [int(x, 16) for x in f[5].split()]
            if f[2] == "Nd":
                self.digit_zero[cp] = cp - int(f[6])
        excl = set()
        for r in _records("CompositionExclusions.txt"):
            excl.add(_rng(r[0])[0])
        self.compose = {}
        for cp, d in self.decomp.items():
            if len(d) == 2 and cp not in excl and self.ccc.get(cp, 0) == 0 and self.ccc.get(d[0], 0) == 0:
                self.compose[(d[0], d[1])] = cp
        # --- IDNA mapping table
        self.idna = {}
        for r in _records("IdnaMappingTable.txt"):
            lo, hi = _rng(r[0])
            st = r[1]
            m = [int(x, 16) for x in r[2].split()] if len(r) > 2 and r[2] else []
            for c in range(lo, hi + 1):
                self.idna[c] = (st, m)
        # --- Bidi_Class (with @missing defaults), Joining_Type
        self.bidi = {}
        missing = []
        for line in _lines("DerivedBidiClass.txt"):
            if line.startswith("# @missing:"):
                p = [x.strip() for x in line[len("# @missing:"):].split(";")]
                missing.append((_rng(p[0]), p[1]))
        self.bidi_missing = missing
        for r in _records("DerivedBidiClass.txt"):
            lo, hi = _rng(r[0])
            for c in range(lo, hi + 1):
                self.bidi[c] = r[1]
        self.jt = {}
        for r in _records("DerivedJoiningType.txt"):
            lo, hi = _rng(r[0])
            for c in range(lo, hi + 1):
                self.jt[c] = r[1]
        # --- Scripts (ids in Pion's numbering: named list, then order of first appearance)
        named = ["Common", "Inherited", "Latin", "Greek", "Cyrillic", "Han", "Hiragana", "Katakana", "Hangul",
                 "Arabic", "Hebrew", "Thai", "Devanagari", "Bengali", "Gurmukhi", "Gujarati", "Oriya", "Tamil",
                 "Telugu", "Kannada", "Malayalam", "Sinhala", "Myanmar", "Georgian", "Armenian", "Ethiopic",
                 "Cherokee", "Khmer", "Lao", "Tibetan", "Bopomofo"]
        self.script_ids = {n: i for i, n in enumerate(named)}
        self.script = {}
        for r in _records("Scripts.txt"):
            if r[1] not in self.script_ids:
                self.script_ids[r[1]] = len(self.script_ids)
            lo, hi = _rng(r[0])
            for c in range(lo, hi + 1):
                self.script[c] = self.script_ids[r[1]]
        # --- Default_Ignorable_Code_Point
        self.di = set()
        for r in _records("DerivedCoreProperties.txt"):
            if r[1] == "Default_Ignorable_Code_Point":
                lo, hi = _rng(r[0])
                self.di.update(range(lo, hi + 1))
        # --- confusables prototypes
        self.proto = {}
        for r in _records("confusables.txt"):
            self.proto[int(r[0], 16)] = [int(x, 16) for x in r[1].split()]

    def bidi_class(self, cp):
        if cp in self.bidi:
            return self.bidi[cp]
        for (lo, hi), v in reversed(self.bidi_missing):
            if lo <= cp <= hi:
                return v
        return "L"

    def is_mark(self, cp):
        return self.gc.get(cp, "Cn").startswith("M")


_D = None


def data():
    global _D
    if _D is None:
        _D = Data()
    return _D
