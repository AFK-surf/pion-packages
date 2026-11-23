#!/usr/bin/env python3
"""Self-consistency proof for audit/redteam_test.pion + audit/control_test.pion.

usage: test_expect.py emit > cases ;  test_expect.py check <cases> <rust transcript>
`emit` rebuilds the exact inputs used by the Pion tests (same std entities / request as
audit/src/lib.pion) and `check` asserts that the Rust `cedar-policy =4.15.0` oracle answers
with one of the outcomes the corresponding test accepts. If this step fails, a test encodes an
expectation the reference does not share - the audit would contradict itself.
"""
import sys

STD_E = ('[{"uid":{"type":"User","id":"alice"},"attrs":{"name":"alice","nested":{"a":{"b":1}}},'
         '"parents":[{"type":"Group","id":"eng"}]},{"uid":{"type":"Group","id":"eng"},"attrs":{},"parents":[]}]')
STD_R = ('{"principal":{"type":"User","id":"alice"},"action":{"type":"Action","id":"view"},'
         '"resource":{"type":"Doc","id":"d1"},"context":{"n":5,"s":"hello",'
         '"ip":{"__extn":{"fn":"ip","arg":"192.168.1.7"}}}}')
H = "permit(principal, action, resource);\nforbid(principal, action, resource)"
CASES = []  # (test name, policies, entities, request, accepted outcomes)


def dl(n):
    return " || ".join(['principal == User::"u%d"' % i for i in range(n - 1)] + ['principal == User::"alice"'])


def pr(e):
    return "permit(principal, action, resource) when { %s };" % e


def ea(a):
    return '[{"uid":{"type":"User","id":"alice"},"attrs":%s,"parents":[]}]' % a


def c(test, pol, want, ents=STD_E, req=STD_R):
    CASES.append((test, pol, ents, req, want if isinstance(want, tuple) else (want,)))


# ---- redteam_test.pion (accepted outcomes exactly as asserted there)
c("p0_1_forbid_denylist_200", H + " when { " + dl(200) + " };", ("Deny r=1 e=", "PERR"))
c("p0_1_forbid_denylist_129", H + " when { " + dl(129) + " };", ("Deny r=1 e=", "PERR"))
c("p0_1_forbid_add_chain", H + " when { " + " + ".join(["1"] * 129) + " == 129 };", ("Deny r=1 e=", "PERR"))
c("p0_1_forbid_unless_and_chain", H + " unless { " + "".join('principal != User::"u%d" && ' % i for i in range(128))
  + 'principal != User::"alice" };', ("Deny r=1 e=", "PERR"))
c("p0_1_permit_allowlist_200", pr(dl(200)), ("Allow r=0 e=", "PERR"))
c("p0_2_misspelled_method", H + ' when { context.ip.isInRnage(ip("192.168.0.0/16")) };', "PERR")
c("p0_2_unknown_function", H + " when { isBlocked(principal) };", "PERR")
c("p0_2_unknown_methods.a", pr("[1].foo()"), "PERR")
c("p0_2_unknown_methods.b", pr('"a".length() == 1'), "PERR")
c("p0_2_datetime", H + ' when { datetime("2026-01-01") < datetime("2027-01-01") };', ("Deny r=1 e=", "PERR"))
c("p0_2_duration", H + ' when { duration("1h") > duration("30m") };', ("Deny r=1 e=", "PERR"))
budget = ["permit(principal, action, resource);"]
for _ in range(7000):
    budget.append("permit(principal, action, resource) when { context.n == 100"
                  + "".join(" || context.n == %d" % (100 + k) for k in range(1, 33)) + " };")
budget.append("forbid(principal, action, resource) when { context.n == 5 };")
c("p1_1_step_budget", "\n".join(budget) + "\n", "Deny r=7001 e=")
for b in ["User\\u0000x", "user name", "NS::", "1User", "if", 'User::\\"x\\"']:
    c("p1_2_invalid_type:" + b, "permit(principal, action, resource);", "EERR",
      ents='[{"uid":{"type":"%s","id":"y"},"attrs":{},"parents":[]}]' % b)
c("p1_2_invalid_request_type", "permit(principal, action, resource);", "RERR",
  req='{"principal":{"type":"not a type","id":"x"},"action":{"type":"Action","id":"view"},"resource":{"type":"Doc","id":"d1"}}')
