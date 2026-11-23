#!/usr/bin/env python3
"""Curated red-team corpus for packages/cedar vs Rust `cedar-policy =4.15.0`.

Prints one case per line:  <id>\t<mode>\t<hex policies>\t<hex entities>\t<hex request>
Case-id prefixes:
  ctl.*   control: behaviour Pion already matches (must stay green)
  p0.* / p1.* / p2.*  finding-specific probes (id = REPORT.md finding id)
  gap.*   documented v0.1.0 scope gaps (README): a mismatch is tolerated ONLY if Pion fails
          closed (PERR/EERR/RERR); any decision that differs from cedar-policy is a defect.
  lim.*   inputs beyond Pion's documented CedarLimits (max_depth): fail-closed PERR tolerated.
  tol.*   cedar-policy accepts, Pion rejects: fail-closed rejection tolerated.
  *.depth_*  P0-1 / P1 depth probes: rejecting the policy at PARSE time (PERR, honouring
          max_depth) is an acceptable fail-closed fix; a decision different from cedar-policy is not.
Every expectation comes from running the real `cedar-policy =4.15.0` (audit/rust oracle);
nothing here hard-codes an expected answer.
"""
import json
import sys

STD_ENTITIES = [
    {"uid": {"type": "User", "id": "alice"},
     "attrs": {"name": "alice", "age": 30, "active": True,
               "nested": {"a": {"b": 1}}, "roles": ["dev", "ops"],
               "owner": {"__entity": {"type": "User", "id": "bob"}},
               "ip": {"__extn": {"fn": "ip", "arg": "10.1.2.3"}},
               "amt": {"__extn": {"fn": "decimal", "arg": "12.5000"}}},
     "parents": [{"type": "Group", "id": "eng"}],
     "tags": {"t1": "v", "level": 3}},
    {"uid": {"type": "User", "id": "bob"}, "attrs": {}, "parents": []},
    {"uid": {"type": "Group", "id": "eng"}, "attrs": {}, "parents": [{"type": "Group", "id": "all"}]},
    {"uid": {"type": "Group", "id": "all"}, "attrs": {}, "parents": []},
    {"uid": {"type": "NS1::User", "id": "a"}, "attrs": {}, "parents": [{"type": "Group", "id": "ns1"}]},
    {"uid": {"type": "NS2::User", "id": "a"}, "attrs": {}, "parents": []},
    {"uid": {"type": "Action", "id": "view"}, "attrs": {}, "parents": [{"type": "Action", "id": "read"}]},
    {"uid": {"type": "Action", "id": "read"}, "attrs": {}, "parents": [{"type": "Action", "id": "all"}]},
    {"uid": {"type": "Doc", "id": "d1"},
     "attrs": {"owner": {"__entity": {"type": "User", "id": "alice"}}, "locked": False},
     "parents": [{"type": "Folder", "id": "f1"}]},
]
STD_REQUEST = {"principal": {"type": "User", "id": "alice"},
               "action": {"type": "Action", "id": "view"},
               "resource": {"type": "Doc", "id": "d1"},
               "context": {"n": 5, "s": "hello", "flag": True, "set": [1, 2, 3],
                           "rec": {"x": 1}, "ip": {"__extn": {"fn": "ip", "arg": "192.168.1.7"}}}}

CASES = []


def hx(s):
    return s.encode("utf-8").hex()


def case(cid, policies, entities=None, request=None, mode="A"):
    ents = json.dumps(STD_ENTITIES if entities is None else entities) if not isinstance(entities, str) else entities
    req = json.dumps(STD_REQUEST if request is None else request) if not isinstance(request, str) else request
    CASES.append((cid, mode, policies, ents, req))


def expr(cid, e, **kw):
    """Single-permit probe: Allow = true, Deny e= = false, Deny e=0 = evaluation error."""
    case(cid, "permit(principal, action, resource) when { %s };" % e, **kw)


def fmt_too(cid, policies, **kw):
    case(cid, policies, **kw)
    case(cid + ".fmt", policies, mode="F", **kw)


P = "permit(principal, action, resource);\n"
F = "forbid(principal, action, resource)"

# ---------------------------------------------------------------- authorization core (controls)
case("ctl.auth.default_deny", "")
case("ctl.auth.permit", P)
case("ctl.auth.forbid_overrides", P + F + ";")
case("ctl.auth.forbid_err_ignored", P + F + " when { principal.missing == 1 };")
case("ctl.auth.permit_err_isolated", F + " when { true };\npermit(principal, action, resource) when { principal.missing };")
case("ctl.auth.mixed", P + F + " when { context.n > 3 };\npermit(principal, action, resource) when { 1 + \"a\" == 2 };")
case("ctl.auth.unless", P + F + " unless { context.flag };")
case("ctl.auth.multi_when", "permit(principal, action, resource) when { true } when { context.n == 5 } unless { false };")
case("ctl.auth.scope_eq", "permit(principal == User::\"alice\", action == Action::\"view\", resource == Doc::\"d1\");")
case("ctl.auth.scope_in", "permit(principal in Group::\"all\", action in Action::\"all\", resource in Folder::\"f1\");")
case("ctl.auth.scope_in_set", "permit(principal, action in [Action::\"x\", Action::\"read\"], resource);")
case("ctl.auth.scope_is", "permit(principal is User, action, resource is Doc);")
case("ctl.auth.scope_is_in", "permit(principal is User in Group::\"eng\", action, resource is Doc in Folder::\"f1\");")
case("ctl.auth.scope_is_wrong", "permit(principal is Group in Group::\"eng\", action, resource);")
case("ctl.auth.scope_unknown_res", "permit(principal, action, resource in Folder::\"zzz\");")
case("ctl.auth.overflow_err", P + F + " when { 9223372036854775807 + context.n > 0 };")

