// Canonical `loop`/`continue`/`continuing` counter loop. Terminates in WGSL (i reaches 10);
// if `continue` skips the continuing block the loop never terminates (GPU hang).
@group(0) @binding(0) var<storage, read_write> o : array<u32>;
@compute @workgroup_size(1)
fn cs_main() {
  var i : u32 = 0u;
  var odd : u32 = 0u;
  loop {
    if i % 2u == 0u {
      continue;
    }
    odd = odd + 1u;
    continuing {
      i = i + 1u;
      break if i >= 10u;
    }
  }
  o[0] = odd;
}
