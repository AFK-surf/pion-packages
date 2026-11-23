// WGSL keywords cannot be identifiers.
var<private> fn : f32;
@compute @workgroup_size(1) fn cs_main() { }
