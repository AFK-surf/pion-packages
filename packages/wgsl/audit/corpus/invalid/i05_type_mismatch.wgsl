// Initializer type does not match the declared type.
@compute @workgroup_size(1) fn cs_main() { let x : f32 = true; }
