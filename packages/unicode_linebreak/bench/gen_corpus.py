#!/usr/bin/env python3
"""Deterministic corpus generator for unicode_linebreak differential oracle & benchmarks.

Generates:
  - diff_corpus.tsv: 120+ diverse UAX #14 cases matching Rust `icu_segmenter 2.4.0`
    byte-for-byte (ASCII, CJK, Japanese kinsoku, Korean Hangul, German, Russian,
    Arabic, Hebrew, Hindi/Devanagari, Balinese/Kawi Brahmic LB28a, Emoji ZWJ /
    skin-tone / RI flags, LB15a/LB15b guillemets, LB21/LB21a/LB21b, LB25 numbers /
    currencies / parentheses / fractions, URLs, code, hard breaks CR/LF/CRLF/NL/BK,
    ZW/SP/GL/WJ/CM).
    Note: Unicode 16.0.0-specific rules where `icu_segmenter 2.4.0` diverges (LB15c,
    LB19a around CJK, LB20a word-initial hyphen, LB25 non-numeric `$(`/`)$`) are
    exhaustively verified separately against all 16,672 vectors of official Unicode
    16.0.0 `LineBreakTest.txt`.
  - bench_multilingual.txt: Corpus 1 — Multilingual web/news layout text
    (CJK / Japanese / Korean / English / German / Russian / Arabic / Hindi /
    Emoji / URLs / inline code).
  - bench_spec_dense.txt: Corpus 2 — Long technical specification document with
    dense numbers, currencies, punctuation, quotes, parentheses, and hyphens.
"""

import os
import sys


def escape_tsv(s: str) -> str:
    return (
        s.replace("\\", "\\\\")
        .replace("\r", "\\r")
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )


def build_diff_cases():
    cases = [
        # Basic ASCII & mandatory breaks
        "hello world",
        "hello   world",
        "a\nb\nc",
        "a\r\nb\r\nc",
        "a\rb\rc",
        "a\u0085b\u000Cb\u000Bb",
        "leading space",
        "trailing space ",
        "   ",
        "a",
        # CJK & Japanese kinsoku
        "中文排版测试。这是第一句，「引号」里面有内容！",
        "日本語のテキスト折り返しテスト（括弧）、句読点。あっ！",
        "한국어 줄바꿈 테스트입니다. 가나다라마바사!",
        "中文English混合123.45元/kg",
        "「中文」『测试』【标题】《书名》",
        # ZW, SP, GL, WJ, combining marks
        "alpha\u200Bbeta\u200B  gamma",
        "word\u2060joiner\u2060test",
        "non\u00A0breaking\u00A0space test",
        "cafe\u0301 na\u0308ive re\u0301sume\u0301",
        "a\u0301\u0302\u0303 b\u0308",
        # Emoji ZWJ, skin tones, RI flags
        "\U0001F469\u200D\U0001F4BB \U0001F468\u200D\U0001F469\u200D\U0001F467\u200D\U0001F466",
        "\U0001F466\U0001F3FB \U0001F44D\U0001F3FD \U0001F777\U0001F3FB",
        "\U0001F1FA\U0001F1F8\U0001F1EF\U0001F1F5\U0001F1EC\U0001F1E7\U0001F1EB\U0001F1F7",
        "\U0001F1FA\U0001F1F8\U0001F1EF",
        # Quotes LB15a, LB15b, LB19
        "\u00AB bonjour \u00BB dit-il",
        "\"hello\" 'world' \u201Csmart\u201D \u2018single\u2019",
        "a\"b\"c",
        "\u00AB a",
        "a \u00BB b",
        # Decimal & IS
        "e.g. i.e. a,b;c:d",
        "version 16.0.0-alpha.1",
        # Hyphens & Hebrew (LB21/LB21a/LB21b)
        "well-known state-of-the-art co\u2010operate",
        "\u05D0-a \u05D0-b \u05D0/\u05D1",
        "a\u2014b\u2014\u2014c",
        # LB25 numbers, currencies, parentheses, fractions
        "$1,234.56 €99.95 ¥10,000 £42.00",
        "$(123)% $(.5) +(100) -(42.5) 100%",
        "1/2 3/4 2026-11-24 12:34:56",
        "(1,000) [2,000] {3,000}",
        # LB28a Brahmic orthographic syllables
        "\U00011F02\u1B05 \u1B05\u1B44\u1B05 \u1B05\u1B05\u1BF2 \u25CC\u1B44\u25CC",
        "हिन्दी भाषा में पंक्ति विच्छेद परीक्षण।",
        # Arabic, Russian, German, Greek
        "مرحبا بالعالم! هذا اختبار لتقسيم الأسطر في اللغة العربية.",
        "Привет, мир! Проверка переноса строк в русском тексте.",
        "Donaudampfschifffahrtsgesellschaft — Straße & Größe (100%).",
        "Γειά σου κόσμε! Δοκιμή αλλαγής γραμμής.",
        # URLs, paths, code
        "https://example.com/api/v2/users?page=1&limit=50#section-3",
        "fn line_breaks(s: &str) => Vec<(usize, BreakKind)> { vec![] }",
        "foo_bar_baz::qux(1, 2, 3) + arr[i] * 42",
        # Punctuation combinations
        "wait... what?! really!! (yes) [no]",
        "a / b / c; d, e: f.",
        "prefix$100 100$postfix",
    ]
    # Structured pair matrix over common UAX #14 classes
    tokens = [
        "A", "1", "中", " ", "\u00A0", "(", "\"", "\u00AB", "\u00BB",
        "!", "?", "\u05D0", "\U0001F1FA",
    ]
    for i in range(len(tokens)):
        row = ""
        for j in range(len(tokens)):
            row += tokens[i] + tokens[j] + " "
        cases.append(row.strip())
    # Add 60 realistic multilingual / technical sentences
    extra = [
        "The quick brown fox jumps over the lazy dog 12345 times.",
        "Pack my box with five dozen liquor jugs; $99.99 (tax included).",
        "你好世界！欢迎使用纯 Pion 实现的 Unicode 16.0.0 文本断行算法。",
        "東京・大阪・名古屋の新幹線（のぞみ号）は毎日運行しています。",
        "서울특별시 강남구 테헤란로 123번길 45-6 (우편번호 06134).",
        "GET /v1/items?limit=100&offset=0 HTTP-1.1\r\nHost: api.example.com\r\n\r\n",
        "Content-Type: text/html; charset=utf-8\r\nCache-Control: max-age=3600\r\n",
        "ratio=16/9, fps=60, bitrate=12,500kbps, latency=0.45ms.",
        "alpha\u200Bbeta\u200Bgamma\u200Bdelta\u200Bepsilon",
        "U+0020 U+00A0 U+200B U+2060 U+FEFF U+1F469\u200D\U0001F4BB",
    ]
    for idx in range(6):
        for s in extra:
            cases.append(f"[{idx}] {s}")
    return cases


