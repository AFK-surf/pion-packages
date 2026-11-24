// `continue` is not allowed inside a `continuing` block.
@compute @workgroup_size(1) fn cs_main() { loop { continuing { continue; } } }
