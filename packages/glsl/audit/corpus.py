"""Adversarial / real-world GLSL ES 1.00 + 3.00 corpus for the OpenGL 4.1 Core ground-truth judge.

Every case is a *valid* WebGL shader pair (checked by hand against the GLSL ES 1.00 / 3.00 specs; the pass-through
partner stage is used where only one stage matters).  For a correct translator every case must (except `reject`-tagged controls,
which a correct translator must refuse):
  translate OK (both stages)  ->  glCompileShader OK (both)  ->  glLinkProgram OK.
A case tagged `loc0` must additionally bind the ES 1.00 `gl_FragColor` replacement to fragment output location 0.

Case tuple: (name, vertex_es | None, fragment_es | None, tags)
None means "use the minimal pass-through shader of that stage" (ES 1.00 below).
"""

VS100 = """attribute vec4 aPos;
void main() { gl_Position = aPos; }
"""
FS100 = """precision mediump float;
void main() { gl_FragColor = vec4(1.0); }
"""
VS300 = """#version 300 es
in vec4 aPos;
void main() { gl_Position = aPos; }
"""
FS300 = """#version 300 es
precision mediump float;
out vec4 o;
void main() { o = vec4(1.0); }
"""


def es1_ident_case(word):
    """A valid ES 1.00 shader that uses `word` as an ordinary identifier (it is not an ES 1.00 keyword)."""
    fs = ("precision mediump float;\nuniform float u;\n"
          "void main() {\n  float %s = u;\n  gl_FragColor = vec4(%s);\n}\n" % (word, word))
    return ("es100_ident_" + word, None, fs, set())


# Identifiers that are legal in GLSL ES 1.00 (not keywords, not reserved, not built-ins there) but are keywords,
# reserved words or built-in names in desktop GLSL 4.10.
ES1_IDENTS = ["sample", "smooth", "noperspective", "patch", "subroutine", "layout", "centroid", "uint",
              "case", "precise", "common", "partition", "active", "filter", "resource", "buffer", "shared",
              "texture", "round", "inverse", "transpose", "row_major", "isampler2D", "usampler2D",
              "sampler2DArray", "samplerBuffer", "mat2x3", "uvec2", "dmat2", "coherent", "readonly"]

