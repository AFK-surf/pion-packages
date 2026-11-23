// An attribute may appear at most once on a declaration.
@group(0) @group(1) @binding(0) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1) fn cs_main() { o[0] = 1.0; }