COL_E = ('[{"uid":{"type":"User","id":"a\\u0000b"},"attrs":{"admin":true},'
         '"parents":[{"type":"Group","id":"admins"}]}]')
COL_R = ('{"principal":{"type":"User\\u0000a","id":"b"},"action":{"type":"Action","id":"view"},'
         '"resource":{"type":"Doc","id":"d1"},"context":{}}')
c("p1_2_collision.in", 'permit(principal in Group::"admins", action, resource);', "RERR", COL_E, COL_R)
c("p1_2_collision.attr", "permit(principal, action, resource) when { principal.admin };", "RERR", COL_E, COL_R)
POL = "permit(principal, action, resource) when { principal has a && principal.a == 1 };"
for i, e in enumerate([
    ea('{"a":1,"a":2}'), ea('{"a":1.0}'), ea('{"a":1e0}'), ea('{"a":-0}'),
    '[{"uid":{"type":"User","id":"alice"},"parents":[]}]',
    '[{"uid":{"type":"User","id":"alice"},"attrs":{"a":1}}]',
    '[{"uid":{"type":"User","id":"alice"},"uid":{"type":"User","id":"bob"},"attrs":{"a":1},"parents":[]}]',
    '[{"uid":{"type":"User","id":"alice"},"attrs":{"a":1},"parents":[{"type":"User","id":"alice"}]}]',
    '[{"uid":{"type":"G","id":"x"},"attrs":{},"parents":[{"type":"G","id":"y"}]},'
    '{"uid":{"type":"G","id":"y"},"attrs":{},"parents":[{"type":"G","id":"x"}]}]',
]):
    c("p1_3_json_strictness.%d" % i, POL, "EERR", ents=e)
c("p1_3_big_int", pr("principal.a == 9007199254740993"), ("Allow r=0 e=", "EERR"), ents=ea('{"a":9007199254740993}'))
c("p1_4_ip.eq", pr('ip("10.0.0.1/24") == ip("10.0.0.0/24")'), "Deny r= e=")
c("p1_4_ip.neq", pr('ip("192.168.1.77/16") != ip("192.168.0.0/16")'), "Allow r=0 e=")
c("p1_4_ip.contains", pr('[ip("10.0.0.1/24")].contains(ip("10.0.0.0/24"))'), "Deny r= e=")
nested = "true"
for k in range(70):
    nested = "if context.n == %d then false else %s" % (k, nested)
c("p1_5_format_reparse(original meaning)", H + " when { " + nested + " };", "Allow r=0 e=")
for e, w in [("principal has nested.a.b", "Allow r=0 e="), ("!!!!!true", "PERR"), ("-----1 == -1", "PERR"),
             ("!!!!true", "Allow r=0 e="), ("{if: 1} == {if: 1}", "PERR"), ("principal has if", "PERR"),
             ("context.in == 1", "PERR"), ("{__cedar: 1} == {__cedar: 1}", "PERR"),
             ('"x" like "\\u{2a}"', "Allow r=0 e="), ('"abc" like "\\x2a"', "Allow r=0 e="),
             ('ip("::ffff:192.0.2.1").isIpv6()', "Deny r= e=0"), ('ip("::1.2.3.4").isIpv6()', "Deny r= e=0"),
             ('{"if": 1}["if"] == 1', "Allow r=0 e=")]:
    c("p2_probe:" + e, pr(e), w)
c("p2_3_annotation_if", '@if("x") permit(principal, action, resource);', "Allow r=0 e=")
c("p2_3_annotation_in", "@in permit(principal, action, resource);", "Allow r=0 e=")
c("p2_4_action_eq_user", 'permit(principal, action == User::"view", resource);', "PERR")
c("p2_4_action_in_set_user", 'permit(principal, action in [Action::"read", User::"x"], resource);', "PERR")
c("p2_6_dup_id", '@id("a") permit(principal, action, resource);\n@id("a") forbid(principal, action, resource);', "Deny r=1 e=")
c("p2_6_shadow_auto", '@id("policy1") forbid(principal, action, resource);\npermit(principal, action, resource);', "Deny r=0 e=")

