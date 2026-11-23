// (group 0, binding 8) and (group 1, binding 0) are distinct WGSL resources but both map to Metal slot 8.
@group(0) @binding(8) var<storage, read_write> a : array<f32>;
@group(1) @binding(0) var<storage, read_write> b : array<f32>;
@compute @workgroup_size(1)
fn cs_main() {
  a[0] = 1.0;
  b[0] = 2.0;
}
