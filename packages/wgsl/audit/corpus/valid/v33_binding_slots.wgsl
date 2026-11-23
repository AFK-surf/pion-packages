// Valid WGSL bindings whose `group * 8 + binding` slots exceed Metal limits (buffer <= 30, sampler <= 15).
@group(3) @binding(31) var<storage, read_write> c : array<f32>;
@group(2) @binding(0) var s : sampler;
@group(2) @binding(1) var t : texture_2d<f32>;
@compute @workgroup_size(1)
fn cs_main() {
  c[0] = textureSampleLevel(t, s, vec2<f32>(0.0), 0.0).x;
}
