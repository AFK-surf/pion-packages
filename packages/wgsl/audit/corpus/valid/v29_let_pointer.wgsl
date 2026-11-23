// let-bound pointers and (*p).field access.
struct P { x : f32, y : f32 }
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1)
fn cs_main() {
  var p : P;
  let ptr_p = &p;
  (*ptr_p).x = 3.0;
  let px = &(*ptr_p).y;
  *px = 4.0;
  o[0] = p.x + p.y;
}