# ---------------------------------------------------------------- short-circuit
for i, e in enumerate([
    "false && (1 + \"a\" == 2)", "false && principal.missing", "true || principal.missing",
    "true || 1", "if true then true else principal.missing", "if false then principal.missing else true",
    "principal has nested && principal.nested.a.b == 1", "principal has missing && principal.missing == 1",
    "false && 9223372036854775807 + 1 == 0", "context has zz && context.zz", "true && 1", "1 || true",
    "false || 1", "if 1 then true else false", "if context.flag then context.n == 5 else 1",
    "!(false && principal.missing)", "(true || principal.missing) && true",
]):
    expr("ctl.sc.%02d" % i, e)

# ---------------------------------------------------------------- entity `in` / `is`
for i, e in enumerate([
    "User::\"alice\" in User::\"alice\"", "principal in Group::\"all\"", "Group::\"all\" in Group::\"eng\"",
    "Group::\"eng\" in Group::\"eng\"", "NS1::User::\"a\" in Group::\"ns1\"", "NS2::User::\"a\" in Group::\"ns1\"",
    "NS1::User::\"a\" == NS2::User::\"a\"", "User::\"ghost\" in User::\"ghost\"", "User::\"ghost\" in Group::\"eng\"",
    "action in [Action::\"x\", Action::\"all\"]", "action in Action::\"all\"", "principal in []",
    "principal in [Group::\"eng\", 1]", "principal in [1, Group::\"eng\"]", "1 in Group::\"x\"",
    "principal in \"x\"", "principal is User in Group::\"eng\"", "principal is Group in Group::\"eng\"",
    "principal is Group in 1", "principal is User in 1", "principal is User in [Group::\"x\", Group::\"all\"]",
    "Doc::\"d1\" in Folder::\"f1\"", "resource.owner in Group::\"eng\"", "1 is User", "principal is NS1::User",
]):
    expr("ctl.in.%02d" % i, e)

# ---------------------------------------------------------------- has / attrs / tags
for i, e in enumerate([
    "principal has name", "principal has \"name\"", "principal has missing", "User::\"ghost\" has name",
    "User::\"ghost\".name == 1", "context has n", "1 has x", "principal.nested has a",
    "principal.nested.a has b", "principal[\"name\"] == \"alice\"", "principal.owner == User::\"bob\"",
    "principal.owner.missing == 1", "context.rec.x == 1", "context.rec.y == 1", "principal.roles.contains(\"ops\")",
    "principal.hasTag(\"t1\")", "principal.getTag(\"t1\") == \"v\"", "principal.getTag(\"level\") == 3",
    "principal.getTag(\"nope\") == 1", "User::\"ghost\".hasTag(\"t1\")", "User::\"ghost\".getTag(\"t1\") == 1",
    "principal.hasTag(1)", "Doc::\"d1\".hasTag(\"x\")", "context.hasTag(\"x\")", "User::\"bob\".getTag(\"t1\") == 1",
    "principal.ip.isInRange(ip(\"10.0.0.0/8\"))", "principal.amt == decimal(\"12.5\")",
    "resource.owner == principal", "resource.locked == false",
]):
    expr("ctl.attr.%02d" % i, e)
# Cedar 4 extended `has` (attribute paths)
for i, e in enumerate(["principal has nested.a.b", "principal has nested.a.zz", "principal has zz.a",
                       "context has rec.x"]):
    expr("p2.has_path.%02d" % i, e)

# ---------------------------------------------------------------- string escapes
for i, e in enumerate([
    r'"\n" == "\u{a}"', r'"\x41" == "A"', r'"\x7f" == "\u{7f}"', r'"\x80" == "a"', r'"\u{D800}" == "a"',
    r'"\u{110000}" == "a"', r'"\u{10FFFF}" == "\u{10ffff}"', r'"\'" == "' + "'" + '"', r'"\0" == "\u{0}"',
    r'"\q" == "q"', r'"\u{}" == ""', r'"\u{1234567}" == ""', r'"\u0041" == "A"', '"a\tb" == "a\\tb"',
    '"a\nb" == "a\\nb"', '"a\x01b" == "a\\u{1}b"', r'"\*" == "*"', '"\u00e9" == "\\u{e9}"',
    r'"\x4" == ""', r'"\xZZ" == ""', r'"\u{0041}" == "A"', '"\u10ffff" == "\\u{10ffff}"', r'"\r\t" == "\u{d}\u{9}"',
]):
    expr("ctl.str.%02d" % i, e)

