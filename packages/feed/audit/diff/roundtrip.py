#!/usr/bin/env python3
"""Serialization safety + roundtrip fidelity: parse -> to_rss2 / to_atom / to_json_feed -> validate -> reparse.

usage: roundtrip.py <out_dir> <pion_probe> <rust_oracle>
Graded (exit 1 on any): output well-formed (expat / strict JSON), RFC 4287 §4.1.3.1 for out-of-line content,
serializer errors only for inputs that contain characters XML 1.0 cannot carry, Pion reparse succeeds and keeps
feed title, entry count, entry ids/titles/summaries/contents and category terms.
feed-rs reparse of every output is reported (informational).
"""
import json
import os
import re
import sys
import xml.parsers.expat

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runner import run_batch, write_requests  # noqa: E402
from vectors import V  # noqa: E402

OPS = {"R2": "to_rss2", "RA": "to_atom", "RJ": "to_json_feed"}


def nasty_json():
    vals = {
        "cdata_end": "a]]>b", "script": "<script>alert(1)</script>&\"'", "crlf": "line1\r\nline2\rline3",
        "u2028": "a b c", "astral": "\U0001F600 é", "backslash": "a\\b\"c", "ctrl_0b": "a\u000bb",
        "nul": "a\u0000b", "entities": "&amp; &lt; &#x26; &#38;", "ws_inner": "a \t b",
    }
    out = []
    for k, v in vals.items():
        doc = {"version": "https://jsonfeed.org/version/1.1", "title": v, "home_page_url": "http://x/?a=1&b=" + v,
               "feed_url": "http://x/feed.json", "description": v,
               "items": [{"id": "id-" + v, "url": "http://x/" + v, "title": v, "content_html": v, "summary": v, "tags": [v, "t2"],
                          "authors": [{"name": v, "url": "http://x/"}],
                          "attachments": [{"url": "http://x/a.mp3", "mime_type": "audio/mpeg", "size_in_bytes": 1234}]}]}
        out.append(("rt_json_" + k, json.dumps(doc)))
    return out


def rich_docs():
    atom = ('<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en" xml:base="http://ex.com/"><id>urn:f</id>'
            '<title type="html">A &amp;lt;b&amp;gt;</title><subtitle>S</subtitle><updated>2026-11-23T12:00:00Z</updated>'
            '<author><name>Ed</name><email>ed@x.com</email></author><link rel="self" href="atom.xml"/><link rel="alternate" href="/"/>'
            '<category term="c1" scheme="http://s/" label="L"/><generator uri="http://g/" version="1">G</generator>'
            '<entry><id>urn:e1</id><title>E1</title><updated>2026-11-23T12:00:00Z</updated><published>2026-11-22T12:00:00+02:00</published>'
            '<link rel="alternate" href="e1.html"/><link rel="enclosure" type="audio/mpeg" href="e1.mp3" length="99"/>'
            '<summary type="html">&lt;p&gt;S1&lt;/p&gt;</summary><content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>C1 <b>x</b></p></div></content>'
            '<category term="t1"/></entry>'
            '<entry><id>urn:e2</id><title type="text">E2 &lt;not html&gt;</title><updated>2026-11-23T12:00:00Z</updated>'
            '<content type="image/png" src="e2.png"/></entry></feed>')
    rss = ('<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/">'
           '<channel><title>R &amp; T</title><link>http://ex.com/</link><description>&lt;b&gt;D&lt;/b&gt;</description>'
           '<managingEditor>ed@x.com (Ed)</managingEditor><pubDate>Mon, 23 Nov 2026 12:00:00 GMT</pubDate><ttl>60</ttl>'
           '<image><url>http://ex.com/l.png</url><title>R</title><link>http://ex.com/</link></image>'
           '<item><title>I1</title><link>http://ex.com/1</link><guid isPermaLink="false">g1</guid><description>&lt;p&gt;S&lt;/p&gt;</description>'
           '<content:encoded><![CDATA[<p>Body ]]]]><![CDATA[> &amp;</p>]]></content:encoded><dc:creator>Alice</dc:creator>'
           '<author>bob@x.com (Bob)</author><category domain="http://d/">c</category>'
           '<enclosure url="http://ex.com/1.mp3" length="10" type="audio/mpeg"/><pubDate>Mon, 23 Nov 2026 12:00:00 GMT</pubDate></item>'
           '<item><title>I2</title><guid>http://ex.com/2</guid></item></channel></rss>')
    return [("rt_atom_rich", atom), ("rt_rss_rich", rss)]


