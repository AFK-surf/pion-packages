#!/usr/bin/env python3
"""Generate deterministic realistic source-code diff corpora in /tmp/diff-bench/.

Produces two large source file pairs:
1. `large_refactor_{before,after}.rs`: ~6,000 lines of realistic structured code with
   small localized edits, medium function refactors, block insertions/deletions,
   moved blocks, and high-repetition braces/blank lines.
2. `helix_syntax_{before,after}.rs`: copied from /tmp/imara-diff/tests/helix_syntax.rs.{before,after}
   if available (optional), otherwise skipped cleanly.
"""

import os
import random
import shutil

OUT_DIR = "/tmp/diff-bench"


def make_function(idx: int, rng: random.Random, variant: int = 0) -> list[str]:
    lines = [
        f"/// Process record batch #{idx} with validation and metrics.",
        f"pub fn process_batch_{idx}(input: &[u8], limit: usize) -> Result<usize, Error> {{",
        "    if input.is_empty() {",
        "        return Ok(0);",
        "    }",
        "    let mut total: usize = 0;",
        "    let mut cursor: usize = 0;",
    ]
    n_stmts = 8 + (idx % 7)
    for s in range(n_stmts):
        op = (idx * 31 + s * 17 + variant) % 5
        if op == 0:
            lines.append(f"    let v_{s} = input[cursor % input.len()] as usize + {s + variant};")
            lines.append(f"    total = total.wrapping_add(v_{s});")
        elif op == 1:
            lines.append("    if total > limit {")
            lines.append(f"        return Err(Error::LimitExceeded({idx}, total));")
            lines.append("    }")
        elif op == 2:
            lines.append(f"    cursor = (cursor + {s + 1}) % input.len();")
        elif op == 3:
            lines.append("    // Accumulate checksum step")
            lines.append(f"    total ^= (cursor << {(s % 4) + 1}) ^ {idx * 13 + s};")
        else:
            lines.append("    match total & 3 {")
            lines.append("        0 => total = total.wrapping_add(1),")
            lines.append("        1 => total = total.wrapping_add(3),")
            lines.append("        _ => total = total.wrapping_add(7),")
            lines.append("    }")
    lines.append("    Ok(total)")
    lines.append("}")
    lines.append("")
    return lines


def generate_large_refactor() -> tuple[str, str]:
    rng = random.Random(20261123)
    num_funcs = 260  # ~6,000 lines
    before_blocks = [make_function(i, rng, variant=0) for i in range(num_funcs)]

    after_blocks: list[list[str]] = []
    # Move a 12-function block from index 40..52 to index 180
    moved_slice = before_blocks[40:52]

    for i in range(num_funcs):
        if 40 <= i < 52:
            # Moved elsewhere
            continue
        if i == 180:
            for blk in moved_slice:
                after_blocks.append(list(blk))
        if i % 37 == 5:
            # Delete this function
            continue
        elif i % 29 == 3:
            # Medium refactor: modify body + insert helper lines
            blk = make_function(i, rng, variant=1)
            blk.insert(2, "    let _guard = MetricsGuard::enter();")
            after_blocks.append(blk)
        elif i % 23 == 7:
            # Small 1-2 line localized edit
            blk = list(before_blocks[i])
            blk[0] = f"/// Process record batch #{i} (v2 fast path)."
            after_blocks.append(blk)
        elif i % 43 == 11:
            # Keep original and insert a brand new function right after
            after_blocks.append(list(before_blocks[i]))
            after_blocks.append(make_function(10000 + i, rng, variant=2))
        else:
            after_blocks.append(list(before_blocks[i]))

    before_text = "\n".join(line for blk in before_blocks for line in blk) + "\n"
    after_text = "\n".join(line for blk in after_blocks for line in blk) + "\n"
    return before_text, after_text


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    before_text, after_text = generate_large_refactor()
    b_path = os.path.join(OUT_DIR, "large_refactor_before.rs")
    a_path = os.path.join(OUT_DIR, "large_refactor_after.rs")
    with open(b_path, "w", encoding="utf-8") as f:
        f.write(before_text)
    with open(a_path, "w", encoding="utf-8") as f:
        f.write(after_text)
    print(
        f"Generated {b_path} ({len(before_text)} B, {before_text.count(chr(10))} lines) "
        f"and {a_path} ({len(after_text)} B, {after_text.count(chr(10))} lines)"
    )

    helix_b = "/tmp/imara-diff/tests/helix_syntax.rs.before"
    helix_a = "/tmp/imara-diff/tests/helix_syntax.rs.after"
    if os.path.isfile(helix_b) and os.path.isfile(helix_a):
        shutil.copyfile(helix_b, os.path.join(OUT_DIR, "helix_syntax_before.rs"))
        shutil.copyfile(helix_a, os.path.join(OUT_DIR, "helix_syntax_after.rs"))
        print("Copied helix_syntax.rs corpus to /tmp/diff-bench/")


if __name__ == "__main__":
    main()
