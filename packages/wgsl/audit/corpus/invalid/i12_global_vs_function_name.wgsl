// A module-scope variable and a function may not share a name.
var<private> f : f32;
fn f() { }
@compute @workgroup_size(1) fn cs_main() { }
