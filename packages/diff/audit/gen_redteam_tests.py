#!/usr/bin/env python3
"""Generate `src/redteam_test.pion`: every expected value is produced by running the
real Rust `imara-diff v0.2.0` oracle (`harness/rust_oracle`) on the same input.

usage: gen_redteam_tests.py ORACLE_BIN OUT.pion
"""
import os, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fuzz import write_cases, parse_dump

def code(s):
    """Compact line encoding: x -> 'x\\n', y -> 'y\\n', _ -> blank line."""
    return "".join({"x": "x\n", "y": "y\n", "_": "\n", "z": "z\n"}[c] for c in s)

HR_B, HR_A = "xyy___yy__y_yy__yxy___y_x_xyyyy_xx_xxx___x_y_yy___yxyxxxx_y_xxyxxyy__y__yx___yxxx___x_xxx_x_y___x_xxxxyyyyy_xyxx__x__xyyyxyyx_y_xyy_y_xxxy__x_yyyyxxyy_xyyxxyxyx_xyxxyx_yxx___x_x_yyyx_xyyxx_yyy _y_yy__yy___y__yyyy_x_xxx___y_y___yxyxxxx_y_xxyxxyy__y__yx__yxxx___x_xxx__y___x_xxxyyyyxyxx__x_yyyxyx_y_xyy_y_xxxy__x_yyyyxxy_xyxxyxy_xyxxyx_yxx___x_x_yyyx_xyyxx".split(" ")
BODY = "".join(f"    stmt_{i}();\n" for i in range(30))

# (name, severity, note, before, after, checks)
# check = (kind, algo, ctx) ; kind in lines|raw|slices|unified
H, M = "Histogram", "Myers"
CASES = [
    ("p0_window_blank_suffix_histogram", "P0",
     "diff_lines (margin-21 window) moves a blank-line deletion; imara and Pion's own diff_slices agree",
     "    if x {\n    }\n" + "\n" * 23, "    }\n" + "\n" * 22,
     [("lines", H, 0), ("slices", H, 0)]),
    ("p0_window_blank_suffix_myers", "P0", "same input, Myers",
     "    if x {\n    }\n" + "\n" * 23, "    }\n" + "\n" * 22,
     [("lines", M, 0), ("slices", M, 0)]),
    ("p0_window_blank_prefix_histogram", "P0",
     "22 blank lines then a deleted 3-line block: window start is mistaken for start-of-file",
     "\n" * 22 + "fn f() {\n\n\n        return;\n", "\n" * 22 + "        return;\n",
     [("lines", H, 0), ("slices", H, 0), ("unified", H, 3)]),
    ("p0_window_header_edit_plus_blank_run_unified", "P0",
     "header line edited + one blank added to a 40-blank run: wrong hunk position AND trailing context cut to 1 line",
     "// v1\n" + BODY + "\n" * 40 + BODY, "// v2\n" + BODY + "\n" * 41 + BODY,
     [("unified", H, 3), ("unified", M, 3), ("lines", H, 0)]),
    ("p0_unified_ctx25_trailing_context_truncated", "P0",
     "context >= 21 makes margin == ctx; a hunk that slid into the stripped suffix loses a trailing context line",
     "\n}\nb\na\n{\nb\na\n\na\n}\nb\n}\n  x\nb\n\nc\na\n}\n\nb\n}\n\nc\n{\n{\n{\n{\na\n",
     "}\nb\nb\na\n{\nb\na\n\na\n}\nb\n}\n  x\nb\n\nc\na\n}\n\nb\n}\n\nc\n{\n{\n{\n{\na\n",
     [("lines", H, 0), ("unified", H, 25), ("unified", M, 25)]),
    ("p1_myers_postprocessed_small", "P1",
     "Myers port deviates from imara (is_odd / common-line pruning) on a 7-line input",
     "c\n}\nc\nc\na\n}\na\n", "a\n}\nc\na\na\n}\nc\na\n",
     [("lines", M, 0), ("slices", M, 0), ("unified", M, 3)]),
    ("p1_myers_raw_small", "P1", "raw Myers hunks differ (no postprocessing involved)",
     "\n\tz();\n\tz();\n\tz();\n\n\n", "\tz();\n\n\tz();\n",
     [("raw", M, 0)]),
    ("p1_myers_raw_mixed", "P1", "raw Myers hunks differ",
     "b\n  x\n}\n\n  x\n", "  x\n\n}\n}\n\n",
     [("raw", M, 0)]),
    ("p1_histogram_myers_fallback_raw", "P1",
     ">63-occurrence Histogram fallback inherits the Myers deviation (192-line x/y/blank input)",
     code(HR_B), code(HR_A),
     [("raw", H, 0), ("lines", H, 0)]),
    ("p1_unified_empty_before_header", "P1", "imara prints -1,0 for an empty side; Pion prints -0,0 (GNU style)",
     "", "a\n", [("unified", H, 3)]),
    ("p1_unified_ctx0_pure_insertion_header", "P1", "context 0 pure insertion header start",
     "a\nb\n", "a\nx\nb\n", [("unified", H, 0), ("unified", M, 0)]),
    ("p1_unified_no_newline_marker", "P1",
     "imara's BasicLineDiffPrinter prints a bare newline, Pion adds '\\ No newline at end of file'",
     "a\n", "b", [("unified", H, 3)]),
    ("p2_unified_first_hunk_context_imara_quirk", "P2",
     "imara quirk: first hunk with ctx < start <= 2*ctx prints context from line 1 under a -(start-ctx+1) header; Pion prints the GNU-correct hunk",
     "".join(f"l{i}\n" for i in range(10)), "".join(("L5\n" if i == 5 else f"l{i}\n") for i in range(10)),
     [("unified", H, 3)]),
    # --- controls: these are expected to PASS (robustness parity) ---
    ("ok_empty_vs_empty", "ok", "", "", "", [("lines", H, 0), ("unified", H, 3)]),
    ("ok_crlf_vs_lf", "ok", "CRLF and LF lines are different tokens in both",
     "a\r\nb\r\nc\r\n", "a\nb\r\nc\n", [("lines", H, 0), ("lines", M, 0)]),
    ("ok_only_newlines", "ok", "", "\n", "\r\n", [("lines", H, 0), ("unified", H, 3)]),
    ("ok_multibyte_utf8", "ok", "",
     "日本語\nçé\n🙂\n", "日本語\nce\n🙂\n", [("lines", H, 0), ("unified", H, 3), ("unified", M, 1)]),
    ("ok_add_trailing_newline_only", "ok", "hunks only (unified differs by the marker)", "a\nb", "a\nb\n", [("lines", H, 0), ("lines", M, 0)]),
]

