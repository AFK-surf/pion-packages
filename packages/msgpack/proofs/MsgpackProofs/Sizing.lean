import MsgpackProofs.Core

open Aeneas Aeneas.Std Result Pion msgpack

namespace MsgpackProofs

/-- MessagePack spec: exact 5-tier canonical unsigned integer encoded size. -/
theorem uint_encoded_size_spec (u : Std.U64) :
    (u.val ≤ 127 → uint_encoded_size u = ok 1#i64) ∧
    (128 ≤ u.val ∧ u.val ≤ 255 → uint_encoded_size u = ok 2#i64) ∧
    (256 ≤ u.val ∧ u.val ≤ 65535 → uint_encoded_size u = ok 3#i64) ∧
    (65536 ≤ u.val ∧ u.val ≤ 4294967295 → uint_encoded_size u = ok 5#i64) ∧
    (4294967296 ≤ u.val → uint_encoded_size u = ok 9#i64) := by
  have h127 := u64_127_val
  have h255 := u64_255_val
  have h65535 := u64_65535_val
  have hu32 := u64_u32max_val
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · intro h; unfold uint_encoded_size
    have c1 : u ≤ 127#u64 := (uscalar_le_iff _ _).mpr (by omega)
    simp only [c1, ↓reduceIte]
  · intro h; unfold uint_encoded_size
    have c1 : ¬(u ≤ 127#u64) := fun hc => by have := (uscalar_le_iff _ _).mp hc; omega
    have c2 : u ≤ 255#u64 := (uscalar_le_iff _ _).mpr (by omega)
    simp only [c1, c2, ↓reduceIte]
  · intro h; unfold uint_encoded_size
    have c1 : ¬(u ≤ 127#u64) := fun hc => by have := (uscalar_le_iff _ _).mp hc; omega
    have c2 : ¬(u ≤ 255#u64) := fun hc => by have := (uscalar_le_iff _ _).mp hc; omega
    have c3 : u ≤ 65535#u64 := (uscalar_le_iff _ _).mpr (by omega)
    simp only [c1, c2, c3, ↓reduceIte]
  · intro h; unfold uint_encoded_size
    have c1 : ¬(u ≤ 127#u64) := fun hc => by have := (uscalar_le_iff _ _).mp hc; omega
    have c2 : ¬(u ≤ 255#u64) := fun hc => by have := (uscalar_le_iff _ _).mp hc; omega
    have c3 : ¬(u ≤ 65535#u64) := fun hc => by have := (uscalar_le_iff _ _).mp hc; omega
    have c4 : u ≤ 4294967295#u64 := (uscalar_le_iff _ _).mpr (by omega)
    simp only [c1, c2, c3, c4, ↓reduceIte]
  · intro h; unfold uint_encoded_size
    have c1 : ¬(u ≤ 127#u64) := fun hc => by have := (uscalar_le_iff _ _).mp hc; omega
    have c2 : ¬(u ≤ 255#u64) := fun hc => by have := (uscalar_le_iff _ _).mp hc; omega
    have c3 : ¬(u ≤ 65535#u64) := fun hc => by have := (uscalar_le_iff _ _).mp hc; omega
    have c4 : ¬(u ≤ 4294967295#u64) := fun hc => by have := (uscalar_le_iff _ _).mp hc; omega
    simp only [c1, c2, c3, c4, ↓reduceIte]

/-- `uint_encoded_size` always lies in `[1, 9]`. -/
theorem uint_encoded_size_bounds (u : Std.U64) :
    ∃ s : Std.I64, uint_encoded_size u = ok s ∧ 1 ≤ s.val ∧ s.val ≤ 9 := by
  obtain ⟨h1, h2, h3, h5, h9⟩ := uint_encoded_size_spec u
  by_cases c1 : u.val ≤ 127
  · exact ⟨1#i64, h1 c1, by norm_num, by norm_num⟩
  · by_cases c2 : u.val ≤ 255
    · exact ⟨2#i64, h2 ⟨by omega, c2⟩, by norm_num, by norm_num⟩
    · by_cases c3 : u.val ≤ 65535
      · exact ⟨3#i64, h3 ⟨by omega, c3⟩, by norm_num, by norm_num⟩
      · by_cases c4 : u.val ≤ 4294967295
        · exact ⟨5#i64, h5 ⟨by omega, c4⟩, by norm_num, by norm_num⟩
        · exact ⟨9#i64, h9 (by omega), by norm_num, by norm_num⟩

/-- `uint_encoded_size` is monotonically non-decreasing. -/
theorem uint_encoded_size_mono (a b : Std.U64) (sa sb : Std.I64)
    (hle : a.val ≤ b.val)
    (ha : uint_encoded_size a = ok sa) (hb : uint_encoded_size b = ok sb) :
    sa.val ≤ sb.val := by
  obtain ⟨a1, a2, a3, a5, a9⟩ := uint_encoded_size_spec a
  obtain ⟨b1, b2, b3, b5, b9⟩ := uint_encoded_size_spec b
  by_cases ca1 : a.val ≤ 127
  · have hsa : sa = 1#i64 := result_ok_inj (ha.symm.trans (a1 ca1))
    obtain ⟨s, hs, hs1, _⟩ := uint_encoded_size_bounds b
    have hsb : sb = s := result_ok_inj (hb.symm.trans hs)
    subst hsa; subst hsb; norm_num; omega
  · by_cases ca2 : a.val ≤ 255
    · have hsa : sa = 2#i64 := result_ok_inj (ha.symm.trans (a2 ⟨by omega, ca2⟩))
      subst hsa
      by_cases cb2 : b.val ≤ 255
      · have hsb := result_ok_inj (hb.symm.trans (b2 ⟨by omega, cb2⟩)); subst hsb; norm_num
      · by_cases cb3 : b.val ≤ 65535
        · have hsb := result_ok_inj (hb.symm.trans (b3 ⟨by omega, cb3⟩)); subst hsb; norm_num
        · by_cases cb4 : b.val ≤ 4294967295
          · have hsb := result_ok_inj (hb.symm.trans (b5 ⟨by omega, cb4⟩)); subst hsb; norm_num
          · have hsb := result_ok_inj (hb.symm.trans (b9 (by omega))); subst hsb; norm_num
    · by_cases ca3 : a.val ≤ 65535
      · have hsa : sa = 3#i64 := result_ok_inj (ha.symm.trans (a3 ⟨by omega, ca3⟩))
        subst hsa
        by_cases cb3 : b.val ≤ 65535
        · have hsb := result_ok_inj (hb.symm.trans (b3 ⟨by omega, cb3⟩)); subst hsb; norm_num
        · by_cases cb4 : b.val ≤ 4294967295
          · have hsb := result_ok_inj (hb.symm.trans (b5 ⟨by omega, cb4⟩)); subst hsb; norm_num
          · have hsb := result_ok_inj (hb.symm.trans (b9 (by omega))); subst hsb; norm_num
      · by_cases ca4 : a.val ≤ 4294967295
        · have hsa : sa = 5#i64 := result_ok_inj (ha.symm.trans (a5 ⟨by omega, ca4⟩))
          subst hsa
          by_cases cb4 : b.val ≤ 4294967295
          · have hsb := result_ok_inj (hb.symm.trans (b5 ⟨by omega, cb4⟩)); subst hsb; norm_num
          · have hsb := result_ok_inj (hb.symm.trans (b9 (by omega))); subst hsb; norm_num
        · have hsa : sa = 9#i64 := result_ok_inj (ha.symm.trans (a9 (by omega)))
          have hsb : sb = 9#i64 := result_ok_inj (hb.symm.trans (b9 (by omega)))
          subst hsa; subst hsb; norm_num

/-- For every non-negative `Int64`, `int_encoded_size` delegates identically to `uint_encoded_size`. -/
theorem int_encoded_size_nonneg_agrees_uint (v : Std.I64) (hnn : 0 ≤ v.val) :
    int_encoded_size v = uint_encoded_size (Pion.I64.to_uint64 v) := by
  unfold int_encoded_size
  have h0 : (0#i64).val = 0 := by norm_num
  have hge : v ≥ 0#i64 := (iscalar_le_iff 0#i64 v).mpr (by omega)
  simp only [hge, ↓reduceIte]
  obtain ⟨s, hs, _, _⟩ := uint_encoded_size_bounds (Pion.I64.to_uint64 v)
  rw [hs, result_bind_ok]

/-- MessagePack spec: exact 5-tier canonical negative integer encoded size. -/
theorem int_encoded_size_neg_spec (v : Std.I64) :
    (-32 ≤ v.val ∧ v.val < 0 → int_encoded_size v = ok 1#i64) ∧
    (-128 ≤ v.val ∧ v.val < -32 → int_encoded_size v = ok 2#i64) ∧
    (-32768 ≤ v.val ∧ v.val < -128 → int_encoded_size v = ok 3#i64) ∧
    (-2147483648 ≤ v.val ∧ v.val < -32768 → int_encoded_size v = ok 5#i64) ∧
    (v.val < -2147483648 → int_encoded_size v = ok 9#i64) := by
  have h0 : (0#i64).val = 0 := by norm_num
  have h32 : ((-32)#i64).val = -32 := by norm_num
  have h128 : ((-128)#i64).val = -128 := by norm_num
  have h32768 : ((-32768)#i64).val = -32768 := by norm_num
  have hi32min : ((-2147483648)#i64).val = -2147483648 := by
    change (BitVec.ofInt 64 (-2147483648)).toInt = -2147483648; rw [BitVec.toInt_ofInt]; norm_num
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · intro h; unfold int_encoded_size
    have c0 : ¬(v ≥ 0#i64) := fun hc => by have := (iscalar_le_iff 0#i64 v).mp hc; omega
    have c1 : v ≥ (-32)#i64 := (iscalar_le_iff _ _).mpr (by omega)
    simp only [c0, c1, ↓reduceIte]
  · intro h; unfold int_encoded_size
    have c0 : ¬(v ≥ 0#i64) := fun hc => by have := (iscalar_le_iff 0#i64 v).mp hc; omega
    have c1 : ¬(v ≥ (-32)#i64) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    have c2 : v ≥ (-128)#i64 := (iscalar_le_iff _ _).mpr (by omega)
    simp only [c0, c1, c2, ↓reduceIte]
  · intro h; unfold int_encoded_size
    have c0 : ¬(v ≥ 0#i64) := fun hc => by have := (iscalar_le_iff 0#i64 v).mp hc; omega
    have c1 : ¬(v ≥ (-32)#i64) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    have c2 : ¬(v ≥ (-128)#i64) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    have c3 : v ≥ (-32768)#i64 := (iscalar_le_iff _ _).mpr (by omega)
    simp only [c0, c1, c2, c3, ↓reduceIte]
  · intro h; unfold int_encoded_size
    have c0 : ¬(v ≥ 0#i64) := fun hc => by have := (iscalar_le_iff 0#i64 v).mp hc; omega
    have c1 : ¬(v ≥ (-32)#i64) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    have c2 : ¬(v ≥ (-128)#i64) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    have c3 : ¬(v ≥ (-32768)#i64) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    have c4 : v ≥ (-2147483648)#i64 := (iscalar_le_iff _ _).mpr (by omega)
    simp only [c0, c1, c2, c3, c4, ↓reduceIte]
  · intro h; unfold int_encoded_size
    have c0 : ¬(v ≥ 0#i64) := fun hc => by have := (iscalar_le_iff 0#i64 v).mp hc; omega
    have c1 : ¬(v ≥ (-32)#i64) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    have c2 : ¬(v ≥ (-128)#i64) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    have c3 : ¬(v ≥ (-32768)#i64) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    have c4 : ¬(v ≥ (-2147483648)#i64) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    simp only [c0, c1, c2, c3, c4, ↓reduceIte]

/-- `int_encoded_size` always lies in `[1, 9]` for all signed 64-bit integers. -/
theorem int_encoded_size_bounds (v : Std.I64) :
    ∃ s : Std.I64, int_encoded_size v = ok s ∧ 1 ≤ s.val ∧ s.val ≤ 9 := by
  by_cases hnn : 0 ≤ v.val
  · rw [int_encoded_size_nonneg_agrees_uint v hnn]
    exact uint_encoded_size_bounds (Pion.I64.to_uint64 v)
  · obtain ⟨h1, h2, h3, h5, h9⟩ := int_encoded_size_neg_spec v
    by_cases c1 : -32 ≤ v.val
    · exact ⟨1#i64, h1 ⟨c1, by omega⟩, by norm_num, by norm_num⟩
    · by_cases c2 : -128 ≤ v.val
      · exact ⟨2#i64, h2 ⟨c2, by omega⟩, by norm_num, by norm_num⟩
      · by_cases c3 : -32768 ≤ v.val
        · exact ⟨3#i64, h3 ⟨c3, by omega⟩, by norm_num, by norm_num⟩
        · by_cases c4 : -2147483648 ≤ v.val
          · exact ⟨5#i64, h5 ⟨c4, by omega⟩, by norm_num, by norm_num⟩
          · exact ⟨9#i64, h9 (by omega), by norm_num, by norm_num⟩

/-- MessagePack spec: exact 4-tier canonical string encoded size (`1+n`, `2+n`, `3+n`, `5+n`). -/
theorem str_encoded_size_spec (n : Std.I32) (hnn : 0 ≤ n.val) :
    ∃ s : Std.I64, str_encoded_size n = ok s ∧
      s.val = n.val + (if n.val ≤ 31 then 1 else if n.val ≤ 255 then 2 else if n.val ≤ 65535 then 3 else 5) := by
  have hb := i32_bounds n
  have hn64 := i32_to_i64_val n
  have h31 : (31#i32).val = 31 := by norm_num
  have h255 : (255#i32).val = 255 := by norm_num
  have h65535 : (65535#i32).val = 65535 := by norm_num
  unfold str_encoded_size
  by_cases c1 : n.val ≤ 31
  · have hc1 : n ≤ 31#i32 := (iscalar_le_iff _ _).mpr (by omega)
    simp only [hc1, c1, ↓reduceIte]
    refine ⟨_, rfl, ?_⟩
    have h1 : (1#i64).val = 1 := by norm_num
    rw [i64_add_val 1#i64 _ (by omega) (by omega), h1, hn64]; omega
  · have hc1 : ¬(n ≤ 31#i32) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    by_cases c2 : n.val ≤ 255
    · have hc2 : n ≤ 255#i32 := (iscalar_le_iff _ _).mpr (by omega)
      simp only [hc1, hc2, c1, c2, ↓reduceIte]
      refine ⟨_, rfl, ?_⟩
      have h2 : (2#i64).val = 2 := by norm_num
      rw [i64_add_val 2#i64 _ (by omega) (by omega), h2, hn64]; omega
    · have hc2 : ¬(n ≤ 255#i32) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
      by_cases c3 : n.val ≤ 65535
      · have hc3 : n ≤ 65535#i32 := (iscalar_le_iff _ _).mpr (by omega)
        simp only [hc1, hc2, hc3, c1, c2, c3, ↓reduceIte]
        refine ⟨_, rfl, ?_⟩
        have h3 : (3#i64).val = 3 := by norm_num
        rw [i64_add_val 3#i64 _ (by omega) (by omega), h3, hn64]; omega
      · have hc3 : ¬(n ≤ 65535#i32) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
        simp only [hc1, hc2, hc3, c1, c2, c3, ↓reduceIte]
        refine ⟨_, rfl, ?_⟩
        have h5 : (5#i64).val = 5 := by norm_num
        rw [i64_add_val 5#i64 _ (by omega) (by omega), h5, hn64]; omega

/-- MessagePack spec: exact 3-tier canonical binary encoded size (`2+n`, `3+n`, `5+n`). -/
theorem bin_encoded_size_spec (n : Std.I32) (hnn : 0 ≤ n.val) :
    ∃ s : Std.I64, bin_encoded_size n = ok s ∧
      s.val = n.val + (if n.val ≤ 255 then 2 else if n.val ≤ 65535 then 3 else 5) := by
  have hb := i32_bounds n
  have hn64 := i32_to_i64_val n
  have h255 : (255#i32).val = 255 := by norm_num
  have h65535 : (65535#i32).val = 65535 := by norm_num
  unfold bin_encoded_size
  by_cases c1 : n.val ≤ 255
  · have hc1 : n ≤ 255#i32 := (iscalar_le_iff _ _).mpr (by omega)
    simp only [hc1, c1, ↓reduceIte]
    refine ⟨_, rfl, ?_⟩
    have h2 : (2#i64).val = 2 := by norm_num
    rw [i64_add_val 2#i64 _ (by omega) (by omega), h2, hn64]; omega
  · have hc1 : ¬(n ≤ 255#i32) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    by_cases c2 : n.val ≤ 65535
    · have hc2 : n ≤ 65535#i32 := (iscalar_le_iff _ _).mpr (by omega)
      simp only [hc1, hc2, c1, c2, ↓reduceIte]
      refine ⟨_, rfl, ?_⟩
      have h3 : (3#i64).val = 3 := by norm_num
      rw [i64_add_val 3#i64 _ (by omega) (by omega), h3, hn64]; omega
    · have hc2 : ¬(n ≤ 65535#i32) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
      simp only [hc1, hc2, c1, c2, ↓reduceIte]
      refine ⟨_, rfl, ?_⟩
      have h5 : (5#i64).val = 5 := by norm_num
      rw [i64_add_val 5#i64 _ (by omega) (by omega), h5, hn64]; omega

/-- MessagePack spec: exact 3-tier array/map container header size (`1`, `3`, `5`). -/
theorem container_head_size_spec (n : Std.I32) :
    (n.val ≤ 15 → container_head_size n = ok 1#i64) ∧
    (16 ≤ n.val ∧ n.val ≤ 65535 → container_head_size n = ok 3#i64) ∧
    (65536 ≤ n.val → container_head_size n = ok 5#i64) := by
  have h15 : (15#i32).val = 15 := by norm_num
  have h65535 : (65535#i32).val = 65535 := by norm_num
  refine ⟨?_, ?_, ?_⟩
  · intro h; unfold container_head_size
    have c1 : n ≤ 15#i32 := (iscalar_le_iff _ _).mpr (by omega)
    simp only [c1, ↓reduceIte]
  · intro h; unfold container_head_size
    have c1 : ¬(n ≤ 15#i32) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    have c2 : n ≤ 65535#i32 := (iscalar_le_iff _ _).mpr (by omega)
    simp only [c1, c2, ↓reduceIte]
  · intro h; unfold container_head_size
    have c1 : ¬(n ≤ 15#i32) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    have c2 : ¬(n ≤ 65535#i32) := fun hc => by have := (iscalar_le_iff _ _).mp hc; omega
    simp only [c1, c2, ↓reduceIte]

/-- MessagePack spec: fixext sizes (`1, 2, 4, 8, 16`) always encode in `2 + n` bytes. -/
theorem ext_encoded_size_fixext (n : Std.I32)
    (hfix : n.val = 1 ∨ n.val = 2 ∨ n.val = 4 ∨ n.val = 8 ∨ n.val = 16) :
    ∃ s : Std.I64, ext_encoded_size n = ok s ∧ s.val = 2 + n.val := by
  have hn64 := i32_to_i64_val n
  unfold ext_encoded_size
  have hcond : (((((n == 1#i32) || (n == 2#i32)) || (n == 4#i32)) || (n == 8#i32)) || (n == 16#i32)) = true := by
    simp only [Bool.or_eq_true, beq_iff_eq, iscalar_eq_iff]
    norm_num; omega
  simp only [hcond, ↓reduceIte]
  refine ⟨_, rfl, ?_⟩
  have h2 : (2#i64).val = 2 := by norm_num
  rw [i64_add_val 2#i64 _ (by omega) (by omega), h2, hn64]

/-- MessagePack spec: Timestamp (ext `-1`) always encodes as 6 (ts32), 10 (ts64), or 15 (ts96) bytes,
    and negative timestamps always use the 15-byte timestamp96 format. -/
theorem timestamp_encoded_size_spec (sec : Std.I64) (nsec : Std.I32) :
    (sec.val < 0 → timestamp_encoded_size sec nsec = ok 15#i64) ∧
    (∃ s : Std.I64, timestamp_encoded_size sec nsec = ok s ∧ (s.val = 6 ∨ s.val = 10 ∨ s.val = 15)) := by
  have hshr34 : Pion.I64.shr_i32 sec 34#i32 = ok (⟨sec.bv.sshiftRight 34⟩ : Std.I64) := by
    unfold Pion.I64.shr_i32
    have h34 : (34#i32).val = 34 := by norm_num
    have h34n : (34#i32).val.toNat = 34 := by norm_num
    have hc : 0 ≤ (34#i32).val ∧ (34#i32).val < 64 := by omega
    simp only [hc, and_self, ↓reduceIte, h34n]
  have hshr32 : Pion.I64.shr_i32 sec 32#i32 = ok (⟨sec.bv.sshiftRight 32⟩ : Std.I64) := by
    unfold Pion.I64.shr_i32
    have h32 : (32#i32).val = 32 := by norm_num
    have h32n : (32#i32).val.toNat = 32 := by norm_num
    have hc : 0 ≤ (32#i32).val ∧ (32#i32).val < 64 := by omega
    simp only [hc, and_self, ↓reduceIte, h32n]
  have h0 : (0#i64).val = 0 := by norm_num
  constructor
  · intro hneg; unfold timestamp_encoded_size
    have c0 : ¬(sec ≥ 0#i64) := fun hc => by have := (iscalar_le_iff 0#i64 sec).mp hc; omega
    simp only [c0, ↓reduceIte, result_bind_ok, Bool.false_eq_true]
  · unfold timestamp_encoded_size
    by_cases hge : sec ≥ 0#i64
    · simp only [hge, ↓reduceIte, hshr34, result_bind_ok]
      by_cases h34 : ((⟨sec.bv.sshiftRight 34⟩ : Std.I64) == 0#i64) = true
      · simp only [h34, ↓reduceIte]
        by_cases hn0 : nsec = 0#i32
        · simp only [hn0, ↓reduceIte, hshr32, result_bind_ok]
          by_cases h32 : ((⟨sec.bv.sshiftRight 32⟩ : Std.I64) == 0#i64) = true
          · simp only [h32, ↓reduceIte]; exact ⟨6#i64, rfl, Or.inl (by norm_num)⟩
          · simp only [h32]; exact ⟨10#i64, rfl, Or.inr (Or.inl (by norm_num))⟩
        · simp only [hn0, ↓reduceIte, Bool.false_eq_true]
          exact ⟨10#i64, rfl, Or.inr (Or.inl (by norm_num))⟩
      · simp only [h34]; exact ⟨15#i64, rfl, Or.inr (Or.inr (by norm_num))⟩
    · simp only [hge, ↓reduceIte, result_bind_ok, Bool.false_eq_true]
      exact ⟨15#i64, rfl, Or.inr (Or.inr (by norm_num))⟩

end MsgpackProofs
