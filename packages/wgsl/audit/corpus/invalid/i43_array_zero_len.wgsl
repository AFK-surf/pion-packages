// Fixed-size arrays need a positive length.
var<private> a : array<f32, 0>;
@compute @workgroup_size(1) fn cs_main() { }