# ---------------------------------------------------------------- integers / unary / arithmetic
for i, e in enumerate([
    "9223372036854775807 == 9223372036854775807", "9223372036854775808 == 0",
    "-9223372036854775808 == -9223372036854775807 - 1", "-(-9223372036854775808) == 0",
    "--9223372036854775808 == 0", "-9223372036854775808 * -1 == 0", "-9223372036854775808 * 1 == -9223372036854775808",
    "9223372036854775807 + 1 == 0", "-9223372036854775807 - 2 == 0", "--1 == 1", "---1 == -1", "----1 == 1",
    "!!true", "!!!!true", "007 == 7", "00 == 0", "99999999999999999999 == 0", "- 1 == -1",
    "2 * -3 == -6", "3 - -9223372036854775808 == 0", "-9223372036854775808 + -1 == 0",
    "9223372036854775807 * 2 == 0", "-9223372036854775808 == context.n * 0 - 9223372036854775807 - 1",
    "context.n * 1844674407370955161 == 0", "1 < 2", "\"a\" < \"b\"", "true < false",
    "1 == \"1\"", "[1,2] == [2,1]", "[1,1] == [1]", "{a:1,b:2} == {b:2,a:1}", "{a:1} == {a:1,b:2}",
    "[[1,2],[3]] == [[3],[2,1]]", "[{a:[1,2]}] == [{a:[2,1]}]", "context.set == [3,2,1]",
    "context.set.containsAll([1,3])", "context.set.containsAny([9,3])", "[].isEmpty()", "context.set.isEmpty()",
    "[1, \"a\", true].contains(\"a\")", "context.set.containsAll(1)", "context.n.contains(1)",
]):
    expr("ctl.int.%02d" % i, e)
for i, e in enumerate(["!!!!!true", "-----1 == -1", "!!!!!!!!!!true"]):
    expr("p2.unary_limit.%02d" % i, e)

# ---------------------------------------------------------------- like
LIKE = [
    r'"abc" like "a*c"', '"a\\nb" like "a*b"', r'"*" like "\*"', r'"a*" like "a\*"', r'"x" like "\*"',
    r'"a\\b" like "a\\*"', r'"\u{e9}a" like "*a"', r'"" like "*"', r'"" like ""', r'"abc" like "abc*"',
    r'"abc" like "*b*"', r'"*" like "\u{2a}"', r'"abc" like ""', r'1 like "*"',
    r'"aXbXc" like "a*b*c"', r'"ab" like "a**b"', r'"a" like "\q"',
    '"\u00e9\u00e9x" like "\u00e9*x"', r'"abc" like "*c*"', r'"abcabc" like "*bc"', r'"ac" like "a*b*c"',
    r'"a\tb" like "a\tb"', r'context.s like "h*o"', r'"\u{1F600}x" like "*x"',
    '"' + "a" * 300 + '" like "' + "a*" * 30 + 'b"', '"' + "a" * 300 + '" like "' + "*a" * 30 + '"',
]
for i, e in enumerate(LIKE):
    expr("ctl.like.%02d" % i, e)
# `\u{2a}` / `\x2a` decode to `*` BEFORE wildcard classification in cedar-policy (only `\*` is a literal star)
for i, e in enumerate([r'"x" like "\u{2a}"', r'"abc" like "\x2a"', r'"abc" like "a\u{2a}"', r'"a*" like "a\x2a"']):
    expr("p2.like_escape.%02d" % i, e)

# ---------------------------------------------------------------- precedence / non-associativity / grammar
for i, e in enumerate([
    "1 == 1 == true", "1 < 2 < 3", "principal in Group::\"eng\" in Group::\"all\"", "principal has name has x",
    "\"a\" like \"a\" like \"a\"", "principal is User is User", "!principal has name",
    "if true then 1 else 2 == 1", "1 + if true then 1 else 2 == 2", "(if true then 1 else 2) == 1",
    "1 + 2 * 3 == 7", "(1 + 2) * 3 == 9", "1 - 2 - 3 == -4", "!true || true", "true || false && false",
    "-context.n == -5", "-context.set.contains(1)", "principal.name like \"a*\" && true",
    "[1,] == [1]", "{a:1,} == {a:1}", "{\"a b\": 1}[\"a b\"] == 1", "{a: 1}.a == 1",
    "principal.\"name\" == \"alice\"", "[1, 2][0] == 1", "context[\"n\"] == 5", "({a:1}).a == 1",
    "context.n.x == 1", "(true)", "((((((((((true))))))))))", "if true then if false then false else true else false",
]):
    expr("ctl.gram.%02d" % i, e)

# reserved words / identifiers / names
for i, e in enumerate([
    "{if: 1} == {if: 1}", "principal has if", "context.in == 1", "{\"if\": 1}[\"if\"] == 1", "{true: 1} == {true: 1}",
    "if::\"x\" == if::\"x\"", "principal == principal::\"x\"", "__cedar::X::\"a\" == __cedar::X::\"a\"",
    "X::__cedar::\"a\" == X::__cedar::\"a\"", "principal is __cedar", "principal is if", "principal.then == 1",
    "{permit: 1}.permit == 1", "context.context == 1", "principal is principal", "principal has __cedar",
    "{__cedar: 1} == {__cedar: 1}", "Action::\"view\" == action", "action == Action::\"view\"",
]):
    expr("p2.ident.%02d" % i, e)

