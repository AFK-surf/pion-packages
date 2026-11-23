import CborProofs.Core

open Aeneas Aeneas.Std Result Pion cbor

namespace CborProofs

/-- RFC 8949 §4.2.1: exact 5-tier head size specification for `head_size_u64`. -/
private lemma head_size_u64_spec (n : Std.U64) :
    (n.val < 24 → head_size_u64 n = ok 1#i32) ∧
    (24 ≤ n.val ∧ n.val ≤ 255 → head_size_u64 n = ok 2#i32) ∧
    (256 ≤ n.val ∧ n.val ≤ 65535 → head_size_u64 n = ok 3#i32) ∧
    (65536 ≤ n.val ∧ n.val ≤ 4294967295 → head_size_u64 n = ok 5#i32) ∧
    (4294967296 ≤ n.val → head_size_u64 n = ok 9#i32) := by
  have h24 := u64_24_val
  have h255 := u64_255_val
  have h65535 := u64_65535_val
  have hu32 := u64_u32max_val
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · intro h; unfold head_size_u64
    have c1 : n < 24#u64 := (uscalar_lt_iff n 24#u64).mpr (by omega)
    simp only [c1, ↓reduceIte]
  · intro h; unfold head_size_u64
    have c1 : ¬(n < 24#u64) := fun hc => by have := (uscalar_lt_iff n 24#u64).mp hc; omega
    have c2 : n ≤ 255#u64 := (uscalar_le_iff n 255#u64).mpr (by omega)
    simp only [c1, c2, ↓reduceIte]
  · intro h; unfold head_size_u64
    have c1 : ¬(n < 24#u64) := fun hc => by have := (uscalar_lt_iff n 24#u64).mp hc; omega
    have c2 : ¬(n ≤ 255#u64) := fun hc => by have := (uscalar_le_iff n 255#u64).mp hc; omega
    have c3 : n ≤ 65535#u64 := (uscalar_le_iff n 65535#u64).mpr (by omega)
    simp only [c1, c2, c3, ↓reduceIte]
  · intro h; unfold head_size_u64
    have c1 : ¬(n < 24#u64) := fun hc => by have := (uscalar_lt_iff n 24#u64).mp hc; omega
    have c2 : ¬(n ≤ 255#u64) := fun hc => by have := (uscalar_le_iff n 255#u64).mp hc; omega
    have c3 : ¬(n ≤ 65535#u64) := fun hc => by have := (uscalar_le_iff n 65535#u64).mp hc; omega
    have c4 : n ≤ 4294967295#u64 := (uscalar_le_iff n 4294967295#u64).mpr (by omega)
    simp only [c1, c2, c3, c4, ↓reduceIte]
  · intro h; unfold head_size_u64
    have c1 : ¬(n < 24#u64) := fun hc => by have := (uscalar_lt_iff n 24#u64).mp hc; omega
    have c2 : ¬(n ≤ 255#u64) := fun hc => by have := (uscalar_le_iff n 255#u64).mp hc; omega
    have c3 : ¬(n ≤ 65535#u64) := fun hc => by have := (uscalar_le_iff n 65535#u64).mp hc; omega
    have c4 : ¬(n ≤ 4294967295#u64) := fun hc => by have := (uscalar_le_iff n 4294967295#u64).mp hc; omega
    simp only [c1, c2, c3, c4, ↓reduceIte]

/-- `head_size_u64` always lies in `[1, 9]`. -/
private lemma head_size_u64_bounds (n : Std.U64) :
    ∃ s : Std.I32, head_size_u64 n = ok s ∧ 1 ≤ s.val ∧ s.val ≤ 9 := by
  obtain ⟨h1, h2, h3, h5, h9⟩ := head_size_u64_spec n
  by_cases c1 : n.val < 24
  · exact ⟨1#i32, h1 c1, by norm_num, by norm_num⟩
  · by_cases c2 : n.val ≤ 255
    · exact ⟨2#i32, h2 ⟨by omega, c2⟩, by norm_num, by norm_num⟩
    · by_cases c3 : n.val ≤ 65535
      · exact ⟨3#i32, h3 ⟨by omega, c3⟩, by norm_num, by norm_num⟩
      · by_cases c4 : n.val ≤ 4294967295
        · exact ⟨5#i32, h5 ⟨by omega, c4⟩, by norm_num, by norm_num⟩
        · exact ⟨9#i32, h9 (by omega), by norm_num, by norm_num⟩

/-- `head_size_u64` is monotonically non-decreasing. -/
theorem head_size_u64_mono (a b : Std.U64) (sa sb : Std.I32)
    (hle : a.val ≤ b.val)
    (ha : head_size_u64 a = ok sa) (hb : head_size_u64 b = ok sb) :
    sa.val ≤ sb.val := by
  obtain ⟨a1, a2, a3, a5, a9⟩ := head_size_u64_spec a
  obtain ⟨b1, b2, b3, b5, b9⟩ := head_size_u64_spec b
  have eq_of : ∀ {x y : Std.I32}, (ok x : Result Std.I32) = ok y → x = y := fun h => result_ok_inj h
  by_cases ca1 : a.val < 24
  · have hsa : sa = 1#i32 := eq_of (ha.symm.trans (a1 ca1))
    obtain ⟨s, hs, hs1, _⟩ := head_size_u64_bounds b
    have hsb : sb = s := eq_of (hb.symm.trans hs)
    subst hsa; subst hsb; norm_num; omega
  · by_cases ca2 : a.val ≤ 255
    · have hsa : sa = 2#i32 := eq_of (ha.symm.trans (a2 ⟨by omega, ca2⟩))
      subst hsa
      by_cases cb2 : b.val ≤ 255
      · have hsb := eq_of (hb.symm.trans (b2 ⟨by omega, cb2⟩)); subst hsb; norm_num
      · by_cases cb3 : b.val ≤ 65535
        · have hsb := eq_of (hb.symm.trans (b3 ⟨by omega, cb3⟩)); subst hsb; norm_num
        · by_cases cb4 : b.val ≤ 4294967295
          · have hsb := eq_of (hb.symm.trans (b5 ⟨by omega, cb4⟩)); subst hsb; norm_num
          · have hsb := eq_of (hb.symm.trans (b9 (by omega))); subst hsb; norm_num
    · by_cases ca3 : a.val ≤ 65535
      · have hsa : sa = 3#i32 := eq_of (ha.symm.trans (a3 ⟨by omega, ca3⟩))
        subst hsa
        by_cases cb3 : b.val ≤ 65535
        · have hsb := eq_of (hb.symm.trans (b3 ⟨by omega, cb3⟩)); subst hsb; norm_num
        · by_cases cb4 : b.val ≤ 4294967295
          · have hsb := eq_of (hb.symm.trans (b5 ⟨by omega, cb4⟩)); subst hsb; norm_num
          · have hsb := eq_of (hb.symm.trans (b9 (by omega))); subst hsb; norm_num
      · by_cases ca4 : a.val ≤ 4294967295
        · have hsa : sa = 5#i32 := eq_of (ha.symm.trans (a5 ⟨by omega, ca4⟩))
          subst hsa
          by_cases cb4 : b.val ≤ 4294967295
          · have hsb := eq_of (hb.symm.trans (b5 ⟨by omega, cb4⟩)); subst hsb; norm_num
          · have hsb := eq_of (hb.symm.trans (b9 (by omega))); subst hsb; norm_num
        · have hsa : sa = 9#i32 := eq_of (ha.symm.trans (a9 (by omega)))
          have hsb : sb = 9#i32 := eq_of (hb.symm.trans (b9 (by omega)))
          subst hsa; subst hsb; norm_num

/-- `head_size_int` agrees identically with `head_size_u64` on all non-negative `Std.I32` values. -/
theorem head_size_int_agrees_u64 (n : Std.I32) (u : Std.U64)
    (hnn : 0 ≤ n.val) (heq : u.val = n.val.toNat) :
    head_size_int n = head_size_u64 u := by
  have hb := i32_bounds n
  have h24i : (24#i32).val = 24 := by norm_num
  have h255i : (255#i32).val = 255 := by norm_num
  have h65535i : (65535#i32).val = 65535 := by norm_num
  obtain ⟨u1, u2, u3, u5, _⟩ := head_size_u64_spec u
  unfold head_size_int
  by_cases c1 : n.val < 24
  · have hc1 : n < 24#i32 := (iscalar_lt_iff n 24#i32).mpr (by omega)
    rw [u1 (by omega)]; simp only [hc1, ↓reduceIte]
  · have hc1 : ¬(n < 24#i32) := fun h => by have := (iscalar_lt_iff n 24#i32).mp h; omega
    by_cases c2 : n.val ≤ 255
    · have hc2 : n ≤ 255#i32 := (iscalar_le_iff n 255#i32).mpr (by omega)
      rw [u2 ⟨by omega, by omega⟩]; simp only [hc1, hc2, ↓reduceIte]
    · have hc2 : ¬(n ≤ 255#i32) := fun h => by have := (iscalar_le_iff n 255#i32).mp h; omega
      by_cases c3 : n.val ≤ 65535
      · have hc3 : n ≤ 65535#i32 := (iscalar_le_iff n 65535#i32).mpr (by omega)
        rw [u3 ⟨by omega, by omega⟩]; simp only [hc1, hc2, hc3, ↓reduceIte]
      · have hc3 : ¬(n ≤ 65535#i32) := fun h => by have := (iscalar_le_iff n 65535#i32).mp h; omega
        rw [u5 ⟨by omega, by omega⟩]; simp only [hc1, hc2, hc3, ↓reduceIte]

/-- RFC 8949 §4.2.1: exact specification of `is_canonical_arg` for additional info `24..27`. -/
private lemma is_canonical_arg_spec (v : Std.U64) :
    is_canonical_arg 24#i32 v = ok (decide (24 ≤ v.val)) ∧
    is_canonical_arg 25#i32 v = ok (decide (255 < v.val)) ∧
    is_canonical_arg 26#i32 v = ok (decide (65535 < v.val)) ∧
    is_canonical_arg 27#i32 v = ok (decide (4294967295 < v.val)) := by
  have h24 := u64_24_val
  have h255 := u64_255_val
  have h65535 := u64_65535_val
  have hu32 := u64_u32max_val
  refine ⟨?_, ?_, ?_, ?_⟩
  · unfold is_canonical_arg; simp only [↓reduceIte]; rfl
  · unfold is_canonical_arg
    have hne : (25#i32 : Std.I32) ≠ 24#i32 := by decide
    simp only [hne, ↓reduceIte]; rfl
  · unfold is_canonical_arg
    have hne1 : (26#i32 : Std.I32) ≠ 24#i32 := by decide
    have hne2 : (26#i32 : Std.I32) ≠ 25#i32 := by decide
    simp only [hne1, hne2, ↓reduceIte]; rfl
  · unfold is_canonical_arg
    have hne1 : (27#i32 : Std.I32) ≠ 24#i32 := by decide
    have hne2 : (27#i32 : Std.I32) ≠ 25#i32 := by decide
    have hne3 : (27#i32 : Std.I32) ≠ 26#i32 := by decide
    simp only [hne1, hne2, hne3, ↓reduceIte]; rfl

/-- RFC 8949 §4.2.1 Encoder-Decoder Canonical Duality:
    the minimal head size chosen by `head_size_u64` is ALWAYS accepted by `is_canonical_arg`,
    and any wider encoding tier is ALWAYS rejected! -/
theorem canonical_encoder_decoder_duality (v : Std.U64) :
    (head_size_u64 v = ok 1#i32 → is_canonical_arg 24#i32 v = ok false) ∧
    (head_size_u64 v = ok 2#i32 → is_canonical_arg 24#i32 v = ok true ∧ is_canonical_arg 25#i32 v = ok false) ∧
    (head_size_u64 v = ok 3#i32 → is_canonical_arg 25#i32 v = ok true ∧ is_canonical_arg 26#i32 v = ok false) ∧
    (head_size_u64 v = ok 5#i32 → is_canonical_arg 26#i32 v = ok true ∧ is_canonical_arg 27#i32 v = ok false) ∧
    (head_size_u64 v = ok 9#i32 → is_canonical_arg 27#i32 v = ok true) := by
  obtain ⟨u1, u2, u3, u5, u9⟩ := head_size_u64_spec v
  obtain ⟨c24, c25, c26, c27⟩ := is_canonical_arg_spec v
  have ne_ok : ∀ {a b : Std.I32}, a.val ≠ b.val → (ok a : Result Std.I32) ≠ ok b :=
    fun hne heq => hne ((iscalar_eq_iff _ _).mp (result_ok_inj heq))
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · intro h
    have hv : v.val < 24 := by
      by_contra hge
      by_cases c2 : v.val ≤ 255
      · exact ne_ok (by norm_num) ((u2 ⟨by omega, c2⟩).symm.trans h)
      · by_cases c3 : v.val ≤ 65535
        · exact ne_ok (by norm_num) ((u3 ⟨by omega, c3⟩).symm.trans h)
        · by_cases c4 : v.val ≤ 4294967295
          · exact ne_ok (by norm_num) ((u5 ⟨by omega, c4⟩).symm.trans h)
          · exact ne_ok (by norm_num) ((u9 (by omega)).symm.trans h)
    rw [c24, decide_eq_false (by omega)]
  · intro h
    have hv : 24 ≤ v.val ∧ v.val ≤ 255 := by
      by_contra hnot
      by_cases c1 : v.val < 24
      · exact ne_ok (by norm_num) ((u1 c1).symm.trans h)
      · by_cases c3 : v.val ≤ 65535
        · exact ne_ok (by norm_num) ((u3 ⟨by omega, c3⟩).symm.trans h)
        · by_cases c4 : v.val ≤ 4294967295
          · exact ne_ok (by norm_num) ((u5 ⟨by omega, c4⟩).symm.trans h)
          · exact ne_ok (by norm_num) ((u9 (by omega)).symm.trans h)
    exact ⟨by rw [c24, decide_eq_true hv.1], by rw [c25, decide_eq_false (by omega)]⟩
  · intro h
    have hv : 256 ≤ v.val ∧ v.val ≤ 65535 := by
      by_contra hnot
      by_cases c1 : v.val < 24
      · exact ne_ok (by norm_num) ((u1 c1).symm.trans h)
      · by_cases c2 : v.val ≤ 255
        · exact ne_ok (by norm_num) ((u2 ⟨by omega, c2⟩).symm.trans h)
        · by_cases c4 : v.val ≤ 4294967295
          · exact ne_ok (by norm_num) ((u5 ⟨by omega, c4⟩).symm.trans h)
          · exact ne_ok (by norm_num) ((u9 (by omega)).symm.trans h)
    exact ⟨by rw [c25, decide_eq_true (by omega)], by rw [c26, decide_eq_false (by omega)]⟩
  · intro h
    have hv : 65536 ≤ v.val ∧ v.val ≤ 4294967295 := by
      by_contra hnot
      by_cases c1 : v.val < 24
      · exact ne_ok (by norm_num) ((u1 c1).symm.trans h)
      · by_cases c2 : v.val ≤ 255
        · exact ne_ok (by norm_num) ((u2 ⟨by omega, c2⟩).symm.trans h)
        · by_cases c3 : v.val ≤ 65535
          · exact ne_ok (by norm_num) ((u3 ⟨by omega, c3⟩).symm.trans h)
          · exact ne_ok (by norm_num) ((u9 (by omega)).symm.trans h)
    exact ⟨by rw [c26, decide_eq_true (by omega)], by rw [c27, decide_eq_false (by omega)]⟩
  · intro h
    have hv : 4294967296 ≤ v.val := by
      by_contra hlt
      by_cases c1 : v.val < 24
      · exact ne_ok (by norm_num) ((u1 c1).symm.trans h)
      · by_cases c2 : v.val ≤ 255
        · exact ne_ok (by norm_num) ((u2 ⟨by omega, c2⟩).symm.trans h)
        · by_cases c3 : v.val ≤ 65535
          · exact ne_ok (by norm_num) ((u3 ⟨by omega, c3⟩).symm.trans h)
          · exact ne_ok (by norm_num) ((u5 ⟨by omega, by omega⟩).symm.trans h)
    rw [c27, decide_eq_true (by omega)]

end CborProofs
