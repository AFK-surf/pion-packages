// bitcast between vector types and between i32/f32.
@group(0) @binding(0) var<storage, read_write> o : array<u32>;
@compute @workgroup_size(1)
fn cs_main() {
  let f = vec2<f32>(1.0, -2.0);
  let bits = bitcast<vec2<u32>>(f);
  o[0] = bits.x;
  let i : i32 = -1;
  o[1] = bitcast<u32>(i);
  o[2] = bitcast<u32>(bitcast<f32>(i));
}