def pion_str(s):
    out = []
    for ch in s:
        o = ord(ch)
        if ch == "\\": out.append("\\\\")
        elif ch == '"': out.append('\\"')
        elif ch == "\n": out.append("\\n")
        elif ch == "\r": out.append("\\r")
        elif ch == "\t": out.append("\\t")
        elif o < 32: raise ValueError(repr(ch))
        else: out.append(ch)
    return '"' + "".join(out) + '"'

def main():
    oracle, out_path = sys.argv[1], sys.argv[2]
    tmp = tempfile.mktemp(suffix=".bin")
    write_cases(tmp, [(c[3], c[4]) for c in CASES])
    res = parse_dump(subprocess.run([oracle, "cases", tmp], check=True, capture_output=True).stdout)
    L = []
    L.append("///| Red-team parity tests: Pion `packages/diff` vs real Rust `imara-diff v0.2.0`.")
    L.append("///| GENERATED by `audit/gen_redteam_tests.py` - every expected value was printed by the")
    L.append("///| Rust oracle `audit/harness/rust_oracle` on the same input. A failing `p0_*`/`p1_*`/`p2_*`")
    L.append("///| test is a reproducible divergence; `ok_*` tests are parity controls expected to pass.")
    L.append("")
    L.append('import "diff"')
    L.append("")
    L.append("""///|
fn hunks_str(res : diff::DiffResult) -> String {
  let sb = StringBuilder::new()
  let mut i = 0
  while i < res.hunks.length() {
    let h = res.hunks[i]
    if i > 0 {
      sb.write_string(" ")
    }
    sb.write_string(h.before_start.to_string())
    sb.write_string("-")
    sb.write_string(h.before_end.to_string())
    sb.write_string(":")
    sb.write_string(h.after_start.to_string())
    sb.write_string("-")
    sb.write_string(h.after_end.to_string())
    i = i + 1
  }
  sb.to_string()
}

///|
fn expect_eq(what : String, got : String, want : String) -> Unit {
  debug_assert(
    got == want,
    what + "\\n--- imara-diff 0.2.0 (expected) ---\\n" + want + "\\n--- pion (got) ---\\n" + got,
  )
}
""")
    for (name, sev, note, b, a, checks), r in zip(CASES, res):
        L.append("///|")
        if note:
            L.append(f"/// [{sev}] {note}")
        L.append(f'test "{name}" {{')
        L.append(f"  let before = {pion_str(b)}")
        L.append(f"  let after = {pion_str(a)}")
        for kind, algo, ctx in checks:
            tag = algo[0]
            alg = f"diff::Algorithm::{algo}"
            if kind == "lines":
                L.append(f'  expect_eq("diff_lines {algo}", hunks_str(diff::diff_lines(before, after, {alg})), {pion_str(r[tag + "P"])})')
            elif kind == "raw":
                L.append(f'  expect_eq("diff_lines_raw {algo}", hunks_str(diff::diff_lines_raw(before, after, {alg})), {pion_str(r[tag + "R"])})')
            elif kind == "slices":
                L.append(f'  expect_eq("diff_slices {algo}", hunks_str(diff::diff_slices(diff::split_lines(before), diff::split_lines(after), {alg})), {pion_str(r[tag + "P"])})')
            elif kind == "unified":
                L.append(f'  expect_eq("unified_diff {algo} ctx={ctx}", diff::unified_diff(before, after, "", "", {ctx}, {alg}), {pion_str(r[f"{tag}U{ctx}"].decode())})')
        L.append("}")
        L.append("")
    open(out_path, "w").write("\n".join(L))

if __name__ == "__main__":
    main()
