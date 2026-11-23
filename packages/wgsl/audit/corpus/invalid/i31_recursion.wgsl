// WGSL forbids recursion.
fn f(x : i32) -> i32 { return f(x - 1); }
@compute @workgroup_size(1) fn cs_main() { let y = f(3); }