for i, src in enumerate([
    "@if(\"x\") permit(principal, action, resource);",
    "@true(\"x\") permit(principal, action, resource);",
    "@in permit(principal, action, resource);",
    "@a(\"x\") @a(\"y\") permit(principal, action, resource);",
    "@a permit(principal, action, resource);",
    "@a(\"\\u{e9}\\n\") permit(principal, action, resource);",
    "permit(principal, action, resource,);",
    "permit(principal, action in [Action::\"read\",], resource);",
    "permit(principal, action in [], resource);",
    "permit(principal, action == User::\"view\", resource);",
    "permit(principal, action in Group::\"eng\", resource);",
    "permit(principal, action in [Action::\"read\", User::\"x\"], resource);",
    "permit(principal, action, resource) when { true } // trailing comment",
    "permit(principal, action, resource) /* block */;",
    "permit(principal, action, resource) when { };",
    "permit(principal, action, resource)",
    "permit(principal, action, resource) when { true };;",
    "permit(action, principal, resource);",
    "permit(principal in Group::\"eng\", action, resource) when { true } unless { false } when { context.flag };",
    "permit(principal, action, resource) when { context.n == 5 }\n// c1\n// c2\n;",
    "PERMIT(principal, action, resource);",
    "permit (principal , action , resource ) ;",
    "permit(principal is User in [Group::\"eng\"], action, resource);",
    "permit(principal in [Group::\"eng\"], action, resource);",
    "permit(principal is User == User::\"alice\", action, resource);",
    "permit(principal, action, resource is Doc::\"d1\");",
]):
    case("p2.scope.%02d" % i, src)

# unknown methods / functions / arity  (parse-time in cedar-policy)
for i, e in enumerate([
    "context.set.foo()", "foo(1) == 1", "decimal(\"1.0\", \"2.0\") == decimal(\"1.0\")", "ip() == ip()",
    "context.set.contains()", "context.set.contains(1, 2)", "A::ip(\"1.1.1.1\") == ip(\"1.1.1.1\")",
    "context.ip.isInRnage(ip(\"10.0.0.0/8\"))", "context.set.containsall([1])", "context.s.length() == 5",
    "ip(\"1.1.1.1\").isLoopback(1)", "decimal(\"1.0\").lessThan()", "context.ip.isIpv4(1)",
    "\"a\".contains(\"a\")", "principal.isEmpty()",
]):
    expr("p1.unknown_fn.%02d" % i, e)
# The fail-open shape: a forbid with an unsupported / misspelled call
case("p1.unknown_fn.forbid_typo", P + F + " when { context.ip.isInRnage(ip(\"192.168.0.0/16\")) };")
case("p1.unknown_fn.forbid_custom", P + F + " when { isBlocked(principal) };")

# ---------------------------------------------------------------- decimal
for i, e in enumerate([
    "decimal(\"1.0\") == decimal(\"1.0000\")", "decimal(\"-0.0\") == decimal(\"0.0\")",
    "decimal(\"922337203685477.5807\").greaterThan(decimal(\"0.0\"))",
    "decimal(\"-922337203685477.5808\").lessThan(decimal(\"0.0\"))",
    "decimal(\"922337203685477.5808\") == decimal(\"0.0\")", "decimal(\"-922337203685477.5809\") == decimal(\"0.0\")",
    "decimal(\"1\") == decimal(\"1.0\")", "decimal(\"1.\") == decimal(\"1.0\")", "decimal(\".5\") == decimal(\"0.5\")",
    "decimal(\"1.00000\") == decimal(\"1.0\")", "decimal(\"+1.0\") == decimal(\"1.0\")", "decimal(\" 1.0 \") == decimal(\"1.0\")",
    "decimal(\"1.0 \") == decimal(\"1.0\")", "decimal(\"0001.5\") == decimal(\"1.5\")",
    "decimal(\"1.5\").lessThanOrEqual(decimal(\"1.5\"))", "decimal(\"1e2\") == decimal(\"100.0\")",
    "decimal(\"--1.0\") == decimal(\"1.0\")", "decimal(\"1.0\").lessThan(1)", "decimal(\"\u0661.\u0660\") == decimal(\"1.0\")",
    "decimal(\"1.0\") == ip(\"1.1.1.1\")", "decimal(context.s) == decimal(\"1.0\")", "decimal(1) == decimal(\"1.0\")",
    "decimal(\"1.0\") < decimal(\"2.0\")", "decimal(\"-1.5\").greaterThanOrEqual(decimal(\"-1.5001\"))",
    "decimal(\"922337203685477.0\").greaterThan(decimal(\"922337203685476.9999\"))",
    "decimal(\"99999999999999999999.0\") == decimal(\"1.0\")", "decimal(\"-0.0001\").lessThan(decimal(\"0.0\"))",
    "decimal(\"0.1234\") != decimal(\"0.1235\")", "decimal(\"1.0\") == decimal(\"1.0\") && true",
    "[decimal(\"1.0\"), decimal(\"1.00\")] == [decimal(\"1.000\")]", "decimal(\"\") == decimal(\"1.0\")",
    "decimal(\"-\") == decimal(\"1.0\")", "decimal(\"-.5\") == decimal(\"-0.5\")", "decimal(\"1.-5\") == decimal(\"1.0\")",
]):
    expr("ctl.dec.%02d" % i, e)

