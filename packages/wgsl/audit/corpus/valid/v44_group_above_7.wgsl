// WGSL places no upper bound of 7 on @group or 31 on @binding (device limits are a pipeline concern).
@group(8) @binding(40) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1)
fn cs_main() {
  o[0] = 1.0;
}