def build_multilingual_corpus() -> str:
    paragraphs = [
        "Unicode 16.0.0 UAX #14 defines the standard Line Breaking Algorithm for modern browser layout engines like Farview and cross-platform GPU UI frameworks such as Invar.\n",
        "中文新闻排版示例：2026年11月24日，新一代纯 Pion 零依赖 Unicode 16.0.0 文本断行引擎正式发布！「避头尾标点」、中英混排（如 HTTP-2、Wasm32、UTF-8）与数字货币 $1,234.56 均严格遵循标准。\n",
        "日本語のレイアウト検証：改行禁則処理（「」、。、・、っ、ゃ、ゅ、ょ）および欧文混在テキスト https://www.unicode.org/reports/tr14/ の折り返し位置を正確に決定します。\n",
        "한국어 문단 테스트: 유니코드 16.0.0 줄바꿈 알고리즘은 한글 음절(가나다라마바사), 문장부호, 숫자(99.9%) 및 이모지 \U0001F469\u200D\U0001F4BB \U0001F1FA\U0001F1F8\U0001F1EF\U0001F1F5 를 정확하게 처리합니다.\n",
        "Deutsch & Русский: Übermäßige Zeilenumbrüche vermeiden — «цитата» в русском тексте (100% точность) und Straße/Größe mit Bindestrich-Wörtern wie State-of-the-Art.\n",
        "العربية والهندية: مرحبا بالعالم في محرك تخطيط النصوص، مع دعم हिन्दी देवनागरी और क्\u200Dष संयोजन तथा URLs https://example.org/docs/uax14?rev=53#LB25.\n",
        "Inline code & telemetry: `line_breaks_with_limits(input, LineBreakLimits::new(16777216, 16777216))` => `Ok(Array[BreakOpportunity])` at 0.00ms latency, emoji \U0001F466\U0001F3FB & \U0001F680!\n",
    ]
    block = "\n".join(paragraphs)
    # ~42 KB corpus
    return (block + "\n") * 28


def build_spec_dense_corpus() -> str:
    lines = [
        "Section 5.1 (LB25): $1,234,567.89 + €42.50 + £(19.95)% = ¥12,345; ratio 3/4, delta 0.005, range [0.00..100.00].\n",
        "Rule LB15a/LB15b/LB19: \u00AB initial quote \u00BB, \"quoted-term\", 'single', (a+b)/(c-d), e.g., i.e., v16.0.0-rc.1.\n",
        "Hyphens & dashes (LB21/LB21a): flag=1 max-bytes=65536 co\u2010operative \u05D0-test a\u2014\u2014b non\u00A0breaking\u2060joiner.\n",
        "Table 4.2: [OP/CL/CP/IS/SY/EX/NS/IN] (100%) => {0x0020, 0x002D, 0x002E, 0x002F, 0x2010, 0x2014, 0x25CC}...\n",
        "Metrics: p50=1.23ms, p95=1.45ms, p99=1.89ms, throughput=125.4MB/s, rss=2.4MiB, sha256=deadbeef01234567.\n",
    ]
    block = "".join(lines)
    # ~44 KB corpus
    return block * 80


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: gen_corpus.py <out_dir>", file=sys.stderr)
        return 2
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)

    diff_cases = build_diff_cases()
    with open(os.path.join(out_dir, "diff_corpus.tsv"), "w", encoding="utf-8") as f:
        for c in diff_cases:
            f.write(escape_tsv(c) + "\n")

    c1 = build_multilingual_corpus()
    with open(os.path.join(out_dir, "bench_multilingual.txt"), "w", encoding="utf-8") as f:
        f.write(c1)

    c2 = build_spec_dense_corpus()
    with open(os.path.join(out_dir, "bench_spec_dense.txt"), "w", encoding="utf-8") as f:
        f.write(c2)

    print(
        f"Generated diff_corpus.tsv ({len(diff_cases)} cases), "
        f"bench_multilingual.txt ({len(c1.encode('utf-8'))} B), "
        f"bench_spec_dense.txt ({len(c2.encode('utf-8'))} B)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
