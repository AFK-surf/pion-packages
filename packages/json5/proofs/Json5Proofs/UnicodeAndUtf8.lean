import Aeneas
import PionLean
import Json5.Types
import Json5.Funs

open Aeneas Aeneas.Std Result Error Pion
open json5

namespace Json5Proofs

private lemma result_bind_ok {α β : Type} (a : α) (f : α → Result β) :
    (do let x ← ok a; f x) = f a := by
  simp

private lemma i32_beq_iff (x y : Std.I32) : (x == y) = true ↔ x.val = y.val := by
  cases x; cases y
  simp [BEq.beq, IScalar.val, BitVec.toInt_inj]

private lemma i32_eq_of_val {x y : Std.I32} (h : x.val = y.val) : x = y := by
  cases x; cases y
  simp [IScalar.val, BitVec.toInt_inj] at h
  congr

private lemma i32_add_val (x y : Std.I32)
    (hlo : -(2 ^ 31 : Int) ≤ x.val + y.val) (hhi : x.val + y.val < 2 ^ 31) :
    (Pion.I32.add x y).val = x.val + y.val := by
  change -(2 ^ 31 : Int) ≤ x.bv.toInt + y.bv.toInt at hlo
  change x.bv.toInt + y.bv.toInt < 2 ^ 31 at hhi
  change (x.bv + y.bv).toInt = x.bv.toInt + y.bv.toInt
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_sub_val (x y : Std.I32)
    (hlo : -(2 ^ 31 : Int) ≤ x.val - y.val) (hhi : x.val - y.val < 2 ^ 31) :
    (Pion.I32.sub x y).val = x.val - y.val := by
  change -(2 ^ 31 : Int) ≤ x.bv.toInt - y.bv.toInt at hlo
  change x.bv.toInt - y.bv.toInt < 2 ^ 31 at hhi
  change (x.bv - y.bv).toInt = x.bv.toInt - y.bv.toInt
  rw [BitVec.toInt_sub]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_toNat_of_nonneg (x : Std.I32) (h0 : 0 ≤ x.val) :
    x.bv.toNat = x.val.toNat := by
  have hb := x.hBounds
  simp at hb
  have hlt : 2 * x.bv.toNat < 2 ^ 32 := by
    have hbv := BitVec.toInt_eq_toNat_cond x.bv
    split_ifs at hbv with hc
    · omega
    · change 0 ≤ x.bv.toInt at h0
      omega
  have hti : x.bv.toInt = (x.bv.toNat : Int) := BitVec.toInt_eq_toNat_of_lt hlt
  change x.bv.toNat = x.bv.toInt.toNat
  rw [hti]; omega

private lemma i32_shl_nonneg (x : Std.I32) (k : Std.I32)
    (hk0 : 0 ≤ k.val) (hk32 : k.val < 32)
    (hx0 : 0 ≤ x.val) (hfit : x.val.toNat * 2 ^ k.val.toNat < 2 ^ 31) :
    ∃ r : Std.I32,
      Pion.I32.shl x k = ok r ∧ r.val = x.val * (2 ^ k.val.toNat : Nat) := by
  have hk : 0 ≤ k.val ∧ k.val < 32 := ⟨hk0, hk32⟩
  have hs : Pion.I32.shl x k = ok ⟨x.bv <<< k.val.toNat⟩ := by
    simp only [Pion.I32.shl, hk, and_self, ↓reduceIte]
  refine ⟨⟨x.bv <<< k.val.toNat⟩, hs, ?_⟩
  have hxn := i32_toNat_of_nonneg x hx0
  have hnat : (x.bv <<< k.val.toNat).toNat = x.val.toNat * 2 ^ k.val.toNat := by
    rw [BitVec.toNat_shiftLeft, hxn, Nat.shiftLeft_eq]
    exact Nat.mod_eq_of_lt (by omega)
  change (x.bv <<< k.val.toNat).toInt = _
  rw [BitVec.toInt_eq_toNat_of_lt (by omega), hnat]
  have hxz : (x.val.toNat : Int) = x.val := Int.toNat_of_nonneg hx0
  rw [Nat.cast_mul, hxz]

