// vec2 of a vector is not a type.
var<private> v : vec2<vec2<f32>>;
@compute @workgroup_size(1) fn cs_main() { }
