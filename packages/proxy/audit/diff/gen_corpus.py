"""Deterministic corpora for the differential oracles (run with python3 -I).

urls.hex     one hex-encoded proxy URL per line (task matrix + cross product of parts; kept
             small because the reference recurses to stack overflow on every unparseable URL)
noproxy.tsv  rules_hex \t host_hex \t port (cross product of NO_PROXY rule sets and targets)
"""
import itertools
import os
import sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

TASK = [
    "http://alice:p%40ss:w0rd@proxy.example:8080", "http://:secret@host:8080", "http://user:@host:8080",
    "http://u:p@evil.com@good.com:8080", "http://u:p@evil.com\\@good.com:8080", "ssh://user:pass@host",
    "ssh://user:@host", "ssh://monoid@station-us:2222?identity=/secret/key#frag", "ftp://bob:hunter2@x",
    "http://u:p%ZZ@h", "http://u:p%0@h", "http://u:p%00@h", "http://u:p%0D@h", "http://u:p%0A@h",
    "http://u:p@h%0A.example", "http://h:0", "http://h:65536", "http://h:99999999999999999999", "http://h:-1",
    "http://[::1", "http://[::1]]:80", "http://[fe80::1%25en0]:80", "http://[1.2.3.4]", "http://[::1]:", "http://:80",
    "http://" + "a" * 300, "http://h:", "alice:hunter2@proxy:3128", "alice:hunter2@proxy:3128/?u=http://x",
    "proxy.example:3128", "http://exa%6dple.com", "http://a\\b", "http://127.1", "http://0x7f.0.0.1:80",
    "HTTP://Proxy.Example.", "socks5h://tok@[2001:DB8::1]:1080", "http://tok@proxy:8080", "https://u:p@h/p?q#f",
]
schemes = ["http", "https", "socks5h", "ssh", "gopher"]
users = ["", "u", "u:", ":p", "u:p", "u%40x:p%3Ay", "u:p@q", "u%3Ap", "%E4%BD%A0:%FF", "u:%25"]
hosts = ["proxy.example", "127.0.0.1", "[::1]", "[2001:db8::1]", "PROXY.EXAMPLE.", "a_b.example", "例子.cn", "a\\b"]
ports = ["", ":8080", ":0", ":08080"]
tails = ["", "/x?y", "?identity=%2Fk%20x"]
urls = list(TASK)
for s, u, h, p, t in itertools.product(schemes, users, hosts, ports, tails):
    urls.append(f"{s}://{u + '@' if u else ''}{h}{p}{t}")
with open(os.path.join(out, "urls.hex"), "w") as f:
    for u in urls:
        f.write(u.encode().hex() + "\n")

rule_sets = [
    "example.com", ".example.com", "*.example.com", "*", "EXAMPLE.COM.", "example.com:443", "10.0.0.0/8",
    "10.0.0.0/33", "192.168.1.5", "::1", "[::1]:8080", "fd00::/8", "2001:db8::/129", "::ffff:10.0.0.1",
    "a.example, ,b.example", "0.0.0.0/0", "::/0", "127.0.0.0/8", "localhost", ".internal:8080", "1.2.3.4:80",
]
targets = [
    "example.com", "EXAMPLE.com.", "a.example.com", "evil-example.com", "example.com.evil", "10.1.2.3",
    "::ffff:10.1.2.3", "[::ffff:10.1.2.3]", "192.168.1.5", "fd00::1", "[fd00::1]", "2001:db8::1", "a.example",
    "b.example", "x.internal", "1.2.3.4", "::ffff:1.2.3.4", "sub.localhost", "github.com",
]
ports_np = [80, 443, 8080]
with open(os.path.join(out, "noproxy.tsv"), "w") as f:
    for r, t, p in itertools.product(rule_sets, targets, ports_np):
        f.write(f"{r.encode().hex()}\t{t.encode().hex()}\t{p}\n")
print(f"urls={len(urls)} noproxy={len(rule_sets) * len(targets) * len(ports_np)}")
