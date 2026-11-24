// Relational operators are non-associative in WGSL.
@compute @workgroup_size(1) fn cs_main() { let a = 1; let b = a < a < a; }
