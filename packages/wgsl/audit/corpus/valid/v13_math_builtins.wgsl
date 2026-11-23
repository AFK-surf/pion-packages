// Numeric builtins with no 1:1 spelling in MSL/GLSL.
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
@group(0) @binding(1) var<storage, read_write> u : array<u32>;
@compute @workgroup_size(1)
fn cs_main() {
  let x = o[0];
  o[1] = degrees(x) + radians(x);
  o[2] = round(x);
  o[3] = quantizeToF16(x);
  let m = modf(x);
  o[4] = m.fract + m.whole;
  let fr = frexp(x);
  o[5] = fr.fract + f32(fr.exp);
  o[6] = ldexp(x, 2);
  u[0] = extractBits(u[1], 2u, 3u);
  u[2] = insertBits(u[1], 5u, 4u, 3u);
  u[3] = firstLeadingBit(u[1]) + firstTrailingBit(u[1]) + countLeadingZeros(u[1]);
  o[7] = determinant(mat2x2<f32>(1.0, 2.0, 3.0, 4.0));
  o[8] = faceForward(vec3<f32>(1.0), vec3<f32>(x), vec3<f32>(1.0)).x;
  o[9] = atan2(x, 1.0) + sinh(x) + inverseSqrt(x) + fma(x, x, x) + saturate(x) + sign(x) + trunc(x);
}
