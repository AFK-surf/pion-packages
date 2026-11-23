// A struct may not contain itself (infinite size).
struct A { x : f32, a : A }
@compute @workgroup_size(1) fn cs_main() { var v : A; }
