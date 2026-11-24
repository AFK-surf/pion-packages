// @binding(2^32) is out of range; it must not wrap to binding 0.
@group(0) @binding(4294967296) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1) fn cs_main() { o[0] = 1.0; }