# ---------------------------------------------------------------- ip
IP_EXPRS = [
    "ip(\"10.0.0.1\").isInRange(ip(\"10.0.0.0/24\"))", "ip(\"10.0.0.1/24\").isInRange(ip(\"10.0.0.0/24\"))",
    "ip(\"10.0.0.0/23\").isInRange(ip(\"10.0.0.0/24\"))", "ip(\"01.2.3.4\") == ip(\"1.2.3.4\")",
    "ip(\"1.2.3.4/33\") == ip(\"1.2.3.4\")", "ip(\"::/129\") == ip(\"::\")", "ip(\"1.2.3.4/01\") == ip(\"1.2.3.4/1\")",
    "ip(\"::ffff:c000:201\").isIpv4()", "ip(\"::1\").isLoopback()", "ip(\"::1/127\").isLoopback()",
    "ip(\"127.0.0.1/7\").isLoopback()", "ip(\"127.255.255.255/8\").isLoopback()", "ip(\"127.0.0.1/0\").isLoopback()",
    "ip(\"224.0.0.1\").isMulticast()", "ip(\"224.0.0.0/3\").isMulticast()", "ip(\"ff02::1\").isMulticast()",
    "ip(\"ff00::/7\").isMulticast()", "ip(\"1.2.3.4\").isInRange(ip(\"::/0\"))", "ip(\"::\").isInRange(ip(\"0.0.0.0/0\"))",
    "ip(\"0.0.0.0/0\").isInRange(ip(\"0.0.0.0/0\"))", "ip(\"1.2.3\") == ip(\"1.2.3.0\")", "ip(\"1.2.3.4.5\") == ip(\"1.2.3.4\")",
    "ip(\"256.1.1.1\") == ip(\"1.1.1.1\")", "ip(\"1.2.3.4/\") == ip(\"1.2.3.4\")", "ip(\"1:2:3:4:5:6:7:8:9\") == ip(\"::\")",
    "ip(\"1::2::3\") == ip(\"::\")", "ip(\"1.2.3.4/24/1\") == ip(\"1.2.3.4\")", "ip(\"fe80::1%eth0\") == ip(\"fe80::1\")",
    "ip(\"FFFF::1\") == ip(\"ffff::1\")", "ip(\"0:0:0:0:0:0:0:1\") == ip(\"::1\")", "ip(\"10.0.0.1/24\") == ip(\"10.0.0.1/24\")",
    "ip(\" 1.2.3.4\") == ip(\"1.2.3.4\")", "ip(\"1.2.3.4\").isLoopback()", "ip(\"10.0.0.0/8\").isInRange(ip(\"10.0.0.0/8\"))",
    "ip(\"1.2.3.4\") == ip(\"1.2.3.4/32\")", "ip(\"::1\") == ip(\"::1/128\")", "ip(\"1.2.3.4\").isIpv4()",
    "ip(\"::\").isIpv6()", "ip(\"1:2:3:4:5:6:7::\") == ip(\"1:2:3:4:5:6:7:0\")", "ip(\"::2:3:4:5:6:7:8\").isIpv6()",
    "ip(\"1:2:3:4:5:6:7:8/64\").isInRange(ip(\"1:2:3:4::/64\"))", "ip(\"1:2:3:4:5:6:7:8/63\").isInRange(ip(\"1:2:3:4::/64\"))",
    "ip(\"2001:db8::/32\").isInRange(ip(\"2001:db8::/31\"))", "ip(\"0.0.0.0/32\").isInRange(ip(\"0.0.0.0/31\"))",
    "ip(\"255.255.255.255\").isInRange(ip(\"255.255.255.254/31\"))", "ip(\"1.2.3.4\").isInRange(1)",
    "ip(1) == ip(\"1.1.1.1\")", "ip(\"::1:2:3:4:5:6:7\").isIpv6()", "ip(\"1:2:3:4:5:6::7:8\").isIpv6()",
    "ip(\"12345::1\").isIpv6()", "ip(\":1::\").isIpv6()", "ip(\"1::\").isIpv6()", "ip(\"::1:\").isIpv6()",
    "ip(\"1.2.3.4/0\").isInRange(ip(\"0.0.0.0/0\"))", "ip(\"192.168.0.1\").isInRange(ip(\"192.168.0.0/16\"))",
    "ip(\"10.0.0.1\").isMulticast()",
]
for i, e in enumerate(IP_EXPRS):
    expr("ctl.ip.%02d" % i, e)
# Divergences in the ip extension (host bits, IPv4-in-IPv6, string length)
for i, e in enumerate([
    "ip(\"10.0.0.1/24\") == ip(\"10.0.0.0/24\")", "[ip(\"10.0.0.1/24\")].contains(ip(\"10.0.0.0/24\"))",
    "ip(\"192.168.1.77/16\") != ip(\"192.168.0.0/16\")", "ip(\"::1/64\") == ip(\"::/64\")",
    "ip(\"::1/64\").isLoopback()", "ip(\"ff02::1/64\") == ip(\"ff02::/64\")",
]):
    expr("p1.ip_hostbits.%02d" % i, e)
for i, e in enumerate([
    "ip(\"::ffff:192.0.2.1\").isIpv6()", "ip(\"::ffff:127.0.0.1\").isLoopback()", "ip(\"::1.2.3.4\").isIpv6()",
    "ip(\"64:ff9b::192.0.2.33\").isIpv6()", "ip(\"0000:0000:0000:0000:0000:0000:0000:0001/128\").isLoopback()",
    "ip(\"::ffff:10.0.0.1\").isInRange(ip(\"::ffff:0:0/96\"))",
]):
    expr("p2.ip_embedded.%02d" % i, e)

