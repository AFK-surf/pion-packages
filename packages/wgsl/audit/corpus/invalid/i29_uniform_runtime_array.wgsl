// Uniform buffers cannot contain runtime-sized arrays.
@group(0) @binding(0) var<uniform> u : array<vec4<f32>>;
@compute @workgroup_size(1) fn cs_main() { }
