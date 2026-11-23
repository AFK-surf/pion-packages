// Unknown access mode.
@group(0) @binding(0) var<storage, write_only> o : array<f32>;
@compute @workgroup_size(1) fn cs_main() { }
