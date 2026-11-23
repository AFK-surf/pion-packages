#!/usr/bin/env python3
"""Deterministic corpus generator for unicode_bidi head-to-head benchmarks."""
import os
import sys

def gen_pure_ltr(path: str, count: int) -> None:
    templates = [
        "The quick brown fox jumps over the lazy dog 0123456789 (standard ASCII text).",
        "HTTP/1.1 200 OK; Content-Type: text/html; charset=utf-8; X-Request-Id: req-9876543210",
        "fn compute_layout(width: f64, height: f64) -> Result[Rect, Error] { Ok(Rect::new(0, 0, width, height)) }",
        "中文与英文混合排版测试 2026-11-23 Farview Browser Engine pure Pion layout pipeline.",
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore.",
    ]
    with open(path, "w", encoding="utf-8") as f:
        for i in range(count):
            t = templates[i % len(templates)]
            f.write(f"{t} [{i}]\n")

def gen_mixed_ar_he_en(path: str, count: int) -> None:
    templates = [
        "مرحبا بالعالم Hello World 12345 שלום עולם (test 2026)!",
        "שלום! The price is $12.34 + $56.78 = $69.12 في المتجر رقم 42.",
        "Arabic العربية 0660: ٠١٢٣٤٥ and Latin 98765, Hebrew עברית (אבג) [xyz].",
        "User أحمد_2026 replied to דוד_99: 'Check https://example.com/path?a=1&b=2 الآن!'",
        "中文 + العربية مرحبا + עברית שלום + English 100% + $99.95 (ok).",
    ]
    with open(path, "w", encoding="utf-8") as f:
        for i in range(count):
            t = templates[i % len(templates)]
            f.write(f"{t} #{i}\n")

def gen_deep_isolate_brackets(path: str, count: int) -> None:
    LRI = "\u2066"
    RLI = "\u2067"
    FSI = "\u2068"
    PDI = "\u2069"
    RLE = "\u202B"
    LRE = "\u202A"
    PDF = "\u202C"
    NSM = "\u0300"
    templates = [
        f"a ({RLI}שלום ({LRI}hello [12+34] {FSI}مرحبا 56{PDI}{PDI}) בעולם{PDI}) z",
        f"שלום {FSI}abc (def [אבג (123) דהו] ghi){PDI} {RLI}مرحبا{NSM} (test {LRI}ok{PDI}){PDI}!",
        f"{RLE}({LRE}[{RLI}({FSI}אבג{NSM} 123+456{PDI}){PDI}]{PDF}){PDF} end",
        f"x (a (b (c (אבג (d (مرحبا (123) שלום) e) f) g) h) i) y",
        f"{FSI}مرحبا{PDI} ({RLI}אבג {FSI}hello (world){PDI} דהו{PDI}) [{LRI}123+456{PDI}]",
    ]
    with open(path, "w", encoding="utf-8") as f:
        for i in range(count):
            t = templates[i % len(templates)]
            f.write(f"{t} [{i}]\n")

def main() -> None:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-unicode-bidi-bench"
    os.makedirs(out_dir, exist_ok=True)
    gen_pure_ltr(os.path.join(out_dir, "pure_ltr.txt"), 2000)
    gen_mixed_ar_he_en(os.path.join(out_dir, "mixed_ar_he_en.txt"), 2000)
    gen_deep_isolate_brackets(os.path.join(out_dir, "deep_isolate_brackets.txt"), 1000)
    print(f"Generated corpora in {out_dir}")

if __name__ == "__main__":
    main()