/-- `decode_surrogate_pair` maps every valid `(hi, lo)` pair to a valid supplementary
    Unicode scalar value in `[0x10000, 0x10FFFF]`. -/
theorem decode_surrogate_pair_bounds (hi lo : Std.I32)
    (hhi : is_high_surrogate hi = ok true) (hlo : is_low_surrogate lo = ok true) :
    ∃ cp : Std.I32,
      decode_surrogate_pair hi lo = ok cp ∧
      cp.val = 65536 + (hi.val - 55296) * 1024 + (lo.val - 56320) ∧
      65536 ≤ cp.val ∧ cp.val ≤ 1114111 := by
  have h1 : (55296#i32).val = 55296 := by decide
  have h2 : (56319#i32).val = 56319 := by decide
  have h3 : (56320#i32).val = 56320 := by decide
  have h4 : (57343#i32).val = 57343 := by decide
  have h65 : (65536#i32).val = 65536 := by decide
  have h10 : (10#i32).val = 10 := by decide
  unfold is_high_surrogate at hhi
  unfold is_low_surrogate at hlo
  simp only [Result.ok.injEq, Bool.and_eq_true, decide_eq_true_eq,
    ge_iff_le, IScalar.le_equiv, h1, h2, h3, h4] at hhi hlo
  unfold decode_surrogate_pair
  have hshi : (Pion.I32.sub hi 55296#i32).val = hi.val - 55296 := by
    rw [i32_sub_val hi 55296#i32 (by omega) (by omega), h1]
  have hslo : (Pion.I32.sub lo 56320#i32).val = lo.val - 56320 := by
    rw [i32_sub_val lo 56320#i32 (by omega) (by omega), h3]
  obtain ⟨sh, hsh, hshv⟩ := i32_shl_nonneg (Pion.I32.sub hi 55296#i32) 10#i32
    (by omega) (by omega) (by omega) (by rw [h10]; change _ * 1024 < _; omega)
  rw [hsh, result_bind_ok]
  rw [h10] at hshv
  have hshv' : sh.val = (hi.val - 55296) * 1024 := by
    change sh.val = (Pion.I32.sub hi 55296#i32).val * (1024 : Nat) at hshv
    omega
  have ha1 : (Pion.I32.add 65536#i32 sh).val = 65536 + sh.val := by
    rw [i32_add_val 65536#i32 sh (by omega) (by omega), h65]
  have ha2 : (Pion.I32.add (Pion.I32.add 65536#i32 sh) (Pion.I32.sub lo 56320#i32)).val =
      65536 + (hi.val - 55296) * 1024 + (lo.val - 56320) := by
    rw [i32_add_val _ _ (by omega) (by omega), ha1, hslo]; omega
  exact ⟨_, rfl, ha2, by omega, by omega⟩

/-- `decode_surrogate_pair` is injective on valid UTF-16 surrogate pairs. -/
theorem decode_surrogate_pair_injective (h1 l1 h2 l2 : Std.I32)
    (hh1 : is_high_surrogate h1 = ok true) (hl1 : is_low_surrogate l1 = ok true)
    (hh2 : is_high_surrogate h2 = ok true) (hl2 : is_low_surrogate l2 = ok true)
    (heq : decode_surrogate_pair h1 l1 = decode_surrogate_pair h2 l2) :
    h1 = h2 ∧ l1 = l2 := by
  obtain ⟨c1, hc1, hcv1, _, _⟩ := decode_surrogate_pair_bounds h1 l1 hh1 hl1
  obtain ⟨c2, hc2, hcv2, _, _⟩ := decode_surrogate_pair_bounds h2 l2 hh2 hl2
  rw [hc1, hc2, Result.ok.injEq] at heq
  subst heq
  have ha : (55296#i32).val = 55296 := by decide
  have hb : (56319#i32).val = 56319 := by decide
  have hc : (56320#i32).val = 56320 := by decide
  have hd : (57343#i32).val = 57343 := by decide
  unfold is_high_surrogate at hh1 hh2
  unfold is_low_surrogate at hl1 hl2
  simp only [Result.ok.injEq, Bool.and_eq_true, decide_eq_true_eq,
    ge_iff_le, IScalar.le_equiv, ha, hb, hc, hd] at hh1 hh2 hl1 hl2
  exact ⟨i32_eq_of_val (by omega), i32_eq_of_val (by omega)⟩

/-- `pack_hex2` packs two hex nibbles (`0..15`) into a byte in `[0, 255]`. -/
theorem pack_hex2_bounds (h0 h1 : Std.I32)
    (h0b : 0 ≤ h0.val ∧ h0.val ≤ 15) (h1b : 0 ≤ h1.val ∧ h1.val ≤ 15) :
    ∃ v : Std.I32, pack_hex2 h0 h1 = ok v ∧ 0 ≤ v.val ∧ v.val ≤ 255 := by
  unfold pack_hex2
  have h4 : (4#i32).val = 4 := by decide
  obtain ⟨sh, hsh, hshv⟩ := i32_shl_nonneg h0 4#i32 (by omega) (by omega) h0b.1
    (by rw [h4]; change _ * 16 < _; omega)
  rw [hsh, result_bind_ok]
  rw [h4] at hshv
  have hshv' : sh.val = h0.val * (16 : Nat) := hshv
  have hsh_lt : sh.bv.toNat < 2 ^ 8 := by
    have := i32_toNat_of_nonneg sh (by omega)
    omega
  have hh1_lt : h1.bv.toNat < 2 ^ 8 := by
    have := i32_toNat_of_nonneg h1 h1b.1
    omega
  have hor_lt : (Pion.I32.bor sh h1).bv.toNat < 2 ^ 8 := by
    change (sh.bv ||| h1.bv).toNat < 2 ^ 8
    rw [BitVec.toNat_or]
    exact Nat.or_lt_two_pow hsh_lt hh1_lt
  have hval : (Pion.I32.bor sh h1).val = ((Pion.I32.bor sh h1).bv.toNat : Int) := by
    change (Pion.I32.bor sh h1).bv.toInt = _
    exact BitVec.toInt_eq_toNat_of_lt (by omega)
  exact ⟨Pion.I32.bor sh h1, rfl, by omega, by omega⟩

private lemma i32_beq_false_of_ne {x y : Std.I32} (h : x.val ≠ y.val) : (x == y) = false := by
  cases hb : (x == y)
  · rfl
  · rw [i32_beq_iff] at hb; exact absurd hb h

/-- `is_unicode_j5_ws` returns `false` for all ASCII code points (`cp < 128`). -/
theorem is_unicode_j5_ws_non_ascii (cp : Std.I32) (h : cp.val < 128) :
    is_unicode_j5_ws cp = ok false := by
  unfold is_unicode_j5_ws
  have h1 : (160#i32).val = 160 := by decide
  have h2 : (65279#i32).val = 65279 := by decide
  have h3 : (8232#i32).val = 8232 := by decide
  have h4 : (8233#i32).val = 8233 := by decide
  have h5 : (5760#i32).val = 5760 := by decide
  have h6 : (8192#i32).val = 8192 := by decide
  have h7 : (8239#i32).val = 8239 := by decide
  have h8 : (8287#i32).val = 8287 := by decide
  have h9 : (12288#i32).val = 12288 := by decide
  have c1 : (cp == 160#i32) = false := i32_beq_false_of_ne (by omega)
  have c2 : (cp == 65279#i32) = false := i32_beq_false_of_ne (by omega)
  have c3 : (cp == 8232#i32) = false := i32_beq_false_of_ne (by omega)
  have c4 : (cp == 8233#i32) = false := i32_beq_false_of_ne (by omega)
  have c5 : (cp == 5760#i32) = false := i32_beq_false_of_ne (by omega)
  have c6 : decide (cp >= 8192#i32) = false := by
    simp only [decide_eq_false_iff_not, ge_iff_le, IScalar.le_equiv, h6]; omega
  have c7 : (cp == 8239#i32) = false := i32_beq_false_of_ne (by omega)
  have c8 : (cp == 8287#i32) = false := i32_beq_false_of_ne (by omega)
  have c9 : (cp == 12288#i32) = false := i32_beq_false_of_ne (by omega)
  simp only [c1, c2, c3, c4, c5, c6, c7, c8, c9, Bool.false_and, Bool.false_or]

end Json5Proofs
