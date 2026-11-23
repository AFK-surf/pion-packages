#!/usr/bin/env python3
"""data: URL red-team cases (one per line, UTF-8). Usage: cases.py OUT_FILE"""
import sys

CASES = [
    # --- comma / fragment / scheme ---
    "data:,", "data:", "data:text/plain", "data:text/plain,a,b,c", "data:,,",
    "data:text/plain#a,b", "data:text/plain,a#b,c", "data:,a#", "data:#,",
    "DATA:,x", "  data:,x  ", "\x01data:,x\x1f", "data :,x", "dat a:,x",
    "data:text/plain,a?b#c", "data:,a b ", "data:,%",  "data:,%2", "data:,%zz", "data:,%2C%2c",
    # --- whitespace / control in header & body ---
    "data:\ttext/plain,x", "data:text/\nplain,x", "data:text/plain\r,x",
    "data:te\txt/plain,x", "data:,a\tb\nc\rd", "data:\x0ctext/plain,x",
    "data:  text/html  ,<b>", "data: ;base64,SGk=",
    # --- ;base64 detection ---
    "data:;base64,SGk=", "data:;BASE64,SGk=", "data:;bAsE64,SGk=",
    "data:text/plain; base64 ,SGk=", "data:text/plain;base64 ,SGk=",
    "data:text/plain; base64,SGk=", "data:text/plain;\tbase64,SGk=",
    "data:text/plain;charset=utf-8;base64,SGk=", "data:text/plain;base64;charset=utf-8,SGk=",
    "data:text/plain;foo=\"a;base64\",abc", "data:text/plain;foo=\"a;base64\";base64,SGk=",
    "data:text/plain;foo=\";base64\",SGk=", "data:text/plainbase64,SGk=", "data:base64,SGk=",
    "data:;base64;base64,SGk=", "data:text/plain;x=base64,SGk=", "data:;base6,SGk=",
    "data:;base64x,SGk=", "data:%3Bbase64,SGk=", "data:;base%364,SGk=",
    # --- forgiving-base64 ---
    "data:;base64,", "data:;base64,S", "data:;base64,SG", "data:;base64,SGk", "data:;base64,SGk=",
    "data:;base64,SGk==", "data:;base64,SGk===", "data:;base64,SG==", "data:;base64,SG=",
    "data:;base64,S===", "data:;base64,====", "data:;base64,=", "data:;base64,SGVs=bG8=",
    "data:;base64,SG=k", "data:;base64,SGVsbG8", "data:;base64,SGVsbG8=", "data:;base64,SGVsbG8==",
    "data:;base64,ab-_", "data:;base64,ab+/", "data:;base64,a b\tc\nd", "data:;base64, SGk= ",
    "data:;base64,SGk%3D", "data:;base64,SGVs%20bG8%3D", "data:;base64,SGVs%0AbG8%3D",
    "data:;base64,%53%47%6b%3d", "data:;base64,SGk%", "data:;base64,SGk%3", "data:;base64,S%Gk=",
    "data:;base64,SGk\xe9", "data:;base64,SGk%E9", "data:;base64,SGk%00", "data:;base64,SG\x0bk=",
    "data:;base64,YQ", "data:;base64,YR", "data:;base64,YWJ", "data:;base64,YWK",
    "data:;base64,SGk=%20", "data:;base64,SGk%3D%3D", "data:;base64,SG%3D%3D",
    "data:;base64,SGk=\x0c", "data:;base64,SGk=?x=1", "data:;base64,SGk=#frag",
    # --- MIME parsing ---
    "data:text/html;charset=UTF-8,x", "data:TEXT/HTML;CHARSET=utf-8,x", "data:text/html;charset=\"utf-8\",x",
    "data:text/html;charset=\"utf\\-8\",x", "data:text/html;charset=\"u;tf\",x",
    "data:text/html;a=1;a=2,x", "data:text/html;;a=1,x", "data:text/html;a,x", "data:text/html;=b,x",
    "data:text/html;a=,x", "data:text/html;a=\"\",x", "data:text/html;a=\"x,y", "data:text/html;a=\"x\"junk,x",
    "data:text/,x", "data:/html,x", "data:text,x", "data:text/html/x,x", "data:t(xt/html,x",
    "data:text/ht ml,x", "data:text/html ;a=b,x", "data:text/html; a = b,x", "data:text/html;a=b c,x",
    "data:text/html;a=\xe9,x", "data:text/html;\xe9=b,x", "data:\xe9/html,x", "data:text/html;a=\"\x01\",x",
    "data:image/svg+xml;utf8,<svg/>", "data:;charset=utf-8,x", "data:;,x", "data:;a=b,x",
    "data:text/plain;charset=utf-8;base64,", "data:application/octet-stream;base64,AAEC",
]

with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as f:
    for c in CASES:
        f.write(c.encode("utf-8").hex() + "\n")
print(len(CASES), "cases")
