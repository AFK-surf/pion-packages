// Vector element type must be a scalar.
var<private> v : vec3<not_a_type>;
@compute @workgroup_size(1) fn cs_main() { }
