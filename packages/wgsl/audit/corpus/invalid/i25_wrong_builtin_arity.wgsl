// Builtin called with the wrong number of arguments.
@compute @workgroup_size(1) fn cs_main() { let d = dot(vec3<f32>(1.0)); }
