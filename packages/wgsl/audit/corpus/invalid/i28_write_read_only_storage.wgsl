// Writing to a read-only storage buffer.
@group(0) @binding(0) var<storage, read> o : array<f32>;
@compute @workgroup_size(1) fn cs_main() { o[0] = 1.0; }
