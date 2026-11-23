// Matrix construction, column indexing, transpose and mat*vec.
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1)
fn cs_main() {
  let m = mat3x3<f32>(vec3<f32>(1.0, 2.0, 3.0), vec3<f32>(4.0, 5.0, 6.0), vec3<f32>(7.0, 8.0, 9.0));
  let n = mat2x2f(1.0, 2.0, 3.0, 4.0);
  let v = m * vec3<f32>(1.0, 0.0, 0.0);
  let t = transpose(m);
  o[0] = v.y + m[1][2] + t[0][1] + n[1].x;
  var mm = m;
  mm[2] = vec3<f32>(0.0);
  o[1] = mm[2].z;
}
