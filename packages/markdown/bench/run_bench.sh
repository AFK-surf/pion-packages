#!/bin/sh
# Reproducible head-to-head benchmark runner for packages/markdown vs Rust pulldown-cmark.
# All build artifacts and generated corpora are kept in /tmp (zero worktree pollution).
set -eu

PKG_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
TMP_DIR="${TMPDIR:-/tmp}/pion-markdown-bench"
mkdir -p "$TMP_DIR/rust_src/src"

export PATH="${HOME}/.pion/bin:${HOME}/.cargo/bin:${PATH}"

echo "==> Building Pion native release benchmark"
pionc build --release -o "$TMP_DIR/bench_pion" "$PKG_DIR/bench/pion_bench"

echo "==> Building Rust pulldown-cmark release benchmark"
cp "$PKG_DIR/bench/rust_bench/Cargo.toml" "$TMP_DIR/rust_src/Cargo.toml"
cp "$PKG_DIR/bench/rust_bench/src/main.rs" "$TMP_DIR/rust_src/src/main.rs"
CARGO_TARGET_DIR="$TMP_DIR/rust_target" cargo build --release --manifest-path "$TMP_DIR/rust_src/Cargo.toml"
cp "$TMP_DIR/rust_target/release/rust_markdown_bench" "$TMP_DIR/bench_rust"

echo "==> Generating Mixed GFM benchmark corpus (~2.5 MB)"
python3 - "$TMP_DIR/corpus_gfm.md" << 'PYEOF'
import sys
gfm_section = """# Release Notes & Architecture Review

This section exercises **bold**, *italic*, ~~deprecated~~, and `inline_code()` alongside [external links](https://example.com/docs/v1?a=1&b=2 "Documentation") and reference links [Pion][pion-lang].

## Performance Summary Table

| Component | Target | Median (ms) | Throughput (MB/s) | Status |
| :--- | :---: | ---: | ---: | :--- |
| Block Parser | `arm64_apple` | 12.4 | 198.4 | **Pass** |
| Inline Scanner | `arm64_apple` | 18.1 | 135.9 | **Pass** |
| HTML Renderer | `wasm32` | 4.2 | 585.7 | ~~Beta~~ Stable |

## Checklist

- [x] CommonMark 0.31.2 compliance (652/652)
- [x] GFM Tables, Strikethrough, Tasklists
- [ ] Streaming incremental parser
  - [x] Zero-copy byte index scanning
  - [x] Linear-time delimiter stack

> Blockquote with *nested emphasis*, `code`, and multiple lines
> continuing lazily across paragraphs to stress block continuation.

```rust
fn parse_markdown(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for line in input.lines() {
        out.push_str(line);
        out.push('\n');
    }
    out
}
```

[pion-lang]: https://github.com/AFK-surf/pion "Pion Programming Language"
""".encode("utf-8")
reps = (2500000 // len(gfm_section)) + 1
open(sys.argv[1], "wb").write(b"\n".join([gfm_section] * reps))
PYEOF

C2_BYTES=$(wc -c < "$TMP_DIR/corpus_gfm.md" | tr -d ' ')
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Markdown Parse + Render HTML (Mixed GFM Corpus, 2.50 MB)" \
  --impl "rust_pulldown_cmark=$TMP_DIR/bench_rust $TMP_DIR/corpus_gfm.md gfm" \
  --impl "pion_markdown=$TMP_DIR/bench_pion $TMP_DIR/corpus_gfm.md gfm" \
  --baseline rust_pulldown_cmark \
  --warmup 1 --rounds 5 --bytes "$C2_BYTES"
