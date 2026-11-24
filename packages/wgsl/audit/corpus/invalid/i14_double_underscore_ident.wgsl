// Identifiers must not start with two underscores.
@compute @workgroup_size(1) fn cs_main() { let __x = 1; }