def expat_ok(s):
    p = xml.parsers.expat.ParserCreate(namespace_separator=" ")
    try:
        p.Parse(s, True)
        return None
    except xml.parsers.expat.ExpatError as e:
        return str(e)


def json_ok(s):
    def hook(pairs):
        keys = [k for k, _ in pairs]
        if len(keys) != len(set(keys)):
            raise ValueError("duplicate key")
        return dict(pairs)
    try:
        d = json.loads(s, object_pairs_hook=hook)
    except ValueError as e:
        return str(e)
    if not isinstance(d.get("version"), str) or not isinstance(d.get("items"), list) or not isinstance(d.get("title"), str):
        return "missing version/title/items"
    for it in d["items"]:
        if not isinstance(it.get("id"), str):
            return "item id not a string"
    return None


CONTENT_TAG = re.compile(r"<content\b[^>]*>")


def atom_src_rule(s):
    for m in CONTENT_TAG.finditer(s):
        t = m.group(0)
        if " src=" in t:
            ty = re.search(r'\btype="([^"]*)"', t)
            if ty and ty.group(1) in ("text", "html", "xhtml"):
                return "RFC 4287 4.1.3.1: %s" % t
    return None


def sem(d):
    keys = ["feed.title", "n"]
    n = int(d.get("n", "0"))
    for i in range(n):
        for k in ("title", "summary", "content"):
            keys.append("e%d.%s" % (i, k))
        if d.get("e%d.id" % i):
            keys.append("e%d.id" % i)
        for j in range(int(d.get("e%d.cat.n" % i, "0"))):
            keys.append(("e%d.cat.%d" % (i, j)))
    return keys


def cat_term(v):
    return v.split("|")[0]


def main():
    out, probe, oracle = sys.argv[1:4]
    os.makedirs(out, exist_ok=True)
    docs = [(vid, data) for vid, tag, data, _ in V if tag != "info"] + nasty_json() + rich_docs()
    req = os.path.join(out, "rt_parse.tsv")
    write_requests(req, [(d, "P", x) for d, x in docs])
    _, orig, _, _ = run_batch([probe], req)
    docs = [(d, x) for d, x in docs if "err" not in orig.get(d, {"err": 1})]
    req = os.path.join(out, "rt_ser.tsv")
    write_requests(req, [("%s~%s" % (d, op), op, x) for d, x in docs for op in OPS])
    _, ser, _, _ = run_batch([probe], req)
    outputs = {}
    fails, info, refused = [], [], 0
    for d, x in docs:
        has_illegal = any("\\x" in v for v in orig[d].values())
        for op in OPS:
            b = ser.get("%s~%s" % (d, op), {})
            if "ser_err" in b:
                if op != "RJ" and has_illegal:
                    refused += 1
                else:
                    fails.append((d, op, "serializer error %s" % b["ser_err"]))
                continue
            s = bytes.fromhex(b.get("ser", "")).decode("utf-8")
            err = json_ok(s) if op == "RJ" else (expat_ok(s) or (atom_src_rule(s) if op == "RA" else None))
            if err:
                fails.append((d, op, "invalid output: " + err))
                continue
            outputs["%s~%s" % (d, op)] = (d, s)
    req = os.path.join(out, "rt_reparse.tsv")
    write_requests(req, [(k, "P", s) for k, (_, s) in outputs.items()])
    _, rp, _, _ = run_batch([probe], req)
    _, ro, _, _ = run_batch([oracle], req)
    for k, (d, _) in outputs.items():
        a, b = orig[d], rp.get(k, {})
        if "err" in b:
            fails.append((d, k.split("~")[1], "Pion cannot reparse its own output: %s" % b["err"]))
            continue
        for key in sem(a):
            av, bv = a.get(key, "-"), b.get(key, "-")
            if ".cat." in key:
                av, bv = cat_term(av), cat_term(bv)
            if key.endswith("title"):
                # serializers must write a (possibly empty) title element where none was parsed
                av, bv = ("" if av == "-" else av), ("" if bv == "-" else bv)
            if av != bv:
                fails.append((d, k.split("~")[1], "%s: %r -> %r" % (key, av, bv)))
        if "err" in ro.get(k, {}):
            info.append((d, k.split("~")[1], "feed-rs rejects the output: %s" % ro[k]["err"]))
    print("documents: %d, serializations: %d (+%d refused for illegal XML chars), Pion reparse: %d"
          % (len(docs), len(outputs), refused, len(outputs)))
    print("graded failures: %d" % len(fails))
    for f in fails:
        print("  FAIL %-34s %s  %s" % f)
    print("feed-rs reparse problems (informational): %d" % len(info))
    for f in info:
        print("  info %-34s %s  %s" % f)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
