#!/usr/bin/env python3
"""DoS / XML-security bombs for packages/dash, run under default DashLimits in native --release and wasm32 --release.

dos.py <out_dir> --list-only            write the bombs, list them
dos.py <out_dir> <native_bin> <wasm_cmd> run every bomb (`bomb <file> [max_xml_depth]`), check budgets

Budget per run: exit 0, no panic / trap, wall time <= TIME_S, peak RSS <= RSS_MB, identical summary line in both
modes. A bomb tagged with an open finding id (P0-1, P1-4) that breaks the budget is reported as that finding
(OPENIDS line); every other bomb breaking the budget fails the run.
"""
import os
import re
import shlex
import signal
import subprocess
import sys
import time

TIME_S = float(os.environ.get("DOS_TIME_S", "20"))
RSS_MB = int(os.environ.get("DOS_RSS_MB", "1024"))

MPD0 = '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="%s">'


def rep_tpl(inner, rid="v"):
    return '<AdaptationSet><Representation id="%s" bandwidth="1000">%s</Representation></AdaptationSet>' % (rid, inner)


def doc(body, dur="PT10S", base=""):
    return (MPD0 % dur) + base + "<Period>" + body + "</Period></MPD>"


def bombs():
    b = []
    a = lambda name, desc, data, tag="", depth=0: b.append((name, desc, data if isinstance(data, bytes) else data.encode(), tag, depth))
    a("b01_xxe", "XXE external entity (SYSTEM file:///etc/passwd)",
      '<?xml version="1.0"?><!DOCTYPE MPD [<!ENTITY x SYSTEM "file:///etc/passwd">]><MPD>&x;</MPD>')
    a("b02_billion_laughs", "Billion Laughs, 10 levels x 10",
      "<!DOCTYPE l [" + '<!ENTITY a0 "lol">' + "".join('<!ENTITY a%d "%s">' % (i, ("&a%d;" % (i - 1)) * 10) for i in range(1, 10)) +
      "]><MPD>&a9;</MPD>")
    a("b03_doctype_case", "case-mixed <!DoCtYpE / <!eNtItY in prolog and content", '<!DoCtYpE MPD><MPD><!eNtItY a "b"></MPD>')
    a("b04_deep_10k", "10,000 nested elements", "<MPD>" + "<a>" * 10000 + "</a>" * 10000 + "</MPD>")
    a("b05_deep_1m", "1,000,000 nested elements (7 MB)", "<MPD>" + "<a>" * 1000000 + "</a>" * 1000000 + "</MPD>")
    a("b06_attrs_100k", "100,000 attributes on <MPD>", "<MPD " + " ".join('a%d="1"' % i for i in range(100000)) + "/>")
    a("b07_dup_attr_256", "256 attributes with long shared prefixes (duplicate check O(n^2))",
      "<MPD " + " ".join('%s%d="1"' % ("x" * 2000, i) for i in range(256)) + "/>")
    a("b08_charrefs_16m", "15.9 MB of &#x10FFFF; references in text", "<MPD><Location>" + "&#x10FFFF;" * 1590000 + "</Location></MPD>")
    a("b09_bad_charrefs", "invalid references &#x110000; &#xD800; &#0; &#99999999999;",
      "<MPD><Location>&#x110000;&#xD800;&#0;&#99999999999;</Location></MPD>")
    a("b10_r_999999999", "S@r=999999999", doc(rep_tpl('<SegmentTemplate media="$Number$"><SegmentTimeline><S d="1" r="999999999"/></SegmentTimeline></SegmentTemplate>')))
    a("b11_r_minus1_open", "S@r=-1 in a dynamic MPD without Period duration",
      '<MPD type="dynamic"><Period>' + rep_tpl('<SegmentTemplate media="$Number$"><SegmentTimeline><S t="0" d="1" r="-1"/></SegmentTimeline></SegmentTemplate>') + "</Period></MPD>")
    a("b12_r_minus1_huge", "S@r=-1 up to a 100000-day Period with d=1 (count >> max_segments)",
      doc(rep_tpl('<SegmentTemplate timescale="1000" media="$Number$"><SegmentTimeline><S t="0" d="1" r="-1"/></SegmentTimeline></SegmentTemplate>'), "P100000D"))
    a("b13_r_negative_min", "S@r=-9223372036854775808",
      doc(rep_tpl('<SegmentTemplate media="$Number$"><SegmentTimeline><S d="1" r="-9223372036854775808"/></SegmentTimeline></SegmentTemplate>')))
    a("b14_time_overflow", "S@t + d*(r+1) beyond Int64",
      doc(rep_tpl('<SegmentTemplate media="$Time$"><SegmentTimeline><S t="9223372036854775000" d="100" r="50"/></SegmentTimeline></SegmentTemplate>')))
    a("b15_timescale_overflow", "timescale x Period duration beyond Int64 (duration-based)",
      doc(rep_tpl('<SegmentTemplate timescale="4294967295" duration="1" media="$Number$"/>'), "P100000D"))
    a("b16_width_bomb", "$Number%999999999d$", doc(rep_tpl('<SegmentTemplate duration="1" media="$Number%999999999d$"/>')))
    a("b17_width_32", "$Number%032d$ x 2000 identifiers, 10 segments",
      doc(rep_tpl('<SegmentTemplate duration="1" media="%s"/>' % ("$Number%032d$" * 2000))))
    a("b18_limit_periods", "1,025 Periods", '<MPD type="static">' + "<Period/>" * 1025 + "</MPD>")
    a("b19_limit_elements", "200,001 elements", "<MPD>" + "<x/>" * 200000 + "</MPD>")
    a("b20_limit_input", "16 MiB + 1 byte input", "<MPD>" + " " * (16777217 - 11) + "</MPD>")
    a("b21_limit_text", "1 MiB + 1 byte text node", "<MPD><Location>" + "a" * 1048577 + "</Location></MPD>")
    a("b22_comment_15m", "15 MB comment", "<MPD><!--" + "c" * 15000000 + "--></MPD>")
    a("b23_unterminated", "15 MB unterminated CDATA", "<MPD><![CDATA[" + "c" * 15000000)
    a("b24_segment_urls", "100,000 SegmentURL (max_segments)", doc(rep_tpl("<SegmentList duration=\"1\">" + '<SegmentURL media="s"/>' * 100000 + "</SegmentList>")))
    a("b25_timeline_100k", "99,999 <S> entries, 99,999 segments",
      doc(rep_tpl('<SegmentTemplate media="s$Number$"><SegmentTimeline>' + '<S d="1"/>' * 99999 + "</SegmentTimeline></SegmentTemplate>")))
    a("b26_amp_entities", "1 MB attribute of &amp; (decoded 5x smaller)", '<MPD id="' + "&amp;" * 200000 + '"/>')
    # P0-1: resolve_segments has no aggregate budget
    a("b27_baseurl_x_segments", "P0-1: 40 KB BaseURL x 99,999 timeline segments",
      doc(rep_tpl('<SegmentTemplate media="$Number$"><SegmentTimeline><S d="1" r="99998"/></SegmentTimeline></SegmentTemplate>'),
          base="<BaseURL>http://h/" + "a" * 40000 + "/</BaseURL>"), "P0-1")
    a("b28_media_x_segments", "P0-1: 900 KB media template of $RepresentationID$ (1 KB id) x 100 segments",
      doc(rep_tpl('<SegmentTemplate duration="1" media="%s"/>' % ("$RepresentationID$" * 50000), rid="i" * 1000), dur="PT100S"), "P0-1")
    a("b29_dotdot_cpu", "P0-1: 1 MB BaseURL of '../' x 99,999 segments (resolve_url per segment)",
      doc(rep_tpl('<SegmentTemplate media="s$Number$"><SegmentTimeline><S d="1" r="99998"/></SegmentTimeline></SegmentTemplate>'),
          base="<BaseURL>" + "x/../" * 200000 + "</BaseURL>"), "P0-1")
    # P1-6: per-segment work proportional to |BaseURL| that the output budget does not see (absolute media URLs)
    a("b31_abs_media_cpu", "P1-6: 1 MB BaseURL, absolute media template, 99,999 segments",
      doc(rep_tpl('<SegmentTemplate media="http://c/$Number$"><SegmentTimeline><S d="1" r="99998"/></SegmentTimeline></SegmentTemplate>'),
          base="<BaseURL>http://h/" + "a" * 1000000 + "/</BaseURL>"), "P1-6")
    a("b32_abs_list_cpu", "P1-6: 1 MB BaseURL, 99,999 absolute SegmentURL@media",
      doc(rep_tpl('<SegmentList duration="1">' + '<SegmentURL media="http://c/s"/>' * 99999 + "</SegmentList>"),
          base="<BaseURL>http://h/" + "a" * 1000000 + "/</BaseURL>"), "P1-6")
    # P1-5: namespace prefix lookup is a linear scan over every in-scope binding
    decl = " ".join('xmlns:p%d="urn:x:%d"' % (i, i) for i in range(255))
    leaf = "<a " + " ".join('q:a%d=""' % i for i in range(250)) + "/>"
    a("b33_ns_lookup_cpu", "P1-5: 62 levels x 255 xmlns bindings, 6,000 elements x 250 prefixed attributes (15 MB)",
      "<MPD>" + "".join("<n%d %s>" % (l, decl) for l in range(62)) + leaf * (15000000 // len(leaf)) +
      "".join("</n%d>" % l for l in reversed(range(62))) + "</MPD>", "P1-5")
    # P1-4: raised max_xml_depth
    a("b30_depth_limit_raised", "P1-4: 20,000 nested elements with max_xml_depth=1,000,000",
      "<MPD>" + "<a>" * 20000 + "</a>" * 20000 + "</MPD>", "P1-4", 1000000)
    return b


def run(cmd, path, depth):
    args = shlex.split(cmd) + ["bomb", path] + ([str(depth)] if depth else [])
    if sys.platform == "darwin":
        full = ["/usr/bin/time", "-l"] + args
    else:
        full = ["/usr/bin/time", "-v"] + args
    t0 = time.time()
    # own process group, so that a timeout kills the measured process too (not only /usr/bin/time)
    p = subprocess.Popen(full, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        so, se = p.communicate(timeout=TIME_S)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return ("TIMEOUT", time.time() - t0, 0, "")
    dt = time.time() - t0
    err = se.decode("utf-8", "replace")
    rss = 0
    m = re.search(r"(\d+)\s+maximum resident set size", err)
    if m:
        rss = int(m.group(1)) // (1 << 20)
    m = re.search(r"Maximum resident set size \(kbytes\): (\d+)", err)
    if m:
        rss = int(m.group(1)) // 1024
    out = so.decode("utf-8", "replace").strip()
    if p.returncode != 0 or not out:
        why = "exit %d" % p.returncode
        for l in err.splitlines():
            if "panic" in l or "RangeError" in l or "out of memory" in l or "Segmentation" in l:
                why += " " + l.strip()[:80]
                break
        return ("CRASH " + why, dt, rss, out)
    return ("OK", dt, rss, out)


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    bs = bombs()
    for name, desc, data, tag, depth in bs:
        p = os.path.join(out, name + ".mpd")
        if not os.path.exists(p) or os.path.getsize(p) != len(data):
            open(p, "wb").write(data)
    if "--list-only" in sys.argv:
        print("  dos: %d bombs (%s)" % (len(bs), ", ".join(n for n, _, _, _, _ in bs)))
        return 0
    native, wasm = sys.argv[2], sys.argv[3]
    bad = 0
    open_ids = set()
    print("  %-24s %-6s %9s %8s  %-9s %8s %8s  %s" % ("bomb", "size", "native s", "RSS MB", "wasm32 s", "RSS MB", "result", "summary"))
    for name, desc, data, tag, depth in bs:
        p = os.path.join(out, name + ".mpd")
        rn = run(native, p, depth)
        rw = run(wasm, p, depth)
        fails = []
        for mode, r in (("native", rn), ("wasm32", rw)):
            if r[0] != "OK":
                fails.append("%s %s" % (mode, r[0]))
            elif r[1] > TIME_S:
                fails.append("%s %.1fs > %.0fs" % (mode, r[1], TIME_S))
            elif r[2] > RSS_MB:
                fails.append("%s RSS %d MB > %d MB" % (mode, r[2], RSS_MB))
        if not fails and rn[3] != rw[3]:
            fails.append("native / wasm32 summaries differ")
        res = "ok" if not fails else ("OPEN " + tag if tag else "FAIL")
        if fails and tag:
            open_ids.add(tag)
        elif fails:
            bad += 1
        sz = len(data)
        szs = "%dM" % (sz >> 20) if sz >= 1 << 20 else "%dK" % (sz >> 10) if sz >= 1024 else "%dB" % sz
        print("  %-24s %-6s %9.2f %8d  %-9.2f %8d %8s  %s" % (name, szs, rn[1], rn[2], rw[1], rw[2], res,
                                                           (rn[3] if rn[0] == "OK" else rn[0])[:90]))
        if fails:
            print("  %24s %s -- %s" % ("", desc, "; ".join(fails)[:160]))
    print("OPENIDS " + " ".join(sorted(open_ids)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
