#!/usr/bin/env python3
"""Deterministic English corpus generator for packages/hyphenation benchmarks."""

import os
import re
import sys

# Rich, realistic English vocabulary spanning short, medium, long, mixed-case,
# technical, academic, and TeX-exception words.
VOCAB = [
    "the", "of", "and", "to", "in", "a", "is", "that", "for", "it",
    "with", "as", "was", "on", "are", "be", "this", "from", "or", "by",
    "hyphenation", "algorithm", "computer", "typography", "internationalization",
    "representation", "extraordinary", "unbelievable", "communication", "programming",
    "miscellaneous", "university", "beautiful", "information", "implementation",
    "dictionary", "performance", "architecture", "optimization", "deterministic",
    "compilation", "serialization", "deserialization", "specification", "verification",
    "documentation", "configuration", "infrastructure", "parallelization", "vectorization",
    "synchronization", "virtualization", "containerization", "authentication", "authorization",
    "cryptography", "compression", "decompression", "fragmentation", "concatenation",
    "interpolation", "extrapolation", "approximation", "differentiation", "integration",
    "transformation", "classification", "categorization", "standardization", "normalization",
    "initialization", "finalization", "allocation", "deallocation", "reallocation",
    "associate", "associates", "declination", "obligatory", "philanthropic",
    "present", "presents", "project", "projects", "reciprocity",
    "recognizance", "reformation", "retribution", "table",
    "Algorithm", "Typography", "HYPHENATION", "Representation", "Communication",
    "Extraordinary", "Internationalization", "Implementation", "Dictionary", "Performance",
    "Associate", "Table", "Present", "Project", "University",
    "supercalifragilisticexpialidocious", "antidisestablishmentarianism",
    "electroencephalographically", "incomprehensibilities", "counterrevolutionary",
    "uncharacteristically", "disproportionately", "interchangeability",
    "misunderstanding", "acknowledgement", "accomplishment", "responsibility",
    "accountability", "accessibility", "compatibility", "maintainability",
    "observability", "reliability", "scalability", "availability",
    "functionality", "portability", "extensibility", "composability",
    "predictability", "reproducibility", "interoperability", "confidentiality",
    "cat", "dog", "word", "book", "code", "fast", "tree", "trie", "byte", "node",
    "layout", "browser", "engine", "render", "window", "screen", "pixel", "glyph",
    "paragraph", "sentence", "document", "character", "language", "pattern", "exception",
    "minimal", "optimal", "compact", "memory", "buffer", "stream", "parser", "scanner",
]


def extract_tex_tables(en_us_data_path: str):
    src = open(en_us_data_path, "r", encoding="utf-8").read()
    m_pat = re.search(r"let en_us_patterns : String =\n(.*?)\n\nlet en_us_exceptions", src, re.S)
    m_exc = re.search(r"let en_us_exceptions : String =\n(.*)", src, re.S)
    if not m_pat or not m_exc:
        raise RuntimeError("failed to extract en_us_patterns/en_us_exceptions")

    def unquote(block: str) -> str:
        parts = re.findall(r'"([^"]*)"', block)
        return "".join(parts).replace("\\n", "\n")

    return unquote(m_pat.group(1)), unquote(m_exc.group(1))


def main() -> int:
    if len(sys.argv) < 5:
        print(
            "usage: gen_data.py <words_out> <pats_out> <excs_out> <word_count>",
            file=sys.stderr,
        )
        return 1

    words_out = sys.argv[1]
    pats_out = sys.argv[2]
    excs_out = sys.argv[3]
    word_count = int(sys.argv[4])

    # Deterministic LCG to produce realistic word distribution.
    state = 0x12345678
    n_vocab = len(VOCAB)
    words = []
    for _ in range(word_count):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        words.append(VOCAB[(state >> 16) % n_vocab])

    with open(words_out, "w", encoding="utf-8") as f:
        f.write("\n".join(words) + "\n")

    bench_dir = os.path.dirname(os.path.abspath(__file__))
    data_pion = os.path.join(bench_dir, "..", "src", "en_us_data.pion")
    pats, excs = extract_tex_tables(data_pion)
    with open(pats_out, "w", encoding="utf-8") as f:
        f.write(pats)
    with open(excs_out, "w", encoding="utf-8") as f:
        f.write(excs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
