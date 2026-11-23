import MsgpackProofs.Core

open Aeneas Aeneas.Std Result Pion msgpack

namespace MsgpackProofs

private lemma i64_shl_i32_const (x : Std.I64) (k : Std.I32) (h0 : 0 ≤ k.val) (h64 : k.val < 64) :
    Pion.I64.shl_i32 x k = ok (⟨x.bv <<< k.val.toNat⟩ : Std.I64) := by
  unfold Pion.I64.shl_i32
  have hc : 0 ≤ k.val ∧ k.val < 64 := ⟨h0, h64⟩
  simp only [hc, and_self, ↓reduceIte]

private lemma i64_shr_i32_const (x : Std.I64) (k : Std.I32) (h0 : 0 ≤ k.val) (h64 : k.val < 64) :
    Pion.I64.shr_i32 x k = ok (⟨x.bv.sshiftRight k.val.toNat⟩ : Std.I64) := by
  unfold Pion.I64.shr_i32
  have hc : 0 ≤ k.val ∧ k.val < 64 := ⟨h0, h64⟩
  simp only [hc, and_self, ↓reduceIte]

private lemma eval_f32_rt (u : Std.I64) :
    (do let d ← float32_to_double_bits u; double_bits_to_float32_exact d) = ok (some u) ↔
    ∃ d, float32_to_double_bits u = ok d ∧ double_bits_to_float32_exact d = ok (some u) := by
  constructor
  · intro heq
    cases hd : float32_to_double_bits u with
    | ret d => rw [hd, result_bind_ok] at heq; exact ⟨d, rfl, heq⟩
    | _ => rw [hd] at heq; simp at heq
  · rintro ⟨d, h1, h2⟩; rw [h1, result_bind_ok, h2]

