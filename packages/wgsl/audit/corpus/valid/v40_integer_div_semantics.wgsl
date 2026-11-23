// WGSL defines integer x/0 == x and x%0 == 0 (no UB), and INT_MIN / -1 == INT_MIN.
@group(0) @binding(0) var<storage, read_write> o : array<i32>;
@compute @workgroup_size(1)
fn cs_main() {
  let a = o[0];
  let z = o[1];
  o[2] = a / z;
  o[3] = a % z;
}
