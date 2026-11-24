// Declared WGSL identifiers that collide with Metal/GLSL predefined macros.
const M_PI_F : f32 = 3.0;
const FLT_MAX : f32 = 1.0;
const GL_ES : f32 = 2.0;
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1)
fn cs_main() {
  let INFINITY = 1.0;
  o[0] = M_PI_F + FLT_MAX + GL_ES + INFINITY;
}
