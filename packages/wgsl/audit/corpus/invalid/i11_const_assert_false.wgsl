// A failing const_assert must reject the module.
const_assert 1 > 2;
@compute @workgroup_size(1) fn cs_main() { }
