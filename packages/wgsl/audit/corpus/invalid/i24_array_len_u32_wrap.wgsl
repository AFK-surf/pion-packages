// array length 2^32 + 1 is out of range; it must not wrap to 1.
var<private> a : array<f32, 4294967297>;
@compute @workgroup_size(1) fn cs_main() { a[0] = 1.0; }
