// Function-scope `var` must use the function address space.
@compute @workgroup_size(1) fn cs_main() { var<workgroup> x : f32; }
