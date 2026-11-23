// Pointer parameters into function and private memory; writes through them must be visible to the caller.
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
var<private> acc : f32;
fn bump(p : ptr<function, f32>) { *p = *p + 1.0; }
fn bump_private(p : ptr<private, f32>) { *p = *p + 2.0; }
@compute @workgroup_size(1)
fn cs_main() {
  var v : f32 = 1.0;
  bump(&v);
  bump_private(&acc);
  o[0] = v + acc;
}