# ---- control_test.pion
P = "permit(principal, action, resource);"
c("control_core.deny", "", "Deny r= e=")
c("control_core.forbid", P + "\nforbid(principal, action, resource);", "Deny r=1 e=")
c("control_core.forbid_err", P + "\nforbid(principal, action, resource) when { principal.missing == 1 };", "Allow r=0 e=1")
c("control_core.permit_err", "forbid(principal, action, resource) when { true };\npermit(principal, action, resource) when { principal.missing };", "Deny r=0 e=1")
c("control_core.overflow", P + "\nforbid(principal, action, resource) when { 9223372036854775807 + context.n > 0 };", "Allow r=0 e=1")
for e, w in [
    ('false && (1 + "a" == 2)', "Deny r= e="), ("true || principal.missing", "Allow r=0 e="), ("true || 1", "Allow r=0 e="),
    ("if true then true else principal.missing", "Allow r=0 e="), ("principal has missing && principal.missing == 1", "Deny r= e="),
    ("true && 1", "Deny r= e=0"), ('User::"ghost" in User::"ghost"', "Allow r=0 e="), ('principal in Group::"eng"', "Allow r=0 e="),
    ("principal is Group in 1", "Deny r= e="), ('principal in [Group::"eng", 1]', "Deny r= e=0"), ('User::"ghost" has name', "Deny r= e="),
    ('User::"ghost".getTag("t") == 1', "Deny r= e=0"), ("-9223372036854775808 == -9223372036854775807 - 1", "Allow r=0 e="),
    ("9223372036854775808 == 0", "PERR"), ("-(-9223372036854775808) == 0", "Deny r= e=0"), ("-9223372036854775808 * -1 == 0", "Deny r= e=0"),
    ("--1 == 1", "Allow r=0 e="), ('decimal("-922337203685477.5808").lessThan(decimal("0.0"))', "Allow r=0 e="),
    ('decimal("922337203685477.5808") == decimal("0.0")', "Deny r= e=0"), ('decimal("1.00000") == decimal("1.0")', "Deny r= e=0"),
    ('decimal("1") == decimal("1.0")', "Deny r= e=0"), ('decimal("-0.0") == decimal("0.0")', "Allow r=0 e="),
    ('ip("10.0.0.1").isInRange(ip("10.0.0.0/24"))', "Allow r=0 e="), ('ip("01.2.3.4") == ip("1.2.3.4")', "Deny r= e=0"),
    ('ip("1.2.3.4/01") == ip("1.2.3.4/1")', "Deny r= e=0"), ('ip("1.2.3.4").isInRange(ip("::/0"))', "Deny r= e="),
    ('ip("127.0.0.1/7").isLoopback()', "Deny r= e="), ('"a\\nb" like "a*b"', "Allow r=0 e="), ('"a*" like "a\\*"', "Allow r=0 e="),
    ('"x" like "\\*"', "Deny r= e="), ('"' + "a" * 5000 + '" like "' + "*a" * 60 + '*b"', "Deny r= e="),
]:
    c("control_probe:" + e[:60], pr(e), w)
c("control_format_roundtrip(original)",
  '@id("x\\"y") permit(principal == User::"al\\"ice\\n", action in [Action::"read"], resource is Doc in Folder::"f") '
  'when { context.s like "a\\*b*" && -context.n == -5 } unless { principal has "na me" };', "Deny r= e=")


def main():
    if sys.argv[1] == "emit":
        for i, (_, pol, ents, req, _) in enumerate(CASES):
            print("t%03d\tA\t%s\t%s\t%s" % (i, pol.encode().hex(), ents.encode().hex(), req.encode().hex()))
        return
    lines = open(sys.argv[3], encoding="utf-8").read().split("\n")
    got = {lines[i][3:]: lines[i + 1] for i in range(0, len(lines) - 1, 2)}
    bad = 0
    for i, (name, _, _, _, want) in enumerate(CASES):
        g = got.get("t%03d" % i)
        if g not in want:
            bad += 1
            print("    CONTRADICTION %s: test accepts %s, cedar-policy says %s" % (name, " | ".join(want), g))
    print("  test-expect %d red-team/control expectations re-derived from cedar-policy: %d consistent, %d contradict"
          % (len(CASES), len(CASES) - bad, bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
