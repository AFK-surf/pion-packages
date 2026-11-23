#!/usr/bin/env python3
"""Stage-attribution profiler for packages/webm: builds patched copies of the package (in $AUDIT_OUT/prof, never in
the repo), each removing or replacing one hot-path cost, and times parse_webm on the same file with wall-clock
loops (no sample/lldb: Developer Mode is off on the audit host).

  prof_variants.py <pkg_dir> <harness_src_dir> <out_dir> <file> <iters> <rounds>
"""
import os
import re
import shutil
import statistics
import subprocess
import sys

pkg, harness, out, f, iters, rounds = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6])
src = open(os.path.join(pkg, "src", "webm.pion")).read()

PUSH_SIMPLE = """    frames.push(Frame::{
      track_number: track_number,
      offset: pos.to_int64(),"""


def must(s, old, new):
    assert old in s, old[:60]
    return s.replace(old, new, 1)


VARIANTS = {
    "baseline": lambda s: s,
    # 1. no Frame index: count instead of push (cost of Array[Frame] growth + 56-byte val copies)
    "no_frame_push": lambda s: must(must(s, PUSH_SIMPLE, "    st.elements_visited = st.elements_visited + 0\n    let _unused = Frame::{\n      track_number: track_number,\n      offset: pos.to_int64(),"),
                                    "    frames.push(Frame::{\n      track_number: track_number,\n      offset: frame_off.to_int64(),",
                                    "    let _unused2 = Frame::{\n      track_number: track_number,\n      offset: frame_off.to_int64(),").replace("      invisible: invisible,\n    })\n    return Ok(())", "      invisible: invisible,\n    }\n    return Ok(())").replace("      invisible: invisible,\n    })\n    frame_off", "      invisible: invisible,\n    }\n    frame_off"),
    # 2. SimpleBlocks skipped entirely (cost of parse_block_payload incl. Result + VINT + push)
    "skip_block_payload": lambda s: must(s, "    } else if vid.id == id_simple_block {\n      match\n      parse_block_payload(",
                                         "    } else if vid.id == id_simple_block && false {\n      match\n      parse_block_payload("),
    # 3. no per-element limit counter (count_element Result per element)
    "no_count_element": lambda s: must(s, "fn count_element(st : ParseState) -> Result[Unit, WebmError] {\n  st.elements_visited = st.elements_visited + 1\n  if st.elements_visited > st.limits.max_elements {",
                                       "fn count_element(st : ParseState) -> Result[Unit, WebmError] {\n  if false {"),
    # 4. no DefaultDuration lookup per block (linear scan over Array[TrackEntry], a ref-counted struct)
    "no_default_duration_lookup": lambda s: must(s, "    track_default_duration(tracks, track_number)\n", "    0L\n"),
    # 6. Result-free fast path for the dominant shape: 1-byte SimpleBlock ID (0xA3) + 1/2-byte size
    "simpleblock_fast_path": lambda s: must(s, "  while pos < end {\n    let vid = match read_vint_id(data, pos, end) {",
        """  while pos < end {
    if pos + 3 <= end && data[pos].to_int() == 0xA3 {
      let s0 = data[pos + 1].to_int()
      let mut plen = -1
      let mut hdr = 0
      if s0 >= 0x80 && s0 != 0xFF {
        plen = s0 & 0x7F
        hdr = 2
      } else if s0 >= 0x40 && s0 < 0x80 && (s0 & 0x3F) != 0x3F || s0 >= 0x40 && s0 < 0x80 && data[pos + 2].to_int() != 0xFF {
        plen = ((s0 & 0x3F) << 8) | data[pos + 2].to_int()
        hdr = 3
      }
      if plen >= 0 && pos + hdr + plen <= end {
        st.elements_visited = st.elements_visited + 1
        if st.elements_visited > st.limits.max_elements {
          return Err(WebmError::LimitExceeded("max_elements exceeded"))
        }
        match parse_block_payload(data, pos + hdr, pos + hdr + plen, cluster_ts, timestamp_scale, tracks, true, false, 0L, st, frames) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
        pos = pos + hdr + plen
        continue
      }
    }
    let vid = match read_vint_id(data, pos, end) {"""),
    # 5. 2 + 3 + 4 together
    "skip_block_and_count": lambda s: VARIANTS["no_count_element"](VARIANTS["skip_block_payload"](s)),
}

os.makedirs(out, exist_ok=True)
bins = {}
for name, patch in VARIANTS.items():
    d = os.path.join(out, "variant_" + name)
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(pkg, os.path.join(d, "webm"), ignore=shutil.ignore_patterns("audit", "bench", "wasm_smoke", "*_test.pion"))
    open(os.path.join(d, "webm", "src", "webm.pion"), "w").write(patch(src))
    os.makedirs(os.path.join(d, "h"), exist_ok=True)
    shutil.copytree(harness, os.path.join(d, "h", "src"))
    open(os.path.join(d, "h", "pion.toml"), "w").write('[package]\nname = "webm_prof"\nversion = "0.1.0"\n\n[dependencies]\nwebm = { path = "../webm" }\n')
    b = os.path.join(d, "bin")
    subprocess.run(["pionc", "build", "--release", "-o", b, os.path.join(d, "h")], check=True)
    bins[name] = b
res = {k: [] for k in bins}
for _ in range(rounds):  # strictly alternating
    for k, b in bins.items():
        o = subprocess.run([b, "bench", f, iters, "parse"], stdout=subprocess.PIPE, check=True).stdout.decode()
        res[k].append(int(re.search(r"ms=(\d+)", o).group(1)))
base = statistics.median(res["baseline"])
for k, v in res.items():
    m = statistics.median(v)
    print(f"  {k:22s} median={m:7.1f} ms  ({m / int(iters) * 1000:7.2f} us/parse)  saves {base - m:6.1f} ms ({(base - m) / base * 100:5.1f}%)")
