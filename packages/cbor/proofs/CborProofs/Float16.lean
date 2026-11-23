import CborProofs.Core

open Aeneas Aeneas.Std Result Pion cbor

namespace CborProofs

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

private lemma i32_shl_const (x : Std.I32) (k : Std.I32) (h0 : 0 ≤ k.val) (h32 : k.val < 32) :
    Pion.I32.shl x k = ok (⟨x.bv <<< k.val.toNat⟩ : Std.I32) := by
  unfold Pion.I32.shl
  have hc : 0 ≤ k.val ∧ k.val < 32 := ⟨h0, h32⟩
  simp only [hc, and_self, ↓reduceIte]

private lemma i32_shr_const (x : Std.I32) (k : Std.I32) (h0 : 0 ≤ k.val) (h32 : k.val < 32) :
    Pion.I32.shr x k = ok (⟨x.bv.sshiftRight k.val.toNat⟩ : Std.I32) := by
  unfold Pion.I32.shr
  have hc : 0 ≤ k.val ∧ k.val < 32 := ⟨h0, h32⟩
  simp only [hc, and_self, ↓reduceIte]

private lemma i32_sub_val (a b : Std.I32)
    (hlo : -(2147483648 : Int) ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  simp only [Pion.I32.sub, Std.I32.wrapping_sub, IScalar.wrapping_sub, IScalar.val, BitVec.toInt_sub]
  have hpow : (2 : Nat) ^ IScalarTy.I32.numBits = 2 ^ 32 := rfl
  rw [hpow]
  change (a.val - b.val).bmod (2 ^ 32) = a.val - b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

private lemma i32_add_val (a b : Std.I32)
    (hlo : -(2147483648 : Int) ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  simp only [Pion.I32.add, Std.I32.wrapping_add, IScalar.wrapping_add, IScalar.val, BitVec.toInt_add]
  have hpow : (2 : Nat) ^ IScalarTy.I32.numBits = 2 ^ 32 := rfl
  rw [hpow]
  change (a.val + b.val).bmod (2 ^ 32) = a.val + b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

private lemma eval_f16_rt (h : Std.I32) :
    (do let d ← float16_to_double_bits h; double_bits_to_float16_exact d) = ok (some h) ↔
    ∃ d, float16_to_double_bits h = ok d ∧ double_bits_to_float16_exact d = ok (some h) := by
  constructor
  · intro heq
    cases hd : float16_to_double_bits h with
    | ret d => rw [hd, result_bind_ok] at heq; exact ⟨d, rfl, heq⟩
    | _ => rw [hd] at heq; simp at heq
  · rintro ⟨d, h1, h2⟩; rw [h1, result_bind_ok, h2]

private lemma eval_f32_rt (u : Std.I64) :
    (do let d ← float32_to_double_bits u; double_bits_to_float32_exact d) = ok (some u) ↔
    ∃ d, float32_to_double_bits u = ok d ∧ double_bits_to_float32_exact d = ok (some u) := by
  constructor
  · intro heq
    cases hd : float32_to_double_bits u with
    | ret d => rw [hd, result_bind_ok] at heq; exact ⟨d, rfl, heq⟩
    | _ => rw [hd] at heq; simp at heq
  · rintro ⟨d, h1, h2⟩; rw [h1, result_bind_ok, h2]

/-- Pure step-evaluator for non-subnormal `float16_to_double_bits` on concrete inputs. -/
private theorem f16_to_f64_concrete (h : Std.I32) (d : Std.I64)
    (he0 : Pion.I32.band (⟨(Pion.I32.band h 65535#i32).bv.sshiftRight 10⟩ : Std.I32) 31#i32 ≠ 0#i32 ∨
           Pion.I32.band (Pion.I32.band h 65535#i32) 1023#i32 = 0#i32)
    (hres :
      let m := Pion.I32.band h 65535#i32
      let sign := Pion.I32.to_int64 (Pion.I32.band (⟨m.bv.sshiftRight 15⟩ : Std.I32) 1#i32)
      let exp := Pion.I32.band (⟨m.bv.sshiftRight 10⟩ : Std.I32) 31#i32
      let frac := Pion.I32.band m 1023#i32
      (if exp = 0#i32 then (⟨sign.bv <<< 63⟩ : Std.I64)
       else if exp = 31#i32 then
         if frac = 0#i32 then Pion.I64.bor ⟨sign.bv <<< 63⟩ ⟨(2047#i64).bv <<< 52⟩
         else Pion.I64.bor (Pion.I64.bor ⟨sign.bv <<< 63⟩ ⟨(2047#i64).bv <<< 52⟩) ⟨(Pion.I32.to_int64 frac).bv <<< 42⟩
       else
         Pion.I64.bor (Pion.I64.bor ⟨sign.bv <<< 63⟩ ⟨(Pion.I32.to_int64 (Pion.I32.add exp 1008#i32)).bv <<< 52⟩)
           ⟨(Pion.I32.to_int64 frac).bv <<< 42⟩) = d) :
    float16_to_double_bits h = ok d := by
  unfold float16_to_double_bits
  dsimp only
  rw [i32_shr_const _ 15#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i32_shr_const _ 10#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h15 : (15#i32).val.toNat = 15 := by norm_num
  have h10 : (10#i32).val.toNat = 10 := by norm_num
  rw [h15, h10]
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
  · rw [i64_shl_i32_const _ 42#i32 (by norm_num) (by norm_num), result_bind_ok]
    rw [i64_shl_i32_const _ 63#i32 (by norm_num) (by norm_num), result_bind_ok]
    rw [i64_shl_i32_const _ 52#i32 (by norm_num) (by norm_num), result_bind_ok]
    have h42 : (42#i32).val.toNat = 42 := by norm_num
    have h63 : (63#i32).val.toNat = 63 := by norm_num
    have h52 : (52#i32).val.toNat = 52 := by norm_num
    rw [h42, h63, h52]; simp only [h3, h4, ↓reduceIte] at hres; exact congrArg ok hres
  · rw [i64_shl_i32_const _ 42#i32 (by norm_num) (by norm_num), result_bind_ok]
    rw [i64_shl_i32_const _ 63#i32 (by norm_num) (by norm_num), result_bind_ok]
    rw [i64_shl_i32_const _ 52#i32 (by norm_num) (by norm_num), result_bind_ok]
    have h42 : (42#i32).val.toNat = 42 := by norm_num
    have h63 : (63#i32).val.toNat = 63 := by norm_num
    have h52 : (52#i32).val.toNat = 52 := by norm_num
    rw [h42, h63, h52]; simp only [h1, h3, ↓reduceIte] at hres; exact congrArg ok hres

/-- Pure step-evaluator for non-subnormal `double_bits_to_float16_exact` on concrete inputs. -/
private theorem f64_to_f16_concrete (bits : Std.I64) (out : Option Std.I32)
    (hres :
      let sign := Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 63⟩ : Std.I64) 1#i64)
      let exp := Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)
      let frac := Pion.I64.band bits 4503599627370495#i64
      let e := Pion.I32.sub exp 1023#i32
      (if exp = 2047#i32 then
         if frac = 0#i64 then some (Pion.I32.bor ⟨sign.bv <<< 15⟩ 31744#i32)
         else some 32256#i32
       else if ((exp == 0#i32) && (frac == 0#i64)) then some ⟨sign.bv <<< 15⟩
       else if ((decide (e >= (-14)#i32)) && (decide (e <= 15#i32))) then
         if Pion.I64.band frac 4398046511103#i64 ≠ 0#i64 then none
         else some (Pion.I32.bor (Pion.I32.bor ⟨sign.bv <<< 15⟩ ⟨(Pion.I32.add e 15#i32).bv <<< 10⟩)
           (Pion.I64.to_int (Pion.I64.band (⟨frac.bv.sshiftRight 42⟩ : Std.I64) 1023#i64)))
       else none) = out)
    (hnsub : ¬(Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64) ≠ 2047#i32 ∧
               ((Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64) == 0#i32) &&
                (Pion.I64.band bits 4503599627370495#i64 == 0#i64)) = false ∧
               ((decide (Pion.I32.sub (Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)) 1023#i32 ≥ (-14)#i32)) &&
                (decide (Pion.I32.sub (Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)) 1023#i32 ≤ 15#i32))) = false ∧
               ((decide (Pion.I32.sub (Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)) 1023#i32 ≥ (-24)#i32)) &&
                (decide (Pion.I32.sub (Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)) 1023#i32 ≤ (-15)#i32))) = true)) :
    double_bits_to_float16_exact bits = ok out := by
  unfold double_bits_to_float16_exact
  rw [i64_shr_i32_const bits 63#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i64_shr_i32_const bits 52#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h63 : (63#i32).val.toNat = 63 := by norm_num
  have h52 : (52#i32).val.toNat = 52 := by norm_num
  rw [h63, h52]
  dsimp only at hres hnsub ⊢
  split_ifs with h1 h2 h3 h4 h5 h6
  · rw [i32_shl_const _ 15#i32 (by norm_num) (by norm_num), result_bind_ok]
    have h15 : (15#i32).val.toNat = 15 := by norm_num
    rw [h15]; simp only [h1, h2, ↓reduceIte] at hres; exact congrArg ok hres
  · simp only [h1, h2, ↓reduceIte] at hres; exact congrArg ok hres
  · rw [i32_shl_const _ 15#i32 (by norm_num) (by norm_num), result_bind_ok]
    have h15 : (15#i32).val.toNat = 15 := by norm_num
    rw [h15]; simp only [h1, h3, ↓reduceIte] at hres; exact congrArg ok hres
  · simp only [h1, h3, h4, Bool.false_eq_true, ↓reduceIte] at hres
    split_ifs at hres with h5'
    · exact congrArg ok hres
    · exact absurd h5 h5'
  · rw [i32_shl_const _ 15#i32 (by norm_num) (by norm_num), result_bind_ok]
    rw [i32_shl_const _ 10#i32 (by norm_num) (by norm_num), result_bind_ok]
    rw [i64_shr_i32_const _ 42#i32 (by norm_num) (by norm_num), result_bind_ok]
    have h15 : (15#i32).val.toNat = 15 := by norm_num
    have h10 : (10#i32).val.toNat = 10 := by norm_num
    have h42 : (42#i32).val.toNat = 42 := by norm_num
    rw [h15, h10, h42]; simp only [h1, h3, h4, h5, Bool.false_eq_true, ↓reduceIte] at hres; exact congrArg ok hres
  · exfalso; exact hnsub ⟨h1, Bool.eq_false_iff.mpr h3, Bool.eq_false_iff.mpr h4, h6⟩
  · simp only [h1, h3, h4, Bool.false_eq_true, ↓reduceIte] at hres; exact congrArg ok hres

/-- Pure step-evaluator for non-subnormal `float32_to_double_bits` on concrete inputs. -/
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

/-- Pure step-evaluator for non-subnormal `double_bits_to_float32_exact` on concrete inputs. -/
private theorem f64_to_f32_concrete (bits : Std.I64) (out : Option Std.I64)
    (hres :
      let sign := Pion.I64.band (⟨bits.bv.sshiftRight 63⟩ : Std.I64) 1#i64
      let exp := Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)
      let frac := Pion.I64.band bits 4503599627370495#i64
      let e := Pion.I32.sub exp 1023#i32
      (if exp = 2047#i32 then
         if frac = 0#i64 then some (Pion.I64.bor ⟨sign.bv <<< 31⟩ 2139095040#i64)
         else some 2143289344#i64
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
  split_ifs with h1 h2 h3 h4 h5 h6
  · rw [i64_shl_i32_const _ 31#i32 (by norm_num) (by norm_num), result_bind_ok]
    have h31 : (31#i32).val.toNat = 31 := by norm_num
    rw [h31]; simp only [h1, h2, ↓reduceIte] at hres; exact congrArg ok hres
  · simp only [h1, h2, ↓reduceIte] at hres; exact congrArg ok hres
  · rw [i64_shl_i32_const _ 31#i32 (by norm_num) (by norm_num), result_bind_ok]
    have h31 : (31#i32).val.toNat = 31 := by norm_num
    rw [h31]; simp only [h1, h3, ↓reduceIte] at hres; exact congrArg ok hres
  · simp only [h1, h3, h4, Bool.false_eq_true, ↓reduceIte] at hres
    split_ifs at hres with h5'
    · exact congrArg ok hres
    · exact absurd h5 h5'
  · rw [i64_shl_i32_const _ 31#i32 (by norm_num) (by norm_num), result_bind_ok]
    rw [i64_shl_i32_const _ 23#i32 (by norm_num) (by norm_num), result_bind_ok]
    rw [i64_shr_i32_const _ 29#i32 (by norm_num) (by norm_num), result_bind_ok]
    have h31 : (31#i32).val.toNat = 31 := by norm_num
    have h23 : (23#i32).val.toNat = 23 := by norm_num
    have h29 : (29#i32).val.toNat = 29 := by norm_num
    rw [h31, h23, h29]; simp only [h1, h3, h4, h5, Bool.false_eq_true, ↓reduceIte] at hres; exact congrArg ok hres
  · exfalso; exact hnsub ⟨h1, Bool.eq_false_iff.mpr h3, Bool.eq_false_iff.mpr h4, h6⟩
  · simp only [h1, h3, h4, Bool.false_eq_true, ↓reduceIte] at hres; exact congrArg ok hres

/-- IEEE-754 binary16 `+0.0` (`0x0000`) roundtrips cleanly through binary64. -/
theorem float16_pos_zero_roundtrip :
    (do let d ← float16_to_double_bits 0#i32; double_bits_to_float16_exact d) = ok (some 0#i32) := by
  rw [eval_f16_rt]
  exact ⟨0#i64, f16_to_f64_concrete _ _ (by decide) (by decide), f64_to_f16_concrete _ _ (by decide) (by decide)⟩

/-- IEEE-754 binary16 `-0.0` (`0x8000`) roundtrips cleanly and preserves the negative zero sign bit. -/
theorem float16_neg_zero_roundtrip :
    (do let d ← float16_to_double_bits 32768#i32; double_bits_to_float16_exact d) = ok (some 32768#i32) := by
  rw [eval_f16_rt]
  exact ⟨⟨(1#i64).bv <<< 63⟩, f16_to_f64_concrete _ _ (by decide) (by decide), f64_to_f16_concrete _ _ (by decide) (by decide)⟩

/-- IEEE-754 binary16 `+Inf` (`0x7C00`) and `-Inf` (`0xFC00`) roundtrip cleanly. -/
theorem float16_inf_roundtrip :
    (do let d ← float16_to_double_bits 31744#i32; double_bits_to_float16_exact d) = ok (some 31744#i32) ∧
    (do let d ← float16_to_double_bits 64512#i32; double_bits_to_float16_exact d) = ok (some 64512#i32) := by
  constructor
  · rw [eval_f16_rt]
    exact ⟨⟨(2047#i64).bv <<< 52⟩, f16_to_f64_concrete _ _ (by decide) (by decide), f64_to_f16_concrete _ _ (by decide) (by decide)⟩
  · rw [eval_f16_rt]
    exact ⟨Pion.I64.bor ⟨(1#i64).bv <<< 63⟩ ⟨(2047#i64).bv <<< 52⟩,
      f16_to_f64_concrete _ _ (by decide) (by decide), f64_to_f16_concrete _ _ (by decide) (by decide)⟩

/-- RFC 8949 §4.2.1: canonical CBOR NaN (`0x7E00`) roundtrips cleanly. -/
theorem float16_canonical_nan_roundtrip :
    (do let d ← float16_to_double_bits 32256#i32; double_bits_to_float16_exact d) = ok (some 32256#i32) := by
  rw [eval_f16_rt]
  exact ⟨Pion.I64.bor ⟨(2047#i64).bv <<< 52⟩ ⟨(512#i64).bv <<< 42⟩,
    f16_to_f64_concrete _ _ (by decide) (by decide), f64_to_f16_concrete _ _ (by decide) (by decide)⟩

/-- RFC 8949 §4.2.1: ANY binary64 NaN (`exp = 0x7FF`, `frac != 0`) canonicalizes to `0x7E00` in float16. -/
theorem double_bits_to_float16_any_nan_canonical (bits : Std.I64)
    (hexp : Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64) = 2047#i32)
    (hfrac : Pion.I64.band bits 4503599627370495#i64 ≠ 0#i64) :
    double_bits_to_float16_exact bits = ok (some 32256#i32) := by
  unfold double_bits_to_float16_exact
  rw [i64_shr_i32_const bits 63#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i64_shr_i32_const bits 52#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h52 : (52#i32).val.toNat = 52 := by norm_num
  rw [h52]
  simp only [hexp, hfrac, ↓reduceIte]

/-- `double_bits_to_float16_exact` never silently loses precision on normal-range values with non-zero low 42 mantissa bits. -/
theorem double_bits_to_float16_rejects_excess_precision (bits : Std.I64)
    (hexp_lo : 1009 ≤ (Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)).val)
    (hexp_hi : (Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)).val ≤ 1038)
    (hlow : Pion.I64.band (Pion.I64.band bits 4503599627370495#i64) 4398046511103#i64 ≠ 0#i64) :
    double_bits_to_float16_exact bits = ok none := by
  unfold double_bits_to_float16_exact
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
  have hrange : ((decide (Pion.I32.sub exp 1023#i32 ≥ (-14)#i32)) &&
      (decide (Pion.I32.sub exp 1023#i32 ≤ 15#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff, he_val]
    norm_num; omega
  simp only [hne2047, hne0, Bool.false_and, Bool.false_eq_true, hrange, ↓reduceIte]
  split_ifs with hc
  · rfl
  · exact absurd hlow hc

/-- IEEE-754 binary32 `+0.0` (`0x00000000`) and `-0.0` (`0x80000000`) roundtrip cleanly. -/
theorem float32_zero_roundtrip :
    (do let d ← float32_to_double_bits 0#i64; double_bits_to_float32_exact d) = ok (some 0#i64) ∧
    (do let d ← float32_to_double_bits 2147483648#i64; double_bits_to_float32_exact d) = ok (some 2147483648#i64) := by
  constructor
  · rw [eval_f32_rt]
    exact ⟨0#i64, f32_to_f64_concrete _ _ (by decide) (by decide), f64_to_f32_concrete _ _ (by decide) (by decide)⟩
  · rw [eval_f32_rt]
    exact ⟨⟨(1#i64).bv <<< 63⟩, f32_to_f64_concrete _ _ (by decide) (by decide), f64_to_f32_concrete _ _ (by decide) (by decide)⟩

/-- IEEE-754 binary32 `+Inf` (`0x7F800000`) and `-Inf` (`0xFF800000`) roundtrip cleanly. -/
theorem float32_inf_roundtrip :
    (do let d ← float32_to_double_bits 2139095040#i64; double_bits_to_float32_exact d) = ok (some 2139095040#i64) ∧
    (do let d ← float32_to_double_bits 4286578688#i64; double_bits_to_float32_exact d) = ok (some 4286578688#i64) := by
  constructor
  · rw [eval_f32_rt]
    exact ⟨⟨(2047#i64).bv <<< 52⟩, f32_to_f64_concrete _ _ (by decide) (by decide), f64_to_f32_concrete _ _ (by decide) (by decide)⟩
  · rw [eval_f32_rt]
    exact ⟨Pion.I64.bor ⟨(1#i64).bv <<< 63⟩ ⟨(2047#i64).bv <<< 52⟩,
      f32_to_f64_concrete _ _ (by decide) (by decide), f64_to_f32_concrete _ _ (by decide) (by decide)⟩

/-- RFC 8949: ANY binary64 NaN canonicalizes to quiet NaN `0x7FC00000` in float32. -/
theorem double_bits_to_float32_any_nan_canonical (bits : Std.I64)
    (hexp : Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64) = 2047#i32)
    (hfrac : Pion.I64.band bits 4503599627370495#i64 ≠ 0#i64) :
    double_bits_to_float32_exact bits = ok (some 2143289344#i64) := by
  unfold double_bits_to_float32_exact
  rw [i64_shr_i32_const bits 63#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i64_shr_i32_const bits 52#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h52 : (52#i32).val.toNat = 52 := by norm_num
  rw [h52]
  simp only [hexp, hfrac, ↓reduceIte]

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

/-- IEEE-754 binary16 normal spot roundtrips: `1.0` (`0x3C00`), `1.5` (`0x3E00`), `-4.0` (`0xC400`), `65504.0` (`0x7BFF`), min normal `2^-14` (`0x0400`). -/
theorem float16_normal_spots_roundtrip :
    (do let d ← float16_to_double_bits 15360#i32; double_bits_to_float16_exact d) = ok (some 15360#i32) ∧
    (do let d ← float16_to_double_bits 15872#i32; double_bits_to_float16_exact d) = ok (some 15872#i32) ∧
    (do let d ← float16_to_double_bits 50176#i32; double_bits_to_float16_exact d) = ok (some 50176#i32) ∧
    (do let d ← float16_to_double_bits 31743#i32; double_bits_to_float16_exact d) = ok (some 31743#i32) ∧
    (do let d ← float16_to_double_bits 1024#i32; double_bits_to_float16_exact d) = ok (some 1024#i32) := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · rw [eval_f16_rt]
    exact ⟨⟨(1023#i64).bv <<< 52⟩, f16_to_f64_concrete _ _ (by decide) (by decide), f64_to_f16_concrete _ _ (by decide) (by decide)⟩
  · rw [eval_f16_rt]
    exact ⟨Pion.I64.bor ⟨(1023#i64).bv <<< 52⟩ ⟨(512#i64).bv <<< 42⟩,
      f16_to_f64_concrete _ _ (by decide) (by decide), f64_to_f16_concrete _ _ (by decide) (by decide)⟩
  · rw [eval_f16_rt]
    exact ⟨Pion.I64.bor ⟨(1#i64).bv <<< 63⟩ ⟨(1025#i64).bv <<< 52⟩,
      f16_to_f64_concrete _ _ (by decide) (by decide), f64_to_f16_concrete _ _ (by decide) (by decide)⟩
  · rw [eval_f16_rt]
    exact ⟨Pion.I64.bor ⟨(1038#i64).bv <<< 52⟩ ⟨(1023#i64).bv <<< 42⟩,
      f16_to_f64_concrete _ _ (by decide) (by decide), f64_to_f16_concrete _ _ (by decide) (by decide)⟩
  · rw [eval_f16_rt]
    exact ⟨⟨(1009#i64).bv <<< 52⟩, f16_to_f64_concrete _ _ (by decide) (by decide), f64_to_f16_concrete _ _ (by decide) (by decide)⟩

/-- Universal IEEE-754 binary16 normal encoding: for EVERY normal binary16 (`0 <= h < 65536`, `1 <= exp <= 30`),
    `float16_to_double_bits` succeeds without overflow and maps `exp` to `exp + 1008` in bits `[52..62]`
    with zero low 42 mantissa bits. -/
theorem float16_to_double_bits_normal_exact (h : Std.I32)
    (hh0 : 0 ≤ h.val) (hh1 : h.val ≤ 65535)
    (hexp1 : 1 ≤ (Pion.I32.band (⟨h.bv.sshiftRight 10⟩ : Std.I32) 31#i32).val)
    (hexp30 : (Pion.I32.band (⟨h.bv.sshiftRight 10⟩ : Std.I32) 31#i32).val ≤ 30) :
    ∃ d : Std.I64, float16_to_double_bits h = ok d ∧
      d.bv =
        ((BitVec.ofInt 64 (Pion.I32.band (⟨h.bv.sshiftRight 15⟩ : Std.I32) 1#i32).val) <<< 63) |||
        ((BitVec.ofInt 64 ((Pion.I32.band (⟨h.bv.sshiftRight 10⟩ : Std.I32) 31#i32).val + 1008)) <<< 52) |||
        ((BitVec.ofInt 64 (Pion.I32.band h 1023#i32).val) <<< 42) := by
  have hh_mask : Pion.I32.band h 65535#i32 = h := by
    unfold Pion.I32.band
    cases h with | mk hv =>
    change (⟨hv &&& (65535#i32).bv⟩ : Std.I32) = ⟨hv⟩
    congr 1
    apply BitVec.eq_of_toNat_eq
    have hpow : (2 : Nat) ^ IScalarTy.I32.numBits = 2 ^ 32 := rfl
    have hval : (⟨hv⟩ : Std.I32).val = hv.toInt := rfl
    rw [hval] at hh0 hh1
    have hv_lt : hv.toNat < 2 ^ 32 := by have := hv.isLt; rw [hpow] at this; exact this
    have hv_nat : hv.toNat = hv.toInt.toNat := by
      have hti := BitVec.toInt_eq_toNat_cond hv
      rw [hpow] at hti
      have hlt : 2 * hv.toNat < 2 ^ 32 := by
        by_contra hge; push Not at hge
        rw [ite_eq_right (by omega)] at hti
        omega
      rw [ite_eq_left hlt] at hti; omega
    rw [BitVec.toNat_and]
    have h65535 : (65535#i32).bv.toNat = 65535 := by norm_num
    rw [h65535]
    have hlt : hv.toNat < 65536 := by omega
    have hmod : hv.toNat &&& 65535 = hv.toNat % 65536 := by
      have : (65535 : Nat) = 2 ^ 16 - 1 := by norm_num
      rw [this, Nat.and_two_pow_sub_one_eq_mod]
    rw [hmod, Nat.mod_eq_of_lt hlt]
  unfold float16_to_double_bits
  rw [hh_mask]
  dsimp only
  rw [i32_shr_const h 15#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i32_shr_const h 10#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h15n : (15#i32).val.toNat = 15 := by norm_num
  have h10n : (10#i32).val.toNat = 10 := by norm_num
  rw [h15n, h10n]
  set exp := Pion.I32.band (⟨h.bv.sshiftRight 10⟩ : Std.I32) 31#i32
  have hne0 : exp ≠ 0#i32 := fun e => by have := (iscalar_eq_iff _ _).mp e; norm_num at this; omega
  have hne31 : exp ≠ 31#i32 := fun e => by have := (iscalar_eq_iff _ _).mp e; norm_num at this; omega
  simp only [hne0, hne31, ↓reduceIte]
  rw [i64_shl_i32_const _ 42#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i64_shl_i32_const _ 63#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i64_shl_i32_const _ 52#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h42n : (42#i32).val.toNat = 42 := by norm_num
  have h63n : (63#i32).val.toNat = 63 := by norm_num
  have h52n : (52#i32).val.toNat = 52 := by norm_num
  rw [h42n, h63n, h52n]
  have he_add : (Pion.I32.add exp 1008#i32).val = exp.val + 1008 := by
    have h1008 : (1008#i32).val = 1008 := by norm_num
    rw [i32_add_val exp 1008#i32 (by omega) (by omega), h1008]
  refine ⟨_, rfl, ?_⟩
  unfold Pion.I64.bor Pion.I32.to_int64
  change ((BitVec.ofInt 64 (Pion.I32.band (⟨h.bv.sshiftRight 15⟩ : Std.I32) 1#i32).val) <<< 63 |||
      (BitVec.ofInt 64 (Pion.I32.add exp 1008#i32).val) <<< 52) |||
      (BitVec.ofInt 64 (Pion.I32.band h 1023#i32).val) <<< 42 = _
  rw [he_add]

end CborProofs
