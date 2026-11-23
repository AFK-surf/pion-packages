// Mutually recursive structs.
struct A { b : B }
struct B { a : A }
@compute @workgroup_size(1) fn cs_main() { var v : A; }
