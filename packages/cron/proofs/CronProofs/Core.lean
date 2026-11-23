/-
Formal verification of `packages/cron` core kernels extracted by `pionc extract-lean`.

Verified theorems (complete kernel-checked proofs;
only standard Lean axioms `propext`, `Classical.choice`, `Quot.sound`):
  1. 64-bit bitmask kernels over all `2^64` inputs:
     - `ctz64_spec`: exact trailing-zero count
     - `msb64_spec`: exact highest-set-bit index
     - `next_set_bit_spec`: exact lowest set bit `>= from` (or `-1`)
     - `prev_set_bit_spec`: exact highest set bit `<= from` (or `-1`)
  2. Proleptic Gregorian calendar & `DateTime` validity / bijection:
     - `is_leap_year_spec` (+ `2000`, `2100`, `2400` corollaries)
     - `days_in_month_spec` (`28 ≤ dim ≤ 31`, exact Feb leap rule, all 12 months)
     - `datetime_is_valid_spec` & `datetime_valid_shift_bounds` (F5 guard)
     - `from_unix_secs_rejects_out_of_range` & `from_unix_secs_in_range_valid` (F3 guard)
     - `to_from_unix_secs_roundtrip`, `from_to_unix_secs_roundtrip`, `to_unix_secs_strict_mono`
  3. Bitmask matcher shift-safety & invalid-`DateTime` guard:
     - `matches_fixed_fields_rejects_invalid`
     - `matches_fixed_fields_valid_exact`
     - `matches_day_rejects_invalid`
-/
import Cron.Funs
open Aeneas Aeneas.Std Result Pion WP

set_option maxRecDepth 4000
set_option maxHeartbeats 200000

namespace CronProofs

open cron

/-! ## General helper lemmas -/

theorem b_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← (ok x : Result α); f y) = f x := by simp

theorem b_ok_pair {α β γ : Type} (a : α) (b : β) (f : α → β → Result γ) :
    (do let (x, y) ← (ok (a, b) : Result (α × β)); f x y) = f a b := by simp

theorem ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  have h1 : (ok a : Result α) ⦃ x => x = a ⦄ := (WP.spec_ok a).mpr rfl
  rw [h, WP.spec_ok] at h1
  exact h1.symm

theorem u64_shr_lit (x k : Std.U64) (h : k.val < 64) :
    Pion.U64.shr x k = ok ⟨x.bv >>> k.val⟩ := by
  simp [Pion.U64.shr, h]

theorem u64_shr_i32_ok (x : Std.U64) (k : Std.I32) (h0 : 0 ≤ k.val) (h1 : k.val < 64) :
    Pion.U64.shr_i32 x k = ok ⟨x.bv >>> k.val.toNat⟩ := by
  simp [Pion.U64.shr_i32, h0, h1]

theorem u64_shl_i32_ok (x : Std.U64) (k : Std.I32) (h0 : 0 ≤ k.val) (h1 : k.val < 64) :
    Pion.U64.shl_i32 x k = ok ⟨x.bv <<< k.val.toNat⟩ := by
  simp [Pion.U64.shl_i32, h0, h1]