# ---------------------------------------------------------------- formatter round-trips (mode F)
FMT = [
    P + F + " when { principal.name like \"a\\*b*\" };",
    "@id(\"x\\\"y\") @note(\"line1\\nline2\\t\\u{e9}\") permit(principal == User::\"al\\\"ice\\n\", action, resource);",
    "permit(principal == User::\"\\u{0}\\u{1}\\u{7f}\", action, resource) when { context.s == \"\\\\\\\"\" };",
    "permit(principal, action, resource) when { -context.n == -5 && --context.n == 5 && -(-context.n) == 5 };",
    "permit(principal, action, resource) when { context.n - -5 == 10 && context.n * -1 == -5 };",
    "permit(principal, action, resource) when { -9223372036854775808 < context.n };",
    "permit(principal, action, resource) when { {\"a b\": 1, ok: 2, \"\": 3}[\"a b\"] == 1 };",
    "permit(principal, action, resource) when { principal has \"na\\u{6d}e\" && principal[\"name\"] == \"alice\" };",
    "permit(principal, action, resource) when { (if context.flag then 1 else 2) + 1 == 2 };",
    "permit(principal, action, resource) when { !(context.flag && false) || principal is User in Group::\"eng\" };",
    "permit(principal, action, resource) when { (principal is User) && (principal in [Group::\"eng\"]) };",
    "permit(principal, action, resource) when { ip(\"10.0.0.0/8\").isInRange(ip(\"10.0.0.0/8\")) && [1,2].containsAll([2]) };",
    "@a permit(principal, action, resource);",
    "permit(principal, action, resource) when { \"\\u{1F600}\" like \"*\" && \"x\" like \"\\u{2a}\" == false };",
    "permit(principal, action, resource) when { principal.nested.a.b == 1 && (principal.nested).a has b };",
    "permit(principal, action, resource) when { (1).foo == 1 || true };",
    "permit(principal, action, resource) when { -(1) == -1 && -(9223372036854775807) == -9223372036854775807 };",
]
FMT_IDENT = [
    "permit(principal, action, resource) when { {\"if\": 1}[\"if\"] == 1 && {\"is\": 2}[\"is\"] == 2 };",
    "permit(principal, action, resource) when { principal has \"in\" || context has \"then\" || true };",
    "permit(principal, action, resource) when { {\"__cedar\": 1, \"true\": 2} has \"true\" };",
    "permit(principal, action, resource) when { principal[\"else\"] == 1 || true };",
]
for i, src in enumerate(FMT):
    fmt_too("ctl.fmt.%02d" % i, src)
# reserved words reached through ["..."] / has "..." / string record keys: legal Cedar, but the
# formatter must keep them quoted (cedar-policy rejects `.if`, `has in`, `{if: ..}`, `__cedar`)
for i, src in enumerate(FMT_IDENT):
    fmt_too("p2.fmt_ident.%02d" % i, src)

# ---------------------------------------------------------------- P0: evaluation-depth fail-open
def or_chain(n, last):
    terms = ["principal == User::\"u%d\"" % k for k in range(n - 1)] + [last]
    return " || ".join(terms)


for n in (100, 127, 128, 129, 130, 200, 1000):
    case("p0.depth_or.%04d" % n, P + F + " when { " + or_chain(n, "principal == User::\"alice\"") + " };")
for n in (129, 300):
    case("p0.depth_and_unless.%04d" % n,
         P + F + " unless { " + " && ".join("principal != User::\"u%d\"" % k for k in range(n - 1))
         + " && principal != User::\"alice\" };")
    case("p0.depth_add.%04d" % n, P + F + " when { " + " + ".join(["1"] * n) + " == %d };" % n)
    case("p0.depth_in_set.%04d" % n,
         P + F + " when { " + " || ".join("principal in Group::\"g%d\"" % k for k in range(n - 1))
         + " || principal in Group::\"all\" };")
    case("p0.depth_like.%04d" % n,
         P + F + " when { " + " || ".join("context.s like \"x%d*\"" % k for k in range(n - 1)) + " || context.s like \"h*\" };")
# the same allow-list shape on a permit: fails CLOSED in Pion (Deny), Allow in cedar-policy
case("p1.depth_permit_allowlist.0200",
     "permit(principal, action, resource) when { " + or_chain(200, "principal == User::\"alice\"") + " };")
# parse-time depth: plain nesting above max_depth (fail-closed, availability only)
case("lim.parse_depth.parens_130", "permit(principal, action, resource) when { " + "(" * 130 + "true" + ")" * 130 + " };")
case("lim.parse_depth.sets_130", "permit(principal, action, resource) when { " + "[" * 130 + "1" + "]" * 130 + " == [] || true };")
def nested_if(n):
    e = "true"
    for k in range(n):
        e = "if context.n == %d then false else %s" % (k, e)
    return e


for n in (40, 70, 100):
    fmt_too("p1.fmt_depth.if_%03d" % n, P + F + " when { " + nested_if(n) + " };")
fmt_too("p1.fmt_depth.has_and_120", P + F + " when { " + " && ".join(["context has n"] * 119) + " && context.n == 5 };")
fmt_too("p1.fmt_depth.or_80", "permit(principal, action, resource) when { " + or_chain(80, "true") + " };")
fmt_too("p1.fmt_depth.add_80", "permit(principal, action, resource) when { " + " + ".join(["1"] * 80) + " == 80 };")

# ---------------------------------------------------------------- policy ids / annotations
case("p2.policy_id.dup_annotation", "@id(\"a\") permit(principal, action, resource);\n@id(\"a\") " + F + ";")
case("p2.policy_id.shadow_auto", "@id(\"policy1\") " + F + ";\npermit(principal, action, resource);")
case("ctl.policy_id.unique", "@id(\"a\") permit(principal, action, resource);\n@id(\"b\") " + F + " when { false };")

