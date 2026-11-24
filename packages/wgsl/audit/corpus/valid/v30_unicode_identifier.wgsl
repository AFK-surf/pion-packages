// WGSL identifiers are Unicode XID (spec 3.5).
@compute @workgroup_size(1)
fn cs_main() {
  let größe = 1.0;
  let 長さ = größe * 2.0;
}