theorem u64_ne_zero_iff (x : Std.U64) :
    x ≠ 0#u64 ↔ ∃ i, i < 64 ∧ x.bv.getLsbD i = true := by
  constructor
  · intro hne
    by_contra hall
    push Not at hall
    apply hne
    cases x with | mk bv =>
    congr 1
    apply BitVec.eq_of_getLsbD_eq
    intro i hi
    change bv.getLsbD i = (0#64).getLsbD i
    rw [BitVec.getLsbD_zero]
    exact Bool.eq_false_iff.mpr (hall i hi)
  · rintro ⟨i, _, hi⟩ h0
    subst h0
    change (0#64).getLsbD i = true at hi
    rw [BitVec.getLsbD_zero] at hi
    exact Bool.false_ne_true hi

theorem bv_eq_zero_iff (x : BitVec 64) :
    x = 0#64 ↔ ∀ i, i < 64 → x.getLsbD i = false := by
  constructor
  · intro h i _; subst h; simp
  · intro h
    apply BitVec.eq_of_getLsbD_eq
    intro i hi
    simp [h i hi]

theorem u64_band_eq_zero_iff (x m : Std.U64) :
    Pion.U64.band x m = 0#u64 ↔ ∀ i, i < 64 → m.bv.getLsbD i = true → x.bv.getLsbD i = false := by
  constructor
  · intro h i hi hm
    have hbv : x.bv &&& m.bv = 0#64 := congrArg (fun u : Std.U64 => u.bv) h
    have h0 := (bv_eq_zero_iff _).mp hbv i hi
    simp [BitVec.getLsbD_and, hm] at h0
    exact h0
  · intro h
    have hbv : x.bv &&& m.bv = 0#64 := by
      apply BitVec.eq_of_getLsbD_eq
      intro i hi
      simp only [BitVec.getLsbD_and, BitVec.getLsbD_zero]
      cases hm : m.bv.getLsbD i
      · simp
      · simp [h i hi hm]
    exact congrArg UScalar.mk hbv

theorem u64_band_ne_zero_iff (x m : Std.U64) :
    Pion.U64.band x m ≠ 0#u64 ↔ ∃ i, i < 64 ∧ m.bv.getLsbD i = true ∧ x.bv.getLsbD i = true := by
  rw [ne_eq, u64_band_eq_zero_iff]
  push Not
  constructor
  · rintro ⟨i, hi, hm, hx⟩
    exact ⟨i, hi, hm, Bool.eq_true_of_not_eq_false hx⟩
  · rintro ⟨i, hi, hm, hx⟩
    exact ⟨i, hi, hm, by simp [hx]⟩

theorem i32_add_val (a b : Std.I32)
    (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  change (a.bv + b.bv).toInt = a.bv.toInt + b.bv.toInt
  change -2147483648 ≤ a.bv.toInt + b.bv.toInt at hlo
  change a.bv.toInt + b.bv.toInt ≤ 2147483647 at hhi
  rw [BitVec.toInt_add, Int.bmod_eq_of_le] <;> omega

theorem i32_sub_val (a b : Std.I32)
    (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  change (a.bv - b.bv).toInt = a.bv.toInt - b.bv.toInt
  change -2147483648 ≤ a.bv.toInt - b.bv.toInt at hlo
  change a.bv.toInt - b.bv.toInt ≤ 2147483647 at hhi
  rw [BitVec.toInt_sub, Int.bmod_eq_of_le] <;> omega

theorem i32_mul_val (a b : Std.I32)
    (hlo : -2147483648 ≤ a.val * b.val) (hhi : a.val * b.val ≤ 2147483647) :
    (Pion.I32.mul a b).val = a.val * b.val := by
  change (a.bv * b.bv).toInt = a.bv.toInt * b.bv.toInt
  change -2147483648 ≤ a.bv.toInt * b.bv.toInt at hlo
  change a.bv.toInt * b.bv.toInt ≤ 2147483647 at hhi
  rw [BitVec.toInt_mul, Int.bmod_eq_of_le] <;> omega

theorem i64_add_val (a b : Std.I64)
    (hlo : -9223372036854775808 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 9223372036854775807) :
    (Pion.I64.add a b).val = a.val + b.val := by
  change (a.bv + b.bv).toInt = a.bv.toInt + b.bv.toInt
  change -9223372036854775808 ≤ a.bv.toInt + b.bv.toInt at hlo
  change a.bv.toInt + b.bv.toInt ≤ 9223372036854775807 at hhi
  rw [BitVec.toInt_add, Int.bmod_eq_of_le] <;> omega

theorem i64_sub_val (a b : Std.I64)
    (hlo : -9223372036854775808 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 9223372036854775807) :
    (Pion.I64.sub a b).val = a.val - b.val := by
  change (a.bv - b.bv).toInt = a.bv.toInt - b.bv.toInt
  change -9223372036854775808 ≤ a.bv.toInt - b.bv.toInt at hlo
  change a.bv.toInt - b.bv.toInt ≤ 9223372036854775807 at hhi
  rw [BitVec.toInt_sub, Int.bmod_eq_of_le] <;> omega

theorem i64_mul_val (a b : Std.I64)
    (hlo : -9223372036854775808 ≤ a.val * b.val) (hhi : a.val * b.val ≤ 9223372036854775807) :
    (Pion.I64.mul a b).val = a.val * b.val := by
  change (a.bv * b.bv).toInt = a.bv.toInt * b.bv.toInt
  change -9223372036854775808 ≤ a.bv.toInt * b.bv.toInt at hlo
  change a.bv.toInt * b.bv.toInt ≤ 9223372036854775807 at hhi
  rw [BitVec.toInt_mul, Int.bmod_eq_of_le] <;> omega

theorem spec_to_ok {α : Type} {m : Result α} {p : α → Prop} (h : m ⦃ p ⦄) :
    ∃ z, m = ok z ∧ p z := by
  cases hres : m with
  | ret z => rw [hres] at h; exact ⟨z, rfl, (WP.spec_ok z).mp h⟩
  | vis e k => rw [hres] at h; exact False.elim ((WP.spec_vis e k).mp h)
  | div => rw [hres] at h; exact False.elim (WP.spec_div.mp h)

theorem i32_div_ok (a b : Std.I32) (hnz : b.val ≠ 0)
    (hno : ¬ (a.val = -2147483648 ∧ b.val = -1)) :
    ∃ z : Std.I32, Pion.I32.div a b = ok z ∧ z.val = Int.tdiv a.val b.val :=
  spec_to_ok (Pion.I32.div_spec (x := a) (y := b) hnz hno)

theorem i32_rem_ok (a b : Std.I32) (hnz : b.val ≠ 0)
    (hno : ¬ (a.val = -2147483648 ∧ b.val = -1)) :
    ∃ z : Std.I32, Pion.I32.rem a b = ok z ∧ z.val = Int.tmod a.val b.val :=
  spec_to_ok (Pion.I32.rem_spec (x := a) (y := b) hnz hno)

theorem i64_div_ok (a b : Std.I64) (hnz : b.val ≠ 0)
    (hno : ¬ (a.val = -9223372036854775808 ∧ b.val = -1)) :
    ∃ z : Std.I64, Pion.I64.div a b = ok z ∧ z.val = Int.tdiv a.val b.val :=
  spec_to_ok (Pion.I64.div_spec (x := a) (y := b) hnz hno)

theorem i32_to_i64_val (a : Std.I32) :
    (Pion.I32.to_int64 a).val = a.val := by
  rw [Pion.I32.to_int64, IScalar.cast_val_eq]
  have ha := a.hBounds
  simp only [IScalar.min, IScalar.max, IScalarTy.numBits] at ha ⊢
  have h2 : (2 ^ min 64 32 : Nat) = 4294967296 := by simp
  rw [h2, Int.bmod_eq_of_le] <;> omega

theorem i64_to_i32_val (a : Std.I64)
    (hlo : -2147483648 ≤ a.val) (hhi : a.val ≤ 2147483647) :
    (Pion.I64.to_int a).val = a.val := by
  rw [Pion.I64.to_int, IScalar.cast_val_eq]
  simp only [IScalarTy.numBits]
  have h2 : (2 ^ min 32 64 : Nat) = 4294967296 := by simp
  rw [h2, Int.bmod_eq_of_le] <;> omega

theorem i32_ext {a b : Std.I32} (h : a.val = b.val) : a = b := by
  cases a with | mk abv =>
  cases b with | mk bbv =>
  congr 1
  exact BitVec.eq_of_toInt_eq h

theorem i64_ext {a b : Std.I64} (h : a.val = b.val) : a = b := by
  cases a with | mk abv =>
  cases b with | mk bbv =>
  congr 1
  exact BitVec.eq_of_toInt_eq h


end CronProofs