# ---------------------------------------------------------------- JSON entities
def ents_with(extra):
    return STD_ENTITIES + extra


def raw_case(cid, policies, ents_text=None, req_text=None):
    case(cid, policies, entities=ents_text if ents_text is not None else json.dumps(STD_ENTITIES),
         request=req_text if req_text is not None else json.dumps(STD_REQUEST))


raw_case("p1.json_type.nul", P, json.dumps([{"uid": {"type": "User\u0000x", "id": "y"}, "attrs": {}, "parents": []}]))
for i, ty in enumerate(["user name", "NS::", "::User", "NS:::User", "1User", "if", "User ", "Us\u00e9r", "",
                        "NS::if", "__cedar::User", "User::\"x\""]):
    raw_case("p1.json_type.bad_%02d" % i, P, json.dumps([{"uid": {"type": ty, "id": "y"}, "attrs": {}, "parents": []}]))
# entity-key collision through NUL: identity confusion with the collided entity's ancestors / attrs
COLLIDE_ENTS = json.dumps([{"uid": {"type": "User", "id": "a\u0000b"}, "attrs": {"admin": True},
                            "parents": [{"type": "Group", "id": "admins"}]}])
COLLIDE_REQ = json.dumps({"principal": {"type": "User\u0000a", "id": "b"}, "action": {"type": "Action", "id": "view"},
                          "resource": {"type": "Doc", "id": "d1"}, "context": {}})
raw_case("p1.uid_collision.in", "permit(principal in Group::\"admins\", action, resource);", COLLIDE_ENTS, COLLIDE_REQ)
raw_case("p1.uid_collision.attr", "permit(principal, action, resource) when { principal.admin };", COLLIDE_ENTS, COLLIDE_REQ)
raw_case("p1.req_type.bad", P, None, json.dumps({"principal": {"type": "not a type", "id": "x"},
                                                  "action": {"type": "Action", "id": "view"},
                                                  "resource": {"type": "Doc", "id": "d1"}}))
raw_case("p1.req_type.action_bad", P, None, json.dumps({"principal": {"type": "User", "id": "x"},
                                                         "action": {"type": "Action::", "id": "view"},
                                                         "resource": {"type": "Doc", "id": "d1"}}))

E1 = '[{"uid":{"type":"User","id":"alice"},"attrs":%s,"parents":[]}]'
for i, attrs in enumerate([
    '{"a":1,"a":2}', '{"a":1.0}', '{"a":1e2}', '{"a":-0}', '{"a":null}', '{"a":{"__extn":{"fn":"nope","arg":"x"}}}',
    '{"a":{"__extn":{"fn":"ip","arg":"10.0.0.1"},"x":1}}', '{"a":{"__entity":{"type":"User","id":"bob"},"x":1}}',
    '{"a":{"type":"User","id":"bob"}}', '{"a":{"__entity":{"__entity":{"type":"User","id":"bob"}}}}',
    '{"a":{"__extn":{"fn":"decimal","arg":"1.0","x":1}}}',
    '{"a":{"__entity":{"type":"User","id":"bob","x":1}}}', '{"a":[1,1,2]}', '{"a":"\\u0000"}',
    '{"a":{"__extn":{"fn":"ip","arg":"10.0.0.1/24"}}}', '{"a":{"__extn":{"fn":"decimal","arg":"1"}}}',
    '{"a":{"__extn":{"fn":"ip","arg":{"__extn":{"fn":"ip","arg":"1.1.1.1"}}}}}', '{"a":true,"b":[{"c":{}}]}',
'{"__entity":{"type":"User","id":"bob"}}',
]):
    raw_case("p1.json_attr.%02d" % i,
             "permit(principal, action, resource) when { principal has a && (principal.a == 1 || principal.a == User::\"bob\" || principal.a == [1,2] || principal.a == ip(\"10.0.0.1\") || principal.a == 100) };",
             E1 % attrs)
for i, n in enumerate(["9007199254740993", "9007199254740992", "-9007199254740993", "9223372036854775807",
                       "-9223372036854775808", "9223372036854775808", "18446744073709551616"]):
    raw_case("gap.json_bigint.%02d" % i,
             "permit(principal, action, resource) when { principal.a == %s };" % n if n not in (
                 "9223372036854775808", "18446744073709551616") else
             "permit(principal, action, resource) when { principal has a };", E1 % ('{"a":%s}' % n))
