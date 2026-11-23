// Call to a function that is declared nowhere (resolves to a Metal builtin if passed through).
@compute @workgroup_size(1) fn cs_main() { discard_fragment(); }
