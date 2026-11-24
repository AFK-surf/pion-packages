#!/usr/bin/env python3
"""RT-sfv mutation proof: inject real bugs into an isolated copy of packages/structured_fields and require the
audit control tests (`pionc test audit`, control_* only) to catch every one. The repository is never touched.
usage: inject.py <pkg_dir> <work_dir>"""
import json
import os
import shutil
import subprocess
import sys

PKG, WORK = sys.argv[1], sys.argv[2]
M = [
    ("I-1 uppercase %XX accepted in Display Strings", "src/types.pion",
     "  } else if b >= 97 && b <= 102 {\n    b - 87\n  } else {\n    -1",
     "  } else if b >= 97 && b <= 102 {\n    b - 87\n  } else if b >= 65 && b <= 70 {\n    b - 55\n  } else {\n    -1"),
    ("I-2 top-level HTAB discarded like SP", "src/parser.pion",
     "while self.pos < self.len && self.bytes[self.pos].to_int() == 32 {",
     "while self.pos < self.len && (self.bytes[self.pos].to_int() == 32 || self.bytes[self.pos].to_int() == 9) {"),
    ("I-3 16-digit integers accepted", "src/parser.pion", "if int_digits > 15 {", "if int_digits > 16 {"),
    ("I-4 dictionary duplicate key keeps the first value", "src/parser.pion",
     "Some(idx) => members[idx] = DictMember::new(key, value)", "Some(_) => ()"),
    ("I-5 parameter duplicate key keeps the first value", "src/parser.pion",
     "Some(idx) => params[idx] = Param::new(key, value)", "Some(_) => ()"),
    ("I-6 serializer lets CR / LF / controls into Strings", "src/serializer.pion",
     "    if b < 32 || b > 126 {\n      return Err(SfvError::InvalidString(\"string contains",
     "    if b > 126 {\n      return Err(SfvError::InvalidString(\"string contains"),
    ("I-7 serializer leaves % unescaped in Display Strings", "src/serializer.pion",
     "if b == 37 || b == 34 || b < 32 || b > 126 {", "if b == 34 || b < 32 || b > 126 {"),
    ("I-8 4 fractional digits accepted", "src/parser.pion", "if frac_digits > 3 {", "if frac_digits > 4 {"),
    ("I-9 uppercase first key character accepted", "src/types.pion",
     "fn is_key_first(b : Int) -> Bool {\n  (b >= 97 && b <= 122) || b == 42",
     "fn is_key_first(b : Int) -> Bool {\n  (b >= 97 && b <= 122) || b == 42 || (b >= 65 && b <= 90)"),
    ("I-10 base64 '=' inside the data accepted", "src/parser.pion", "if pad_len > 0 {", "if pad_len > 8 {"),
    ("I-11 UTF-16 surrogates (ED A0..BF) accepted", "src/types.pion",
     "if b1 < 0x80 || b1 > 0x9F || b2 < 0x80 || b2 > 0xBF {", "if b1 < 0x80 || b1 > 0xBF || b2 < 0x80 || b2 > 0xBF {"),
    ("I-12 max_params off by one", "src/parser.pion",
     "if params.length() >= self.limits.max_params {", "if params.length() > self.limits.max_params {"),
    ("I-13 Priority u=8 accepted", "src/helpers.pion", "if v >= 0L && v <= 7L {", "if v >= 0L && v <= 8L {"),
    ("I-14 serializer integer range check removed", "src/serializer.pion",
     "fn Serializer::write_integer(self : Serializer, v : Int64) -> Result[Unit, SfvError] {\n  if v < sfv_min_int || v > sfv_max_int {",
     "fn Serializer::write_integer(self : Serializer, v : Int64) -> Result[Unit, SfvError] {\n  if false {"),
    ("I-15 byte sequence decoded-size limit off by one", "src/parser.pion",
     "  if out_len > self.limits.max_string_bytes {\n    return Err(SfvError::LimitExceeded(\"byte sequence",
     "  if out_len > self.limits.max_string_bytes + 1 {\n    return Err(SfvError::LimitExceeded(\"byte sequence"),
]
caught = 0
for title, f, old, new in M:
    d = os.path.join(WORK, "pkg")
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(PKG, d, ignore=shutil.ignore_patterns("bench", "wasm_smoke", "sft", "rust", "*.md"))
    p = os.path.join(d, f)
    s = open(p).read()
    if s.count(old) != 1:
        print("  %-55s SKIPPED: anchor not found exactly once in %s (source changed?)" % (title, f))
        continue
    open(p, "w").write(s.replace(old, new))
    r = subprocess.run(["pionc", "test", "--json", os.path.join(d, "audit")], capture_output=True, text=True)
    try:
        tests = json.loads(r.stdout)["tests"]
        failed = [t["name"] for t in tests if not t["ok"] and t["name"].startswith("control_")]
    except (ValueError, KeyError):
        failed = ["<build failed: %s>" % (r.stdout + r.stderr)[-200:]]
    if failed:
        caught += 1
    print("  %-55s %s" % (title, ("CAUGHT by " + ", ".join(failed)) if failed else "MISSED"))
shutil.rmtree(os.path.join(WORK, "pkg"), ignore_errors=True)
print("injected bugs caught: %d/%d" % (caught, len(M)))
sys.exit(0 if caught == len(M) else 1)
