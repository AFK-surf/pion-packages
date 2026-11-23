// Undeclared names that only exist in Metal (macro `M_PI_F`, builtin `simd_sum`) must be rejected,
// not passed through to the target compiler.
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1) fn cs_main() { o[0] = M_PI_F + simd_sum(o[1]); }
