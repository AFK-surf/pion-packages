#!/usr/bin/env python3
"""Deterministic corpus generator for `packages/idna` differential oracle & head-to-head benchmarks."""

import os
import sys


def build_diff_corpus():
    # 240+ diverse domains across `url` and `strict_hyphens` modes covering:
    # pure ASCII, case folding, fullwidth, dots, NFC/NFD, deviations, STD3, hyphens,
    # Bidi, ContextJ, Punycode valid/invalid/overflow/not-NFC/dot-injection, DNS length,
    # CJK, Japanese, Korean, Thai, Arabic, Hebrew, Cyrillic, Greek, Emoji.
    base_domains = [
        "example.com",
        "EXAMPLE.COM",
        "sub.domain.example.co.uk",
        "a-b.c-d.com",
        "123.456.example.org",
        "example.com.",
        "münchen.de",
        "MÜNCHEN.DE",
        "xn--mnchen-3ya.de",
        "XN--MNCHEN-3YA.DE",
        "café.fr",
        "cafe\u0301.fr",
        "CAFE\u0301.FR",
        "xn--caf-dma.fr",
        "faß.de",
        "FAẞ.DE",
        "xn--fa-hia.de",
        "βόλος.com",
        "ΒΌΛΟΣ.COM",
        "xn--nxasmm1c.com",
        "中文.com",
        "xn--fiq228c.com",
        "日本語.jp",
        "xn--wgv71a119e.jp",
        "한국어.kr",
        "xn--3e0bk47br7k.kr",
        "www.ร้าน.ไทย",
        "www.xn--q3ct9b5e.xn--o3cw4h",
        "привет.рф",
        "xn--b1agh1afp.xn--p1ai",
        "مثال.إختبار",
        "xn--mgbh0fb.xn--kgbechtv",
        "שלום.ישראל",
        "ＥＸＡＭＰＬＥ。ＣＯＭ",
        "a\uFF0Eb\u3002c\uFF61com",
        "foo\u3002bar\u3002jp",
        "l\u00B7l.cat",
        "a\u00B7a.cat",
        "\u0375\u03B1.gr",
        "\u05D0\u05F3.il",
        "ア\u30FBイ.jp",
        "3年B組金八先生.jp",
        "Pročprostěnemluvíčesky.cz",
        "почемужеонинеговорятпорусски.ru",
        "他们为什么不说中文.cn",
        "他們爲什麽不說中文.tw",
        "세계의모든사람들이한국어를이해한다면얼마나좋을까.kr",
        "🚀.ws",
        "xn--158h.ws",
        "i❤.ws",
        "p\u0430ypal.com",
        "\u0430\u0440\u0440\u04CF\u0435.com",
        "g\u03BF\u03BFgle.com",
        # STD3 & Hyphens & DNS length
        "_dmarc.example.com",
        "foo_bar.example.com",
        "-leading.com",
        "trailing-.com",
        "ab--cd.com",
        "a--b.com",
        "a..b.com",
        ".leadingdot.com",
        "a" * 63 + ".com",
        "a" * 64 + ".com",
        ("a" * 61 + ".") * 4 + "com",
        ("a" * 63 + ".") * 4 + "com",
        # Bidi valid & invalid
        "אa.com",
        "aא.com",
        "مثال1٠.com",
        "مثال123.com",
        "مثال\u0660\u0661.com",
        "א\u05B0.il",
        # ContextJ valid & invalid
        "a\u200Cb.com",
        "a\u200Db.com",
        "\u0915\u094D\u200C\u0937.com",
        "\u0915\u094D\u200D\u0937.com",
        "\u0628\u200C\u0628.com",
        # Combining marks & normalization
        "\u0300a.com",
        "a\u0300\u0323.com",
        "a\u0323\u0300.com",
        "\u212B.org",  # Angstrom sign -> å
        "\u00C5.org",
        "o\u0308sterreich.at",
        "bücher.example",
        "straße.de",
        "mañana.es",
        "naïve.fr",
        "résumé.eu",
        "über.ch",
        "åland.ax",
        "øresund.dk",
        "łódź.pl",
        "český.cz",
        "türkiye.tr",
        "việt-nam.vn",
        "ελλάδα.gr",
        "россия.рф",
        "україна.укр",
        "қазақстан.қаз",
        "սիրելի.հայ",
        "საქართველო.გე",
        "বাংলা.বাংলা",
        "भारत.भारत",
        "தமிழ்.இந்தியா",
        "తెలుగు.భారత్",
        "മലയാളം.ഭാരതം",
        "සිංහල.ලංකා",
        "မြန်မာ.com",
        "ខ្មែរ.kh",
        "ລາວ.la",
        "བོད་ཡིག.com",
        "ኢትዮጵያ.et",
        "ᏣᎳᎩ.com",
        # Punycode edge cases
        "xn--",
        "xn--abc-.com",
        "xn--zzzz.com",
        "xn--99999999999999a.com",
        "xn--e-lfa.com",  # NFD e + combining acute
        "xn--a-815a.com",
        "xn--mnchen-3ya.xn--fiq228c.xn--wgv71a119e",
        "xn--nxasmq6b.com",
        "xn--bcher-kva.example",
        "xn--strae-oqa.de",
        # Ignored / soft hyphen / mapped
        "ex\u00ADample.com",
        "foo\u200Bbar.com",
        "a\u00A0b.com",
        "foo bar.com",
        "foo/bar.com",
        "foo@bar.com",
        "foo:bar.com",
    ]
    rows = []
    for mode in ("url", "strict_hyphens"):
        for d in base_domains:
            rows.append(f"{mode}\t{d}")
    return rows


