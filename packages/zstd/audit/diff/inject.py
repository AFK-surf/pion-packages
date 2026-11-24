#!/usr/bin/env python3
"""RT-zstd mutation proof: inject real bugs into an isolated copy of packages/zstd and require the audit control
tests (`pionc test audit`, control_* only) to catch every one. The repository is never touched.
usage: inject.py <pkg_dir> <work_dir>"""
import json
import os
import shutil
import subprocess
import sys

PKG, WORK = sys.argv[1], sys.argv[2]
D, H, X, E = "src/decode.pion", "src/huffman.pion", "src/xxhash64.pion", "src/encode.pion"
M = [
    ("I-1 xxHash64 round uses rotl 30", X, [("input * xxh_prime2, 31)", "input * xxh_prime2, 30)")]),
    ("I-2 xxHash64 avalanche uses an arithmetic shift", X,
     [("h64 = (h64 ^ (h64 >> 33)) * xxh_prime2", "h64 = (h64 ^ (h64.to_int64() >> 33).to_uint64()) * xxh_prime2")]),
    ("I-3 FHD Reserved_bit accepted", D, [("if (fhd & 0x08) != 0 {", "if false {")]),
    ("I-4 Block_Type 3 (Reserved) decoded as Raw", D, [("if block_type == 3 {", "if false {")]),
    ("I-5 offset > Window_Size accepted", D,
     [("if off64 > window_size || off64 > max_container_bytes.to_int64() {", "if off64 > max_container_bytes.to_int64() {"),
      ("if offset <= 0 || offset > frame_written || offset.to_int64() > window_size {",
       "if offset <= 0 || offset > frame_written {")]),
    ("I-6 offset > decoded history accepted (reads stale buffer)", D,
     [("if offset <= 0 || offset > frame_written || offset.to_int64() > window_size {",
       "if offset <= 0 || offset > out.len || offset.to_int64() > window_size {")]),
    ("I-7 Treeless literals without a previous table use a default tree", D,
     [("        None =>\n        return Err(\n          ZstdError::InvalidLiteralsHeader(\n            \"treeless literals without prior Huffman table\",\n          ),\n        )",
       "        None =>\n        match huff_build_table_from_weights(FixedArray::make(256, 1), 1) {\n          Ok(t) => t\n          Err(e) => return Err(e)\n        }")]),
    ("I-8 Repeat_Mode without a previous table uses Predefined", D,
     [("      None =>\n      return Err(\n        ZstdError::InvalidSequences(\"LL Repeat_Mode without prior table\"),\n      )",
       "      None => predef_ll")]),
    ("I-9 tables / repeat offsets carried across frames", D,
     [("    let state = FrameState::new()\n    let mut last_block = false", "    let mut last_block = false"),
      ("  let mut frame_count = 0\n", "  let mut frame_count = 0\n  let state = FrameState::new()\n")]),
    ("I-10 LL == 0 repeat-offset shift ignored", D, [("      if lit_count == 0 {", "      if false {")]),
    ("I-11 offset 0 (rep1 - 1 == 0) accepted", D,
     [("          if off <= 0 {", "          if off < 0 {"),
      ("if offset <= 0 || offset > frame_written || offset.to_int64() > window_size {",
       "if offset < 0 || offset > frame_written || offset.to_int64() > window_size {")]),
    ("I-12 max_output_bytes not enforced", D, [("if needed > self.max_output.to_int64() {", "if false {")]),
    ("I-13 4-stream Huffman segment size rounds down", H,
     [("let seg = (regen_size + 3) >> 2", "let seg = regen_size >> 2")]),
    ("I-14 FSE Huffman weights: tail symbol from the wrong state", H,
     [("        weights[count] = fse_tbl.sym[state2]\n        count = count + 1\n        break",
       "        weights[count] = fse_tbl.sym[state1]\n        count = count + 1\n        break")]),
    ("I-15 Frame_Content_Size mismatch accepted", D,
     [("if has_fcs && frame_written.to_int64().to_uint64() != fcs {", "if false {")]),
    ("I-16 Skippable frames not recognised", D,
     [("if magic >= skippable_magic_low && magic <= skippable_magic_high {", "if false {")]),
    ("I-17 content checksum not verified", D, [("if actual_chk != expected_chk {", "if false {")]),
    ("I-18 non-zero Dictionary_ID accepted", D, [("if dict_id != 0U {", "if false {")]),
    ("I-19 2-byte Frame_Content_Size without +256", D,
     [("fcs = (read_u16_le(data, pos) + 256).to_int64().to_uint64()", "fcs = read_u16_le(data, pos).to_int64().to_uint64()")]),
    ("I-20 Window_Descriptor mantissa ignored", D,
     [("let window_add : Int64 = (window_base >> 3) * mantissa.to_int64()", "let window_add : Int64 = 0L")]),
    ("I-21 Block_Size off by one", D, [("      if block_size > block_max {", "      if block_size > block_max + 1 {")]),
    ("I-22 sequence bitstream not required to be consumed", D,
     [("if br.bits_avail != 0 || br.byte_pos != pos {", "if false {")]),
    ("I-23 Huffman stream not required to be consumed", H,
     [("if br.bits_avail != 0 || br.byte_pos != start {", "if false {")]),
    ("I-24 max_frames off by one", D, [("if frame_count > limits.max_frames {", "if frame_count > limits.max_frames + 1 {")]),
    ("I-25 compressor emits repeat code 2 for rep2 at LL == 0", E,
     [("        if best_off == rep2 {\n          rep2 = rep1\n          rep1 = best_off\n          1",
       "        if best_off == rep2 {\n          rep2 = rep1\n          rep1 = best_off\n          2")]),
]
caught = 0
for title, f, edits in M:
    d = os.path.join(WORK, "pkg")
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(PKG, d, ignore=shutil.ignore_patterns("bench", "wasm_smoke", "rust", "*.md", "__pycache__"))
    p = os.path.join(d, f)
    s = open(p).read()
    skipped = False
    for old, new in edits:
        if s.count(old) != 1:
            print("  %-62s SKIPPED: anchor not found exactly once in %s (source changed?)" % (title, f))
            skipped = True
            break
        s = s.replace(old, new)
    if skipped:
        continue
    open(p, "w").write(s)
    r = subprocess.run(["pionc", "test", "--json", os.path.join(d, "audit")], capture_output=True, text=True)
    try:
        tests = json.loads(r.stdout)["tests"]
        failed = [t["name"] for t in tests if not t["ok"] and t["name"].startswith("control_")]
    except (ValueError, KeyError):
        failed = ["<build failed: %s>" % (r.stdout + r.stderr)[-200:]]
    if failed:
        caught += 1
    print("  %-62s %s" % (title, ("CAUGHT by " + ", ".join(failed)) if failed else "MISSED"))
shutil.rmtree(os.path.join(WORK, "pkg"), ignore_errors=True)
print("  injected bugs caught: %d/%d" % (caught, len(M)))
sys.exit(0 if caught == len(M) else 1)
