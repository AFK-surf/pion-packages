// `continue` inside `loop` must run the `continuing` block (WGSL spec 9.4.6): expected o[0]=3, o[1]=4.
@group(0) @binding(0) var<storage, read_write> o : array<u32>;
@compute @workgroup_size(1)
fn cs_main() {
  var i : u32 = 0u;
  var j : u32 = 0u;
  var hits : u32 = 0u;
  loop {
    j = j + 1u;
    if j == 2u {
      continue;
    }
    hits = hits + 1u;
    continuing {
      i = i + 1u;
      break if j >= 4u;
    }
  }
  o[0] = hits;
  o[1] = i;
}
