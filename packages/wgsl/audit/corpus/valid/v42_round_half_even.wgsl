// WGSL round() rounds half to even: round(2.5) == 2.0, round(-1.5) == -2.0, round(0.5) == 0.0.
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1)
fn cs_main() {
  o[1] = round(o[0]);
  o[2] = round(o[0] - 4.0);
  o[3] = round(o[0] - 2.0);
}
