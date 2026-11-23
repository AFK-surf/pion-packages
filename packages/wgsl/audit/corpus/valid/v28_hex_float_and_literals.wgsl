// Hexadecimal floats and exponent forms.
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1)
fn cs_main() {
  o[0] = 0x1p3;
  o[1] = 0x1.8p1f;
  o[2] = 1e-3;
  o[3] = .5;
  o[4] = 2.;
}
