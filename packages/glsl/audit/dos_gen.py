#!/usr/bin/env python3
"""Generate DoS / boundary probes for packages/glsl into $AUDIT_OUT/dos and list them in dos_cases.txt.

Each line of dos_cases.txt: <file> <stage> <mode>, mode `tr` = default ParseLimits, `time` = all limits 0 (unlimited).
"""
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("AUDIT_OUT", "/private/tmp/pion-glsl-audit")
D = os.path.join(OUT, "dos")
os.makedirs(D, exist_ok=True)
cases = []


def put(name, data, stage="frag", modes=("tr",)):
    p = os.path.join(D, name)
    with open(p, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())
    for m in modes:
        cases.append(f"{p} {stage} {m}")


FS = "precision mediump float;\nvoid main(){gl_FragColor=vec4(1.0);}\n"
# O(defines x lookups): every array size / gl_FragData index is resolved by a linear scan over all #defines
for nd in (1000, 4096):
    defs = "".join(f"#define D{i} {i}\n" for i in range(nd))
    decls = "".join(f"uniform float a{i}[D0];\n" for i in range(60000))
    put(f"define_scan_{nd}x60k.frag", defs + decls + FS, modes=("tr", "time"))
# O(D^2) #define table maintenance (set_int_define scans before append); default cap is 4096
for nd in (4096, 20000, 50000):
    put(f"defines_{nd}.frag", "".join(f"#define D{i} {i}\n" for i in range(nd)) + FS, modes=("tr", "time"))
# token / byte / nesting bombs
put("tokens_2M.frag", FS + "float x = " + "1.0+" * 1000000 + "1.0;\n", modes=("tr", "time"))
put("parens_1M.frag", "precision mediump float;\nvoid main(){gl_FragColor=vec4(" + "(" * 1000000 + "1.0" + ")" * 1000000 + ");}\n",
    modes=("tr", "time"))
put("ifdef_100k_deep.frag", "#ifdef A\n" * 100000 + "#endif\n" * 100000 + FS, modes=("tr", "time"))
put("ifdef_unbalanced.frag", "#ifdef A\n" * 10 + FS)
put("endif_unbalanced.frag", FS + "#endif\n")
put("ident_4MiB.frag", "precision mediump float;\nfloat " + "a" * (4 * 1024 * 1024 - 64) + ";\n" + "void main(){}\n",
    modes=("tr", "time"))
put("line_4MiB_comment.frag", "// " + "x" * (4 * 1024 * 1024 - 100) + "\n" + FS)
put("over_4MiB.frag", "// " + "x" * (4 * 1024 * 1024) + "\n" + FS)
put("cont_lines_1M.frag", "precision mediump float;\nfloat ab\\\n" + "\\\n" * 1000000 + "c;\n" + "void main(){}\n",
    modes=("tr", "time"))
put("unterminated_block_4MiB.frag", "/*" + "*" * (4 * 1024 * 1024 - 10))
put("define_expansion_bomb.frag",
    "".join(f"#define X{i+1} X{i} X{i}\n" for i in range(60)) + "#define X0 1.0+\n" + FS)
# integer overflow probes (32-bit Int wraps silently)
put("fragdata_idx_2147483647.frag", "#extension GL_EXT_draw_buffers : require\nprecision mediump float;\n"
    "void main(){gl_FragData[2147483647]=vec4(1.0);}\n")
put("fragdata_idx_4294967296.frag", "#extension GL_EXT_draw_buffers : require\nprecision mediump float;\n"
    "void main(){gl_FragData[4294967296]=vec4(1.0);}\n")
put("array_20digits.vert", "attribute vec4 p;\nuniform vec4 a[99999999999999999999];\nvoid main(){gl_Position=p;}\n", "vert")
put("location_huge.vert", "#version 300 es\nlayout(location = 999999999999999) in vec4 p;\nvoid main(){gl_Position=p;}\n", "vert")
put("line_directive_huge.frag", "#line 99999999999999\n" + FS)
# byte-level hostility
put("nul_byte.frag", FS.replace("void", "vo\0id"))
put("nul_in_comment.frag", "// a\0b\n" + FS)
put("bad_utf8_in_comment.frag", b"// \xc3\x28 \xff\xfe\n" + FS.encode())
put("bad_utf8_in_code.frag", FS.encode().replace(b"main", b"ma\xffin"))
put("bom.frag", b"\xef\xbb\xbf" + FS.encode())
put("cr_only.frag", FS.replace("\n", "\r"))
put("crlf_mixed.frag", FS.replace("\n", "\r\n", 1))
put("block_comment_open.frag", FS + "/*/")
put("slash_star_line.frag", "//*\n" + FS)
put("comment_continuation_eats_decl.frag", "precision mediump float;\n// C:\\path\\\nuniform float eaten;\n"
    "void main(){gl_FragColor=vec4(eaten);}\n")
with open(os.path.join(OUT, "dos_cases.txt"), "w") as f:
    f.write("\n".join(cases) + "\n")
print(f"{len(cases)} DoS/boundary probes -> {D}")
