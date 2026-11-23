// `1f` / `2h`-style suffixed decimal literals without a dot are valid WGSL floats.
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1)
fn cs_main() {
  o[0] = 1f / 2f;
  o[1] = 3f;
}
