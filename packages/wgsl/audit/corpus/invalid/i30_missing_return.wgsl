// A function with a return type must return on every path.
fn f(x : f32) -> f32 { if x > 0.0 { return 1.0; } }
@compute @workgroup_size(1) fn cs_main() { let y = f(1.0); }
