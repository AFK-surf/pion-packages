// A vertex/fragment pair whose varyings must link (struct out of VS, struct in of FS).
struct V { @builtin(position) pos : vec4<f32>, @location(0) uv : vec2<f32>, @location(1) @interpolate(flat) id : u32 }
@vertex
fn vs_main(@builtin(vertex_index) vi : u32) -> V {
  var v : V;
  v.pos = vec4<f32>(0.0, 0.0, 0.0, 1.0);
  v.uv = vec2<f32>(f32(vi), 0.0);
  v.id = vi;
  return v;
}
@fragment
fn fs_main(v : V) -> @location(0) vec4<f32> {
  return vec4<f32>(v.uv, f32(v.id), v.pos.w);
}
