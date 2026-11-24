// Decimal integer literals may not have leading zeros.
@compute @workgroup_size(1) fn cs_main() { let x = 0123; }
