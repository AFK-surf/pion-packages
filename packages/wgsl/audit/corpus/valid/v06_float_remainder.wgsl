// `%` is defined on f32 in WGSL (truncated remainder).
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1)
fn cs_main() {
  let a = o[0];
  o[1] = a % 2.5;
  let v = vec2<f32>(a, a) % vec2<f32>(1.5, 2.0);
  o[2] = v.x;
}
