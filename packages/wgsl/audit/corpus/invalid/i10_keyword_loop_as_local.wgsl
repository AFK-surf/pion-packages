// WGSL keywords cannot be identifiers.
@compute @workgroup_size(1) fn cs_main() { var loop : f32 = 1.0; }
