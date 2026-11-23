#!/usr/bin/env python3
"""Seeded grammar fuzzer for packages/cedar vs cedar-policy =4.15.0 (same case format as gen_cases.py).

usage: gen_fuzz.py <seed> <count>
Generates well-typed AND ill-typed random expressions (depth <= 4) over the v0.1.0 feature set
(literals, arithmetic, comparison, &&/||/!, if, in/is/has/like, sets, records, attribute access,
contains*/isEmpty, getTag/hasTag, decimal/ip). Known, separately reported divergence triggers
(ip host bits / IPv4-in-IPv6, `\\u{2a}` in patterns, reserved identifiers) are excluded so the fuzz
measures the rest of the semantics. Each expression becomes a permit / forbid pair so both
policy effects and error isolation are exercised.
"""
import json
import random
import sys

sys.path.insert(0, __import__("os").path.dirname(__file__))
import gen_cases as G  # noqa: E402

INTS = ["0", "1", "-1", "2", "7", "9223372036854775807", "-9223372036854775808", "4611686018427387904",
        "3037000500", "-3037000500", "context.n", "principal.age"]
STRS = ['""', '"a"', '"hello"', '"h*"', '"\\u{e9}"', '"a\\nb"', "context.s", "principal.name"]
ENTS = ['User::"alice"', 'User::"bob"', 'User::"ghost"', 'Group::"eng"', 'Group::"all"', "principal",
        "resource", "action", 'Action::"read"', 'NS1::User::"a"', "resource.owner", "principal.owner"]
PATS = ['"*"', '"h*o"', '"*l*"', '"a\\*"', '""', '"\\u{e9}"', '"*b"', '"a**"']
DECS = ['decimal("1.0")', 'decimal("-0.5")', 'decimal("12.5")', 'decimal("922337203685477.5807")',
        "principal.amt"]
IPS = ['ip("10.1.2.3")', 'ip("10.0.0.0/8")', 'ip("192.168.1.7")', 'ip("::1")', 'ip("ff02::1")',
       'ip("127.0.0.1")', "context.ip", "principal.ip", 'ip("2001:db8::/32")']
ATTRS = ["name", "age", "active", "nested", "roles", "owner", "missing", "locked", "x"]