def build_bench_mixed():
    # 200 diverse multilingual IDNs (no invalid domains that error early — realistic full IDN workload)
    seeds = [
        "münchen.de",
        "MÜNCHEN.DE",
        "xn--mnchen-3ya.de",
        "café.fr",
        "cafe\u0301.fr",
        "faß.de",
        "βόλος.com",
        "中文.com",
        "xn--fiq228c.com",
        "日本語.jp",
        "한국어.kr",
        "www.ร้าน.ไทย",
        "привет.рф",
        "مثال.إختبار",
        "שלום.ישראל",
        "bücher.example",
        "straße.de",
        "mañana.es",
        "naïve.fr",
        "résumé.eu",
        "über.ch",
        "åland.ax",
        "øresund.dk",
        "łódź.pl",
        "český.cz",
        "türkiye.tr",
        "việt-nam.vn",
        "ελλάδα.gr",
        "россия.рф",
        "україна.укр",
        "3年b組金八先生.jp",
        "o\u0308sterreich.at",
        "a\u0300\u0323.example.com",
        "www.xn--wgv71a119e.jp",
        "api.xn--3e0bk47br7k.kr",
        "cdn.xn--b1agh1afp.xn--p1ai",
        "ＥＸＡＭＰＬＥ。ＣＯＭ",
        "shop.bücher.de",
        "mail.café-paris.fr",
        "news.日本語ニュース.jp",
    ]
    out = []
    for i in range(5):
        for s in seeds:
            out.append(s)
    return out


def build_bench_realworld():
    # 200 realistic browser traffic domains (~70% ASCII, ~30% IDN / Punycode)
    ascii_seeds = [
        "www.google.com",
        "github.com",
        "API.GitHub.COM",
        "cdn-1.cloudflare.net",
        "static.wikipedia.org",
        "news.ycombinator.com",
        "docs.rust-lang.org",
        "developer.mozilla.org",
        "mail.proton.me",
        "assets.example-cdn.co.uk",
        "edge-us-east-1.fastly.net",
        "login.microsoftonline.com",
        "fonts.googleapis.com",
        "s3.us-west-2.amazonaws.com",
    ]
    idn_seeds = [
        "münchen.de",
        "中文.com",
        "日本語.jp",
        "한국어.kr",
        "xn--mnchen-3ya.de",
        "café.fr",
    ]
    out = []
    for _ in range(10):
        out.extend(ascii_seeds)
        out.extend(idn_seeds)
    return out


def main():
    if len(sys.argv) != 2:
        print("usage: gen_corpus.py <out_dir>", file=sys.stderr)
        sys.exit(1)
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)

    diff_rows = build_diff_corpus()
    with open(os.path.join(out_dir, "diff_corpus.tsv"), "w", encoding="utf-8") as f:
        for r in diff_rows:
            f.write(r + "\n")

    mixed = build_bench_mixed()
    with open(os.path.join(out_dir, "bench_mixed.txt"), "w", encoding="utf-8") as f:
        for d in mixed:
            f.write(d + "\n")

    realworld = build_bench_realworld()
    with open(os.path.join(out_dir, "bench_realworld.txt"), "w", encoding="utf-8") as f:
        for d in realworld:
            f.write(d + "\n")

    print(f"diff={len(diff_rows)} mixed={len(mixed)} realworld={len(realworld)}")


if __name__ == "__main__":
    main()