for i, ent in enumerate([
    '[{"uid":{"type":"User","id":"alice"},"parents":[]}]', '[{"uid":{"type":"User","id":"alice"},"attrs":{}}]',
    '[{"uid":{"type":"User","id":"alice"}}]', '[{"uid":{"type":"User","id":"alice"},"attrs":{},"parents":{}}]',
    '[{"uid":{"type":"User","id":"alice","x":1},"attrs":{},"parents":[]}]',
    '[{"uid":{"__entity":{"type":"User","id":"alice"}},"attrs":{},"parents":[]}]',
    '[{"uid":{"type":"User","id":1},"attrs":{},"parents":[]}]',
    '[{"uid":{"type":"User","id":"alice"},"attrs":{},"parents":[],"extra":1}]',
    '{"uid":{"type":"User","id":"alice"}}', '[{"uid":{"type":"User","id":"alice"},"attrs":{},"parents":[],"tags":[]}]',
    '[{"uid":{"type":"User","id":"alice"},"attrs":[],"parents":[]}]',
    '[{"uid":{"type":"User","id":"alice"},"attrs":{},"parents":[{"__entity":{"type":"Group","id":"g"}}]}]',
    '[{"uid":{"type":"User","id":"alice"},"attrs":{},"parents":["Group::\\"g\\""]}]',
    '[{"uid":"User::\\"alice\\"","attrs":{},"parents":[]}]',
    '[{"uid":{"type":"User","id":"alice"},"attrs":{},"parents":[{"type":"Group","id":"g"},{"type":"Group","id":"g"}]}]',
    '[{"uid":{"type":"User","id":"alice"},"attrs":{},"parents":[{"type":"User","id":"alice"}]}]',
    '[{"uid":{"type":"User","id":"alice"},"uid":{"type":"User","id":"bob"},"attrs":{},"parents":[]}]',
    '[]', '[{"uid":{"type":"User","id":"\\u00e9"},"attrs":{},"parents":[]}]',
]):
    raw_case("p1.json_ent.%02d" % i, "permit(principal in Group::\"g\", action, resource);", ent)
for i, req in enumerate([
    '{"principal":{"type":"User","id":"alice"},"action":{"type":"Action","id":"view"},"resource":{"type":"Doc","id":"d1"},"context":[]}',
    '{"principal":{"type":"User","id":"alice"},"action":{"type":"Action","id":"view"},"resource":{"type":"Doc","id":"d1"},"context":{"a":1.5}}',
    '{"principal":{"__entity":{"type":"User","id":"alice"}},"action":{"type":"Action","id":"view"},"resource":{"type":"Doc","id":"d1"}}',
    '{"principal":{"type":"User","id":"alice"},"action":{"type":"Action","id":"view"},"resource":{"type":"Doc","id":"d1"},"context":{"x":{"__entity":{"type":"User","id":"alice"}}}}',
    '{"principal":{"type":"User","id":"alice"},"action":{"type":"Action","id":"view"},"resource":{"type":"Doc","id":"d1"},"context":{"a":null}}',
    '{"principal":{"type":"User","id":"alice"},"action":{"type":"Action","id":"view"}}',
    '{"principal":{"type":"User","id":"alice"},"action":{"type":"Action","id":"view"},"resource":{"type":"Doc","id":"d1"},"context":{"x":{"type":"User","id":"alice"}}}',
]):
    raw_case("p1.json_req.%02d" % i,
             "permit(principal, action, resource) when { context has x && context.x == User::\"alice\" || context == {} };",
             None, req)

# cedar-policy is MORE permissive than Pion here; Pion failing closed is tolerated (tol.*)
raw_case("tol.json_dup_entity", "permit(principal in Group::\"g\", action, resource);",
         '[{"uid":{"type":"User","id":"alice"},"attrs":{},"parents":[]},{"uid":{"type":"User","id":"alice"},"attrs":{},"parents":[]}]')
raw_case("tol.json_extn_malformed", "permit(principal, action, resource) when { principal has a };",
         E1 % '{"a":{"__extn":{"fn":"ip"}}}')

# cyclic hierarchies: cedar-policy refuses them at load time (TransitiveClosureError::HasCycle)
CYC = [{"uid": {"type": "Group", "id": "x"}, "attrs": {}, "parents": [{"type": "Group", "id": "y"}]},
       {"uid": {"type": "Group", "id": "y"}, "attrs": {}, "parents": [{"type": "Group", "id": "x"}]},
       {"uid": {"type": "User", "id": "alice"}, "attrs": {}, "parents": [{"type": "Group", "id": "x"}]}]
case("p1.cycle.two", "permit(principal in Group::\"y\", action, resource);", entities=CYC)
case("p1.cycle.self", "permit(principal in Group::\"g\", action, resource);",
     entities=[{"uid": {"type": "User", "id": "alice"}, "attrs": {}, "parents": [{"type": "User", "id": "alice"}, {"type": "Group", "id": "g"}]}])
case("p1.cycle.forbid", P + F + " when { principal in Group::\"y\" };", entities=CYC)

# ---------------------------------------------------------------- documented gaps (must fail closed)
raw_case("gap.json_datetime", "permit(principal, action, resource) when { principal has a };",
         E1 % '{"a":{"__extn":{"fn":"datetime","arg":"2024-01-01"}}}')
case("gap.datetime.forbid", P + F + " when { datetime(\"2026-01-01\") < datetime(\"2027-01-01\") };")
case("gap.duration.forbid", P + F + " when { duration(\"1h\") > duration(\"30m\") };")
case("gap.datetime.permit", "permit(principal, action, resource) when { datetime(\"2026-01-01\").toDate() == datetime(\"2026-01-01\") };")
case("gap.template.principal", "permit(principal == ?principal, action, resource);")
case("gap.template.resource", "permit(principal, action, resource in ?resource);")
case("gap.template.unlinked", "permit(principal == ?principal, action, resource);\n" + F + " when { false };")
case("gap.decimal_lt_overload", P + F + " when { decimal(\"1.0\") < decimal(\"2.0\") || true };")

if __name__ == "__main__":
    out = sys.stdout
    seen = set()
    for cid, mode, pol, ents, req in CASES:
        assert cid not in seen, cid
        seen.add(cid)
        out.write("%s\t%s\t%s\t%s\t%s\n" % (cid, mode, hx(pol), hx(ents), hx(req)))