CASES = [
    # ---------------- controls: plain real-world shaders ----------------
    ("ctl_es100_basic", """precision highp float;
attribute vec3 position;
attribute vec2 uv;
uniform mat4 modelViewMatrix, projectionMatrix;
varying vec2 vUv;
void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }
""", """precision mediump float;
uniform sampler2D map;
uniform vec3 diffuse;
varying vec2 vUv;
void main() { vec4 t = texture2D(map, vUv); gl_FragColor = vec4(diffuse * t.rgb, t.a); }
""", {"loc0"}),
    ("ctl_es300_basic", """#version 300 es
layout(location = 0) in vec3 position;
layout(location = 1) in vec2 uv;
uniform mat4 mvp;
out vec2 vUv;
flat out int vId;
void main() { vUv = uv; vId = gl_VertexID; gl_Position = mvp * vec4(position, 1.0); }
""", """#version 300 es
precision highp float;
precision highp sampler2DArray;
precision mediump isampler2D;
precision highp usampler3D;
uniform sampler2DArray layers;
uniform isampler2D ids;
uniform usampler3D vol;
in vec2 vUv;
flat in int vId;
layout(location = 0) out vec4 fragColor;
void main() {
  ivec4 a = texelFetch(ids, ivec2(0), 0);
  uvec4 b = texture(vol, vec3(vUv, 0.0));
  fragColor = texture(layers, vec3(vUv, float(vId))) + vec4(a) + vec4(b);
}
""", set()),
    ("ctl_es300_std140_block", """#version 300 es
layout(std140) uniform Camera { mat4 view; mat4 proj; } cam;
in vec4 p;
out VsData { vec2 uv; } dummy_never_used_in_es3;
void main() { gl_Position = cam.proj * cam.view * p; }
""".replace("out VsData { vec2 uv; } dummy_never_used_in_es3;\n", ""), None, set()),
    ("ctl_es300_arrays_two_spellings", """#version 300 es
uniform vec4 a[4];
uniform vec4[4] b;
in vec4 p;
void main() { gl_Position = p + a[1] + b[2]; }
""", None, set()),

    # ---------------- texture builtin rewrites ----------------
    ("tex_es100_all_frag_builtins", None, """#extension GL_EXT_shader_texture_lod : enable
#extension GL_OES_standard_derivatives : enable
precision mediump float;
uniform sampler2D s; uniform samplerCube c;
varying vec2 v;
void main() {
  vec4 a = texture2D(s, v) + texture2D(s, v, 0.5) + texture2DProj(s, vec3(v, 1.0)) + texture2DProj(s, vec4(v, 0.0, 1.0));
  a += textureCube(c, vec3(v, 1.0)) + textureCube(c, vec3(v, 1.0), 1.0);
  a += texture2DLodEXT(s, v, 1.0) + textureCubeLodEXT(c, vec3(v, 1.0), 1.0) + texture2DProjLodEXT(s, vec3(v, 1.0), 0.0);
  a += texture2DGradEXT(s, v, dFdx(v), dFdy(v)) + textureCubeGradEXT(c, vec3(v, 1.0), vec3(0.0), vec3(0.0));
  gl_FragColor = a + vec4(fwidth(v.x));
}
""", {"loc0"}),
    ("tex_es100_vertex_lod_builtins", """attribute vec2 p;
uniform sampler2D hm; uniform samplerCube env;
varying vec4 vc;
void main() {
  vc = texture2DLod(hm, p, 0.0) + textureCubeLod(env, vec3(p, 1.0), 0.0) + texture2DProjLod(hm, vec3(p, 1.0), 0.0) + texture2DProjLod(hm, vec4(p, 0.0, 1.0), 0.0);
  gl_Position = vec4(p, 0.0, 1.0);
}
""", """precision mediump float;
varying vec4 vc;
void main() { gl_FragColor = vc; }
""", set()),
    ("tex_es100_multiline_nested_call", None, """precision mediump float;
uniform sampler2D s;
varying vec2 v;
vec2 warp(vec2 x) { return x * 0.5; }
void main() {
  gl_FragColor = texture2D
  (
    s,
    warp(texture2D(s, warp(v)).xy)
  );
}
""", {"loc0"}),
    ("tex_es100_define_function_like", None, """precision mediump float;
#define SAMPLE(t, uv) texture2D(t, uv)
#define BLUR(t, uv) (SAMPLE(t, uv) + SAMPLE(t, uv + 0.01)) * 0.5
uniform sampler2D s;
varying vec2 v;
void main() { gl_FragColor = BLUR(s, v); }
""", {"loc0"}),
    ("tex_es100_global_initializer_ok", None, """precision mediump float;
uniform sampler2D s;
const float K = 2.0;
void main() { vec4 c = texture2D(s, vec2(K)); gl_FragColor = c; }
""", {"loc0"}),
    ("tex_es100_shadow_ext", None, """#extension GL_EXT_shadow_samplers : require
precision mediump float;
uniform sampler2DShadow sm;
varying vec3 v;
void main() { gl_FragColor = vec4(shadow2DEXT(sm, v)); }
""", {"loc0"}),
    ("tex_es100_texture3D_oes", None, """#extension GL_OES_texture_3D : enable
precision mediump float;
uniform mediump sampler3D vol;
varying vec3 v;
void main() { gl_FragColor = texture3D(vol, v); }
""", {"loc0"}),

    # ---------------- gl_FragColor / gl_FragData ----------------
    ("frag_es100_mrt_ifdef_else", None, """#extension GL_EXT_draw_buffers : require
precision mediump float;
varying vec2 v;
void main() {
#ifdef USE_MRT
  gl_FragData[0] = vec4(v, 0.0, 1.0);
  gl_FragData[1] = vec4(1.0);
#else
  gl_FragColor = vec4(v, 0.0, 1.0);
#endif
}
""", {"loc0"}),
    ("frag_es100_fragdata_dynamic_plus_fragcolor_ifdef", None, """#extension GL_EXT_draw_buffers : require
precision mediump float;
uniform int n;
void main() {
#ifdef MRT
  for (int i = 0; i < 4; i++) { if (i < n) gl_FragData[i] = vec4(float(i)); }
#else
  gl_FragColor = vec4(1.0);
#endif
}
""", {"loc0"}),
    ("frag_es100_fragdata_define_index", None, """#extension GL_EXT_draw_buffers : require
precision mediump float;
#define NORMAL_TARGET 2
void main() { gl_FragData[0] = vec4(1.0); gl_FragData[NORMAL_TARGET] = vec4(0.5); }
""", set()),
    ("frag_es100_fragdata_const_expr_index", None, """#extension GL_EXT_draw_buffers : require
precision mediump float;
void main() { gl_FragData[0] = vec4(1.0); gl_FragData[1 + 1] = vec4(0.5); }
""", set()),
    ("frag_es100_fragcolor_in_macro_assign", None, """precision mediump float;
#define OUTPUT(c) gl_FragColor=(c)
void main() { OUTPUT(vec4(1.0)); }
""", {"loc0"}),
    ("frag_es100_fragcolor_in_macro_paren", None, """precision mediump float;
#define FRAG (gl_FragColor)
void main() { FRAG = vec4(1.0); }
""", {"loc0"}),
    ("frag_es100_fragdata_in_macro", None, """#extension GL_EXT_draw_buffers : require
precision mediump float;
#define OUT0 gl_FragData[0]
#define OUT1 gl_FragData[1]
void main() { OUT0 = vec4(1.0); OUT1 = vec4(0.0); }
""", set()),
    ("frag_es100_fragcolor_in_helper_fn", None, """precision mediump float;
void writeColor(vec4 c) { gl_FragColor = c; }
void main() { writeColor(vec4(1.0)); }
""", {"loc0"}),
    ("frag_es100_fragcolor_read_back", None, """precision mediump float;
void main() { gl_FragColor = vec4(0.5); gl_FragColor.rgb *= gl_FragColor.a; }
""", {"loc0"}),
    ("frag_es100_frag_depth_ext", None, """#extension GL_EXT_frag_depth : enable
precision mediump float;
varying float d;
void main() { gl_FragDepthEXT = d; gl_FragColor = vec4(1.0); }
""", {"loc0"}),
    ("frag_es100_user_ident_prefix_collision", None, """precision mediump float;
uniform vec4 _fv_gl_FragColor;
void main() { gl_FragColor = _fv_gl_FragColor; }
""", {"loc0"}),
    ("frag_es100_macro_type_in_signature", None, """precision mediump float;
#define PREC highp
uniform sampler2D s;
varying vec2 v;
PREC vec4 sampleIt(vec2 uv) { return texture2D(s, uv); }
void main() { gl_FragColor = sampleIt(v); }
""", {"loc0"}),
    ("frag_es100_macro_declared_function", None, """precision mediump float;
#define DECL_GETTER(name, val) vec4 name() { return val; }
uniform sampler2D s;
DECL_GETTER(white, vec4(1.0))
void main() { gl_FragColor = white() * texture2D(s, vec2(0.5)); }
""", {"loc0"}),

    # ---------------- varying linkage ----------------
    ("link_es100_qualified_varyings", """attribute vec4 p;
invariant varying highp vec3 vNormal;
varying mediump vec2 vUv;
varying lowp vec4 vColor;
varying mat4 vMat;
varying vec3 vArr[4];
invariant gl_Position;
void main() {
  vNormal = p.xyz; vUv = p.xy; vColor = p; vMat = mat4(1.0);
  for (int i = 0; i < 4; i++) vArr[i] = p.xyz;
  gl_Position = p;
}
""", """precision mediump float;
invariant varying highp vec3 vNormal;
varying mediump vec2 vUv;
varying lowp vec4 vColor;
varying mat4 vMat;
varying vec3 vArr[4];
void main() { gl_FragColor = vec4(vNormal + vArr[3], 1.0) * vColor * vMat[0] + vec4(vUv, 0.0, 0.0); }
""", {"loc0"}),
    ("link_es100_varying_via_define", """#define VARYING varying
attribute vec4 p;
VARYING vec2 vUv;
void main() { vUv = p.xy; gl_Position = p; }
""", """precision mediump float;
#define VARYING varying
VARYING vec2 vUv;
void main() { gl_FragColor = vec4(vUv, 0.0, 1.0); }
""", {"loc0"}),
    ("link_es300_threejs_webgl2_prelude", """#version 300 es
#define attribute in
#define varying out
#define texture2D texture
precision highp float;
attribute vec3 position;
varying vec2 vUv;
void main() { vUv = position.xy; gl_Position = vec4(position, 1.0); }
""", """#version 300 es
#define varying in
layout(location = 0) out highp vec4 pc_fragColor;
#define gl_FragColor pc_fragColor
#define texture2D texture
precision highp float;
uniform sampler2D map;
varying vec2 vUv;
void main() { gl_FragColor = texture2D(map, vUv); }
""", set()),
    ("link_es300_interp_qualifiers", """#version 300 es
in vec4 p;
flat out int id;
smooth out vec2 a;
centroid out vec2 b;
invariant out vec3 c;
void main() { id = 1; a = p.xy; b = p.zw; c = p.xyz; gl_Position = p; }
""", """#version 300 es
precision mediump float;
flat in int id;
smooth in vec2 a;
centroid in vec2 b;
invariant in vec3 c;
out vec4 o;
void main() { o = vec4(a, b) + vec4(c, float(id)); }
""", set()),

    # ---------------- ES 3.00 traps ----------------
    ("es300_version_after_comment_and_blank", "\n// leading comment\n/* block */\n#version 300 es\nin vec4 p;\nvoid main(){gl_Position=p;}\n",
     None, set()),
    ("es300_multiline_precision", None, """#version 300 es
precision
  highp
  float
;
out vec4 o;
void main() { o = vec4(1.0); }
""", set()),
    ("es300_pack_half", None, """#version 300 es
precision highp float;
uniform vec4 v;
out vec4 o;
void main() {
  uint h = packHalf2x16(v.xy);
  uint s = packSnorm2x16(v.zw);
  o = vec4(unpackHalf2x16(h), unpackSnorm2x16(s));
}
""", set()),
    ("es300_pack_unorm", None, """#version 300 es
precision highp float;
uniform vec4 v;
out vec4 o;
void main() { uint u = packUnorm2x16(v.xy); o = vec4(unpackUnorm2x16(u), 0.0, 1.0); }
""", set()),
    ("es300_ident_precise", None, """#version 300 es
precision mediump float;
uniform float u;
out vec4 o;
void main() { float precise = u; o = vec4(precise); }
""", set()),
    ("es300_uniform_struct_and_multi_decl", """#version 300 es
struct Light { vec3 pos; vec3 color; };
uniform Light lights[2];
uniform struct Mat { float r; } mat;
uniform vec3 a, b[2], c;
in vec4 p;
void main() { gl_Position = p + vec4(lights[1].pos + a + b[1] + c, mat.r); }
""", None, set()),
    # control: a BOM outside comments is outside the GLSL ES character set; WebGL rejects it too -> must reject
    ("ctl_es300_bom_rejected", "\ufeff#version 300 es\nin vec4 p;\nvoid main(){gl_Position=p;}\n", None, {"reject"}),

    # ---------------- preprocessor structure ----------------
    ("pp_es100_ifdef_split_braces", """attribute vec4 p;
#ifdef FLIP
void main() { gl_Position = -p;
#else
void main() { gl_Position = p;
#endif
}
""", None, set()),
    ("pp_es100_single_source_uber_shader", """#define VERTEX
#ifdef VERTEX
attribute vec4 p;
void main() { gl_Position = p; }
#else
precision mediump float;
void main() { gl_FragColor = vec4(1.0); }
#endif
""", None, set()),
    ("pp_es100_extension_after_decl", None, """precision mediump float;
uniform float u;
#extension GL_OES_standard_derivatives : enable
void main() { gl_FragColor = vec4(dFdx(u)); }
""", {"loc0"}),
    ("pp_line_continuation_in_ident", None, """#version 300 es
precision mediump float;
out vec4 frag\\
Color;
void main() { fragColor = vec4(1.0); }
""", set()),
    ("pp_line_continuation_in_version", "#ver\\\nsion 300 es\nin vec4 p;\nvoid main(){gl_Position=p;}\n", None, set()),

    # ---------------- user functions overloading 410 built-ins (glslify modules, WebGL1 polyfills) -----------
    ("es100_user_inverse_transpose", """attribute vec4 p;
uniform mat3 m;
mat3 transpose(mat3 m) { return mat3(m[0][0], m[1][0], m[2][0], m[0][1], m[1][1], m[2][1], m[0][2], m[1][2], m[2][2]); }
float round(float x) { return floor(x + 0.5); }
void main() { gl_Position = vec4(transpose(m) * p.xyz, round(p.w)); }
""", None, set()),
]

CASES += [
    ("es100_uniform_named_texture", None, """precision mediump float;
uniform sampler2D texture;
varying vec2 v;
void main() { gl_FragColor = texture2D(texture, v); }
""", {"loc0"}),
    ("frag_es100_fragdata7_plus_fragcolor_ifdef", None, """#extension GL_EXT_draw_buffers : require
precision mediump float;
void main() {
#ifdef MRT
  gl_FragData[7] = vec4(1.0);
#else
  gl_FragColor = vec4(1.0);
#endif
}
""", {"loc0"}),
    ("frag_es100_fragdata0_plus_fragcolor_decl_order", None, """#extension GL_EXT_draw_buffers : require
precision mediump float;
void main() {
#if 0
  gl_FragData[0] = vec4(0.0);
#endif
  gl_FragColor = vec4(1.0);
}
""", {"loc0"}),
]

CASES += [es1_ident_case(w) for w in ES1_IDENTS]