private theorem f32_to_f64_concrete (bits : Std.I64) (d : Std.I64)
    (he0 : Pion.I64.to_int (Pion.I64.band (⟨(Pion.I64.band bits 4294967295#i64).bv.sshiftRight 23⟩ : Std.I64) 255#i64) ≠ 0#i32 ∨
           Pion.I64.band (Pion.I64.band bits 4294967295#i64) 8388607#i64 = 0#i64)
    (hres :
      let u := Pion.I64.band bits 4294967295#i64
      let sign := Pion.I64.band (⟨u.bv.sshiftRight 31⟩ : Std.I64) 1#i64
      let exp := Pion.I64.to_int (Pion.I64.band (⟨u.bv.sshiftRight 23⟩ : Std.I64) 255#i64)
      let frac := Pion.I64.band u 8388607#i64
      (if exp = 0#i32 then (⟨sign.bv <<< 63⟩ : Std.I64)
       else if exp = 255#i32 then
         if frac = 0#i64 then Pion.I64.bor ⟨sign.bv <<< 63⟩ ⟨(2047#i64).bv <<< 52⟩
         else Pion.I64.bor (Pion.I64.bor ⟨sign.bv <<< 63⟩ ⟨(2047#i64).bv <<< 52⟩) ⟨frac.bv <<< 29⟩
       else
         Pion.I64.bor (Pion.I64.bor ⟨sign.bv <<< 63⟩ ⟨(Pion.I32.to_int64 (Pion.I32.add exp 896#i32)).bv <<< 52⟩)
           ⟨frac.bv <<< 29⟩) = d) :
    float32_to_double_bits bits = ok d := by
  unfold float32_to_double_bits
  dsimp only
  rw [i64_shr_i32_const _ 31#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i64_shr_i32_const _ 23#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h31 : (31#i32).val.toNat = 31 := by norm_num
  have h23 : (23#i32).val.toNat = 23 := by norm_num
  rw [h31, h23]
  dsimp only at hres ⊢
  split_ifs with h1 h2 h3 h4
  · rw [i64_shl_i32_const _ 63#i32 (by norm_num) (by norm_num), result_bind_ok]
    have h63 : (63#i32).val.toNat = 63 := by norm_num
    rw [h63]; simp only [h1, ↓reduceIte] at hres; exact congrArg ok hres
  · rcases he0 with he0 | he0
    · exact absurd h1 he0
    · exact absurd he0 h2
  · rw [i64_shl_i32_const _ 63#i32 (by norm_num) (by norm_num), result_bind_ok]
    rw [i64_shl_i32_const _ 52#i32 (by norm_num) (by norm_num), result_bind_ok]
    have h63 : (63#i32).val.toNat = 63 := by norm_num
    have h52 : (52#i32).val.toNat = 52 := by norm_num
    rw [h63, h52]; simp only [h3, h4, ↓reduceIte] at hres; exact congrArg ok hres
  · rw [i64_shl_i32_const _ 29#i32 (by norm_num) (by norm_num), result_bind_ok]
    rw [i64_shl_i32_const _ 63#i32 (by norm_num) (by norm_num), result_bind_ok]
    rw [i64_shl_i32_const _ 52#i32 (by norm_num) (by norm_num), result_bind_ok]
    have h29 : (29#i32).val.toNat = 29 := by norm_num
    have h63 : (63#i32).val.toNat = 63 := by norm_num
    have h52 : (52#i32).val.toNat = 52 := by norm_num
    rw [h29, h63, h52]; simp only [h3, h4, ↓reduceIte] at hres; exact congrArg ok hres
  · rw [i64_shl_i32_const _ 29#i32 (by norm_num) (by norm_num), result_bind_ok]
    rw [i64_shl_i32_const _ 63#i32 (by norm_num) (by norm_num), result_bind_ok]
    rw [i64_shl_i32_const _ 52#i32 (by norm_num) (by norm_num), result_bind_ok]
    have h29 : (29#i32).val.toNat = 29 := by norm_num
    have h63 : (63#i32).val.toNat = 63 := by norm_num
    have h52 : (52#i32).val.toNat = 52 := by norm_num
    rw [h29, h63, h52]; simp only [h1, h3, ↓reduceIte] at hres; exact congrArg ok hres

private theorem f64_to_f32_concrete (bits : Std.I64) (out : Option Std.I64)
    (hres :
      let sign := Pion.I64.band (⟨bits.bv.sshiftRight 63⟩ : Std.I64) 1#i64
      let exp := Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)
      let frac := Pion.I64.band bits 4503599627370495#i64
      let e := Pion.I32.sub exp 1023#i32
      (if exp = 2047#i32 then
         if frac = 0#i64 then some (Pion.I64.bor ⟨sign.bv <<< 31⟩ 2139095040#i64)
         else if Pion.I64.band frac 536870911#i64 ≠ 0#i64 then none
         else
           let payload := Pion.I64.band (⟨frac.bv.sshiftRight 29⟩ : Std.I64) 8388607#i64
           if payload = 0#i64 then none
           else some (Pion.I64.bor (Pion.I64.bor ⟨sign.bv <<< 31⟩ 2139095040#i64) payload)
       else if ((exp == 0#i32) && (frac == 0#i64)) then some ⟨sign.bv <<< 31⟩
       else if ((decide (e >= (-126)#i32)) && (decide (e <= 127#i32))) then
         if Pion.I64.band frac 536870911#i64 ≠ 0#i64 then none
         else some (Pion.I64.bor (Pion.I64.bor ⟨sign.bv <<< 31⟩ ⟨(Pion.I32.to_int64 (Pion.I32.add e 127#i32)).bv <<< 23⟩)
           (Pion.I64.band (⟨frac.bv.sshiftRight 29⟩ : Std.I64) 8388607#i64))
       else none) = out)
    (hnsub : ¬(Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64) ≠ 2047#i32 ∧
               ((Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64) == 0#i32) &&
                (Pion.I64.band bits 4503599627370495#i64 == 0#i64)) = false ∧
               ((decide (Pion.I32.sub (Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)) 1023#i32 ≥ (-126)#i32)) &&
                (decide (Pion.I32.sub (Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)) 1023#i32 ≤ 127#i32))) = false ∧
               ((decide (Pion.I32.sub (Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)) 1023#i32 ≥ (-149)#i32)) &&
                (decide (Pion.I32.sub (Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)) 1023#i32 ≤ (-127)#i32))) = true)) :
    double_bits_to_float32_exact bits = ok out := by
  unfold double_bits_to_float32_exact
  rw [i64_shr_i32_const bits 63#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i64_shr_i32_const bits 52#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h63 : (63#i32).val.toNat = 63 := by norm_num
  have h52 : (52#i32).val.toNat = 52 := by norm_num
  rw [h63, h52]
  dsimp only at hres hnsub ⊢
  split_ifs with h1 h2 h3 h4 h5 h6 h7
  · rw [i64_shl_i32_const _ 31#i32 (by norm_num) (by norm_num), result_bind_ok]
    have h31 : (31#i32).val.toNat = 31 := by norm_num
    rw [h31]; simp only [h1, h2, ↓reduceIte] at hres; exact congrArg ok hres
  · simp only [h1, h2, ↓reduceIte] at hres
    split_ifs at hres with h3'
    · exact congrArg ok hres
    · exact absurd h3 h3'
  · rw [i64_shr_i32_const _ 29#i32 (by norm_num) (by norm_num), result_bind_ok]
    have h29 : (29#i32).val.toNat = 29 := by norm_num
    rw [h29]
    simp only [h1, h2, h3, ↓reduceIte] at hres
    split_ifs with hp
    · simp only [hp, ↓reduceIte] at hres; exact congrArg ok hres
    · rw [i64_shl_i32_const _ 31#i32 (by norm_num) (by norm_num), result_bind_ok]
      have h31 : (31#i32).val.toNat = 31 := by norm_num
      rw [h31]; simp only [hp, ↓reduceIte] at hres; exact congrArg ok hres
  · rw [i64_shl_i32_const _ 31#i32 (by norm_num) (by norm_num), result_bind_ok]
    have h31 : (31#i32).val.toNat = 31 := by norm_num
    rw [h31]; simp only [h1, h4, ↓reduceIte] at hres; exact congrArg ok hres
  · simp only [h1, h4, h5, Bool.false_eq_true, ↓reduceIte] at hres
    split_ifs at hres with h6'
    · exact congrArg ok hres
    · exact absurd h6 h6'
  · rw [i64_shl_i32_const _ 31#i32 (by norm_num) (by norm_num), result_bind_ok]
    rw [i64_shl_i32_const _ 23#i32 (by norm_num) (by norm_num), result_bind_ok]
    rw [i64_shr_i32_const _ 29#i32 (by norm_num) (by norm_num), result_bind_ok]
    have h31 : (31#i32).val.toNat = 31 := by norm_num
    have h23 : (23#i32).val.toNat = 23 := by norm_num
    have h29 : (29#i32).val.toNat = 29 := by norm_num
    rw [h31, h23, h29]; simp only [h1, h4, h5, h6, Bool.false_eq_true, ↓reduceIte] at hres; exact congrArg ok hres
  · exfalso; exact hnsub ⟨h1, Bool.eq_false_iff.mpr h4, Bool.eq_false_iff.mpr h5, h7⟩
  · simp only [h1, h4, h5, Bool.false_eq_true, ↓reduceIte] at hres; exact congrArg ok hres

/-- `double_bits_to_float32_exact` never silently loses precision on normal-range values with non-zero low 29 mantissa bits. -/
theorem double_bits_to_float32_rejects_excess_precision (bits : Std.I64)
    (hexp_lo : 897 ≤ (Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)).val)
    (hexp_hi : (Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)).val ≤ 1150)
    (hlow : Pion.I64.band (Pion.I64.band bits 4503599627370495#i64) 536870911#i64 ≠ 0#i64) :
    double_bits_to_float32_exact bits = ok none := by
  unfold double_bits_to_float32_exact
  rw [i64_shr_i32_const bits 63#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i64_shr_i32_const bits 52#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h52 : (52#i32).val.toNat = 52 := by norm_num
  rw [h52]
  set exp := Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)
  have hne2047 : exp ≠ 2047#i32 := fun h => by
    have := (iscalar_eq_iff _ _).mp h; norm_num at this; omega
  have hne0 : (exp == 0#i32) = false := by
    apply beq_false_of_ne; intro h
    have := (iscalar_eq_iff _ _).mp h; norm_num at this; omega
  have he_val : (Pion.I32.sub exp 1023#i32).val = exp.val - 1023 := by
    have h1023 : (1023#i32).val = 1023 := by norm_num
    rw [i32_sub_val exp 1023#i32 (by omega) (by omega), h1023]
  have hrange : ((decide (Pion.I32.sub exp 1023#i32 ≥ (-126)#i32)) &&
      (decide (Pion.I32.sub exp 1023#i32 ≤ 127#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff, he_val]
    norm_num; omega
  simp only [hne2047, hne0, Bool.false_and, Bool.false_eq_true, hrange, ↓reduceIte]
  split_ifs with hc
  · rfl
  · exact absurd hlow hc

/-- `double_bits_to_float32_exact` rejects ANY binary64 NaN whose lower 29 payload bits are non-zero (strict bit-exactness). -/
theorem double_bits_to_float32_rejects_lossy_nan (bits : Std.I64)
    (hexp : Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64) = 2047#i32)
    (hfrac : Pion.I64.band bits 4503599627370495#i64 ≠ 0#i64)
    (hlow : Pion.I64.band (Pion.I64.band bits 4503599627370495#i64) 536870911#i64 ≠ 0#i64) :
    double_bits_to_float32_exact bits = ok none := by
  unfold double_bits_to_float32_exact
  rw [i64_shr_i32_const bits 63#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i64_shr_i32_const bits 52#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h52 : (52#i32).val.toNat = 52 := by norm_num
  rw [h52]
  simp only [hexp, hfrac, ↓reduceIte]
  split_ifs with hc
  · rfl
  · exact absurd hlow hc

/-- Universal IEEE-754 binary32 normal encoding: for EVERY normal binary32 (`0 <= u < 2^32`, `1 <= exp <= 254`),
    `float32_to_double_bits` succeeds and maps `exp` to `exp + 896` in bits `[52..62]` with exact 23-bit mantissa shifted by 29. -/
theorem float32_to_double_bits_normal_exact (u : Std.I64)
    (hu0 : 0 ≤ u.val) (hu1 : u.val ≤ 4294967295)
    (hexp1 : 1 ≤ (Pion.I64.to_int (Pion.I64.band (⟨u.bv.sshiftRight 23⟩ : Std.I64) 255#i64)).val)
    (hexp254 : (Pion.I64.to_int (Pion.I64.band (⟨u.bv.sshiftRight 23⟩ : Std.I64) 255#i64)).val ≤ 254) :
    ∃ d : Std.I64, float32_to_double_bits u = ok d ∧
      d.bv =
        ((Pion.I64.band (⟨u.bv.sshiftRight 31⟩ : Std.I64) 1#i64).bv <<< 63) |||
        ((BitVec.ofInt 64 ((Pion.I64.to_int (Pion.I64.band (⟨u.bv.sshiftRight 23⟩ : Std.I64) 255#i64)).val + 896)) <<< 52) |||
        ((Pion.I64.band u 8388607#i64).bv <<< 29) := by
  have hu_mask : Pion.I64.band u 4294967295#i64 = u := by
    unfold Pion.I64.band
    cases u with | mk uv =>
    change (⟨uv &&& (4294967295#i64).bv⟩ : Std.I64) = ⟨uv⟩
    congr 1
    apply BitVec.eq_of_toNat_eq
    have hpow : (2 : Nat) ^ IScalarTy.I64.numBits = 2 ^ 64 := rfl
    have hval : (⟨uv⟩ : Std.I64).val = uv.toInt := rfl
    rw [hval] at hu0 hu1
    have huv_lt : uv.toNat < 2 ^ 64 := by have := uv.isLt; rw [hpow] at this; exact this
    have huv_nat : uv.toNat = uv.toInt.toNat := by
      have hti := BitVec.toInt_eq_toNat_cond uv
      rw [hpow] at hti
      have hlt : 2 * uv.toNat < 2 ^ 64 := by
        by_contra hge; push Not at hge
        rw [ite_eq_right (by omega)] at hti
        omega
      rw [ite_eq_left hlt] at hti; omega
    rw [BitVec.toNat_and]
    have hmask : (4294967295#i64).bv.toNat = 4294967295 := by
      change (BitVec.ofInt 64 4294967295).toNat = 4294967295
      rw [BitVec.toNat_ofInt]; norm_num
    rw [hmask]
    have hlt : uv.toNat < 4294967296 := by omega
    have hmod : uv.toNat &&& 4294967295 = uv.toNat % 4294967296 := by
      have : (4294967295 : Nat) = 2 ^ 32 - 1 := by norm_num
      rw [this, Nat.and_two_pow_sub_one_eq_mod]
    rw [hmod, Nat.mod_eq_of_lt hlt]
  unfold float32_to_double_bits
  rw [hu_mask]
  dsimp only
  rw [i64_shr_i32_const u 31#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i64_shr_i32_const u 23#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h31n : (31#i32).val.toNat = 31 := by norm_num
  have h23n : (23#i32).val.toNat = 23 := by norm_num
  rw [h31n, h23n]
  set exp := Pion.I64.to_int (Pion.I64.band (⟨u.bv.sshiftRight 23⟩ : Std.I64) 255#i64)
  have hne0 : exp ≠ 0#i32 := fun e => by have := (iscalar_eq_iff _ _).mp e; norm_num at this; omega
  have hne255 : exp ≠ 255#i32 := fun e => by have := (iscalar_eq_iff _ _).mp e; norm_num at this; omega
  simp only [hne0, hne255, ↓reduceIte]
  rw [i64_shl_i32_const _ 29#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i64_shl_i32_const _ 63#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i64_shl_i32_const _ 52#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h29n : (29#i32).val.toNat = 29 := by norm_num
  have h63n : (63#i32).val.toNat = 63 := by norm_num
  have h52n : (52#i32).val.toNat = 52 := by norm_num
  rw [h29n, h63n, h52n]
  have he_add : (Pion.I32.add exp 896#i32).val = exp.val + 896 := by
    have h896 : (896#i32).val = 896 := by norm_num
    rw [i32_add_val exp 896#i32 (by omega) (by omega), h896]
  refine ⟨_, rfl, ?_⟩
  unfold Pion.I64.bor Pion.I32.to_int64
  change (((Pion.I64.band (⟨u.bv.sshiftRight 31⟩ : Std.I64) 1#i64).bv <<< 63) |||
      (BitVec.ofInt 64 (Pion.I32.add exp 896#i32).val) <<< 52) |||
      ((Pion.I64.band u 8388607#i64).bv <<< 29) = _
  rw [he_add]

end MsgpackProofs
