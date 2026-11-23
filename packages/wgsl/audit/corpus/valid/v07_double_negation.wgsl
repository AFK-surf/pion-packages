// `- -x` is double negation in WGSL; it must not become the C/MSL/GLSL pre-decrement `--x`.
@group(0) @binding(0) var<storage, read_write> o : array<i32>;
@compute @workgroup_size(1)
fn cs_main() {
  var x : i32 = o[0];
  let y = - -x;
  o[1] = y;
  o[2] = x;
}
