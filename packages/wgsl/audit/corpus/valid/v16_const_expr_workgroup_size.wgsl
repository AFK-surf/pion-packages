// @workgroup_size from const expressions and an override.
const TILE : u32 = 8u;
const WG = TILE * 8u;
@compute @workgroup_size(WG, 1, 1)
fn cs_main(@builtin(local_invocation_index) li : u32) {
}
