import Aeneas
import PionLean
import Crypto.Types
import Crypto.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion crypto

namespace CryptoProofs

/-! ## Curve25519 GF(2^255 - 19) Ref10 Radix-2^25.5 Semantics -/

/-- Prime modulus `p = 2^255 - 19` of Curve25519 / Ed25519. -/
def p25519 : Int := 2 ^ 255 - 19

/-- Mathematical integer value of a Ref10 10-limb signed radix-`2^25.5` field element. -/
def feVal (f : Fe) : Int :=
  f.h0.val
    + f.h1.val * 2 ^ 26
    + f.h2.val * 2 ^ 51
    + f.h3.val * 2 ^ 77
    + f.h4.val * 2 ^ 102
    + f.h5.val * 2 ^ 128
    + f.h6.val * 2 ^ 153
    + f.h7.val * 2 ^ 179
    + f.h8.val * 2 ^ 204
    + f.h9.val * 2 ^ 230

/-- Limb magnitude bound `|f.h_i| ≤ B` for all 10 limbs. -/
def feBounded (f : Fe) (B : Int) : Prop :=
  -B ≤ f.h0.val ∧ f.h0.val ≤ B ∧
  -B ≤ f.h1.val ∧ f.h1.val ≤ B ∧
  -B ≤ f.h2.val ∧ f.h2.val ≤ B ∧
  -B ≤ f.h3.val ∧ f.h3.val ≤ B ∧
  -B ≤ f.h4.val ∧ f.h4.val ≤ B ∧
  -B ≤ f.h5.val ∧ f.h5.val ≤ B ∧
  -B ≤ f.h6.val ∧ f.h6.val ≤ B ∧
  -B ≤ f.h7.val ∧ f.h7.val ≤ B ∧
  -B ≤ f.h8.val ∧ f.h8.val ≤ B ∧
  -B ≤ f.h9.val ∧ f.h9.val ≤ B

/-- Post-carry Ref10 reduced limb bounds (strictly implies `feBounded r (2^26)`). -/
def feCarryReduced (r : Fe) : Prop :=
  -(2 ^ 25) ≤ r.h0.val ∧ r.h0.val ≤ 2 ^ 25 ∧
  -(2 ^ 25) ≤ r.h1.val ∧ r.h1.val ≤ 2 ^ 25 ∧
  -(2 ^ 25) ≤ r.h2.val ∧ r.h2.val ≤ 2 ^ 25 ∧
  -(2 ^ 24) ≤ r.h3.val ∧ r.h3.val ≤ 2 ^ 24 ∧
  -(2 ^ 25) ≤ r.h4.val ∧ r.h4.val ≤ 2 ^ 25 ∧
  -(2 ^ 25) ≤ r.h5.val ∧ r.h5.val ≤ 2 ^ 25 ∧
  -(2 ^ 25) ≤ r.h6.val ∧ r.h6.val ≤ 2 ^ 25 ∧
  -(2 ^ 24) ≤ r.h7.val ∧ r.h7.val ≤ 2 ^ 24 ∧
  -(2 ^ 25) ≤ r.h8.val ∧ r.h8.val ≤ 2 ^ 25 ∧
  -(2 ^ 24) ≤ r.h9.val ∧ r.h9.val ≤ 2 ^ 24

/-! ## Fast Exact Non-Overflowing `I64` / `U64` Helpers -/

private lemma result_bind_ok_fp {α β : Type} (a : α) (f : α → Result β) :
    (do let x ← ok a; f x) = f a := by simp

