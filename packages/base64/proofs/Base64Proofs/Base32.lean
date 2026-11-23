import Base64Proofs.Core

open Aeneas Aeneas.Std Result Pion base64

namespace Base64Proofs

/-- Pure mathematical Base32 tail symbol count for remainder `r ∈ {0..4}`. -/
def specB32Tail (r : Int) : Int :=
  if r = 0 then 0 else if r = 1 then 2 else if r = 2 then 4 else if r = 3 then 5 else 7

private lemma b32_tail_symbols_spec (rem : Std.I32) (h0 : 0 ≤ rem.val) (h5 : rem.val < 5) :
    ∃ t : Std.I32, b32_tail_symbols rem = ok t ∧ t.val = specB32Tail rem.val := by
  have hcases : rem = 0#i32 ∨ rem = 1#i32 ∨ rem = 2#i32 ∨ rem = 3#i32 ∨ rem = 4#i32 := by
    have : rem.val = 0 ∨ rem.val = 1 ∨ rem.val = 2 ∨ rem.val = 3 ∨ rem.val = 4 := by omega
    rcases this with h | h | h | h | h
    · left; exact (iscalar_eq_iff _ _).mpr (by norm_num; omega)
    · right; left; exact (iscalar_eq_iff _ _).mpr (by norm_num; omega)
    · right; right; left; exact (iscalar_eq_iff _ _).mpr (by norm_num; omega)
    · right; right; right; left; exact (iscalar_eq_iff _ _).mpr (by norm_num; omega)
    · right; right; right; right; exact (iscalar_eq_iff _ _).mpr (by norm_num; omega)
  rcases hcases with rfl | rfl | rfl | rfl | rfl
  · exact ⟨0#i32, by simp [b32_tail_symbols], by decide⟩
  · exact ⟨2#i32, by simp [b32_tail_symbols], by decide⟩
  · exact ⟨4#i32, by simp [b32_tail_symbols], by decide⟩
  · exact ⟨5#i32, by simp [b32_tail_symbols], by decide⟩
  · exact ⟨7#i32, by simp [b32_tail_symbols], by decide⟩

/-- Full-domain RFC 4648 §6/§7 Base32 `b32_encoded_len` specification over ALL `Std.I32` inputs:
    never traps, never overflows negative, returns `0` for `n ≤ 0`, saturates at `INT32_MAX`,
    and when padded and unsaturated, is always a multiple of 8. -/
