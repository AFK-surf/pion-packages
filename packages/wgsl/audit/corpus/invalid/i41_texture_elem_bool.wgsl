// Sampled texture element type must be f32/i32/u32.
@group(0) @binding(0) var t : texture_2d<bool>;
@compute @workgroup_size(1) fn cs_main() { }