def gen(r, d, ty=None):
    if ty is None:
        ty = r.choice(["bool"] * 4 + ["int", "str", "ent", "set", "rec", "dec", "ip", "any"])
    if d <= 0 or r.random() < 0.25:
        return leaf(r, ty)
    k = r.random()
    if ty == "bool":
        ops = [
            lambda: "(%s && %s)" % (gen(r, d - 1, "bool"), gen(r, d - 1, "bool")),
            lambda: "(%s || %s)" % (gen(r, d - 1, "bool"), gen(r, d - 1, "bool")),
            lambda: "!%s" % gen(r, d - 1, "bool"),
            lambda: "(%s %s %s)" % (gen(r, d - 1, "int"), r.choice(["<", "<=", ">", ">=", "==", "!="]), gen(r, d - 1, "int")),
            lambda: "(%s == %s)" % (gen(r, d - 1), gen(r, d - 1)),
            lambda: "(%s in %s)" % (gen(r, d - 1, "ent"), r.choice([gen(r, d - 1, "ent"), "[%s, %s]" % (gen(r, d - 1, "ent"), gen(r, d - 1, "ent"))])),
            lambda: "(%s has %s)" % (r.choice(["principal", "context", "resource", "principal.nested", gen(r, d - 1, "rec")]), r.choice(ATTRS)),
            lambda: "(%s like %s)" % (gen(r, d - 1, "str"), r.choice(PATS)),
            lambda: "(%s is %s)" % (gen(r, d - 1, "ent"), r.choice(["User", "Group", "Doc", "NS1::User"])),
            lambda: "%s.contains(%s)" % (gen(r, d - 1, "set"), gen(r, d - 1)),
            lambda: "%s.%s(%s)" % (gen(r, d - 1, "set"), r.choice(["containsAll", "containsAny"]), gen(r, d - 1, "set")),
            lambda: "%s.isEmpty()" % gen(r, d - 1, "set"),
            lambda: "%s.hasTag(%s)" % (gen(r, d - 1, "ent"), r.choice(['"t1"', '"level"', '"zz"'])),
            lambda: "%s.%s(%s)" % (gen(r, d - 1, "dec"), r.choice(["lessThan", "lessThanOrEqual", "greaterThan", "greaterThanOrEqual"]), gen(r, d - 1, "dec")),
            lambda: "%s.%s()" % (gen(r, d - 1, "ip"), r.choice(["isIpv4", "isIpv6", "isLoopback", "isMulticast"])),
            lambda: "%s.isInRange(%s)" % (gen(r, d - 1, "ip"), gen(r, d - 1, "ip")),
            lambda: "(if %s then %s else %s)" % (gen(r, d - 1, "bool"), gen(r, d - 1, "bool"), gen(r, d - 1, "bool")),
            lambda: "(%s is User in %s)" % (gen(r, d - 1, "ent"), gen(r, d - 1, "ent")),
        ]
        return r.choice(ops)()
    if ty == "int":
        if k < 0.7:
            return "(%s %s %s)" % (gen(r, d - 1, "int"), r.choice(["+", "-", "*"]), gen(r, d - 1, "int"))
        if k < 0.85:
            return "-%s" % gen(r, d - 1, "int")
        return "(if %s then %s else %s)" % (gen(r, d - 1, "bool"), gen(r, d - 1, "int"), gen(r, d - 1, "int"))
    if ty == "set":
        return "[%s]" % ", ".join(gen(r, d - 1, r.choice(["int", "str", "ent", "bool", "any"])) for _ in range(r.randint(0, 3)))
    if ty == "rec":
        keys = r.sample(["a", "b", "x", "name", '"q r"'], r.randint(0, 3))
        return "{%s}" % ", ".join("%s: %s" % (kk, gen(r, d - 1)) for kk in keys)
    if ty == "ent":
        return r.choice(["%s.owner" % gen(r, d - 1, "ent"), leaf(r, "ent")])
    if ty == "any":
        return r.choice(["%s.%s" % (gen(r, d - 1, r.choice(["ent", "rec"])), r.choice(ATTRS)),
                         "%s.getTag(%s)" % (gen(r, d - 1, "ent"), r.choice(['"t1"', '"level"', '"zz"'])),
                         gen(r, d - 1, r.choice(["int", "str", "bool", "set"]))])
    return leaf(r, ty)


def leaf(r, ty):
    return {
        "bool": lambda: r.choice(["true", "false", "context.flag", "principal.active", "resource.locked"]),
        "int": lambda: r.choice(INTS),
        "str": lambda: r.choice(STRS),
        "ent": lambda: r.choice(ENTS),
        "set": lambda: r.choice(["context.set", "principal.roles", "[]", "[1, 2]", '["dev"]']),
        "rec": lambda: r.choice(["context.rec", "principal.nested", "{}", "{a: 1}", "context"]),
        "dec": lambda: r.choice(DECS),
        "ip": lambda: r.choice(IPS),
        "any": lambda: r.choice(INTS + STRS + ENTS + ["context.rec", "[1]", "true"]),
    }[ty]()


def main():
    seed, count = int(sys.argv[1]), int(sys.argv[2])
    r = random.Random(seed)
    ents = json.dumps(G.STD_ENTITIES)
    req = json.dumps(G.STD_REQUEST)
    for i in range(count):
        e1, e2 = gen(r, 4, "bool"), gen(r, 4, "bool")
        mode = "F" if i % 5 == 4 else "A"
        pol = ("permit(principal, action, resource) when { %s };\n"
               "forbid(principal, action, resource) when { %s };\n"
               "permit(principal in Group::\"eng\", action, resource) unless { %s };") % (e1, e2, e2)
        sys.stdout.write("fz.%05d\t%s\t%s\t%s\t%s\n" % (i, mode, G.hx(pol), G.hx(ents), G.hx(req)))


if __name__ == "__main__":
    main()
