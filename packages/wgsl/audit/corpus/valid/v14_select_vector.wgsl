// select with a vector condition, and select argument order.
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1)
fn cs_main() {
  let f = vec2<f32>(1.0, 2.0);
  let t = vec2<f32>(10.0, 20.0);
  let r = select(f, t, vec2<bool>(true, false));
  o[0] = r.x;
  o[1] = r.y;
  o[2] = select(5.0, 7.0, o[3] > 0.0);
}
