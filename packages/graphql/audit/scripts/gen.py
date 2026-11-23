"""Deterministic grammar fuzzer for GraphQL documents (executable + SDL) with adversarial lexical content."""
import random

NAMES = ["a", "b", "on", "true", "false", "null", "query", "fragment", "type", "x1", "_", "__typename", "Ab9", "extend",
         "input", "schema", "repeatable", "implements", "e", "E1"]
TYPES = ["Int", "String", "T", "Query", "on", "type", "I"]
STR_PIECES = ["a", " ", "  ", "\\n", "\\t", "\\\\", '\\"', "\\/", "\\u0041", "\\u00e9", "\\u{1F600}", "\\uD83D\\uDE00",
              "\u00e9", "\U0001F600", "\u4e2d", "#", "\"\"", "\\b", "\\f", "\\r", "\\u{0}", "\\u{10FFFF}", "\t", "\ufeff"]
BLOCK_PIECES = ["a", " ", "  ", "\t", "\n", "\r\n", "\r", '\\"""', '"', '""', "\\", "\\n", "#", "\u00e9", "\U0001F600",
                "\n  ", "\n    ", "\n\t", "\n \t", "x\n", " \n", "\\\\"]


def gname(r):
    return r.choice(NAMES)


def gstring(r):
    return '"' + "".join(r.choice(STR_PIECES) for _ in range(r.randint(0, 6))) + '"'


def gblock(r):
    body = "".join(r.choice(BLOCK_PIECES) for _ in range(r.randint(0, 8)))
    if body.endswith('"') or body.endswith("\\"):
        body += " "
    return '"""' + body + '"""'


def gnum(r):
    s = r.choice(["0", "-0", "1", "-12", "123456789012345678901234567890"])
    if r.random() < 0.4:
        s += "." + r.choice(["0", "5", "000", "25"])
    if r.random() < 0.3:
        s += r.choice(["e", "E"]) + r.choice(["", "+", "-"]) + r.choice(["0", "7", "10"])
    return s


def gvalue(r, depth=0, const=False):
    k = r.randint(0, 9 if depth < 3 else 6)
    if k == 0 and not const:
        return "$" + gname(r)
    if k <= 1:
        return gnum(r)
    if k == 2:
        return gstring(r)
    if k == 3:
        return gblock(r)
    if k == 4:
        return r.choice(["true", "false", "null"])
    if k <= 6:
        return r.choice(["A", "B_C", "on", "query", "fragment", "TRUE"])
    if k <= 8:
        return "[" + r.choice([" ", ",", ""]).join(gvalue(r, depth + 1, const) for _ in range(r.randint(0, 3))) + "]"
    fields = []
    for i in range(r.randint(0, 3)):
        fields.append(f"{r.choice(NAMES)}{r.choice([':', ' :', ': '])}{gvalue(r, depth + 1, const)}")
    return "{" + r.choice([" ", ",", ""]).join(fields) + "}"


def gargs(r, const=False):
    if r.random() < 0.5:
        return ""
    return "(" + r.choice([" ", ","]).join(f"{gname(r)}:{gvalue(r, 0, const)}" for _ in range(r.randint(1, 3))) + ")"


def gdirs(r, const=False):
    return "".join(f" @{gname(r)}{gargs(r, const)}" for _ in range(r.choice([0, 0, 1, 2])))


def gsel(r, depth):
    k = r.random()
    if k < 0.6 or depth > 4:
        alias = f"{gname(r)}{r.choice([':', ' : '])}" if r.random() < 0.3 else ""
        sub = gss(r, depth + 1) if (r.random() < 0.35 and depth < 4) else ""
        return f"{alias}{gname(r)}{gargs(r)}{gdirs(r)}{sub}"
    if k < 0.8:
        return f"...{r.choice(['F', 'G', 'onX', 'trueish'])}{gdirs(r)}"
    tc = r.choice(["", " on T", " on on", "on T"])
    return f"...{tc}{gdirs(r)}{gss(r, depth + 1)}"


def gss(r, depth=0):
    sep = r.choice([" ", ",", "\n", "\t", " # c\n", ",,"])
    return "{" + sep.join(gsel(r, depth) for _ in range(r.randint(1, 4))) + "}"


def gtype(r):
    t = r.choice(TYPES)
    for _ in range(r.randint(0, 2)):
        if r.random() < 0.5:
            t += "!"
        t = "[" + t + "]"
    if r.random() < 0.4:
        t += "!"
    return t


def gdesc(r):
    k = r.random()
    if k < 0.5:
        return ""
    return (gstring(r) if k < 0.7 else gblock(r)) + r.choice([" ", "\n", "\n  "])


