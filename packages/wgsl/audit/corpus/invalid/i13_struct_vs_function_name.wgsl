// A struct and a function may not share a name.
struct S { x : f32 }
fn S() { }
@compute @workgroup_size(1) fn cs_main() { }