theorem b32_encoded_len_full_domain (n : Std.I32) (pad : Bool) :
    ∃ L : Std.I32, b32_encoded_len n pad = ok L ∧
      0 ≤ L.val ∧ L.val ≤ 2147483647 ∧
      L.val = (if n.val ≤ 0 then 0
               else min 2147483647
                 (if pad && decide (n.val % 5 ≠ 0) then (n.val / 5 + 1) * 8
                  else (n.val / 5) * 8 + specB32Tail (n.val % 5))) := by
  have hb := i32_bounds n
  have hmax := i64_max32_val
  have h1 : (1#i64).val = 1 := by decide
  have h5 : (5#i64).val = 5 := by decide
  have h8 : (8#i64).val = 8 := by decide
  have hmax32 : (2147483647#i32).val = 2147483647 := by norm_num
  unfold b32_encoded_len
  by_cases hle : n.val ≤ 0
  · have hle' : n ≤ 0#i32 := hle
    simp only [hle', hle, ↓reduceIte]
    exact ⟨0#i32, rfl, by norm_num, by norm_num, by norm_num⟩
  · have hle' : ¬(n ≤ 0#i32) := hle
    simp only [hle', hle, ↓reduceIte]
    have hn64 : (Pion.I32.to_int64 n).val = n.val := i32_to_int64_val n
    obtain ⟨full, hfull, hfullv⟩ := i64_div_pos_val (Pion.I32.to_int64 n) 5#i64 (by rw [hn64]; omega) (by rw [h5]; omega)
    rw [hfull, result_bind_ok]
    rw [hn64, h5] at hfullv
    have hmul5 : (Pion.I64.mul full 5#i64).val = full.val * 5 := by
      rw [i64_mul_val full 5#i64 (by rw [hfullv, h5]; omega) (by rw [hfullv, h5]; omega), h5]
    have hsub : (Pion.I64.sub (Pion.I32.to_int64 n) (Pion.I64.mul full 5#i64)).val = n.val % 5 := by
      rw [i64_sub_val _ _ (by rw [hn64, hmul5, hfullv]; omega) (by rw [hn64, hmul5, hfullv]; omega), hn64, hmul5, hfullv]
      omega
    set rem := Pion.I64.to_int (Pion.I64.sub (Pion.I32.to_int64 n) (Pion.I64.mul full 5#i64))
    have hremv : rem.val = n.val % 5 := by
      rw [i64_to_int_val _ (by omega) (by omega), hsub]
    obtain ⟨t, ht, htv⟩ := b32_tail_symbols_spec rem (by omega) (by omega)
    rw [ht, result_bind_ok]
    have htail64 : (Pion.I32.to_int64 t).val = specB32Tail (n.val % 5) := by
      rw [i32_to_int64_val t, htv, hremv]
    have ht_rng : 0 ≤ specB32Tail (n.val % 5) ∧ specB32Tail (n.val % 5) ≤ 7 := by
      unfold specB32Tail; split_ifs <;> omega
    have hcond_eq : (pad && (rem != 0#i32)) = (pad && decide (n.val % 5 ≠ 0)) := by
      cases pad
      · rfl
      · simp only [Bool.true_and]
        by_cases hr0 : n.val % 5 = 0
        · have hre : rem = 0#i32 := (iscalar_eq_iff _ _).mpr (by rw [hremv, hr0]; rfl)
          simp [hre, hr0]
        · have hre : rem ≠ 0#i32 := fun h => hr0 (by have := (iscalar_eq_iff _ _).mp h; rw [hremv] at this; exact this)
          simp [hre, hr0]
    set res := if (pad && (rem != 0#i32)) then Pion.I64.mul (Pion.I64.add full 1#i64) 8#i64
               else Pion.I64.add (Pion.I64.mul full 8#i64) (Pion.I32.to_int64 t)
    have hresv : res.val = if (pad && decide (n.val % 5 ≠ 0)) then (n.val / 5 + 1) * 8
                           else (n.val / 5) * 8 + specB32Tail (n.val % 5) := by
      simp only [res, hcond_eq]
      split_ifs
      · have hadd1 : (Pion.I64.add full 1#i64).val = full.val + 1 := by
          rw [i64_add_val full 1#i64 (by rw [hfullv, h1]; omega) (by rw [hfullv, h1]; omega), h1]
        rw [i64_mul_val _ 8#i64 (by rw [hadd1, hfullv, h8]; omega) (by rw [hadd1, hfullv, h8]; omega), hadd1, hfullv, h8]
      · have hmul8 : (Pion.I64.mul full 8#i64).val = full.val * 8 := by
          rw [i64_mul_val full 8#i64 (by rw [hfullv, h8]; omega) (by rw [hfullv, h8]; omega), h8]
        rw [i64_add_val _ _ (by rw [hmul8, hfullv, htail64]; omega) (by rw [hmul8, hfullv, htail64]; omega),
            hmul8, hfullv, htail64]
    by_cases hgt : res.val > 2147483647
    · have hgt' : res > 2147483647#i64 := by rw [iscalar_gt_iff, hmax]; omega
      simp only [hgt', ↓reduceIte]
      exact ⟨2147483647#i32, rfl, by omega, by omega, by omega⟩
    · have hgt' : ¬(res > 2147483647#i64) := by rw [iscalar_gt_iff, hmax]; omega
      simp only [hgt', ↓reduceIte]
      have hcast := i64_to_int_val res (by split_ifs at hresv <;> omega) (by omega)
      exact ⟨Pion.I64.to_int res, rfl, by split_ifs at hresv <;> omega, by omega, by omega⟩

/-- Full-domain unpadded Base32 length roundtrip over ALL non-negative `Std.I32`:
    exact tail-decoded length recovery `(L / 8) * 5 + b32_tail_bytes (L & 7) = n` whenever
    the exact length fits in `Int32` (`n ≤ 1342177279`), and safe saturation at `INT32_MAX` above. -/
theorem b32_encoded_len_nopad_roundtrip_full (n : Std.I32) (h0 : 0 ≤ n.val) :
    if (n.val / 5) * 8 + specB32Tail (n.val % 5) ≤ 2147483647 then
      ∃ L t : Std.I32,
        b32_encoded_len n false = ok L ∧
        b32_tail_bytes (Pion.I32.band L 7#i32) = ok t ∧
        (L.val / 8) * 5 + t.val = n.val
    else
      b32_encoded_len n false = ok 2147483647#i32 := by
  obtain ⟨L, hL, hL0, hLhi, hLv⟩ := b32_encoded_len_full_domain n false
  simp only [Bool.false_and, Bool.false_eq_true, ↓reduceIte] at hLv
  by_cases hfit : (n.val / 5) * 8 + specB32Tail (n.val % 5) ≤ 2147483647
  · simp only [hfit, ↓reduceIte]
    have hLexact : L.val = (n.val / 5) * 8 + specB32Tail (n.val % 5) := by
      unfold specB32Tail at hLv hfit ⊢
      split_ifs at hLv hfit ⊢ <;> omega
    have hband7 : (Pion.I32.band L 7#i32).val = L.val % 8 := by
      have ⟨hLnat, _⟩ := i32_toNat_of_nonneg L hL0
      have hb : (Pion.I32.band L 7#i32).bv.toNat = L.bv.toNat % 8 := by
        rw [i32_band_bv, BitVec.toNat_and]
        have h7 : (7#i32).bv.toNat = 7 := by decide
        rw [h7]
        have : (7 : Nat) = 2 ^ 3 - 1 := by norm_num
        rw [this, Nat.and_two_pow_sub_one_eq_mod]
      have hv : (Pion.I32.band L 7#i32).val = ((Pion.I32.band L 7#i32).bv.toNat : Int) := by
        change (Pion.I32.band L 7#i32).bv.toInt = _
        rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
      omega
    have hr_cases : n.val % 5 = 0 ∨ n.val % 5 = 1 ∨ n.val % 5 = 2 ∨ n.val % 5 = 3 ∨ n.val % 5 = 4 := by omega
    rcases hr_cases with hr | hr | hr | hr | hr
    · have ht0 : specB32Tail (n.val % 5) = 0 := by rw [hr]; rfl
      have heq : Pion.I32.band L 7#i32 = 0#i32 := (iscalar_eq_iff _ _).mpr (by rw [hband7]; norm_num; omega)
      exact ⟨L, 0#i32, hL, by rw [heq]; simp [b32_tail_bytes], by norm_num; omega⟩
    · have ht1 : specB32Tail (n.val % 5) = 2 := by rw [hr]; rfl
      have heq : Pion.I32.band L 7#i32 = 2#i32 := (iscalar_eq_iff _ _).mpr (by rw [hband7]; norm_num; omega)
      exact ⟨L, 1#i32, hL, by rw [heq]; simp [b32_tail_bytes], by norm_num; omega⟩
    · have ht2 : specB32Tail (n.val % 5) = 4 := by rw [hr]; rfl
      have heq : Pion.I32.band L 7#i32 = 4#i32 := (iscalar_eq_iff _ _).mpr (by rw [hband7]; norm_num; omega)
      exact ⟨L, 2#i32, hL, by rw [heq]; simp [b32_tail_bytes], by norm_num; omega⟩
    · have ht3 : specB32Tail (n.val % 5) = 5 := by rw [hr]; rfl
      have heq : Pion.I32.band L 7#i32 = 5#i32 := (iscalar_eq_iff _ _).mpr (by rw [hband7]; norm_num; omega)
      exact ⟨L, 3#i32, hL, by rw [heq]; simp [b32_tail_bytes], by norm_num; omega⟩
    · have ht4 : specB32Tail (n.val % 5) = 7 := by rw [hr]; rfl
      have heq : Pion.I32.band L 7#i32 = 7#i32 := (iscalar_eq_iff _ _).mpr (by rw [hband7]; norm_num; omega)
      exact ⟨L, 4#i32, hL, by rw [heq]; simp [b32_tail_bytes], by norm_num; omega⟩
  · simp only [hfit, ↓reduceIte]
    rw [hL]
    congr 1
    apply (iscalar_eq_iff _ _).mpr
    have hmax32 : (2147483647#i32).val = 2147483647 := by norm_num
    unfold specB32Tail at hLv hfit
    split_ifs at hLv hfit <;> omega

end Base64Proofs