def gargdefs(r):
    if r.random() < 0.6:
        return ""
    return "(" + " ".join(f"{gdesc(r)}{gname(r)}: {gtype(r)}{' = ' + gvalue(r, 0, True) if r.random() < 0.3 else ''}{gdirs(r, True)}"
                          for _ in range(r.randint(1, 3))) + ")"


def gdef(r):
    k = r.randint(0, 11)
    if k == 0:
        return gss(r)
    if k <= 2:
        op = r.choice(["query", "mutation", "subscription"])
        name = r.choice(["", " Q", " on", " query"])
        vars_ = ""
        if r.random() < 0.5:
            vars_ = "(" + " ".join(f"${gname(r)}: {gtype(r)}{' = ' + gvalue(r, 0, True) if r.random() < 0.3 else ''}{gdirs(r, True)}"
                                   for _ in range(r.randint(1, 3))) + ")"
        return f"{op}{name}{vars_}{gdirs(r)} {gss(r)}"
    if k == 3:
        return f"fragment {r.choice(['F', 'G', 'query', 'true'])} on {r.choice(TYPES)}{gdirs(r)} {gss(r)}"
    if k == 4:
        ifs = f" implements {r.choice(['', '& '])}" + " & ".join(r.choice(["I", "J", "K"]) for _ in range(r.randint(1, 3))) if r.random() < 0.4 else ""
        fields = " {" + "\n".join(f"  {gdesc(r)}{gname(r)}{gargdefs(r)}: {gtype(r)}{gdirs(r, True)}" for _ in range(r.randint(1, 4))) + "\n}" if r.random() < 0.85 else ""
        return f"{gdesc(r)}{r.choice(['type', 'interface'])} {r.choice(TYPES)}{ifs}{gdirs(r, True)}{fields}"
    if k == 5:
        return f"{gdesc(r)}enum E{gdirs(r, True)} {{ " + " ".join(f"{gdesc(r)}{r.choice(['A', 'B', 'on', 'query', 'TRUE'])}{gdirs(r, True)}" for _ in range(r.randint(1, 3))) + " }"
    if k == 6:
        return f"{gdesc(r)}input In{gdirs(r, True)} {{ " + " ".join(f"{gdesc(r)}{gname(r)}: {gtype(r)}{' = ' + gvalue(r, 0, True) if r.random() < 0.4 else ''}" for _ in range(r.randint(1, 3))) + " }"
    if k == 7:
        return f"{gdesc(r)}union U{gdirs(r, True)} = {r.choice(['', '| '])}" + " | ".join(r.choice(TYPES) for _ in range(r.randint(1, 3)))
    if k == 8:
        return f"{gdesc(r)}scalar S{gdirs(r, True)}"
    if k == 9:
        return f"{gdesc(r)}directive @{gname(r)}{gargdefs(r)}{r.choice(['', ' repeatable'])} on {r.choice(['', '| '])}" + " | ".join(r.choice(["FIELD", "QUERY", "OBJECT", "ENUM_VALUE"]) for _ in range(r.randint(1, 3)))
    if k == 10:
        return f"{gdesc(r)}schema{gdirs(r, True)} {{ query: Q mutation: M }}"
    return r.choice([f"extend type T{gdirs(r, True) or ' @x'}", "extend schema @d", f"extend union U = A | B", "extend enum E { Z }",
                     f"extend input In {{ z: Int = {gvalue(r, 0, True)} }}", "extend scalar S @y", "extend interface I implements J"])


def gdoc(r):
    sep = r.choice(["\n", " ", "\n\n", ",", "\r\n", "\n# comment\n"])
    return sep.join(gdef(r) for _ in range(r.randint(1, 4)))


def gexec(r):
    sep = r.choice(["\n", " ", ","])
    parts = [gdef(r) if r.random() < 0.2 else r.choice([gss(r), f"query Q{r.randint(0, 3)} {gss(r)}", f"fragment F on T {gss(r)}"])
             for _ in range(r.randint(1, 3))]
    return sep.join(parts)


def mutate(r, s):
    """Byte-level mutation of a valid document (insert / delete / duplicate / swap a token-ish slice)."""
    if not s:
        return s
    b = list(s)
    for _ in range(r.randint(1, 3)):
        k = r.randint(0, 4)
        i = r.randrange(len(b) + 1)
        if k == 0:
            b.insert(i, r.choice(list('{}()[]!$&:=@|."\\#,\n -0e1a') + ["...", '"""', "on", "\u00e9"]))
        elif k == 1 and b:
            del b[min(i, len(b) - 1)]
        elif k == 2 and b:
            j = min(len(b), i + r.randint(1, 6))
            b[i:i] = b[i:j]
        elif k == 3 and len(b) > 2:
            i = min(i, len(b) - 2)
            b[i], b[i + 1] = b[i + 1], b[i]
        else:
            b.insert(i, r.choice([" ", "\t", ",", "\r", "\ufeff"]))
    return "".join(b)
