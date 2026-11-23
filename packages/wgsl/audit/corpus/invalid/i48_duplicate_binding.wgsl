// Two resources at the same group/binding used by one entry point.
@group(0) @binding(0) var<storage, read_write> a : array<f32>;
@group(0) @binding(0) var<storage, read_write> b : array<f32>;
@compute @workgroup_size(1) fn cs_main() { a[0] = b[0]; }
