// `let` bindings are immutable.
@compute @workgroup_size(1) fn cs_main() { let x = 1; x = 2; }
