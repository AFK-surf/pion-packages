// WGSL zero-initialises function, private and workgroup variables.
var<private> pv : u32;
var<workgroup> wv : u32;
@group(0) @binding(0) var<storage, read_write> o : array<u32>;
@compute @workgroup_size(1)
fn cs_main() {
  var fv : u32;
  var arr : array<u32, 4>;
  o[0] = fv + pv + wv + arr[3];
}