private lemma i64_add_val (x y : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val + y.val)
    (hhi : x.val + y.val ≤ 9223372036854775807) :
    (Pion.I64.add x y).val = x.val + y.val := by
  unfold Pion.I64.add
  change (x.bv + y.bv).toInt = x.val + y.val
  rw [BitVec.toInt_add]
  have hx : x.bv.toInt = x.val := rfl
  have hy : y.bv.toInt = y.val := rfl
  rw [hx, hy]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i64_sub_val (x y : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val - y.val)
    (hhi : x.val - y.val ≤ 9223372036854775807) :
    (Pion.I64.sub x y).val = x.val - y.val := by
  unfold Pion.I64.sub
  change (x.bv - y.bv).toInt = x.val - y.val
  rw [BitVec.toInt_sub]
  have hx : x.bv.toInt = x.val := rfl
  have hy : y.bv.toInt = y.val := rfl
  rw [hx, hy]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i64_mul_val (x y : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val * y.val)
    (hhi : x.val * y.val ≤ 9223372036854775807) :
    (Pion.I64.mul x y).val = x.val * y.val := by
  unfold Pion.I64.mul
  change (x.bv * y.bv).toInt = x.val * y.val
  rw [BitVec.toInt_mul]
  have hx : x.bv.toInt = x.val := rfl
  have hy : y.bv.toInt = y.val := rfl
  rw [hx, hy]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i64_shr_26_eval (x : Std.I64) :
    Pion.I64.shr_i32 x 26#i32 = ok ⟨x.bv.sshiftRight 26⟩ := by
  unfold Pion.I64.shr_i32
  have h : (0 : Int) ≤ (26#i32).val ∧ (26#i32).val < 64 := by decide
  simp only [h, and_self, ↓reduceIte]; rfl

private lemma i64_shr_25_eval (x : Std.I64) :
    Pion.I64.shr_i32 x 25#i32 = ok ⟨x.bv.sshiftRight 25⟩ := by
  unfold Pion.I64.shr_i32
  have h : (0 : Int) ≤ (25#i32).val ∧ (25#i32).val < 64 := by decide
  simp only [h, and_self, ↓reduceIte]; rfl

private lemma i64_shl_26_eval (x : Std.I64) :
    Pion.I64.shl_i32 x 26#i32 = ok ⟨x.bv <<< 26⟩ := by
  unfold Pion.I64.shl_i32
  have h : (0 : Int) ≤ (26#i32).val ∧ (26#i32).val < 64 := by decide
  simp only [h, and_self, ↓reduceIte]; rfl

private lemma i64_shl_25_eval (x : Std.I64) :
    Pion.I64.shl_i32 x 25#i32 = ok ⟨x.bv <<< 25⟩ := by
  unfold Pion.I64.shl_i32
  have h : (0 : Int) ≤ (25#i32).val ∧ (25#i32).val < 64 := by decide
  simp only [h, and_self, ↓reduceIte]; rfl

private lemma i64_sshiftRight_val (x : Std.I64) (k : Nat) :
    (⟨x.bv.sshiftRight k⟩ : Std.I64).val = x.val / (2 ^ k : Int) := by
  change (x.bv.sshiftRight k).toInt = x.bv.toInt / (2 ^ k : Int)
  rw [BitVec.toInt_sshiftRight, Int.shiftRight_eq_div_pow]
  push_cast; rfl

private lemma i64_shl26_val (x : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val * (2 ^ 26 : Int))
    (hhi : x.val * (2 ^ 26 : Int) ≤ 9223372036854775807) :
    (⟨x.bv <<< 26⟩ : Std.I64).val = x.val * (2 ^ 26 : Int) := by
  change (x.bv <<< 26).toInt = x.val * (2 ^ 26 : Int)
  rw [BitVec.shiftLeft_eq_mul_twoPow, BitVec.toInt_mul]
  have hx : x.bv.toInt = x.val := rfl
  have h2 : (BitVec.twoPow 64 26).toInt = (2 ^ 26 : Int) := by decide
  rw [hx, h2]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i64_shl25_val (x : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val * (2 ^ 25 : Int))
    (hhi : x.val * (2 ^ 25 : Int) ≤ 9223372036854775807) :
    (⟨x.bv <<< 25⟩ : Std.I64).val = x.val * (2 ^ 25 : Int) := by
  change (x.bv <<< 25).toInt = x.val * (2 ^ 25 : Int)
  rw [BitVec.shiftLeft_eq_mul_twoPow, BitVec.toInt_mul]
  have hx : x.bv.toInt = x.val := rfl
  have h2 : (BitVec.twoPow 64 25).toInt = (2 ^ 25 : Int) := by decide
  rw [hx, h2]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma carry26_step (h c h' : Std.I64) (B : Int)
    (hc_eq : c = ⟨(Pion.I64.add h 33554432#i64).bv.sshiftRight 26⟩)
    (hh'_eq : h' = Pion.I64.sub h ⟨c.bv <<< 26⟩)
    (hB : 0 ≤ B) (hBmax : B ≤ 8000000000000000000)
    (hlo : -B ≤ h.val) (hhi : h.val ≤ B) :
    h'.val = h.val - c.val * 2 ^ 26 ∧
    -(2 ^ 25) ≤ h'.val ∧ h'.val ≤ 2 ^ 25 ∧
    -(B / 2 ^ 26 + 1) ≤ c.val ∧ c.val ≤ B / 2 ^ 26 + 1 := by
  subst hc_eq; subst hh'_eq
  have hbias : (33554432#i64).val = 33554432 := rfl
  have hadd : (Pion.I64.add h 33554432#i64).val = h.val + 33554432 := by
    have := i64_add_val h 33554432#i64 (by rw [hbias]; omega) (by rw [hbias]; omega)
    rw [hbias] at this; exact this
  have hc : (⟨(Pion.I64.add h 33554432#i64).bv.sshiftRight 26⟩ : Std.I64).val = (h.val + 33554432) / 2 ^ 26 := by
    rw [i64_sshiftRight_val, hadd]
  have hc_lo : -(B / 2 ^ 26 + 1) ≤ (⟨(Pion.I64.add h 33554432#i64).bv.sshiftRight 26⟩ : Std.I64).val := by omega
  have hc_hi : (⟨(Pion.I64.add h 33554432#i64).bv.sshiftRight 26⟩ : Std.I64).val ≤ B / 2 ^ 26 + 1 := by omega
  have hshl : (⟨(⟨(Pion.I64.add h 33554432#i64).bv.sshiftRight 26⟩ : Std.I64).bv <<< 26⟩ : Std.I64).val =
      (⟨(Pion.I64.add h 33554432#i64).bv.sshiftRight 26⟩ : Std.I64).val * 2 ^ 26 :=
    i64_shl26_val _ (by omega) (by omega)
  have hsub : (Pion.I64.sub h ⟨(⟨(Pion.I64.add h 33554432#i64).bv.sshiftRight 26⟩ : Std.I64).bv <<< 26⟩).val =
      h.val - (⟨(Pion.I64.add h 33554432#i64).bv.sshiftRight 26⟩ : Std.I64).val * 2 ^ 26 := by
    have := i64_sub_val h ⟨(⟨(Pion.I64.add h 33554432#i64).bv.sshiftRight 26⟩ : Std.I64).bv <<< 26⟩ (by rw [hshl]; omega) (by rw [hshl]; omega)
    rw [hshl] at this; exact this
  exact ⟨hsub, by rw [hsub]; omega, by rw [hsub]; omega, hc_lo, hc_hi⟩

private lemma carry25_step (h c h' : Std.I64) (B : Int)
    (hc_eq : c = ⟨(Pion.I64.add h 16777216#i64).bv.sshiftRight 25⟩)
    (hh'_eq : h' = Pion.I64.sub h ⟨c.bv <<< 25⟩)
    (hB : 0 ≤ B) (hBmax : B ≤ 8000000000000000000)
    (hlo : -B ≤ h.val) (hhi : h.val ≤ B) :
    h'.val = h.val - c.val * 2 ^ 25 ∧
    -(2 ^ 24) ≤ h'.val ∧ h'.val ≤ 2 ^ 24 ∧
    -(B / 2 ^ 25 + 1) ≤ c.val ∧ c.val ≤ B / 2 ^ 25 + 1 := by
  subst hc_eq; subst hh'_eq
  have hbias : (16777216#i64).val = 16777216 := rfl
  have hadd : (Pion.I64.add h 16777216#i64).val = h.val + 16777216 := by
    have := i64_add_val h 16777216#i64 (by rw [hbias]; omega) (by rw [hbias]; omega)
    rw [hbias] at this; exact this
  have hc : (⟨(Pion.I64.add h 16777216#i64).bv.sshiftRight 25⟩ : Std.I64).val = (h.val + 16777216) / 2 ^ 25 := by
    rw [i64_sshiftRight_val, hadd]
  have hc_lo : -(B / 2 ^ 25 + 1) ≤ (⟨(Pion.I64.add h 16777216#i64).bv.sshiftRight 25⟩ : Std.I64).val := by omega
  have hc_hi : (⟨(Pion.I64.add h 16777216#i64).bv.sshiftRight 25⟩ : Std.I64).val ≤ B / 2 ^ 25 + 1 := by omega
  have hshl : (⟨(⟨(Pion.I64.add h 16777216#i64).bv.sshiftRight 25⟩ : Std.I64).bv <<< 25⟩ : Std.I64).val =
      (⟨(Pion.I64.add h 16777216#i64).bv.sshiftRight 25⟩ : Std.I64).val * 2 ^ 25 :=
    i64_shl25_val _ (by omega) (by omega)
  have hsub : (Pion.I64.sub h ⟨(⟨(Pion.I64.add h 16777216#i64).bv.sshiftRight 25⟩ : Std.I64).bv <<< 25⟩).val =
      h.val - (⟨(Pion.I64.add h 16777216#i64).bv.sshiftRight 25⟩ : Std.I64).val * 2 ^ 25 := by
    have := i64_sub_val h ⟨(⟨(Pion.I64.add h 16777216#i64).bv.sshiftRight 25⟩ : Std.I64).bv <<< 25⟩ (by rw [hshl]; omega) (by rw [hshl]; omega)
    rw [hshl] at this; exact this
  exact ⟨hsub, by rw [hsub]; omega, by rw [hsub]; omega, hc_lo, hc_hi⟩

/-- Ref10 12-step carry chain preserves `feVal · mod (2^255 - 19)` and reduces all 10 limbs to `feCarryReduced`. -/
private lemma ref10_carry_chain
    (h0 h1 h2 h3 h4 h5 h6 h7 h8 h9 : Std.I64)
    (hb0 : -5000000000000000000 ≤ h0.val ∧ h0.val ≤ 5000000000000000000)
    (hb1 : -5000000000000000000 ≤ h1.val ∧ h1.val ≤ 5000000000000000000)
    (hb2 : -5000000000000000000 ≤ h2.val ∧ h2.val ≤ 5000000000000000000)
    (hb3 : -5000000000000000000 ≤ h3.val ∧ h3.val ≤ 5000000000000000000)
    (hb4 : -5000000000000000000 ≤ h4.val ∧ h4.val ≤ 5000000000000000000)
    (hb5 : -5000000000000000000 ≤ h5.val ∧ h5.val ≤ 5000000000000000000)
    (hb6 : -5000000000000000000 ≤ h6.val ∧ h6.val ≤ 5000000000000000000)
    (hb7 : -5000000000000000000 ≤ h7.val ∧ h7.val ≤ 5000000000000000000)
    (hb8 : -5000000000000000000 ≤ h8.val ∧ h8.val ≤ 5000000000000000000)
    (hb9 : -5000000000000000000 ≤ h9.val ∧ h9.val ≤ 5000000000000000000) :
    ∃ r : Fe,
      (do
        let c0 ← Pion.I64.shr_i32 (Pion.I64.add h0 33554432#i64) 26#i32
        let h11 := Pion.I64.add h1 c0
        let __t_1 ← Pion.I64.shl_i32 c0 26#i32
        let h01 := Pion.I64.sub h0 __t_1
        let c4 ← Pion.I64.shr_i32 (Pion.I64.add h4 33554432#i64) 26#i32
        let h51 := Pion.I64.add h5 c4
        let __t_3 ← Pion.I64.shl_i32 c4 26#i32
        let h41 := Pion.I64.sub h4 __t_3
        let c1 ← Pion.I64.shr_i32 (Pion.I64.add h11 16777216#i64) 25#i32
        let h21 := Pion.I64.add h2 c1
        let __t_5 ← Pion.I64.shl_i32 c1 25#i32
        let h12 := Pion.I64.sub h11 __t_5
        let c5 ← Pion.I64.shr_i32 (Pion.I64.add h51 16777216#i64) 25#i32
        let h61 := Pion.I64.add h6 c5
        let __t_7 ← Pion.I64.shl_i32 c5 25#i32
        let h52 := Pion.I64.sub h51 __t_7
        let c2 ← Pion.I64.shr_i32 (Pion.I64.add h21 33554432#i64) 26#i32
        let h31 := Pion.I64.add h3 c2
        let __t_9 ← Pion.I64.shl_i32 c2 26#i32
        let h22 := Pion.I64.sub h21 __t_9
        let c6 ← Pion.I64.shr_i32 (Pion.I64.add h61 33554432#i64) 26#i32
        let h71 := Pion.I64.add h7 c6
        let __t_11 ← Pion.I64.shl_i32 c6 26#i32
        let h62 := Pion.I64.sub h61 __t_11
        let c3 ← Pion.I64.shr_i32 (Pion.I64.add h31 16777216#i64) 25#i32
        let h42 := Pion.I64.add h41 c3
        let __t_13 ← Pion.I64.shl_i32 c3 25#i32
        let h32 := Pion.I64.sub h31 __t_13
        let c7 ← Pion.I64.shr_i32 (Pion.I64.add h71 16777216#i64) 25#i32
        let h81 := Pion.I64.add h8 c7
        let __t_15 ← Pion.I64.shl_i32 c7 25#i32
        let h72 := Pion.I64.sub h71 __t_15
        let c4b ← Pion.I64.shr_i32 (Pion.I64.add h42 33554432#i64) 26#i32
        let h53 := Pion.I64.add h52 c4b
        let __t_17 ← Pion.I64.shl_i32 c4b 26#i32
        let h43 := Pion.I64.sub h42 __t_17
        let c8 ← Pion.I64.shr_i32 (Pion.I64.add h81 33554432#i64) 26#i32
        let h91 := Pion.I64.add h9 c8
        let __t_19 ← Pion.I64.shl_i32 c8 26#i32
        let h82 := Pion.I64.sub h81 __t_19
        let c9 ← Pion.I64.shr_i32 (Pion.I64.add h91 16777216#i64) 25#i32
        let h02 := Pion.I64.add h01 (Pion.I64.mul c9 19#i64)
        let __t_21 ← Pion.I64.shl_i32 c9 25#i32
        let h92 := Pion.I64.sub h91 __t_21
        let c0b ← Pion.I64.shr_i32 (Pion.I64.add h02 33554432#i64) 26#i32
        let h13 := Pion.I64.add h12 c0b
        let __t_23 ← Pion.I64.shl_i32 c0b 26#i32
        let h03 := Pion.I64.sub h02 __t_23
        ok (Fe.mk h03 h13 h22 h32 h43 h53 h62 h72 h82 h92) : Result Fe) = ok r ∧
      p25519 ∣ (feVal r - feVal (Fe.mk h0 h1 h2 h3 h4 h5 h6 h7 h8 h9)) ∧
      feCarryReduced r := by
  rw [i64_shr_26_eval, result_bind_ok_fp]
  generalize hc0_eq : (⟨(Pion.I64.add h0 33554432#i64).bv.sshiftRight 26⟩ : Std.I64) = c0
  rw [i64_shl_26_eval, result_bind_ok_fp]
  generalize hh01_eq : Pion.I64.sub h0 ⟨c0.bv <<< 26⟩ = h01
  generalize hh11_eq : Pion.I64.add h1 c0 = h11
  have ⟨eh01, h01_lo, h01_hi, c0_lo, c0_hi⟩ := carry26_step h0 c0 h01 5000000000000000000 hc0_eq.symm hh01_eq.symm (by norm_num) (by norm_num) hb0.1 hb0.2
  have eh11 : h11.val = h1.val + c0.val := by rw [← hh11_eq]; exact i64_add_val h1 c0 (by linarith [hb1.1, c0_lo]) (by linarith [hb1.2, c0_hi])

  rw [i64_shr_26_eval, result_bind_ok_fp]
  generalize hc4_eq : (⟨(Pion.I64.add h4 33554432#i64).bv.sshiftRight 26⟩ : Std.I64) = c4
  rw [i64_shl_26_eval, result_bind_ok_fp]
  generalize hh41_eq : Pion.I64.sub h4 ⟨c4.bv <<< 26⟩ = h41
  generalize hh51_eq : Pion.I64.add h5 c4 = h51
  have ⟨eh41, h41_lo, h41_hi, c4_lo, c4_hi⟩ := carry26_step h4 c4 h41 5000000000000000000 hc4_eq.symm hh41_eq.symm (by norm_num) (by norm_num) hb4.1 hb4.2
  have eh51 : h51.val = h5.val + c4.val := by rw [← hh51_eq]; exact i64_add_val h5 c4 (by linarith [hb5.1, c4_lo]) (by linarith [hb5.2, c4_hi])

  rw [i64_shr_25_eval, result_bind_ok_fp]
  generalize hc1_eq : (⟨(Pion.I64.add h11 16777216#i64).bv.sshiftRight 25⟩ : Std.I64) = c1
  rw [i64_shl_25_eval, result_bind_ok_fp]
  generalize hh12_eq : Pion.I64.sub h11 ⟨c1.bv <<< 25⟩ = h12
  generalize hh21_eq : Pion.I64.add h2 c1 = h21
  have ⟨eh12, h12_lo, h12_hi, c1_lo, c1_hi⟩ := carry25_step h11 c1 h12 5100000000000000000 hc1_eq.symm hh12_eq.symm (by norm_num) (by norm_num) (by linarith [eh11, hb1.1, c0_lo]) (by linarith [eh11, hb1.2, c0_hi])
  have eh21 : h21.val = h2.val + c1.val := by rw [← hh21_eq]; exact i64_add_val h2 c1 (by linarith [hb2.1, c1_lo]) (by linarith [hb2.2, c1_hi])

  rw [i64_shr_25_eval, result_bind_ok_fp]
  generalize hc5_eq : (⟨(Pion.I64.add h51 16777216#i64).bv.sshiftRight 25⟩ : Std.I64) = c5
  rw [i64_shl_25_eval, result_bind_ok_fp]
  generalize hh52_eq : Pion.I64.sub h51 ⟨c5.bv <<< 25⟩ = h52
  generalize hh61_eq : Pion.I64.add h6 c5 = h61
  have ⟨eh52, h52_lo, h52_hi, c5_lo, c5_hi⟩ := carry25_step h51 c5 h52 5100000000000000000 hc5_eq.symm hh52_eq.symm (by norm_num) (by norm_num) (by linarith [eh51, hb5.1, c4_lo]) (by linarith [eh51, hb5.2, c4_hi])
  have eh61 : h61.val = h6.val + c5.val := by rw [← hh61_eq]; exact i64_add_val h6 c5 (by linarith [hb6.1, c5_lo]) (by linarith [hb6.2, c5_hi])

  rw [i64_shr_26_eval, result_bind_ok_fp]
  generalize hc2_eq : (⟨(Pion.I64.add h21 33554432#i64).bv.sshiftRight 26⟩ : Std.I64) = c2
  rw [i64_shl_26_eval, result_bind_ok_fp]
  generalize hh22_eq : Pion.I64.sub h21 ⟨c2.bv <<< 26⟩ = h22
  generalize hh31_eq : Pion.I64.add h3 c2 = h31
  have ⟨eh22, h22_lo, h22_hi, c2_lo, c2_hi⟩ := carry26_step h21 c2 h22 5100000000000000000 hc2_eq.symm hh22_eq.symm (by norm_num) (by norm_num) (by linarith [eh21, hb2.1, c1_lo]) (by linarith [eh21, hb2.2, c1_hi])
  have eh31 : h31.val = h3.val + c2.val := by rw [← hh31_eq]; exact i64_add_val h3 c2 (by linarith [hb3.1, c2_lo]) (by linarith [hb3.2, c2_hi])

  rw [i64_shr_26_eval, result_bind_ok_fp]
  generalize hc6_eq : (⟨(Pion.I64.add h61 33554432#i64).bv.sshiftRight 26⟩ : Std.I64) = c6
  rw [i64_shl_26_eval, result_bind_ok_fp]
  generalize hh62_eq : Pion.I64.sub h61 ⟨c6.bv <<< 26⟩ = h62
  generalize hh71_eq : Pion.I64.add h7 c6 = h71
  have ⟨eh62, h62_lo, h62_hi, c6_lo, c6_hi⟩ := carry26_step h61 c6 h62 5100000000000000000 hc6_eq.symm hh62_eq.symm (by norm_num) (by norm_num) (by linarith [eh61, hb6.1, c5_lo]) (by linarith [eh61, hb6.2, c5_hi])
  have eh71 : h71.val = h7.val + c6.val := by rw [← hh71_eq]; exact i64_add_val h7 c6 (by linarith [hb7.1, c6_lo]) (by linarith [hb7.2, c6_hi])

  rw [i64_shr_25_eval, result_bind_ok_fp]
  generalize hc3_eq : (⟨(Pion.I64.add h31 16777216#i64).bv.sshiftRight 25⟩ : Std.I64) = c3
  rw [i64_shl_25_eval, result_bind_ok_fp]
  generalize hh32_eq : Pion.I64.sub h31 ⟨c3.bv <<< 25⟩ = h32
  generalize hh42_eq : Pion.I64.add h41 c3 = h42
  have ⟨eh32, h32_lo, h32_hi, c3_lo, c3_hi⟩ := carry25_step h31 c3 h32 5100000000000000000 hc3_eq.symm hh32_eq.symm (by norm_num) (by norm_num) (by linarith [eh31, hb3.1, c2_lo]) (by linarith [eh31, hb3.2, c2_hi])
  have eh42 : h42.val = h41.val + c3.val := by rw [← hh42_eq]; exact i64_add_val h41 c3 (by linarith [h41_lo, c3_lo]) (by linarith [h41_hi, c3_hi])

  rw [i64_shr_25_eval, result_bind_ok_fp]
  generalize hc7_eq : (⟨(Pion.I64.add h71 16777216#i64).bv.sshiftRight 25⟩ : Std.I64) = c7
  rw [i64_shl_25_eval, result_bind_ok_fp]
  generalize hh72_eq : Pion.I64.sub h71 ⟨c7.bv <<< 25⟩ = h72
  generalize hh81_eq : Pion.I64.add h8 c7 = h81
  have ⟨eh72, h72_lo, h72_hi, c7_lo, c7_hi⟩ := carry25_step h71 c7 h72 5100000000000000000 hc7_eq.symm hh72_eq.symm (by norm_num) (by norm_num) (by linarith [eh71, hb7.1, c6_lo]) (by linarith [eh71, hb7.2, c6_hi])
  have eh81 : h81.val = h8.val + c7.val := by rw [← hh81_eq]; exact i64_add_val h8 c7 (by linarith [hb8.1, c7_lo]) (by linarith [hb8.2, c7_hi])

  rw [i64_shr_26_eval, result_bind_ok_fp]
  generalize hc4b_eq : (⟨(Pion.I64.add h42 33554432#i64).bv.sshiftRight 26⟩ : Std.I64) = c4b
  rw [i64_shl_26_eval, result_bind_ok_fp]
  generalize hh43_eq : Pion.I64.sub h42 ⟨c4b.bv <<< 26⟩ = h43
  generalize hh53_eq : Pion.I64.add h52 c4b = h53
  have ⟨eh43, h43_lo, h43_hi, c4b_lo, c4b_hi⟩ := carry26_step h42 c4b h43 200000000000 hc4b_eq.symm hh43_eq.symm (by norm_num) (by norm_num) (by linarith [eh42, h41_lo, c3_lo]) (by linarith [eh42, h41_hi, c3_hi])
  have eh53 : h53.val = h52.val + c4b.val := by rw [← hh53_eq]; exact i64_add_val h52 c4b (by linarith [h52_lo, c4b_lo]) (by linarith [h52_hi, c4b_hi])

  rw [i64_shr_26_eval, result_bind_ok_fp]
  generalize hc8_eq : (⟨(Pion.I64.add h81 33554432#i64).bv.sshiftRight 26⟩ : Std.I64) = c8
  rw [i64_shl_26_eval, result_bind_ok_fp]
  generalize hh82_eq : Pion.I64.sub h81 ⟨c8.bv <<< 26⟩ = h82
  generalize hh91_eq : Pion.I64.add h9 c8 = h91
  have ⟨eh82, h82_lo, h82_hi, c8_lo, c8_hi⟩ := carry26_step h81 c8 h82 5100000000000000000 hc8_eq.symm hh82_eq.symm (by norm_num) (by norm_num) (by linarith [eh81, hb8.1, c7_lo]) (by linarith [eh81, hb8.2, c7_hi])
  have eh91 : h91.val = h9.val + c8.val := by rw [← hh91_eq]; exact i64_add_val h9 c8 (by linarith [hb9.1, c8_lo]) (by linarith [hb9.2, c8_hi])

  rw [i64_shr_25_eval, result_bind_ok_fp]
  generalize hc9_eq : (⟨(Pion.I64.add h91 16777216#i64).bv.sshiftRight 25⟩ : Std.I64) = c9
  rw [i64_shl_25_eval, result_bind_ok_fp]
  generalize hh92_eq : Pion.I64.sub h91 ⟨c9.bv <<< 25⟩ = h92
  generalize hh02_eq : Pion.I64.add h01 (Pion.I64.mul c9 19#i64) = h02
  have ⟨eh92, h92_lo, h92_hi, c9_lo, c9_hi⟩ := carry25_step h91 c9 h92 5100000000000000000 hc9_eq.symm hh92_eq.symm (by norm_num) (by norm_num) (by linarith [eh91, hb9.1, c8_lo]) (by linarith [eh91, hb9.2, c8_hi])
  have h19v : (19#i64).val = 19 := rfl
  have ec9_19 : (Pion.I64.mul c9 19#i64).val = c9.val * 19 := by
    have := i64_mul_val c9 19#i64 (by rw [h19v]; linarith [c9_lo]) (by rw [h19v]; linarith [c9_hi])
    rw [h19v] at this; exact this
  have eh02 : h02.val = h01.val + c9.val * 19 := by
    rw [← hh02_eq]
    have := i64_add_val h01 (Pion.I64.mul c9 19#i64) (by rw [ec9_19]; linarith [h01_lo, c9_lo]) (by rw [ec9_19]; linarith [h01_hi, c9_hi])
    rw [ec9_19] at this; exact this

  rw [i64_shr_26_eval, result_bind_ok_fp]
  generalize hc0b_eq : (⟨(Pion.I64.add h02 33554432#i64).bv.sshiftRight 26⟩ : Std.I64) = c0b
  rw [i64_shl_26_eval, result_bind_ok_fp]
  generalize hh03_eq : Pion.I64.sub h02 ⟨c0b.bv <<< 26⟩ = h03
  generalize hh13_eq : Pion.I64.add h12 c0b = h13
  have ⟨eh03, h03_lo, h03_hi, c0b_lo, c0b_hi⟩ := carry26_step h02 c0b h03 4000000000000 hc0b_eq.symm hh03_eq.symm (by norm_num) (by norm_num) (by linarith [eh02, h01_lo, c9_lo]) (by linarith [eh02, h01_hi, c9_hi])
  have eh13 : h13.val = h12.val + c0b.val := by rw [← hh13_eq]; exact i64_add_val h12 c0b (by linarith [h12_lo, c0b_lo]) (by linarith [h12_hi, c0b_hi])

  refine ⟨Fe.mk h03 h13 h22 h32 h43 h53 h62 h72 h82 h92, rfl, ?_, ?_⟩
  · refine ⟨-c9.val, ?_⟩
    unfold feVal p25519
    simp only []
    linarith [eh03, eh13, eh22, eh32, eh43, eh53, eh62, eh72, eh82, eh92,
              eh02, eh12, eh21, eh31, eh42, eh52, eh61, eh71, eh81, eh91,
              eh01, eh11, eh41, eh51]
  · unfold feCarryReduced
    refine ⟨h03_lo, h03_hi, by linarith [eh13, h12_lo, c0b_lo], by linarith [eh13, h12_hi, c0b_hi],
            h22_lo, h22_hi, h32_lo, h32_hi,
            h43_lo, h43_hi, by linarith [eh53, h52_lo, c4b_lo], by linarith [eh53, h52_hi, c4b_hi],
            h62_lo, h62_hi, h72_lo, h72_hi,
            h82_lo, h82_hi, h92_lo, h92_hi⟩

/-! ## A-Grade Curve25519 Field Arithmetic Theorems -/

/-- `fe_add` computes the exact integer sum (hence congruent mod `2^255 - 19`) without 64-bit overflow
    whenever all 10 input limbs satisfy `|h_i| ≤ 2^61`. -/
theorem fe_add_mod_p_and_bounds (a b : Fe) (ha : feBounded a (2 ^ 61)) (hb : feBounded b (2 ^ 61)) :
    ∃ r : Fe, fe_add a b = ok r ∧
      feVal r = feVal a + feVal b ∧
      p25519 ∣ (feVal r - (feVal a + feVal b)) ∧
      feBounded r (2 ^ 62) := by
  unfold fe_add
  rcases ha with ⟨a0l, a0h, a1l, a1h, a2l, a2h, a3l, a3h, a4l, a4h, a5l, a5h, a6l, a6h, a7l, a7h, a8l, a8h, a9l, a9h⟩
  rcases hb with ⟨b0l, b0h, b1l, b1h, b2l, b2h, b3l, b3h, b4l, b4h, b5l, b5h, b6l, b6h, b7l, b7h, b8l, b8h, b9l, b9h⟩
  have e0 := i64_add_val a.h0 b.h0 (by omega) (by omega)
  have e1 := i64_add_val a.h1 b.h1 (by omega) (by omega)
  have e2 := i64_add_val a.h2 b.h2 (by omega) (by omega)
  have e3 := i64_add_val a.h3 b.h3 (by omega) (by omega)
  have e4 := i64_add_val a.h4 b.h4 (by omega) (by omega)
  have e5 := i64_add_val a.h5 b.h5 (by omega) (by omega)
  have e6 := i64_add_val a.h6 b.h6 (by omega) (by omega)
  have e7 := i64_add_val a.h7 b.h7 (by omega) (by omega)
  have e8 := i64_add_val a.h8 b.h8 (by omega) (by omega)
  have e9 := i64_add_val a.h9 b.h9 (by omega) (by omega)
  refine ⟨_, rfl, ?_, ?_, ?_⟩
  · unfold feVal; simp only []; rw [e0, e1, e2, e3, e4, e5, e6, e7, e8, e9]; ring
  · refine ⟨0, ?_⟩; unfold feVal; simp only []; rw [e0, e1, e2, e3, e4, e5, e6, e7, e8, e9]; ring
  · unfold feBounded; simp only []; rw [e0, e1, e2, e3, e4, e5, e6, e7, e8, e9]
    exact ⟨by omega, by omega, by omega, by omega, by omega, by omega, by omega, by omega,
           by omega, by omega, by omega, by omega, by omega, by omega, by omega, by omega,
           by omega, by omega, by omega, by omega⟩

/-- `fe_sub` computes the exact integer difference (hence congruent mod `2^255 - 19`) without 64-bit
    overflow whenever all 10 input limbs satisfy `|h_i| ≤ 2^61`. -/
theorem fe_sub_mod_p_and_bounds (a b : Fe) (ha : feBounded a (2 ^ 61)) (hb : feBounded b (2 ^ 61)) :
    ∃ r : Fe, fe_sub a b = ok r ∧
      feVal r = feVal a - feVal b ∧
      p25519 ∣ (feVal r - (feVal a - feVal b)) ∧
      feBounded r (2 ^ 62) := by
  unfold fe_sub
  rcases ha with ⟨a0l, a0h, a1l, a1h, a2l, a2h, a3l, a3h, a4l, a4h, a5l, a5h, a6l, a6h, a7l, a7h, a8l, a8h, a9l, a9h⟩
  rcases hb with ⟨b0l, b0h, b1l, b1h, b2l, b2h, b3l, b3h, b4l, b4h, b5l, b5h, b6l, b6h, b7l, b7h, b8l, b8h, b9l, b9h⟩
  have e0 := i64_sub_val a.h0 b.h0 (by omega) (by omega)
  have e1 := i64_sub_val a.h1 b.h1 (by omega) (by omega)
  have e2 := i64_sub_val a.h2 b.h2 (by omega) (by omega)
  have e3 := i64_sub_val a.h3 b.h3 (by omega) (by omega)
  have e4 := i64_sub_val a.h4 b.h4 (by omega) (by omega)
  have e5 := i64_sub_val a.h5 b.h5 (by omega) (by omega)
  have e6 := i64_sub_val a.h6 b.h6 (by omega) (by omega)
  have e7 := i64_sub_val a.h7 b.h7 (by omega) (by omega)
  have e8 := i64_sub_val a.h8 b.h8 (by omega) (by omega)
  have e9 := i64_sub_val a.h9 b.h9 (by omega) (by omega)
  refine ⟨_, rfl, ?_, ?_, ?_⟩
  · unfold feVal; simp only []; rw [e0, e1, e2, e3, e4, e5, e6, e7, e8, e9]; ring
  · refine ⟨0, ?_⟩; unfold feVal; simp only []; rw [e0, e1, e2, e3, e4, e5, e6, e7, e8, e9]; ring
  · unfold feBounded; simp only []; rw [e0, e1, e2, e3, e4, e5, e6, e7, e8, e9]
    exact ⟨by omega, by omega, by omega, by omega, by omega, by omega, by omega, by omega,
           by omega, by omega, by omega, by omega, by omega, by omega, by omega, by omega,
           by omega, by omega, by omega, by omega⟩

private def absLe (x : Std.I64) (B : Int) : Prop := -B ≤ x.val ∧ x.val ≤ B

private lemma mul_absLe {x y : Std.I64} {A B : Int} (hx : absLe x A) (hy : absLe y B)
    (hAB : A * B ≤ 5000000000000000000) :
    absLe (Pion.I64.mul x y) (A * B) ∧ (Pion.I64.mul x y).val = x.val * y.val := by
  rcases hx with ⟨hx1, hx2⟩; rcases hy with ⟨hy1, hy2⟩
  have h1 : -(A * B) ≤ x.val * y.val := by nlinarith
  have h2 : x.val * y.val ≤ A * B := by nlinarith
  have hm := i64_mul_val x y (by omega) (by omega)
  exact ⟨⟨by omega, by omega⟩, hm⟩

private lemma add_absLe {x y : Std.I64} {A B : Int} (hx : absLe x A) (hy : absLe y B)
    (hAB : A + B ≤ 5000000000000000000) :
    absLe (Pion.I64.add x y) (A + B) ∧ (Pion.I64.add x y).val = x.val + y.val := by
  rcases hx with ⟨hx1, hx2⟩; rcases hy with ⟨hy1, hy2⟩
  have ha := i64_add_val x y (by omega) (by omega)
  exact ⟨⟨by omega, by omega⟩, ha⟩

private lemma scale2_absLe {x : Std.I64} (hx : absLe x (2 ^ 27)) :
    absLe (Pion.I64.mul 2#i64 x) (2 * 2 ^ 27) ∧ (Pion.I64.mul 2#i64 x).val = 2 * x.val := by
  rcases hx with ⟨h1, h2⟩
  have hv : (2#i64).val = 2 := rfl
  have hm := i64_mul_val 2#i64 x (by rw [hv]; omega) (by rw [hv]; omega)
  rw [hv] at hm
  exact ⟨⟨by omega, by omega⟩, hm⟩

private lemma scale19_absLe {x : Std.I64} (hx : absLe x (2 ^ 27)) :
    absLe (Pion.I64.mul 19#i64 x) (19 * 2 ^ 27) ∧ (Pion.I64.mul 19#i64 x).val = 19 * x.val := by
  rcases hx with ⟨h1, h2⟩
  have hv : (19#i64).val = 19 := rfl
  have hm := i64_mul_val 19#i64 x (by rw [hv]; omega) (by rw [hv]; omega)
  rw [hv] at hm
  exact ⟨⟨by omega, by omega⟩, hm⟩

private lemma scale38_absLe {x : Std.I64} (hx : absLe x (2 ^ 27)) :
    absLe (Pion.I64.mul 38#i64 x) (38 * 2 ^ 27) ∧ (Pion.I64.mul 38#i64 x).val = 38 * x.val := by
  rcases hx with ⟨h1, h2⟩
  have hv : (38#i64).val = 38 := rfl
  have hm := i64_mul_val 38#i64 x (by rw [hv]; omega) (by rw [hv]; omega)
  rw [hv] at hm
  exact ⟨⟨by omega, by omega⟩, hm⟩

private lemma dot10_fast
    {a0 b0 a1 b1 a2 b2 a3 b3 a4 b4 a5 b5 a6 b6 a7 b7 a8 b8 a9 b9 : Std.I64}
    {A0 B0 A1 B1 A2 B2 A3 B3 A4 B4 A5 B5 A6 B6 A7 B7 A8 B8 A9 B9 : Int}
    (ha0 : absLe a0 A0) (hb0 : absLe b0 B0) (ha1 : absLe a1 A1) (hb1 : absLe b1 B1)
    (ha2 : absLe a2 A2) (hb2 : absLe b2 B2) (ha3 : absLe a3 A3) (hb3 : absLe b3 B3)
    (ha4 : absLe a4 A4) (hb4 : absLe b4 B4) (ha5 : absLe a5 A5) (hb5 : absLe b5 B5)
    (ha6 : absLe a6 A6) (hb6 : absLe b6 B6) (ha7 : absLe a7 A7) (hb7 : absLe b7 B7)
    (ha8 : absLe a8 A8) (hb8 : absLe b8 B8) (ha9 : absLe a9 A9) (hb9 : absLe b9 B9)
    (htot : A0*B0 + A1*B1 + A2*B2 + A3*B3 + A4*B4 + A5*B5 + A6*B6 + A7*B7 + A8*B8 + A9*B9 ≤ 5000000000000000000)
    (hnn : 0 ≤ A0*B0 ∧ 0 ≤ A1*B1 ∧ 0 ≤ A2*B2 ∧ 0 ≤ A3*B3 ∧ 0 ≤ A4*B4 ∧
           0 ≤ A5*B5 ∧ 0 ≤ A6*B6 ∧ 0 ≤ A7*B7 ∧ 0 ≤ A8*B8 ∧ 0 ≤ A9*B9) :
    let s := Pion.I64.add (Pion.I64.add (Pion.I64.add (Pion.I64.add (Pion.I64.add (Pion.I64.add (Pion.I64.add (Pion.I64.add (Pion.I64.add
      (Pion.I64.mul a0 b0) (Pion.I64.mul a1 b1)) (Pion.I64.mul a2 b2)) (Pion.I64.mul a3 b3)) (Pion.I64.mul a4 b4))
      (Pion.I64.mul a5 b5)) (Pion.I64.mul a6 b6)) (Pion.I64.mul a7 b7)) (Pion.I64.mul a8 b8)) (Pion.I64.mul a9 b9)
    s.val = a0.val*b0.val + a1.val*b1.val + a2.val*b2.val + a3.val*b3.val + a4.val*b4.val +
            a5.val*b5.val + a6.val*b6.val + a7.val*b7.val + a8.val*b8.val + a9.val*b9.val ∧
    -5000000000000000000 ≤ s.val ∧ s.val ≤ 5000000000000000000 := by
  rcases hnn with ⟨n0, n1, n2, n3, n4, n5, n6, n7, n8, n9⟩
  have ⟨p0, e0⟩ := mul_absLe ha0 hb0 (by omega)
  have ⟨p1, e1⟩ := mul_absLe ha1 hb1 (by omega)
  have ⟨p2, e2⟩ := mul_absLe ha2 hb2 (by omega)
  have ⟨p3, e3⟩ := mul_absLe ha3 hb3 (by omega)
  have ⟨p4, e4⟩ := mul_absLe ha4 hb4 (by omega)
  have ⟨p5, e5⟩ := mul_absLe ha5 hb5 (by omega)
  have ⟨p6, e6⟩ := mul_absLe ha6 hb6 (by omega)
  have ⟨p7, e7⟩ := mul_absLe ha7 hb7 (by omega)
  have ⟨p8, e8⟩ := mul_absLe ha8 hb8 (by omega)
  have ⟨p9, e9⟩ := mul_absLe ha9 hb9 (by omega)
  have ⟨q1, f1⟩ := add_absLe p0 p1 (by omega)
  have ⟨q2, f2⟩ := add_absLe q1 p2 (by omega)
  have ⟨q3, f3⟩ := add_absLe q2 p3 (by omega)
  have ⟨q4, f4⟩ := add_absLe q3 p4 (by omega)
  have ⟨q5, f5⟩ := add_absLe q4 p5 (by omega)
  have ⟨q6, f6⟩ := add_absLe q5 p6 (by omega)
  have ⟨q7, f7⟩ := add_absLe q6 p7 (by omega)
  have ⟨q8, f8⟩ := add_absLe q7 p8 (by omega)
  have ⟨q9, f9⟩ := add_absLe q8 p9 (by omega)
  rcases q9 with ⟨ql, qh⟩
  refine ⟨?_, by omega, by omega⟩
  rw [f9, f8, f7, f6, f5, f4, f3, f2, f1, e0, e1, e2, e3, e4, e5, e6, e7, e8, e9]

private lemma dot6_fast
    {a0 b0 a1 b1 a2 b2 a3 b3 a4 b4 a5 b5 : Std.I64}
    {A0 B0 A1 B1 A2 B2 A3 B3 A4 B4 A5 B5 : Int}
    (ha0 : absLe a0 A0) (hb0 : absLe b0 B0) (ha1 : absLe a1 A1) (hb1 : absLe b1 B1)
    (ha2 : absLe a2 A2) (hb2 : absLe b2 B2) (ha3 : absLe a3 A3) (hb3 : absLe b3 B3)
    (ha4 : absLe a4 A4) (hb4 : absLe b4 B4) (ha5 : absLe a5 A5) (hb5 : absLe b5 B5)
    (htot : A0*B0 + A1*B1 + A2*B2 + A3*B3 + A4*B4 + A5*B5 ≤ 5000000000000000000)
    (hnn : 0 ≤ A0*B0 ∧ 0 ≤ A1*B1 ∧ 0 ≤ A2*B2 ∧ 0 ≤ A3*B3 ∧ 0 ≤ A4*B4 ∧ 0 ≤ A5*B5) :
    let s := Pion.I64.add (Pion.I64.add (Pion.I64.add (Pion.I64.add (Pion.I64.add
      (Pion.I64.mul a0 b0) (Pion.I64.mul a1 b1)) (Pion.I64.mul a2 b2)) (Pion.I64.mul a3 b3))
      (Pion.I64.mul a4 b4)) (Pion.I64.mul a5 b5)
    s.val = a0.val*b0.val + a1.val*b1.val + a2.val*b2.val + a3.val*b3.val + a4.val*b4.val + a5.val*b5.val ∧
    -5000000000000000000 ≤ s.val ∧ s.val ≤ 5000000000000000000 := by
  rcases hnn with ⟨n0, n1, n2, n3, n4, n5⟩
  have ⟨p0, e0⟩ := mul_absLe ha0 hb0 (by omega)
  have ⟨p1, e1⟩ := mul_absLe ha1 hb1 (by omega)
  have ⟨p2, e2⟩ := mul_absLe ha2 hb2 (by omega)
  have ⟨p3, e3⟩ := mul_absLe ha3 hb3 (by omega)
  have ⟨p4, e4⟩ := mul_absLe ha4 hb4 (by omega)
  have ⟨p5, e5⟩ := mul_absLe ha5 hb5 (by omega)
  have ⟨q1, f1⟩ := add_absLe p0 p1 (by omega)
  have ⟨q2, f2⟩ := add_absLe q1 p2 (by omega)
  have ⟨q3, f3⟩ := add_absLe q2 p3 (by omega)
  have ⟨q4, f4⟩ := add_absLe q3 p4 (by omega)
  have ⟨q5, f5⟩ := add_absLe q4 p5 (by omega)
  rcases q5 with ⟨ql, qh⟩
  refine ⟨?_, by omega, by omega⟩
  rw [f5, f4, f3, f2, f1, e0, e1, e2, e3, e4, e5]

private lemma dot5_fast
    {a0 b0 a1 b1 a2 b2 a3 b3 a4 b4 : Std.I64}
    {A0 B0 A1 B1 A2 B2 A3 B3 A4 B4 : Int}
    (ha0 : absLe a0 A0) (hb0 : absLe b0 B0) (ha1 : absLe a1 A1) (hb1 : absLe b1 B1)
    (ha2 : absLe a2 A2) (hb2 : absLe b2 B2) (ha3 : absLe a3 A3) (hb3 : absLe b3 B3)
    (ha4 : absLe a4 A4) (hb4 : absLe b4 B4)
    (htot : A0*B0 + A1*B1 + A2*B2 + A3*B3 + A4*B4 ≤ 5000000000000000000)
    (hnn : 0 ≤ A0*B0 ∧ 0 ≤ A1*B1 ∧ 0 ≤ A2*B2 ∧ 0 ≤ A3*B3 ∧ 0 ≤ A4*B4) :
    let s := Pion.I64.add (Pion.I64.add (Pion.I64.add (Pion.I64.add
      (Pion.I64.mul a0 b0) (Pion.I64.mul a1 b1)) (Pion.I64.mul a2 b2)) (Pion.I64.mul a3 b3))
      (Pion.I64.mul a4 b4)
    s.val = a0.val*b0.val + a1.val*b1.val + a2.val*b2.val + a3.val*b3.val + a4.val*b4.val ∧
    -5000000000000000000 ≤ s.val ∧ s.val ≤ 5000000000000000000 := by
  rcases hnn with ⟨n0, n1, n2, n3, n4⟩
  have ⟨p0, e0⟩ := mul_absLe ha0 hb0 (by omega)
  have ⟨p1, e1⟩ := mul_absLe ha1 hb1 (by omega)
  have ⟨p2, e2⟩ := mul_absLe ha2 hb2 (by omega)
  have ⟨p3, e3⟩ := mul_absLe ha3 hb3 (by omega)
  have ⟨p4, e4⟩ := mul_absLe ha4 hb4 (by omega)
  have ⟨q1, f1⟩ := add_absLe p0 p1 (by omega)
  have ⟨q2, f2⟩ := add_absLe q1 p2 (by omega)
  have ⟨q3, f3⟩ := add_absLe q2 p3 (by omega)
  have ⟨q4, f4⟩ := add_absLe q3 p4 (by omega)
  rcases q4 with ⟨ql, qh⟩
  refine ⟨?_, by omega, by omega⟩
  rw [f4, f3, f2, f1, e0, e1, e2, e3, e4]

private lemma fe_mul_col0 (f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g0 : Int) :
    (f0 * g0) + (f1 * g0) * 2 ^ 26 + (f2 * g0) * 2 ^ 51 + (f3 * g0) * 2 ^ 77 + (f4 * g0) * 2 ^ 102 +
    (f5 * g0) * 2 ^ 128 + (f6 * g0) * 2 ^ 153 + (f7 * g0) * 2 ^ 179 + (f8 * g0) * 2 ^ 204 + (f9 * g0) * 2 ^ 230 =
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * g0 := by ring

private lemma fe_mul_col1 (f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g1 : Int) :
    ((2 * f9) * (19 * g1)) + (f0 * g1) * 2 ^ 26 + ((2 * f1) * g1) * 2 ^ 51 + (f2 * g1) * 2 ^ 77 + ((2 * f3) * g1) * 2 ^ 102 +
    (f4 * g1) * 2 ^ 128 + ((2 * f5) * g1) * 2 ^ 153 + (f6 * g1) * 2 ^ 179 + ((2 * f7) * g1) * 2 ^ 204 + (f8 * g1) * 2 ^ 230 -
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g1 * 2 ^ 26) =
    (2 ^ 255 - 19) * (-(2 * f9 * g1)) := by ring

private lemma fe_mul_col2 (f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g2 : Int) :
    (f8 * (19 * g2)) + (f9 * (19 * g2)) * 2 ^ 26 + (f0 * g2) * 2 ^ 51 + (f1 * g2) * 2 ^ 77 + (f2 * g2) * 2 ^ 102 +
    (f3 * g2) * 2 ^ 128 + (f4 * g2) * 2 ^ 153 + (f5 * g2) * 2 ^ 179 + (f6 * g2) * 2 ^ 204 + (f7 * g2) * 2 ^ 230 -
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g2 * 2 ^ 51) =
    (2 ^ 255 - 19) * (-(f8 * g2 + 2 ^ 26 * (f9 * g2))) := by ring

private lemma fe_mul_col3 (f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g3 : Int) :
    ((2 * f7) * (19 * g3)) + (f8 * (19 * g3)) * 2 ^ 26 + ((2 * f9) * (19 * g3)) * 2 ^ 51 + (f0 * g3) * 2 ^ 77 + ((2 * f1) * g3) * 2 ^ 102 +
    (f2 * g3) * 2 ^ 128 + ((2 * f3) * g3) * 2 ^ 153 + (f4 * g3) * 2 ^ 179 + ((2 * f5) * g3) * 2 ^ 204 + (f6 * g3) * 2 ^ 230 -
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g3 * 2 ^ 77) =
    (2 ^ 255 - 19) * (-(2 * f7 * g3 + 2 ^ 26 * (f8 * g3) + 2 ^ 51 * (2 * f9 * g3))) := by ring

private lemma fe_mul_col4 (f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g4 : Int) :
    (f6 * (19 * g4)) + (f7 * (19 * g4)) * 2 ^ 26 + (f8 * (19 * g4)) * 2 ^ 51 + (f9 * (19 * g4)) * 2 ^ 77 + (f0 * g4) * 2 ^ 102 +
    (f1 * g4) * 2 ^ 128 + (f2 * g4) * 2 ^ 153 + (f3 * g4) * 2 ^ 179 + (f4 * g4) * 2 ^ 204 + (f5 * g4) * 2 ^ 230 -
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g4 * 2 ^ 102) =
    (2 ^ 255 - 19) * (-(f6 * g4 + 2 ^ 26 * (f7 * g4) + 2 ^ 51 * (f8 * g4) + 2 ^ 77 * (f9 * g4))) := by ring

private lemma fe_mul_col5 (f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g5 : Int) :
    ((2 * f5) * (19 * g5)) + (f6 * (19 * g5)) * 2 ^ 26 + ((2 * f7) * (19 * g5)) * 2 ^ 51 + (f8 * (19 * g5)) * 2 ^ 77 + ((2 * f9) * (19 * g5)) * 2 ^ 102 +
    (f0 * g5) * 2 ^ 128 + ((2 * f1) * g5) * 2 ^ 153 + (f2 * g5) * 2 ^ 179 + ((2 * f3) * g5) * 2 ^ 204 + (f4 * g5) * 2 ^ 230 -
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g5 * 2 ^ 128) =
    (2 ^ 255 - 19) * (-(2 * f5 * g5 + 2 ^ 26 * (f6 * g5) + 2 ^ 51 * (2 * f7 * g5) + 2 ^ 77 * (f8 * g5) + 2 ^ 102 * (2 * f9 * g5))) := by ring

private lemma fe_mul_col6 (f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g6 : Int) :
    (f4 * (19 * g6)) + (f5 * (19 * g6)) * 2 ^ 26 + (f6 * (19 * g6)) * 2 ^ 51 + (f7 * (19 * g6)) * 2 ^ 77 + (f8 * (19 * g6)) * 2 ^ 102 +
    (f9 * (19 * g6)) * 2 ^ 128 + (f0 * g6) * 2 ^ 153 + (f1 * g6) * 2 ^ 179 + (f2 * g6) * 2 ^ 204 + (f3 * g6) * 2 ^ 230 -
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g6 * 2 ^ 153) =
    (2 ^ 255 - 19) * (-(f4 * g6 + 2 ^ 26 * (f5 * g6) + 2 ^ 51 * (f6 * g6) + 2 ^ 77 * (f7 * g6) + 2 ^ 102 * (f8 * g6) + 2 ^ 128 * (f9 * g6))) := by ring

private lemma fe_mul_col7 (f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g7 : Int) :
    ((2 * f3) * (19 * g7)) + (f4 * (19 * g7)) * 2 ^ 26 + ((2 * f5) * (19 * g7)) * 2 ^ 51 + (f6 * (19 * g7)) * 2 ^ 77 + ((2 * f7) * (19 * g7)) * 2 ^ 102 +
    (f8 * (19 * g7)) * 2 ^ 128 + ((2 * f9) * (19 * g7)) * 2 ^ 153 + (f0 * g7) * 2 ^ 179 + ((2 * f1) * g7) * 2 ^ 204 + (f2 * g7) * 2 ^ 230 -
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g7 * 2 ^ 179) =
    (2 ^ 255 - 19) * (-(2 * f3 * g7 + 2 ^ 26 * (f4 * g7) + 2 ^ 51 * (2 * f5 * g7) + 2 ^ 77 * (f6 * g7) + 2 ^ 102 * (2 * f7 * g7) + 2 ^ 128 * (f8 * g7) + 2 ^ 153 * (2 * f9 * g7))) := by ring

private lemma fe_mul_col8 (f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g8 : Int) :
    (f2 * (19 * g8)) + (f3 * (19 * g8)) * 2 ^ 26 + (f4 * (19 * g8)) * 2 ^ 51 + (f5 * (19 * g8)) * 2 ^ 77 + (f6 * (19 * g8)) * 2 ^ 102 +
    (f7 * (19 * g8)) * 2 ^ 128 + (f8 * (19 * g8)) * 2 ^ 153 + (f9 * (19 * g8)) * 2 ^ 179 + (f0 * g8) * 2 ^ 204 + (f1 * g8) * 2 ^ 230 -
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g8 * 2 ^ 204) =
    (2 ^ 255 - 19) * (-(f2 * g8 + 2 ^ 26 * (f3 * g8) + 2 ^ 51 * (f4 * g8) + 2 ^ 77 * (f5 * g8) + 2 ^ 102 * (f6 * g8) + 2 ^ 128 * (f7 * g8) + 2 ^ 153 * (f8 * g8) + 2 ^ 179 * (f9 * g8))) := by ring

private lemma fe_mul_col9 (f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g9 : Int) :
    ((2 * f1) * (19 * g9)) + (f2 * (19 * g9)) * 2 ^ 26 + ((2 * f3) * (19 * g9)) * 2 ^ 51 + (f4 * (19 * g9)) * 2 ^ 77 + ((2 * f5) * (19 * g9)) * 2 ^ 102 +
    (f6 * (19 * g9)) * 2 ^ 128 + ((2 * f7) * (19 * g9)) * 2 ^ 153 + (f8 * (19 * g9)) * 2 ^ 179 + ((2 * f9) * (19 * g9)) * 2 ^ 204 + (f0 * g9) * 2 ^ 230 -
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g9 * 2 ^ 230) =
    (2 ^ 255 - 19) * (-(2 * f1 * g9 + 2 ^ 26 * (f2 * g9) + 2 ^ 51 * (2 * f3 * g9) + 2 ^ 77 * (f4 * g9) + 2 ^ 102 * (2 * f5 * g9) + 2 ^ 128 * (f6 * g9) + 2 ^ 153 * (2 * f7 * g9) + 2 ^ 179 * (f8 * g9) + 2 ^ 204 * (2 * f9 * g9))) := by ring

private lemma fe_mul_poly_id (f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g0 g1 g2 g3 g4 g5 g6 g7 g8 g9 : Int) :
    (2 ^ 255 - 19 : Int) ∣
    ((f0 * g0 + (2 * f1) * (19 * g9) + f2 * (19 * g8) + (2 * f3) * (19 * g7) + f4 * (19 * g6) +
      (2 * f5) * (19 * g5) + f6 * (19 * g4) + (2 * f7) * (19 * g3) + f8 * (19 * g2) + (2 * f9) * (19 * g1)) +
     (f0 * g1 + f1 * g0 + f2 * (19 * g9) + f3 * (19 * g8) + f4 * (19 * g7) +
      f5 * (19 * g6) + f6 * (19 * g5) + f7 * (19 * g4) + f8 * (19 * g3) + f9 * (19 * g2)) * 2 ^ 26 +
     (f0 * g2 + (2 * f1) * g1 + f2 * g0 + (2 * f3) * (19 * g9) + f4 * (19 * g8) +
      (2 * f5) * (19 * g7) + f6 * (19 * g6) + (2 * f7) * (19 * g5) + f8 * (19 * g4) + (2 * f9) * (19 * g3)) * 2 ^ 51 +
     (f0 * g3 + f1 * g2 + f2 * g1 + f3 * g0 + f4 * (19 * g9) +
      f5 * (19 * g8) + f6 * (19 * g7) + f7 * (19 * g6) + f8 * (19 * g5) + f9 * (19 * g4)) * 2 ^ 77 +
     (f0 * g4 + (2 * f1) * g3 + f2 * g2 + (2 * f3) * g1 + f4 * g0 +
      (2 * f5) * (19 * g9) + f6 * (19 * g8) + (2 * f7) * (19 * g7) + f8 * (19 * g6) + (2 * f9) * (19 * g5)) * 2 ^ 102 +
     (f0 * g5 + f1 * g4 + f2 * g3 + f3 * g2 + f4 * g1 +
      f5 * g0 + f6 * (19 * g9) + f7 * (19 * g8) + f8 * (19 * g7) + f9 * (19 * g6)) * 2 ^ 128 +
     (f0 * g6 + (2 * f1) * g5 + f2 * g4 + (2 * f3) * g3 + f4 * g2 +
      (2 * f5) * g1 + f6 * g0 + (2 * f7) * (19 * g9) + f8 * (19 * g8) + (2 * f9) * (19 * g7)) * 2 ^ 153 +
     (f0 * g7 + f1 * g6 + f2 * g5 + f3 * g4 + f4 * g3 +
      f5 * g2 + f6 * g1 + f7 * g0 + f8 * (19 * g9) + f9 * (19 * g8)) * 2 ^ 179 +
     (f0 * g8 + (2 * f1) * g7 + f2 * g6 + (2 * f3) * g5 + f4 * g4 +
      (2 * f5) * g3 + f6 * g2 + (2 * f7) * g1 + f8 * g0 + (2 * f9) * (19 * g9)) * 2 ^ 204 +
     (f0 * g9 + f1 * g8 + f2 * g7 + f3 * g6 + f4 * g5 +
      f5 * g4 + f6 * g3 + f7 * g2 + f8 * g1 + f9 * g0) * 2 ^ 230 -
     (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
      f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) *
     (g0 + g1 * 2 ^ 26 + g2 * 2 ^ 51 + g3 * 2 ^ 77 + g4 * 2 ^ 102 +
      g5 * 2 ^ 128 + g6 * 2 ^ 153 + g7 * 2 ^ 179 + g8 * 2 ^ 204 + g9 * 2 ^ 230)) := by
  have c0 := fe_mul_col0 f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g0
  have c1 := fe_mul_col1 f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g1
  have c2 := fe_mul_col2 f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g2
  have c3 := fe_mul_col3 f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g3
  have c4 := fe_mul_col4 f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g4
  have c5 := fe_mul_col5 f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g5
  have c6 := fe_mul_col6 f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g6
  have c7 := fe_mul_col7 f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g7
  have c8 := fe_mul_col8 f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g8
  have c9 := fe_mul_col9 f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 g9
  have hdist :
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) *
    (g0 + g1 * 2 ^ 26 + g2 * 2 ^ 51 + g3 * 2 ^ 77 + g4 * 2 ^ 102 +
     g5 * 2 ^ 128 + g6 * 2 ^ 153 + g7 * 2 ^ 179 + g8 * 2 ^ 204 + g9 * 2 ^ 230) =
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * g0 +
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g1 * 2 ^ 26) +
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g2 * 2 ^ 51) +
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g3 * 2 ^ 77) +
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g4 * 2 ^ 102) +
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g5 * 2 ^ 128) +
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g6 * 2 ^ 153) +
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g7 * 2 ^ 179) +
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g8 * 2 ^ 204) +
    (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
     f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) * (g9 * 2 ^ 230) := by
    simp only [mul_add]
  rw [hdist]
  refine ⟨-(2 * f9 * g1) + -(f8 * g2 + 2 ^ 26 * (f9 * g2)) +
          -(2 * f7 * g3 + 2 ^ 26 * (f8 * g3) + 2 ^ 51 * (2 * f9 * g3)) +
          -(f6 * g4 + 2 ^ 26 * (f7 * g4) + 2 ^ 51 * (f8 * g4) + 2 ^ 77 * (f9 * g4)) +
          -(2 * f5 * g5 + 2 ^ 26 * (f6 * g5) + 2 ^ 51 * (2 * f7 * g5) + 2 ^ 77 * (f8 * g5) + 2 ^ 102 * (2 * f9 * g5)) +
          -(f4 * g6 + 2 ^ 26 * (f5 * g6) + 2 ^ 51 * (f6 * g6) + 2 ^ 77 * (f7 * g6) + 2 ^ 102 * (f8 * g6) + 2 ^ 128 * (f9 * g6)) +
          -(2 * f3 * g7 + 2 ^ 26 * (f4 * g7) + 2 ^ 51 * (2 * f5 * g7) + 2 ^ 77 * (f6 * g7) + 2 ^ 102 * (2 * f7 * g7) + 2 ^ 128 * (f8 * g7) + 2 ^ 153 * (2 * f9 * g7)) +
          -(f2 * g8 + 2 ^ 26 * (f3 * g8) + 2 ^ 51 * (f4 * g8) + 2 ^ 77 * (f5 * g8) + 2 ^ 102 * (f6 * g8) + 2 ^ 128 * (f7 * g8) + 2 ^ 153 * (f8 * g8) + 2 ^ 179 * (f9 * g8)) +
          -(2 * f1 * g9 + 2 ^ 26 * (f2 * g9) + 2 ^ 51 * (2 * f3 * g9) + 2 ^ 77 * (f4 * g9) + 2 ^ 102 * (2 * f5 * g9) + 2 ^ 128 * (f6 * g9) + 2 ^ 153 * (2 * f7 * g9) + 2 ^ 179 * (f8 * g9) + 2 ^ 204 * (2 * f9 * g9)), ?_⟩
  simp only [mul_add, add_mul]
  linarith [c0, c1, c2, c3, c4, c5, c6, c7, c8, c9]

private lemma fe_sq_poly_id (f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 : Int) :
    (2 ^ 255 - 19 : Int) ∣
    ((f0 * f0 + (2 * f1) * (38 * f9) + (2 * f2) * (19 * f8) + (2 * f3) * (38 * f7) + (2 * f4) * (19 * f6) + f5 * (38 * f5)) +
     ((2 * f0) * f1 + f2 * (38 * f9) + (2 * f3) * (19 * f8) + f4 * (38 * f7) + (2 * f5) * (19 * f6)) * 2 ^ 26 +
     ((2 * f0) * f2 + (2 * f1) * f1 + (2 * f3) * (38 * f9) + (2 * f4) * (19 * f8) + (2 * f5) * (38 * f7) + f6 * (19 * f6)) * 2 ^ 51 +
     ((2 * f0) * f3 + (2 * f1) * f2 + f4 * (38 * f9) + (2 * f5) * (19 * f8) + f6 * (38 * f7)) * 2 ^ 77 +
     ((2 * f0) * f4 + (2 * f1) * (2 * f3) + f2 * f2 + (2 * f5) * (38 * f9) + (2 * f6) * (19 * f8) + f7 * (38 * f7)) * 2 ^ 102 +
     ((2 * f0) * f5 + (2 * f1) * f4 + (2 * f2) * f3 + f6 * (38 * f9) + (2 * f7) * (19 * f8)) * 2 ^ 128 +
     ((2 * f0) * f6 + (2 * f1) * (2 * f5) + (2 * f2) * f4 + (2 * f3) * f3 + (2 * f7) * (38 * f9) + f8 * (19 * f8)) * 2 ^ 153 +
     ((2 * f0) * f7 + (2 * f1) * f6 + (2 * f2) * f5 + (2 * f3) * f4 + f8 * (38 * f9)) * 2 ^ 179 +
     ((2 * f0) * f8 + (2 * f1) * (2 * f7) + (2 * f2) * f6 + (2 * f3) * (2 * f5) + f4 * f4 + f9 * (38 * f9)) * 2 ^ 204 +
     ((2 * f0) * f9 + (2 * f1) * f8 + (2 * f2) * f7 + (2 * f3) * f6 + (2 * f4) * f5) * 2 ^ 230 -
     (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
      f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230) *
     (f0 + f1 * 2 ^ 26 + f2 * 2 ^ 51 + f3 * 2 ^ 77 + f4 * 2 ^ 102 +
      f5 * 2 ^ 128 + f6 * 2 ^ 153 + f7 * 2 ^ 179 + f8 * 2 ^ 204 + f9 * 2 ^ 230)) := by
  have l0 : f0 * f0 + (2 * f1) * (38 * f9) + (2 * f2) * (19 * f8) + (2 * f3) * (38 * f7) + (2 * f4) * (19 * f6) + f5 * (38 * f5) =
            f0 * f0 + (2 * f1) * (19 * f9) + f2 * (19 * f8) + (2 * f3) * (19 * f7) + f4 * (19 * f6) + (2 * f5) * (19 * f5) + f6 * (19 * f4) + (2 * f7) * (19 * f3) + f8 * (19 * f2) + (2 * f9) * (19 * f1) := by ring
  have l1 : (2 * f0) * f1 + f2 * (38 * f9) + (2 * f3) * (19 * f8) + f4 * (38 * f7) + (2 * f5) * (19 * f6) =
            f0 * f1 + f1 * f0 + f2 * (19 * f9) + f3 * (19 * f8) + f4 * (19 * f7) + f5 * (19 * f6) + f6 * (19 * f5) + f7 * (19 * f4) + f8 * (19 * f3) + f9 * (19 * f2) := by ring
  have l2 : (2 * f0) * f2 + (2 * f1) * f1 + (2 * f3) * (38 * f9) + (2 * f4) * (19 * f8) + (2 * f5) * (38 * f7) + f6 * (19 * f6) =
            f0 * f2 + (2 * f1) * f1 + f2 * f0 + (2 * f3) * (19 * f9) + f4 * (19 * f8) + (2 * f5) * (19 * f7) + f6 * (19 * f6) + (2 * f7) * (19 * f5) + f8 * (19 * f4) + (2 * f9) * (19 * f3) := by ring
  have l3 : (2 * f0) * f3 + (2 * f1) * f2 + f4 * (38 * f9) + (2 * f5) * (19 * f8) + f6 * (38 * f7) =
            f0 * f3 + f1 * f2 + f2 * f1 + f3 * f0 + f4 * (19 * f9) + f5 * (19 * f8) + f6 * (19 * f7) + f7 * (19 * f6) + f8 * (19 * f5) + f9 * (19 * f4) := by ring
  have l4 : (2 * f0) * f4 + (2 * f1) * (2 * f3) + f2 * f2 + (2 * f5) * (38 * f9) + (2 * f6) * (19 * f8) + f7 * (38 * f7) =
            f0 * f4 + (2 * f1) * f3 + f2 * f2 + (2 * f3) * f1 + f4 * f0 + (2 * f5) * (19 * f9) + f6 * (19 * f8) + (2 * f7) * (19 * f7) + f8 * (19 * f6) + (2 * f9) * (19 * f5) := by ring
  have l5 : (2 * f0) * f5 + (2 * f1) * f4 + (2 * f2) * f3 + f6 * (38 * f9) + (2 * f7) * (19 * f8) =
            f0 * f5 + f1 * f4 + f2 * f3 + f3 * f2 + f4 * f1 + f5 * f0 + f6 * (19 * f9) + f7 * (19 * f8) + f8 * (19 * f7) + f9 * (19 * f6) := by ring
  have l6 : (2 * f0) * f6 + (2 * f1) * (2 * f5) + (2 * f2) * f4 + (2 * f3) * f3 + (2 * f7) * (38 * f9) + f8 * (19 * f8) =
            f0 * f6 + (2 * f1) * f5 + f2 * f4 + (2 * f3) * f3 + f4 * f2 + (2 * f5) * f1 + f6 * f0 + (2 * f7) * (19 * f9) + f8 * (19 * f8) + (2 * f9) * (19 * f7) := by ring
  have l7 : (2 * f0) * f7 + (2 * f1) * f6 + (2 * f2) * f5 + (2 * f3) * f4 + f8 * (38 * f9) =
            f0 * f7 + f1 * f6 + f2 * f5 + f3 * f4 + f4 * f3 + f5 * f2 + f6 * f1 + f7 * f0 + f8 * (19 * f9) + f9 * (19 * f8) := by ring
  have l8 : (2 * f0) * f8 + (2 * f1) * (2 * f7) + (2 * f2) * f6 + (2 * f3) * (2 * f5) + f4 * f4 + f9 * (38 * f9) =
            f0 * f8 + (2 * f1) * f7 + f2 * f6 + (2 * f3) * f5 + f4 * f4 + (2 * f5) * f3 + f6 * f2 + (2 * f7) * f1 + f8 * f0 + (2 * f9) * (19 * f9) := by ring
  have l9 : (2 * f0) * f9 + (2 * f1) * f8 + (2 * f2) * f7 + (2 * f3) * f6 + (2 * f4) * f5 =
            f0 * f9 + f1 * f8 + f2 * f7 + f3 * f6 + f4 * f5 + f5 * f4 + f6 * f3 + f7 * f2 + f8 * f1 + f9 * f0 := by ring
  rw [l0, l1, l2, l3, l4, l5, l6, l7, l8, l9]
  exact fe_mul_poly_id f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 f0 f1 f2 f3 f4 f5 f6 f7 f8 f9

/-- Production Ref10 `fe_mul` computes exact multiplication modulo `p = 2^255 - 19` with zero 64-bit
    overflow and restores `feCarryReduced` limb bounds (closed under repeated `fe_mul` / `fe_add` / `fe_sub`). -/
theorem fe_mul_mod_p_and_bounds (f g : Fe) (hf : feBounded f (2 ^ 27)) (hg : feBounded g (2 ^ 27)) :
    ∃ r : Fe, fe_mul f g = ok r ∧
      p25519 ∣ (feVal r - feVal f * feVal g) ∧
      feCarryReduced r := by
  unfold fe_mul
  rcases hf with ⟨f0l, f0h, f1l, f1h, f2l, f2h, f3l, f3h, f4l, f4h, f5l, f5h, f6l, f6h, f7l, f7h, f8l, f8h, f9l, f9h⟩
  rcases hg with ⟨g0l, g0h, g1l, g1h, g2l, g2h, g3l, g3h, g4l, g4h, g5l, g5h, g6l, g6h, g7l, g7h, g8l, g8h, g9l, g9h⟩
  have af0 : absLe f.h0 (2 ^ 27) := ⟨f0l, f0h⟩
  have af1 : absLe f.h1 (2 ^ 27) := ⟨f1l, f1h⟩
  have af2 : absLe f.h2 (2 ^ 27) := ⟨f2l, f2h⟩
  have af3 : absLe f.h3 (2 ^ 27) := ⟨f3l, f3h⟩
  have af4 : absLe f.h4 (2 ^ 27) := ⟨f4l, f4h⟩
  have af5 : absLe f.h5 (2 ^ 27) := ⟨f5l, f5h⟩
  have af6 : absLe f.h6 (2 ^ 27) := ⟨f6l, f6h⟩
  have af7 : absLe f.h7 (2 ^ 27) := ⟨f7l, f7h⟩
  have af8 : absLe f.h8 (2 ^ 27) := ⟨f8l, f8h⟩
  have af9 : absLe f.h9 (2 ^ 27) := ⟨f9l, f9h⟩
  have ag0 : absLe g.h0 (2 ^ 27) := ⟨g0l, g0h⟩
  have ag1 : absLe g.h1 (2 ^ 27) := ⟨g1l, g1h⟩
  have ag2 : absLe g.h2 (2 ^ 27) := ⟨g2l, g2h⟩
  have ag3 : absLe g.h3 (2 ^ 27) := ⟨g3l, g3h⟩
  have ag4 : absLe g.h4 (2 ^ 27) := ⟨g4l, g4h⟩
  have ag5 : absLe g.h5 (2 ^ 27) := ⟨g5l, g5h⟩
  have ag6 : absLe g.h6 (2 ^ 27) := ⟨g6l, g6h⟩
  have ag7 : absLe g.h7 (2 ^ 27) := ⟨g7l, g7h⟩
  have ag8 : absLe g.h8 (2 ^ 27) := ⟨g8l, g8h⟩
  have ag9 : absLe g.h9 (2 ^ 27) := ⟨g9l, g9h⟩
  have ⟨bg1, eg1⟩ := scale19_absLe ag1
  have ⟨bg2, eg2⟩ := scale19_absLe ag2
  have ⟨bg3, eg3⟩ := scale19_absLe ag3
  have ⟨bg4, eg4⟩ := scale19_absLe ag4
  have ⟨bg5, eg5⟩ := scale19_absLe ag5
  have ⟨bg6, eg6⟩ := scale19_absLe ag6
  have ⟨bg7, eg7⟩ := scale19_absLe ag7
  have ⟨bg8, eg8⟩ := scale19_absLe ag8
  have ⟨bg9, eg9⟩ := scale19_absLe ag9
  have ⟨bf1, ef1⟩ := scale2_absLe af1
  have ⟨bf3, ef3⟩ := scale2_absLe af3
  have ⟨bf5, ef5⟩ := scale2_absLe af5
  have ⟨bf7, ef7⟩ := scale2_absLe af7
  have ⟨bf9, ef9⟩ := scale2_absLe af9
  have d0 := dot10_fast af0 ag0 bf1 bg9 af2 bg8 bf3 bg7 af4 bg6 bf5 bg5 af6 bg4 bf7 bg3 af8 bg2 bf9 bg1 (by norm_num) (by norm_num)
  have d1 := dot10_fast af0 ag1 af1 ag0 af2 bg9 af3 bg8 af4 bg7 af5 bg6 af6 bg5 af7 bg4 af8 bg3 af9 bg2 (by norm_num) (by norm_num)
  have d2 := dot10_fast af0 ag2 bf1 ag1 af2 ag0 bf3 bg9 af4 bg8 bf5 bg7 af6 bg6 bf7 bg5 af8 bg4 bf9 bg3 (by norm_num) (by norm_num)
  have d3 := dot10_fast af0 ag3 af1 ag2 af2 ag1 af3 ag0 af4 bg9 af5 bg8 af6 bg7 af7 bg6 af8 bg5 af9 bg4 (by norm_num) (by norm_num)
  have d4 := dot10_fast af0 ag4 bf1 ag3 af2 ag2 bf3 ag1 af4 ag0 bf5 bg9 af6 bg8 bf7 bg7 af8 bg6 bf9 bg5 (by norm_num) (by norm_num)
  have d5 := dot10_fast af0 ag5 af1 ag4 af2 ag3 af3 ag2 af4 ag1 af5 ag0 af6 bg9 af7 bg8 af8 bg7 af9 bg6 (by norm_num) (by norm_num)
  have d6 := dot10_fast af0 ag6 bf1 ag5 af2 ag4 bf3 ag3 af4 ag2 bf5 ag1 af6 ag0 bf7 bg9 af8 bg8 bf9 bg7 (by norm_num) (by norm_num)
  have d7 := dot10_fast af0 ag7 af1 ag6 af2 ag5 af3 ag4 af4 ag3 af5 ag2 af6 ag1 af7 ag0 af8 bg9 af9 bg8 (by norm_num) (by norm_num)
  have d8 := dot10_fast af0 ag8 bf1 ag7 af2 ag6 bf3 ag5 af4 ag4 bf5 ag3 af6 ag2 bf7 ag1 af8 ag0 bf9 bg9 (by norm_num) (by norm_num)
  have d9 := dot10_fast af0 ag9 af1 ag8 af2 ag7 af3 ag6 af4 ag5 af5 ag4 af6 ag3 af7 ag2 af8 ag1 af9 ag0 (by norm_num) (by norm_num)
  dsimp only [] at d0 d1 d2 d3 d4 d5 d6 d7 d8 d9
  rcases ref10_carry_chain _ _ _ _ _ _ _ _ _ _ d0.2 d1.2 d2.2 d3.2 d4.2 d5.2 d6.2 d7.2 d8.2 d9.2 with ⟨r, hr, hdiv_carry, hred⟩
  refine ⟨r, hr, ?_, hred⟩
  have htrans : ∀ x y z : Int, p25519 ∣ (x - y) → p25519 ∣ (y - z) → p25519 ∣ (x - z) := by
    intro x y z h1 h2
    have h := dvd_add h1 h2
    rwa [show (x - y) + (y - z) = x - z by ring] at h
  refine htrans _ _ _ hdiv_carry ?_
  unfold feVal p25519
  simp only []
  rw [d0.1, d1.1, d2.1, d3.1, d4.1, d5.1, d6.1, d7.1, d8.1, d9.1,
      eg1, eg2, eg3, eg4, eg5, eg6, eg7, eg8, eg9, ef1, ef3, ef5, ef7, ef9]
  exact fe_mul_poly_id f.h0.val f.h1.val f.h2.val f.h3.val f.h4.val f.h5.val f.h6.val f.h7.val f.h8.val f.h9.val
                       g.h0.val g.h1.val g.h2.val g.h3.val g.h4.val g.h5.val g.h6.val g.h7.val g.h8.val g.h9.val

/-- Production Ref10 `fe_sq` computes exact squaring modulo `p = 2^255 - 19` with zero 64-bit
    overflow and restores `feCarryReduced` limb bounds. -/
theorem fe_sq_mod_p_and_bounds (f : Fe) (hf : feBounded f (2 ^ 27)) :
    ∃ r : Fe, fe_sq f = ok r ∧
      p25519 ∣ (feVal r - feVal f * feVal f) ∧
      feCarryReduced r := by
  unfold fe_sq
  rcases hf with ⟨f0l, f0h, f1l, f1h, f2l, f2h, f3l, f3h, f4l, f4h, f5l, f5h, f6l, f6h, f7l, f7h, f8l, f8h, f9l, f9h⟩
  have af0 : absLe f.h0 (2 ^ 27) := ⟨f0l, f0h⟩
  have af1 : absLe f.h1 (2 ^ 27) := ⟨f1l, f1h⟩
  have af2 : absLe f.h2 (2 ^ 27) := ⟨f2l, f2h⟩
  have af3 : absLe f.h3 (2 ^ 27) := ⟨f3l, f3h⟩
  have af4 : absLe f.h4 (2 ^ 27) := ⟨f4l, f4h⟩
  have af5 : absLe f.h5 (2 ^ 27) := ⟨f5l, f5h⟩
  have af6 : absLe f.h6 (2 ^ 27) := ⟨f6l, f6h⟩
  have af7 : absLe f.h7 (2 ^ 27) := ⟨f7l, f7h⟩
  have af8 : absLe f.h8 (2 ^ 27) := ⟨f8l, f8h⟩
  have af9 : absLe f.h9 (2 ^ 27) := ⟨f9l, f9h⟩
  have ⟨bf0, ef0⟩ := scale2_absLe af0
  have ⟨bf1, ef1⟩ := scale2_absLe af1
  have ⟨bf2, ef2⟩ := scale2_absLe af2
  have ⟨bf3, ef3⟩ := scale2_absLe af3
  have ⟨bf4, ef4⟩ := scale2_absLe af4
  have ⟨bf5, ef5⟩ := scale2_absLe af5
  have ⟨bf6, ef6⟩ := scale2_absLe af6
  have ⟨bf7, ef7⟩ := scale2_absLe af7
  have ⟨b5_38, e5_38⟩ := scale38_absLe af5
  have ⟨b6_19, e6_19⟩ := scale19_absLe af6
  have ⟨b7_38, e7_38⟩ := scale38_absLe af7
  have ⟨b8_19, e8_19⟩ := scale19_absLe af8
  have ⟨b9_38, e9_38⟩ := scale38_absLe af9
  have d0 := dot6_fast af0 af0 bf1 b9_38 bf2 b8_19 bf3 b7_38 bf4 b6_19 af5 b5_38 (by norm_num) (by norm_num)
  have d1 := dot5_fast bf0 af1 af2 b9_38 bf3 b8_19 af4 b7_38 bf5 b6_19 (by norm_num) (by norm_num)
  have d2 := dot6_fast bf0 af2 bf1 af1 bf3 b9_38 bf4 b8_19 bf5 b7_38 af6 b6_19 (by norm_num) (by norm_num)
  have d3 := dot5_fast bf0 af3 bf1 af2 af4 b9_38 bf5 b8_19 af6 b7_38 (by norm_num) (by norm_num)
  have d4 := dot6_fast bf0 af4 bf1 bf3 af2 af2 bf5 b9_38 bf6 b8_19 af7 b7_38 (by norm_num) (by norm_num)
  have d5 := dot5_fast bf0 af5 bf1 af4 bf2 af3 af6 b9_38 bf7 b8_19 (by norm_num) (by norm_num)
  have d6 := dot6_fast bf0 af6 bf1 bf5 bf2 af4 bf3 af3 bf7 b9_38 af8 b8_19 (by norm_num) (by norm_num)
  have d7 := dot5_fast bf0 af7 bf1 af6 bf2 af5 bf3 af4 af8 b9_38 (by norm_num) (by norm_num)
  have d8 := dot6_fast bf0 af8 bf1 bf7 bf2 af6 bf3 bf5 af4 af4 af9 b9_38 (by norm_num) (by norm_num)
  have d9 := dot5_fast bf0 af9 bf1 af8 bf2 af7 bf3 af6 bf4 af5 (by norm_num) (by norm_num)
  dsimp only [] at d0 d1 d2 d3 d4 d5 d6 d7 d8 d9
  rcases ref10_carry_chain _ _ _ _ _ _ _ _ _ _ d0.2 d1.2 d2.2 d3.2 d4.2 d5.2 d6.2 d7.2 d8.2 d9.2 with ⟨r, hr, hdiv_carry, hred⟩
  refine ⟨r, hr, ?_, hred⟩
  have htrans : ∀ x y z : Int, p25519 ∣ (x - y) → p25519 ∣ (y - z) → p25519 ∣ (x - z) := by
    intro x y z h1 h2
    have h := dvd_add h1 h2
    rwa [show (x - y) + (y - z) = x - z by ring] at h
  refine htrans _ _ _ hdiv_carry ?_
  unfold feVal p25519
  simp only []
  rw [d0.1, d1.1, d2.1, d3.1, d4.1, d5.1, d6.1, d7.1, d8.1, d9.1,
      ef0, ef1, ef2, ef3, ef4, ef5, ef6, ef7, e5_38, e6_19, e7_38, e8_19, e9_38]
  exact fe_sq_poly_id f.h0.val f.h1.val f.h2.val f.h3.val f.h4.val f.h5.val f.h6.val f.h7.val f.h8.val f.h9.val

/-! ## A-Grade Poly1305 RFC 8439 §2.5 Clamping & Canonical Reduction Mod `2^130 - 5` -/

/-- Prime modulus `p = 2^130 - 5` of Poly1305. -/
def p1305 : Nat := 2 ^ 130 - 5

/-- Mathematical natural-number value of a 5×26-bit Poly1305 accumulator. -/
def polyVal (h0 h1 h2 h3 h4 : Std.U64) : Nat :=
  h0.val + h1.val * 2 ^ 26 + h2.val * 2 ^ 52 + h3.val * 2 ^ 78 + h4.val * 2 ^ 104

private lemma uscalar_eq_of_bv_fp {ty} {x y : UScalar ty} (h : x.bv = y.bv) : x = y := by
  cases x; cases y; congr

private lemma u64_shr26_eval (x : Std.U64) :
    Pion.U64.shr x 26#u64 = ok ⟨x.bv >>> 26⟩ := by
  unfold Pion.U64.shr
  have h : (26#u64).val < 64 := by decide
  simp only [h, ↓reduceIte]; rfl

private lemma u64_shl26_eval (x : Std.U64) :
    Pion.U64.shl x 26#u64 = ok ⟨x.bv <<< 26⟩ := by
  unfold Pion.U64.shl
  have h : (26#u64).val < 64 := by decide
  simp only [h, ↓reduceIte]; rfl

private lemma u64_shr63_eval (x : Std.U64) :
    Pion.U64.shr x 63#u64 = ok ⟨x.bv >>> 63⟩ := by
  unfold Pion.U64.shr
  have h : (63#u64).val < 64 := by decide
  simp only [h, ↓reduceIte]; rfl

private lemma u64_shr_eval (x : Std.U64) (k : Std.U64) (hk : k.val < 64) :
    Pion.U64.shr x k = ok ⟨x.bv >>> k.val⟩ := by
  unfold Pion.U64.shr
  simp only [hk, ↓reduceIte]

private lemma u64_band_mask26 (x : Std.U64) :
    (Pion.U64.band x 67108863#u64).val = x.val % 2 ^ 26 := by
  change (x.bv &&& 67108863#64).toNat = x.bv.toNat % 2 ^ 26
  rw [BitVec.toNat_and]
  change x.bv.toNat &&& (2 ^ 26 - 1) = x.bv.toNat % 2 ^ 26
  exact Nat.and_two_pow_sub_one_eq_mod x.bv.toNat 26

private lemma u64_shr26_val (x : Std.U64) :
    (⟨x.bv >>> 26⟩ : Std.U64).val = x.val / 2 ^ 26 := by
  change (x.bv >>> 26).toNat = x.bv.toNat / 2 ^ 26
  rw [BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]

private lemma u64_add_val (x y : Std.U64) (h : x.val + y.val < 2 ^ 64) :
    (Pion.U64.add x y).val = x.val + y.val := by
  unfold Pion.U64.add
  change (x.bv + y.bv).toNat = x.bv.toNat + y.bv.toNat
  rw [BitVec.toNat_add]
  exact Nat.mod_eq_of_lt h

private lemma u64_mul_val (x y : Std.U64) (h : x.val * y.val < 2 ^ 64) :
    (Pion.U64.mul x y).val = x.val * y.val := by
  unfold Pion.U64.mul
  change (x.bv * y.bv).toNat = x.bv.toNat * y.bv.toNat
  rw [BitVec.toNat_mul]
  exact Nat.mod_eq_of_lt h

private lemma u64_sub_val_lt (x y : Std.U64) (h : x.val < y.val) :
    (Pion.U64.sub x y).val = 2 ^ 64 + x.val - y.val := by
  unfold Pion.U64.sub
  change (x.bv - y.bv).toNat = 2 ^ 64 + x.bv.toNat - y.bv.toNat
  rw [BitVec.toNat_sub]
  have hx : x.bv.toNat < 2 ^ 64 := x.bv.isLt
  have hy : y.bv.toNat < 2 ^ 64 := y.bv.isLt
  have hlt : x.bv.toNat < y.bv.toNat := h
  omega

private lemma u64_sub_val_ge (x y : Std.U64) (h : y.val ≤ x.val) :
    (Pion.U64.sub x y).val = x.val - y.val := by
  unfold Pion.U64.sub
  change (x.bv - y.bv).toNat = x.bv.toNat - y.bv.toNat
  rw [BitVec.toNat_sub_of_le (BitVec.le_def.mpr h)]

/-- RFC 8439 §2.5 Poly1305 `r` key clamping clears the top 4 bits of bytes 3, 7, 11, 15 and the
    bottom 2 bits of bytes 4, 8, 12, and bounds every 26-bit limb (`r4 < 2^20`, `R < 2^124`). -/
theorem poly1305_clamp_r_rfc8439_spec (w0 w1 w2 w3 w4 : Std.U64) :
    ∃ r0 r1 r2 r3 r4 : Std.U64,
      poly1305_clamp_r w0 w1 w2 w3 w4 = ok (r0, r1, r2, r3, r4) ∧
      r0.val < 2 ^ 26 ∧ r1.val < 2 ^ 26 ∧ r2.val < 2 ^ 26 ∧ r3.val < 2 ^ 26 ∧ r4.val < 2 ^ 20 ∧
      let R := polyVal r0 r1 r2 r3 r4
      R < 2 ^ 124 ∧
      (R / 2 ^ 28) % 16 = 0 ∧
      (R / 2 ^ 60) % 16 = 0 ∧
      (R / 2 ^ 92) % 16 = 0 ∧
      (R / 2 ^ 124) % 16 = 0 ∧
      (R / 2 ^ 32) % 4 = 0 ∧
      (R / 2 ^ 64) % 4 = 0 ∧
      (R / 2 ^ 96) % 4 = 0 := by
  unfold poly1305_clamp_r
  simp only [u64_shr_eval _ 2#u64 (by decide), u64_shr_eval _ 4#u64 (by decide),
             u64_shr_eval _ 6#u64 (by decide), u64_shr_eval _ 8#u64 (by decide), result_bind_ok_fp]
  set r0 := Pion.U64.band w0 67108863#u64
  set r1 := Pion.U64.band ⟨w1.bv >>> 2⟩ 67108611#u64
  set r2 := Pion.U64.band ⟨w2.bv >>> 4⟩ 67092735#u64
  set r3 := Pion.U64.band ⟨w3.bv >>> 6⟩ 66076671#u64
  set r4 := Pion.U64.band ⟨w4.bv >>> 8⟩ 1048575#u64
  have hr0 : r0.val < 2 ^ 26 := by
    have : r0.val = w0.val % 2 ^ 26 := u64_band_mask26 w0; omega
  have hr1_mask : r1.val = (w1.bv >>> 2).toNat &&& 67108611 := by
    change ((w1.bv >>> 2) &&& 67108611#64).toNat = _; rw [BitVec.toNat_and]; rfl
  have hr2_mask : r2.val = (w2.bv >>> 4).toNat &&& 67092735 := by
    change ((w2.bv >>> 4) &&& 67092735#64).toNat = _; rw [BitVec.toNat_and]; rfl
  have hr3_mask : r3.val = (w3.bv >>> 6).toNat &&& 66076671 := by
    change ((w3.bv >>> 6) &&& 66076671#64).toNat = _; rw [BitVec.toNat_and]; rfl
  have hr4_mask : r4.val = (w4.bv >>> 8).toNat &&& 1048575 := by
    change ((w4.bv >>> 8) &&& 1048575#64).toNat = _; rw [BitVec.toNat_and]; rfl
  have hr1 : r1.val < 2 ^ 26 := by rw [hr1_mask]; have := Nat.and_le_right (n := (w1.bv >>> 2).toNat) (m := 67108611); omega
  have hr2 : r2.val < 2 ^ 26 := by rw [hr2_mask]; have := Nat.and_le_right (n := (w2.bv >>> 4).toNat) (m := 67092735); omega
  have hr3 : r3.val < 2 ^ 26 := by rw [hr3_mask]; have := Nat.and_le_right (n := (w3.bv >>> 6).toNat) (m := 66076671); omega
  have hr4 : r4.val < 2 ^ 20 := by rw [hr4_mask]; have := Nat.and_le_right (n := (w4.bv >>> 8).toNat) (m := 1048575); omega
  have clear_bits : ∀ (x m s w : Nat), (m >>> s) &&& (2 ^ w - 1) = 0 → ((x &&& m) / 2 ^ s) % 2 ^ w = 0 := by
    intro x m s w hm
    rw [← Nat.shiftRight_eq_div_pow, ← Nat.and_two_pow_sub_one_eq_mod, Nat.shiftRight_and_distrib,
        Nat.and_assoc, hm, Nat.and_zero]
  have h1_c : (r1.val / 2 ^ 2) % 64 = 0 := by
    rw [hr1_mask]; exact clear_bits _ 67108611 2 6 (by decide)
  have h2_c : (r2.val / 2 ^ 8) % 64 = 0 := by
    rw [hr2_mask]; exact clear_bits _ 67092735 8 6 (by decide)
  have h3_c : (r3.val / 2 ^ 14) % 64 = 0 := by
    rw [hr3_mask]; exact clear_bits _ 66076671 14 6 (by decide)
  refine ⟨r0, r1, r2, r3, r4, rfl, hr0, hr1, hr2, hr3, hr4, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals dsimp only [polyVal]
  · omega
  · omega
  · omega
  · omega
  · omega
  · omega
  · omega
  · omega

private lemma u64_mask_zero_select (h g : Std.U64) :
    Pion.U64.bor (Pion.U64.band h (Pion.U64.bxor 0#u64 18446744073709551615#u64)) (Pion.U64.band g 0#u64) = h := by
  apply uscalar_eq_of_bv_fp
  change (h.bv &&& (0#64 ^^^ 18446744073709551615#64)) ||| (g.bv &&& 0#64) = h.bv
  have hm : (0#64 ^^^ 18446744073709551615#64 : BitVec 64) = BitVec.allOnes 64 := rfl
  rw [hm, BitVec.and_allOnes, BitVec.and_zero, BitVec.or_zero]

private lemma u64_mask_allones_select (h g : Std.U64) :
    Pion.U64.bor (Pion.U64.band h (Pion.U64.bxor (Pion.U64.sub 0#u64 1#u64) 18446744073709551615#u64))
                 (Pion.U64.band g (Pion.U64.sub 0#u64 1#u64)) = g := by
  apply uscalar_eq_of_bv_fp
  change (h.bv &&& ((0#64 - 1#64) ^^^ 18446744073709551615#64)) ||| (g.bv &&& (0#64 - 1#64)) = g.bv
  have h0 : ((0#64 - 1#64) ^^^ 18446744073709551615#64 : BitVec 64) = 0#64 := rfl
  have hm : (0#64 - 1#64 : BitVec 64) = BitVec.allOnes 64 := rfl
  rw [h0, hm, BitVec.and_zero, BitVec.and_allOnes, BitVec.zero_or]

/-- Production constant-time `poly1305_final_reduce` produces the unique canonical representative in
    `[0, 2^130 - 5)` congruent modulo `2^130 - 5` (including the exact boundary `h = 2^130 - 5 ↦ 0`). -/
theorem poly1305_final_reduce_canonical (h0 h1 h2 h3 h4 : Std.U64)
    (hb0 : h0.val < 2 ^ 26) (hb1 : h1.val < 2 ^ 32)
    (hb2 : h2.val < 2 ^ 26) (hb3 : h3.val < 2 ^ 26) (hb4 : h4.val < 2 ^ 26) :
    ∃ r0 r1 r2 r3 r4 : Std.U64,
      poly1305_final_reduce h0 h1 h2 h3 h4 = ok (r0, r1, r2, r3, r4) ∧
      polyVal r0 r1 r2 r3 r4 < p1305 ∧
      polyVal r0 r1 r2 r3 r4 % p1305 = polyVal h0 h1 h2 h3 h4 % p1305 := by
  suffices hmain : ∀ res : Result (Std.U64 × Std.U64 × Std.U64 × Std.U64 × Std.U64),
      res = poly1305_final_reduce h0 h1 h2 h3 h4 →
      ∃ r0 r1 r2 r3 r4 : Std.U64,
        res = ok (r0, r1, r2, r3, r4) ∧
        polyVal r0 r1 r2 r3 r4 < p1305 ∧
        polyVal r0 r1 r2 r3 r4 % p1305 = polyVal h0 h1 h2 h3 h4 % p1305 from
    hmain _ rfl
  intro res hres
  unfold poly1305_final_reduce at hres
  dsimp only [] at hres
  have h5v : (5#u64).val = 5 := rfl
  -- Linearly peel the 11 monadic shifts in hres so the do-block never expands exponentially
  rw [u64_shr26_eval, result_bind_ok_fp] at hres
  generalize hc0_eq : (⟨h1.bv >>> 26⟩ : Std.U64) = c0 at hres
  generalize hh11_eq : Pion.U64.band h1 67108863#u64 = h11 at hres
  generalize hh21_eq : Pion.U64.add h2 c0 = h21 at hres
  have ec0 : c0.val = h1.val / 2 ^ 26 := by rw [← hc0_eq]; exact u64_shr26_val h1
  have eh11 : h11.val = h1.val % 2 ^ 26 := by rw [← hh11_eq]; exact u64_band_mask26 h1
  have eh21 : h21.val = h2.val + c0.val := by rw [← hh21_eq]; exact u64_add_val h2 c0 (by omega)

  rw [u64_shr26_eval, result_bind_ok_fp] at hres
  generalize hc1_eq : (⟨h21.bv >>> 26⟩ : Std.U64) = c1 at hres
  generalize hh22_eq : Pion.U64.band h21 67108863#u64 = h22 at hres
  generalize hh31_eq : Pion.U64.add h3 c1 = h31 at hres
  have ec1 : c1.val = h21.val / 2 ^ 26 := by rw [← hc1_eq]; exact u64_shr26_val h21
  have eh22 : h22.val = h21.val % 2 ^ 26 := by rw [← hh22_eq]; exact u64_band_mask26 h21
  have eh31 : h31.val = h3.val + c1.val := by rw [← hh31_eq]; exact u64_add_val h3 c1 (by omega)

  rw [u64_shr26_eval, result_bind_ok_fp] at hres
  generalize hc2_eq : (⟨h31.bv >>> 26⟩ : Std.U64) = c2 at hres
  generalize hh32_eq : Pion.U64.band h31 67108863#u64 = h32 at hres
  generalize hh41_eq : Pion.U64.add h4 c2 = h41 at hres
  have ec2 : c2.val = h31.val / 2 ^ 26 := by rw [← hc2_eq]; exact u64_shr26_val h31
  have eh32 : h32.val = h31.val % 2 ^ 26 := by rw [← hh32_eq]; exact u64_band_mask26 h31
  have eh41 : h41.val = h4.val + c2.val := by rw [← hh41_eq]; exact u64_add_val h4 c2 (by omega)

  rw [u64_shr26_eval, result_bind_ok_fp] at hres
  generalize hc3_eq : (⟨h41.bv >>> 26⟩ : Std.U64) = c3 at hres
  generalize hh42_eq : Pion.U64.band h41 67108863#u64 = h42 at hres
  generalize hh01_eq : Pion.U64.add h0 (Pion.U64.mul c3 5#u64) = h01 at hres
  have ec3 : c3.val = h41.val / 2 ^ 26 := by rw [← hc3_eq]; exact u64_shr26_val h41
  have eh42 : h42.val = h41.val % 2 ^ 26 := by rw [← hh42_eq]; exact u64_band_mask26 h41
  have ec3m5 : (Pion.U64.mul c3 5#u64).val = c3.val * 5 := by
    have := u64_mul_val c3 5#u64 (by rw [h5v]; omega); rw [h5v] at this; exact this
  have eh01 : h01.val = h0.val + c3.val * 5 := by
    rw [← hh01_eq]; have := u64_add_val h0 (Pion.U64.mul c3 5#u64) (by omega); rw [ec3m5] at this; exact this

  rw [u64_shr26_eval, result_bind_ok_fp] at hres
  generalize hc4_eq : (⟨h01.bv >>> 26⟩ : Std.U64) = c4 at hres
  generalize hh02_eq : Pion.U64.band h01 67108863#u64 = h02 at hres
  generalize hh12_eq : Pion.U64.add h11 c4 = h12 at hres
  have ec4 : c4.val = h01.val / 2 ^ 26 := by rw [← hc4_eq]; exact u64_shr26_val h01
  have eh02 : h02.val = h01.val % 2 ^ 26 := by rw [← hh02_eq]; exact u64_band_mask26 h01
  have eh12 : h12.val = h11.val + c4.val := by rw [← hh12_eq]; exact u64_add_val h11 c4 (by omega)

  have hphase1_eq : polyVal h02 h12 h22 h32 h42 + c3.val * p1305 = polyVal h0 h1 h2 h3 h4 := by
    unfold polyVal p1305; omega
  have hphase1_mod : polyVal h02 h12 h22 h32 h42 % p1305 = polyVal h0 h1 h2 h3 h4 % p1305 := by
    rw [← hphase1_eq, Nat.add_mul_mod_self_right]

  generalize hg0_eq : Pion.U64.add h02 5#u64 = g0 at hres
  have eg0 : g0.val = h02.val + 5 := by
    rw [← hg0_eq]; have := u64_add_val h02 5#u64 (by rw [h5v]; omega); rw [h5v] at this; exact this
  rw [u64_shr26_eval, result_bind_ok_fp] at hres
  generalize hc5_eq : (⟨g0.bv >>> 26⟩ : Std.U64) = c5 at hres
  generalize hg01_eq : Pion.U64.band g0 67108863#u64 = g01 at hres
  generalize hg1_eq : Pion.U64.add h12 c5 = g1 at hres
  have ec5 : c5.val = g0.val / 2 ^ 26 := by rw [← hc5_eq]; exact u64_shr26_val g0
  have eg01 : g01.val = g0.val % 2 ^ 26 := by rw [← hg01_eq]; exact u64_band_mask26 g0
  have eg1 : g1.val = h12.val + c5.val := by rw [← hg1_eq]; exact u64_add_val h12 c5 (by omega)

  rw [u64_shr26_eval, result_bind_ok_fp] at hres
  generalize hc6_eq : (⟨g1.bv >>> 26⟩ : Std.U64) = c6 at hres
  generalize hg11_eq : Pion.U64.band g1 67108863#u64 = g11 at hres
  generalize hg2_eq : Pion.U64.add h22 c6 = g2 at hres
  have ec6 : c6.val = g1.val / 2 ^ 26 := by rw [← hc6_eq]; exact u64_shr26_val g1
  have eg11 : g11.val = g1.val % 2 ^ 26 := by rw [← hg11_eq]; exact u64_band_mask26 g1
  have eg2 : g2.val = h22.val + c6.val := by rw [← hg2_eq]; exact u64_add_val h22 c6 (by omega)

  rw [u64_shr26_eval, result_bind_ok_fp] at hres
  generalize hc7_eq : (⟨g2.bv >>> 26⟩ : Std.U64) = c7 at hres
  generalize hg21_eq : Pion.U64.band g2 67108863#u64 = g21 at hres
  generalize hg3_eq : Pion.U64.add h32 c7 = g3 at hres
  have ec7 : c7.val = g2.val / 2 ^ 26 := by rw [← hc7_eq]; exact u64_shr26_val g2
  have eg21 : g21.val = g2.val % 2 ^ 26 := by rw [← hg21_eq]; exact u64_band_mask26 g2
  have eg3 : g3.val = h32.val + c7.val := by rw [← hg3_eq]; exact u64_add_val h32 c7 (by omega)

  rw [u64_shr26_eval, result_bind_ok_fp] at hres
  generalize hc8_eq : (⟨g3.bv >>> 26⟩ : Std.U64) = c8 at hres
  generalize hg31_eq : Pion.U64.band g3 67108863#u64 = g31 at hres
  have ec8 : c8.val = g3.val / 2 ^ 26 := by rw [← hc8_eq]; exact u64_shr26_val g3
  have eg31 : g31.val = g3.val % 2 ^ 26 := by rw [← hg31_eq]; exact u64_band_mask26 g3

  rw [u64_shl26_eval, result_bind_ok_fp] at hres
  generalize htwo26_eq : (⟨(1#u64).bv <<< 26⟩ : Std.U64) = two26 at hres
  generalize hg4_eq : Pion.U64.sub (Pion.U64.add h42 c8) two26 = g4 at hres
  rw [u64_shr63_eval, result_bind_ok_fp] at hres
  have eh4c8 : (Pion.U64.add h42 c8).val = h42.val + c8.val := u64_add_val h42 c8 (by omega)
  have h1shl : two26.val = 2 ^ 26 := by rw [← htwo26_eq]; decide

  by_cases hlt : h42.val + c8.val < 2 ^ 26
  · have hg4_val : g4.val = 2 ^ 64 + (h42.val + c8.val) - 2 ^ 26 := by
      rw [← hg4_eq, u64_sub_val_lt _ _ (by omega), eh4c8, h1shl]
    have hshr63 : (⟨g4.bv >>> 63⟩ : Std.U64) = 1#u64 := by
      apply uscalar_eq_of_bv_fp; apply BitVec.eq_of_toNat_eq
      change (g4.bv >>> 63).toNat = 1
      rw [BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
      change g4.val / 2 ^ 63 = 1
      omega
    have hmask : Pion.U64.sub ⟨g4.bv >>> 63⟩ 1#u64 = 0#u64 := by
      rw [hshr63]; rfl
    refine ⟨h02, h12, h22, h32, h42, ?_, ?_, hphase1_mod⟩
    · rw [hres, hmask]
      simp only [u64_mask_zero_select]
    · unfold polyVal p1305
      omega
  · have hg4_val : g4.val = h42.val + c8.val - 2 ^ 26 := by
      rw [← hg4_eq, u64_sub_val_ge _ _ (by omega), eh4c8, h1shl]
    have hshr63 : (⟨g4.bv >>> 63⟩ : Std.U64) = 0#u64 := by
      apply uscalar_eq_of_bv_fp; apply BitVec.eq_of_toNat_eq
      change (g4.bv >>> 63).toNat = 0
      rw [BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
      change g4.val / 2 ^ 63 = 0
      omega
    refine ⟨g01, g11, g21, g31, g4, ?_, ?_, ?_⟩
    · rw [hres, hshr63]
      simp only [u64_mask_allones_select]
    · unfold polyVal p1305
      omega
    · have hg_eq : polyVal g01 g11 g21 g31 g4 + p1305 = polyVal h02 h12 h22 h32 h42 := by
        unfold polyVal p1305
        omega
      rw [← hphase1_mod, ← hg_eq, Nat.add_mod_right]

/-! ## A-Grade Constant-Time Branch-Free Nibble Selector (`ct_eq_nibble`) -/

/-- Branch-free Ed25519 4-bit window selector `ct_eq_nibble a b` returns `1` iff `a = b` and `0`
    otherwise for all non-negative 32-bit inputs (strictly covering all `[0, 15]` nibbles). -/
theorem ct_eq_nibble_spec (a b : Std.I32) (ha : 0 ≤ a.val) (hb : 0 ≤ b.val) :
    ct_eq_nibble a b = ok (if a = b then 1#i64 else 0#i64) := by
  unfold ct_eq_nibble Pion.I32.shr
  have hsh : (0 : Int) ≤ (31#i32).val ∧ (31#i32).val < 32 := by decide
  simp only [hsh, and_self, ↓reduceIte, result_bind_ok_fp]
  apply congrArg ok
  have ha_nat : a.bv.toNat < 2 ^ 31 := by
    have hti := BitVec.toInt_eq_toNat_cond a.bv
    change a.val = _ at hti
    split at hti <;> omega
  have hb_nat : b.bv.toNat < 2 ^ 31 := by
    have hti := BitVec.toInt_eq_toNat_cond b.bv
    change b.val = _ at hti
    split at hti <;> omega
  have hxor_lt : (a.bv ^^^ b.bv).toNat < 2 ^ 31 := by
    rw [BitVec.toNat_xor]
    exact Nat.xor_lt_two_pow ha_nat hb_nat
  by_cases hab : a = b
  · subst hab
    simp only [↓reduceIte]
    have hx0 : a.bv ^^^ a.bv = 0#32 := BitVec.xor_self
    change Pion.I64.band (Pion.I32.to_int64 ⟨((a.bv ^^^ a.bv) - 1#32).sshiftRight 31⟩) 1#i64 = 1#i64
    rw [hx0]
    decide
  · simp only [hab, ↓reduceIte]
    have hx_ne : a.bv ^^^ b.bv ≠ 0#32 := by
      intro h0
      have hbv : a.bv = b.bv := by
        have := congrArg (fun v => a.bv ^^^ v) h0
        simp only [← BitVec.xor_assoc, BitVec.xor_self, BitVec.zero_xor, BitVec.xor_zero] at this
        exact this.symm
      exact hab (by cases a; cases b; congr)
    have hx_pos : 1 ≤ (a.bv ^^^ b.bv).toNat := by
      have hne0 : (a.bv ^^^ b.bv).toNat ≠ 0 := by
        intro h; exact hx_ne (BitVec.eq_of_toNat_eq h)
      omega
    have hsub_nat : ((a.bv ^^^ b.bv) - 1#32).toNat = (a.bv ^^^ b.bv).toNat - 1 := by
      rw [BitVec.toNat_sub_of_le]
      · rfl
      · exact BitVec.le_def.mpr hx_pos
    have hsub_toInt : ((a.bv ^^^ b.bv) - 1#32).toInt = (((a.bv ^^^ b.bv).toNat - 1 : Nat) : Int) := by
      rw [BitVec.toInt_eq_toNat_cond, hsub_nat]
      have h2 : 2 * ((a.bv ^^^ b.bv).toNat - 1) < 2 ^ 32 := by omega
      simp only [h2, ↓reduceIte]
    have hshr0 : ((a.bv ^^^ b.bv) - 1#32).sshiftRight 31 = 0#32 := by
      apply BitVec.eq_of_toInt_eq
      rw [BitVec.toInt_sshiftRight, Int.shiftRight_eq_div_pow, hsub_toInt]
      have : (((a.bv ^^^ b.bv).toNat - 1 : Nat) : Int) / ((2 ^ 31 : Nat) : Int) = 0 := by
        push_cast; omega
      rw [this]; rfl
    change Pion.I64.band (Pion.I32.to_int64 ⟨((a.bv ^^^ b.bv) - 1#32).sshiftRight 31⟩) 1#i64 = 0#i64
    rw [hshr0]
    decide

end CryptoProofs
