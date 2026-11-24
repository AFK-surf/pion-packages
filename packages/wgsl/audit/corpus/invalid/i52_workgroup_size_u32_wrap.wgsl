// @workgroup_size(2^32 + 1) is out of range; it must not wrap to 1.
@compute @workgroup_size(4294967297) fn cs_main() { }
