// Fragment outputs other than color 0: frag_depth and location(1).
struct FsOut { @location(1) color : vec4<f32>, @builtin(frag_depth) depth : f32 }
@fragment
fn fs_a(@builtin(position) p : vec4<f32>, @builtin(front_facing) ff : bool) -> @builtin(frag_depth) f32 {
  return p.z;
}
@fragment
fn fs_b(@location(0) @interpolate(flat) id : u32) -> FsOut {
  var o : FsOut;
  o.color = vec4<f32>(f32(id));
  o.depth = 0.5;
  return o;
}
@fragment
fn fs_c() -> @location(1) vec4<f32> {
  return vec4<f32>(1.0);
}
