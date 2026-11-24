#!/usr/bin/env python3
"""Deterministic differential & benchmark corpus generator for packages/unicode_segment."""

import os
import sys

DIFF_CASES = [
    "Hello, world! Don't stop at 3.14 or 1,000.50.",
    "Dr. Smith paid $3.14! He said \"Hi.\" Next? Last.",
    "U.S.A. is big. See e.g. this example. Now!",
    "e\u0301\u0308 a\u0300\u0327 o\u0302\u0323",
    "\u1100\u1161\u11A8 \uAC00\u11A8 한글 테스트입니다.",
    "\u0915\u094D\u0937 \u0915\u093C\u094D\u0937 \u0915\u094D\u0924\u094D\u0930 नमस्ते दुनिया।",
    "\U0001F468\u200D\U0001F469\u200D\U0001F467\u200D\U0001F466 \U0001F469\U0001F3FD\u200D\U0001F680",
    "\U0001F1E8\U0001F1F3\U0001F1FA\U0001F1F8 \U0001F1E6\U0001F1E7\U0001F1E8",
    "你好，世界！这是中文分词与分句测试。第二句在这里？第三句！",
    "日本語のテスト：カタカナとひらがな、漢字123。次の文です！",
    "Ελληνικά αθήνα. Русский привет мир! العربية مرحبا بكم 2026.",
    "\u05D0' \u05D0\"\u05D1 \u05E9\u05DC\u05D5\u05DD עולם!",
    "snake_case_var123 foo_bar 42_000 foo's bar's",
    "multiple   spaces\tand\ttabs  here.",
    "a\u200D\U0001F468 \U0001F44D\U0001F3FB \u2764\uFE0F\u200D\U0001F525",
    "Version 16.0.0 released on 2026-11-24. See https://example.com/v1.2/docs.",
    "\"Wait...\" she whispered. \"Really?!\" (Yes!)",
    "a:b c;d e-f g/h i@j k#l m$n o%p",
    "123.456.789 1,234,567.89 0xDEADBEEF",
    "Über die Straße in München: Grüße!",
]

MULTILINGUAL_PARAS = [
    "Breaking news 🌍: The Unicode 16.0.0 UAX #29 release brings full Indic Conjunct Break (GB9c) support for Devanagari like क्ष (\u0915\u094D\u0937) and क्त्र (\u0915\u094D\u0924\u094D\u0930)! Families 👨‍👩‍👧‍👦 and astronauts 👩🏽‍🚀 travel between 🇨🇳 and 🇺🇸.\n",
    "中文社区动态：浏览器引擎与文本编辑器必须精确处理字素簇边界、左右光标移动与退格键删除，绝不能把四字节 Emoji 或合字劈裂！今天下午 3.14 点在东京召开技术评审会。\n",
    "日本語のアップデート：カタカナ（プロトコル・ベンチマーク）と漢字・ひらがな混在テキストの境界検出。バージョン 16.0.0 で高速化されました！\n",
    "한국어 테스트: 조합형 한글 (\u1100\u1161\u11A8)과 완성형 한글이 모두 정확하게 분리됩니다. Dr. Kim은 \"완벽해요!\"라고 말했습니다.\n",
    "Grüße aus München! Über 1,250 Entwickler arbeiten an π ≈ 3.14159. Ελληνικά: Αθήνα και Θεσσαλονίκη. Русский: Привет, мир! العربية: مرحباً بالعالم ٢٠٢٦. עברית: שלום א' א\"ב.\n",
]

TECHNICAL_PARAS = [
    "Section 4.1.2 (UAX #29): Word boundaries use rules WB1 through WB999, e.g. AHLetter x (MidLetter | MidNumLetQ) AHLetter, Numeric x (MidNum | MidNumLetQ) Numeric, and ExtendNumLet joins snake_case_identifiers_v2.\n",
    "Benchmark configuration: warmup=1, rounds=5, payload_bytes=65536, throughput=128.45 MB/s, p95=4.21 ms, rss=2.18 MiB. See https://unicode.org/reports/tr29/ for normative tables.\n",
    "Error handling: SegmentLimits::new(16777216, 4194304) enforces strict O(n) execution. Negative values (-1, -1) return Err(SegmentError::LimitExceeded); zero (0, 0) accepts only empty strings.\n",
    "Abbreviation & quote handling: Dr. A. B. Smith wrote \"See U.S.A. vs. U.K. data (Fig. 3.2, p. 14).\" Next sentence starts cleanly after closing punctuation and spaces! Is 99.95% enough? Yes.\n",
]


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-unicode-segment-bench/data"
    os.makedirs(out_dir, exist_ok=True)

    with open(os.path.join(out_dir, "diff_corpus.txt"), "w", encoding="utf-8") as f:
        for line in DIFF_CASES:
            f.write(line + "\n")

    with open(os.path.join(out_dir, "bench_multilingual.txt"), "w", encoding="utf-8") as f:
        for _ in range(30):
            for p in MULTILINGUAL_PARAS:
                f.write(p)

    with open(os.path.join(out_dir, "bench_technical.txt"), "w", encoding="utf-8") as f:
        for _ in range(40):
            for p in TECHNICAL_PARAS:
                f.write(p)

    print(f"Generated corpora in {out_dir}")


if __name__ == "__main__":
    main()
