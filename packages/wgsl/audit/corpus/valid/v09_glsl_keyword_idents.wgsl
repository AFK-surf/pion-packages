// Identifiers that are legal in WGSL but keywords in GLSL (`in`, `out`, `uniform`, `buffer`, `sample`, `input`).
struct VsOut { @builtin(position) pos : vec4<f32>, @location(0) col : vec4<f32> }
@vertex
fn vs_main(@location(0) uniform : vec4<f32>) -> VsOut {
  var out : VsOut;
  out.pos = uniform;
  out.col = vec4<f32>(1.0);
  return out;
}
@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
  let sample = in.col;
  let buffer = sample * 0.5;
  return buffer;
}
