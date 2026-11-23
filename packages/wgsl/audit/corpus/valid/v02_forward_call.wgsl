// WGSL allows calling a function declared later in the module.
@compute @workgroup_size(1)
fn cs_main() {
  let x = helper(2.0);
}
fn helper(v : f32) -> f32 {
  return v * 2.0;
}
