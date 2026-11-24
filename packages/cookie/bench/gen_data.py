#!/usr/bin/env python3
"""Generate deterministic Set-Cookie and Mozilla PSL corpora for differential testing and benchmarking."""
import os
import sys

def gen_set_cookie_corpus():
    base = [
        "session_id=abc123; Path=/; HttpOnly; Secure; SameSite=Lax",
        "__Host-csrf=tok_9f8e7d6c; Secure; Path=/; SameSite=Strict",
        "__Secure-auth=eyJhbGciOiJIUzI1NiJ9.payload.sig; Secure; HttpOnly; Max-Age=86400; Path=/api; SameSite=None",
        "chips_id=part_001; Secure; Path=/; SameSite=None; Partitioned",
        "legacy=old_val; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Domain=.Example.COM; Path=/legacy",
        "pref=dark; Max-Age=31536000; Domain=example.co.uk; Path=/; SameSite=Lax",
        "clear_me=; Max-Age=0; Path=/app",
        "expired_neg=gone; Max-Age=-10; Path=/",
        "quoted=\"hello world\"; Path=/; Secure",
        "multi_eq=a=b=c=d; Path=/v1/items; HttpOnly",
        "dup_attr=1; Path=/first; Path=/second; Domain=a.example.com; Domain=.b.example.com; SameSite=Strict; SameSite=None; Secure",
        "case_mix=val; sEcUrE; hTtPoNlY; sAmEsItE=lAx; pArTiTiOnEd; mAx-AgE=600; pAtH=/mix",
        "date_leap=ok; Expires=Thu, 29 Feb 2024 23:59:59 GMT; Path=/",
        "date_2000=ok; Expires=Tue, 29 Feb 2000 12:00:00 GMT; Path=/",
        "date_2038=ok; Expires=Tue, 19 Jan 2038 03:14:07 GMT; Path=/",
        "date_2099=ok; Expires=Thu, 31 Dec 2099 23:59:59 GMT; Path=/",
        "date_epoch=ok; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/",
        "ws_trim=  spaced_value  ;  Path = /trimmed ;  Domain = .Sub.Example.Org ",
        "only_name=value",
        "empty_val=",
    ]
    out = []
    for i in range(10):
        for idx, h in enumerate(base):
            if i == 0:
                out.append(h)
            else:
                # Slight deterministic variation in cookie name/value
                eq = h.find("=")
                out.append(f"c{i}_{idx}_" + h[:eq] + "=" + h[eq+1:])
    return out

def gen_psl_corpus():
    # Official Mozilla test_psl.txt vectors (ASCII + Punycode) + ICANN + Private + Wildcard + Exception + IPs
    domains = [
        # Mixed case
        "COM",
        "example.COM",
        "WwW.example.COM",
        # Leading dot
        ".com",
        ".example",
        ".example.com",
        ".example.example",
        # Unlisted TLD
        "example",
        "example.example",
        "b.example.example",
        "a.b.example.example",
        # 1-rule TLD
        "biz",
        "domain.biz",
        "b.domain.biz",
        "a.b.domain.biz",
        # 2-level rules
        "com",
        "example.com",
        "b.example.com",
        "a.b.example.com",
        "uk.com",
        "example.uk.com",
        "b.example.uk.com",
        "a.b.example.uk.com",
        "test.ac",
        # Wildcard rule (mm)
        "mm",
        "c.mm",
        "b.c.mm",
        "a.b.c.mm",
        # Complex jp
        "jp",
        "test.jp",
        "www.test.jp",
        "ac.jp",
        "test.ac.jp",
        "www.test.ac.jp",
        "kyoto.jp",
        "test.kyoto.jp",
        "ide.kyoto.jp",
        "b.ide.kyoto.jp",
        "a.b.ide.kyoto.jp",
        "c.kobe.jp",
        "b.c.kobe.jp",
        "a.b.c.kobe.jp",
        "city.kobe.jp",
        "www.city.kobe.jp",
        # Wildcard + exception (ck)
        "ck",
        "test.ck",
        "b.test.ck",
        "a.b.test.ck",
        "www.ck",
        "www.www.ck",
        # US K12
        "us",
        "test.us",
        "www.test.us",
        "ak.us",
        "test.ak.us",
        "www.test.ak.us",
        "k12.ak.us",
        "test.k12.ak.us",
        "www.test.k12.ak.us",
        # Punycode IDN from test_psl.txt
        "xn--85x722f.com.cn",
        "xn--85x722f.xn--55qx5d.cn",
        "www.xn--85x722f.xn--55qx5d.cn",
        "shishi.xn--55qx5d.cn",
        "xn--55qx5d.cn",
        "xn--85x722f.xn--fiqs8s",
        "www.xn--85x722f.xn--fiqs8s",
        "shishi.xn--fiqs8s",
        "xn--fiqs8s",
        # Common ICANN & Private suffixes
        "co.uk",
        "bbc.co.uk",
        "news.bbc.co.uk",
        "com.au",
        "abc.com.au",
        "org.uk",
        "example.org.uk",
        "gov.uk",
        "www.gov.uk",
        "github.io",
        "user.github.io",
        "docs.user.github.io",
        "pages.dev",
        "app.pages.dev",
        "sub.app.pages.dev",
        "s3.amazonaws.com",
        "bucket.s3.amazonaws.com",
        "blogspot.com",
        "myblog.blogspot.com",
        "herokuapp.com",
        "myapp.herokuapp.com",
        "vercel.app",
        "demo.vercel.app",
        "netlify.app",
        "site.netlify.app",
        "cloudfront.net",
        "d111111abcdef8.cloudfront.net",
        "googleapis.com",
        "storage.googleapis.com",
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "google.co.jp",
        "mail.google.co.jp",
        "amazon.co.uk",
        "www.amazon.co.uk",
        "127.0.0.1",
        "192.168.1.1",
    ]
    return domains

def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-cookie-bench"
    os.makedirs(out_dir, exist_ok=True)
    sc = gen_set_cookie_corpus()
    with open(os.path.join(out_dir, "set_cookie_corpus.txt"), "w", encoding="utf-8") as f:
        for line in sc:
            f.write(line + "\n")
    psl = gen_psl_corpus()
    with open(os.path.join(out_dir, "psl_corpus.txt"), "w", encoding="utf-8") as f:
        for line in psl:
            f.write(line + "\n")
    print(f"Generated {len(sc)} Set-Cookie cases and {len(psl)} PSL cases in {out_dir}")

if __name__ == "__main__":
    main()
