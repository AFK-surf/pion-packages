import MsgpackProofs.Core

open Aeneas Aeneas.Std Result Pion msgpack

namespace MsgpackProofs

/-- MessagePack spec: exact 5-tier canonical unsigned integer encoded size. -/
lemma uint_encoded_size_spec (u : Std.U64) :
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
lemma uint_encoded_size_bounds (u : Std.U64) :
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

end MsgpackProofs
