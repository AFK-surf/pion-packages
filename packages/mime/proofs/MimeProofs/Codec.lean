import Aeneas
import PionLean
import Mime.Types
import Mime.Funs

open Aeneas Aeneas.Std Result Pion mime

namespace MimeProofs

@[simp]
lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

lemma result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

lemma iscalar_eq_of_bv_eq {ty} {a b : IScalar ty} (h : a.bv = b.bv) : a = b := by
  cases a; cases b; congr

lemma iscalar_eq_of_val_eq {ty} {a b : IScalar ty} (h : a.val = b.val) : a = b :=
  iscalar_eq_of_bv_eq (BitVec.eq_of_toInt_eq h)

lemma i32_mk_bv (x : BitVec 32) : (⟨x⟩ : I32).bv = x := rfl

lemma i32_band_bv (a b : I32) : (Pion.I32.band a b).bv = a.bv &&& b.bv := rfl

lemma i32_bor_bv (a b : I32) : (Pion.I32.bor a b).bv = a.bv ||| b.bv := rfl

lemma i32_shl_ok (x : I32) (s : I32) (hs0 : 0 ≤ s.val) (hs1 : s.val < 32) :
    Pion.I32.shl x s = ok (⟨x.bv <<< s.val.toNat⟩ : I32) := by
  unfold Pion.I32.shl
  simp [hs0, hs1]

lemma i32_shr_ok (x : I32) (s : I32) (hs0 : 0 ≤ s.val) (hs1 : s.val < 32) :
    Pion.I32.shr x s = ok (⟨x.bv.sshiftRight s.val.toNat⟩ : I32) := by
  unfold Pion.I32.shr
  simp [hs0, hs1]

lemma i32_val_nonneg_toNat (x : I32) (hx : 0 ≤ x.val) :
    x.bv.toNat = x.val.toNat := by
  have h1 : x.val = x.bv.toInt := rfl
  have h2 : x.bv.toInt = if 2 * x.bv.toNat < 2 ^ 32 then (x.bv.toNat : Int) else (x.bv.toNat : Int) - 2 ^ 32 := by
    rw [BitVec.toInt_eq_toNat_cond]; rfl
  have hlt : x.bv.toNat < 2 ^ 32 := x.bv.isLt
  omega

lemma i32_add_val_of_bounds (a b : I32)
    (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  have h1 : (Pion.I32.add a b).val = (a.bv + b.bv).toInt := rfl
  rw [h1, BitVec.toInt_add]
  have ha : a.bv.toInt = a.val := rfl
  have hb : b.bv.toInt = b.val := rfl
  rw [ha, hb]
  by_cases h0 : 0 ≤ a.val + b.val
  · have hm : (a.val + b.val) % ((2 ^ 32 : Nat) : Int) = a.val + b.val :=
      Int.emod_eq_of_lt h0 (by omega)
    simp only [Int.bmod, hm]; split <;> omega
  · have hm : (a.val + b.val) % ((2 ^ 32 : Nat) : Int) = a.val + b.val + ((2 ^ 32 : Nat) : Int) := by
      have h' : (a.val + b.val + ((2 ^ 32 : Nat) : Int)) % ((2 ^ 32 : Nat) : Int) =
          a.val + b.val + ((2 ^ 32 : Nat) : Int) :=
        Int.emod_eq_of_lt (by omega) (by omega)
      simpa [Int.add_emod_right] using h'
    simp only [Int.bmod, hm]; split <;> omega

lemma i32_sub_val_of_bounds (a b : I32)
    (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  have h1 : (Pion.I32.sub a b).val = (a.bv - b.bv).toInt := rfl
  rw [h1, BitVec.toInt_sub]
  have ha : a.bv.toInt = a.val := rfl
  have hb : b.bv.toInt = b.val := rfl
  rw [ha, hb]
  by_cases h0 : 0 ≤ a.val - b.val
  · have hm : (a.val - b.val) % ((2 ^ 32 : Nat) : Int) = a.val - b.val :=
      Int.emod_eq_of_lt h0 (by omega)
    simp only [Int.bmod, hm]; split <;> omega
  · have hm : (a.val - b.val) % ((2 ^ 32 : Nat) : Int) = a.val - b.val + ((2 ^ 32 : Nat) : Int) := by
      have h' : (a.val - b.val + ((2 ^ 32 : Nat) : Int)) % ((2 ^ 32 : Nat) : Int) =
          a.val - b.val + ((2 ^ 32 : Nat) : Int) :=
        Int.emod_eq_of_lt (by omega) (by omega)
      simpa [Int.add_emod_right] using h'
    simp only [Int.bmod, hm]; split <;> omega

lemma bv32_getElem_high_false (x : I32) (hx0 : 0 ≤ x.val) {k : Nat} (hx : x.val < ((2 ^ k : Nat) : Int))
    (i : Nat) (hi : i < 32) (hki : k ≤ i) : x.bv[i] = false := by
  rw [BitVec.getElem_eq_testBit_toNat, i32_val_nonneg_toNat x hx0]
  apply Nat.testBit_lt_two_pow
  have hlt : x.val.toNat < 2 ^ k := by omega
  exact Nat.lt_of_lt_of_le hlt (Nat.pow_le_pow_right (by omega) hki)

/-- Theorem 1: `hex_nibble_val ∘ hex_upper_digit = id` for all 4-bit nibbles `0..15`. -/
theorem hex_upper_digit_roundtrip (n : I32) (hlo : 0 ≤ n.val) (hhi : n.val ≤ 15) :
    (do let c ← hex_upper_digit n; hex_nibble_val c) = ok n := by
  unfold hex_upper_digit hex_nibble_val
  have c48 : (48#i32 : I32).val = 48 := rfl
  have c55 : (55#i32 : I32).val = 55 := rfl
  by_cases h10 : n.val < 10
  · have hlt : n < (10#i32 : I32) := h10
    simp only [hlt, ↓reduceIte, result_bind_ok]
    have hv := i32_add_val_of_bounds 48#i32 n (by omega) (by omega)
    have hge : (48#i32 : I32) ≤ Pion.I32.add 48#i32 n := show (48 : Int) ≤ (Pion.I32.add 48#i32 n).val by omega
    have hle : Pion.I32.add 48#i32 n ≤ (57#i32 : I32) := show (Pion.I32.add 48#i32 n).val ≤ (57 : Int) by omega
    simp only [hge, hle, decide_true, Bool.and_self, ↓reduceIte]
    congr 1
    apply iscalar_eq_of_val_eq
    have hs := i32_sub_val_of_bounds (Pion.I32.add 48#i32 n) 48#i32 (by omega) (by omega)
    omega
  · have hge10 : ¬(n < (10#i32 : I32)) := h10
    simp only [hge10, ↓reduceIte, result_bind_ok]
    have hv := i32_add_val_of_bounds 55#i32 n (by omega) (by omega)
    have hnot_d : ¬(Pion.I32.add 55#i32 n ≤ (57#i32 : I32)) := show ¬((Pion.I32.add 55#i32 n).val ≤ (57 : Int)) by omega
    have hge : (65#i32 : I32) ≤ Pion.I32.add 55#i32 n := show (65 : Int) ≤ (Pion.I32.add 55#i32 n).val by omega
    have hle : Pion.I32.add 55#i32 n ≤ (70#i32 : I32) := show (Pion.I32.add 55#i32 n).val ≤ (70 : Int) by omega
    simp only [hnot_d, hge, hle, decide_false, decide_true, Bool.and_false, Bool.and_self, ↓reduceIte, Bool.false_eq_true]
    congr 1
    apply iscalar_eq_of_val_eq
    have hs := i32_sub_val_of_bounds (Pion.I32.add 55#i32 n) 55#i32 (by omega) (by omega)
    omega

/-- Theorem 2: `hex_nibble_val` always returns either `-1` (invalid) or a valid nibble in `[0, 15]`. -/
theorem hex_nibble_val_bounds (c : I32) :
    ∃ v, hex_nibble_val c = ok v ∧ (v.val = -1 ∨ (0 ≤ v.val ∧ v.val ≤ 15)) := by
  unfold hex_nibble_val
  have c48 : (48#i32 : I32).val = 48 := rfl
  have c55 : (55#i32 : I32).val = 55 := rfl
  have c87 : (87#i32 : I32).val = 87 := rfl
  have cm1 : ((-1)#i32 : I32).val = -1 := rfl
  by_cases hd : 48 ≤ c.val ∧ c.val ≤ 57
  · have h1 : (48#i32 : I32) ≤ c := hd.1
    have h2 : c ≤ (57#i32 : I32) := hd.2
    simp only [h1, h2, decide_true, Bool.and_self, ↓reduceIte]
    have hs := i32_sub_val_of_bounds c 48#i32 (by omega) (by omega)
    exact ⟨_, rfl, Or.inr ⟨by omega, by omega⟩⟩
  · have hfd : (decide (c ≥ 48#i32) && decide (c ≤ 57#i32)) = false := by
      rw [Bool.and_eq_false_iff]; by_cases ha : 48 ≤ c.val
      · right; rw [decide_eq_false_iff_not]; change ¬(c.val ≤ 57); omega
      · left; rw [decide_eq_false_iff_not]; change ¬(48 ≤ c.val); omega
    by_cases hu : 65 ≤ c.val ∧ c.val ≤ 70
    · have h1 : (65#i32 : I32) ≤ c := hu.1
      have h2 : c ≤ (70#i32 : I32) := hu.2
      simp only [hfd, h1, h2, decide_true, Bool.and_self, ↓reduceIte, Bool.false_eq_true]
      have hs := i32_sub_val_of_bounds c 55#i32 (by omega) (by omega)
      exact ⟨_, rfl, Or.inr ⟨by omega, by omega⟩⟩
    · have hfu : (decide (c ≥ 65#i32) && decide (c ≤ 70#i32)) = false := by
        rw [Bool.and_eq_false_iff]; by_cases ha : 65 ≤ c.val
        · right; rw [decide_eq_false_iff_not]; change ¬(c.val ≤ 70); omega
        · left; rw [decide_eq_false_iff_not]; change ¬(65 ≤ c.val); omega
      by_cases hl : 97 ≤ c.val ∧ c.val ≤ 102
      · have h1 : (97#i32 : I32) ≤ c := hl.1
        have h2 : c ≤ (102#i32 : I32) := hl.2
        simp only [hfd, hfu, h1, h2, decide_true, Bool.and_self, ↓reduceIte, Bool.false_eq_true]
        have hs := i32_sub_val_of_bounds c 87#i32 (by omega) (by omega)
        exact ⟨_, rfl, Or.inr ⟨by omega, by omega⟩⟩
      · have hfl : (decide (c ≥ 97#i32) && decide (c ≤ 102#i32)) = false := by
          rw [Bool.and_eq_false_iff]; by_cases ha : 97 ≤ c.val
          · right; rw [decide_eq_false_iff_not]; change ¬(c.val ≤ 102); omega
          · left; rw [decide_eq_false_iff_not]; change ¬(97 ≤ c.val); omega
        simp only [hfd, hfu, hfl, ↓reduceIte, Bool.false_eq_true]
        exact ⟨(-1)#i32, rfl, Or.inl cm1⟩

/-- Theorem 4: `ascii_lower_byte` is idempotent on all bytes `0..255`. -/
theorem ascii_lower_byte_idempotent (c : I32) (hlo : 0 ≤ c.val) (hhi : c.val ≤ 255) :
    (do let y ← ascii_lower_byte c; ascii_lower_byte y) = ascii_lower_byte c := by
  unfold ascii_lower_byte
  have c32 : (32#i32 : I32).val = 32 := rfl
  by_cases hu : 65 ≤ c.val ∧ c.val ≤ 90
  · have h1 : (65#i32 : I32) ≤ c := hu.1
    have h2 : c ≤ (90#i32 : I32) := hu.2
    simp only [h1, h2, decide_true, Bool.and_self, ↓reduceIte, result_bind_ok]
    have ha := i32_add_val_of_bounds c 32#i32 (by omega) (by omega)
    have hnot : ¬(Pion.I32.add c 32#i32 ≤ (90#i32 : I32)) := show ¬((Pion.I32.add c 32#i32).val ≤ (90 : Int)) by omega
    simp only [hnot, decide_false, Bool.and_false, Bool.false_eq_true, ↓reduceIte]
  · have hfu : (decide (c ≥ 65#i32) && decide (c ≤ 90#i32)) = false := by
      rw [Bool.and_eq_false_iff]; by_cases ha : 65 ≤ c.val
      · right; rw [decide_eq_false_iff_not]; change ¬(c.val ≤ 90); omega
      · left; rw [decide_eq_false_iff_not]; change ¬(65 ≤ c.val); omega
    simp only [hfu, Bool.false_eq_true, ↓reduceIte, result_bind_ok]

private lemma i32_15_mask_range (x : I32) :
    0 ≤ (Pion.I32.band x 15#i32).val ∧ (Pion.I32.band x 15#i32).val ≤ 15 := by
  have hval : (Pion.I32.band x 15#i32).val = (Pion.I32.band x 15#i32).bv.toInt := rfl
  have htoNat : (Pion.I32.band x 15#i32).bv.toNat ≤ 15 := by
    rw [i32_band_bv, BitVec.toNat_and]
    have : (15#i32).bv.toNat = 15 := by decide
    rw [this]; exact Nat.and_le_right
  have h2 : (Pion.I32.band x 15#i32).bv.toInt =
      if 2 * (Pion.I32.band x 15#i32).bv.toNat < 2 ^ 32 then ((Pion.I32.band x 15#i32).bv.toNat : Int)
      else ((Pion.I32.band x 15#i32).bv.toNat : Int) - 2 ^ 32 := by
    rw [BitVec.toInt_eq_toNat_cond]; rfl
  omega

/-- Theorem 7: RFC 2045 §6.7 Quoted-Printable byte nibble unpack/pack roundtrip bijection for all `0 ≤ c ≤ 255`. -/
theorem qp_hex_byte_roundtrip (c : I32) (hlo : 0 ≤ c.val) (hhi : c.val ≤ 255) :
    (do
      let hi ← qp_hi_nibble c
      let lo ← qp_lo_nibble c
      qp_pack_hex_byte hi lo) = ok c := by
  unfold qp_hi_nibble qp_lo_nibble qp_pack_hex_byte
  rw [i32_shr_ok c 4#i32 (by decide) (by decide), result_bind_ok, result_bind_ok, result_bind_ok]
  rw [i32_shl_ok _ 4#i32 (by decide) (by decide), result_bind_ok]
  congr 1
  apply iscalar_eq_of_bv_eq
  apply BitVec.eq_of_getElem_eq
  intro i hi
  have hi32 : i < 32 := hi
  have h4n : (4#i32 : I32).val.toNat = 4 := rfl
  simp only [i32_bor_bv, i32_band_bv, i32_mk_bv, h4n, BitVec.getElem_or, BitVec.getElem_and, BitVec.getElem_shiftLeft]
  by_cases h4 : i < 4
  · have hm : (15#i32).bv[i] = true := by
      rw [BitVec.getElem_eq_testBit_toNat]
      have : (15#i32).bv.toNat = 15 := by decide
      rw [this]; revert i h4; decide
    simp only [h4, decide_true, Bool.not_true, Bool.false_and, Bool.false_or, hm, Bool.and_true]
  · by_cases h8 : i < 8
    · have hm0 : (15#i32).bv[i] = false := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (15#i32).bv.toNat = 15 := by decide
        rw [this]
        exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 4 ≤ i)))
      have hm1 : (15#i32).bv[i - 4] = true := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (15#i32).bv.toNat = 15 := by decide
        rw [this]
        have : i - 4 < 4 := by omega
        revert this; generalize i - 4 = k; intro hk; revert k hk; decide
      have hlt : 4 + (i - 4) < 32 := by omega
      simp only [h4, decide_false, Bool.not_false, Bool.true_and, hm0, hm1,
                 Bool.and_false, Bool.and_true, Bool.or_false,
                 BitVec.getElem_sshiftRight, hlt, ↓reduceDIte]
      congr 1; omega
    · have hm0 : (15#i32).bv[i] = false := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (15#i32).bv.toNat = 15 := by decide
        rw [this]
        exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 4 ≤ i)))
      have hm1 : (15#i32).bv[i - 4] = false := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (15#i32).bv.toNat = 15 := by decide
        rw [this]
        exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 4 ≤ i - 4)))
      have hc0 : c.bv[i] = false :=
        bv32_getElem_high_false c hlo (by omega : c.val < ((2 ^ 8 : Nat) : Int)) i hi32 (by omega)
      simp only [h4, decide_false, Bool.not_false, hm0, hm1, Bool.and_false, Bool.or_false, hc0]

/-- Theorem 8: RFC 2045 §6.7 Quoted-Printable encoder ALWAYS escapes `=`, CTLs (except HTAB), DEL, and non-ASCII. -/
theorem qp_encode_forbids_equals_and_ctl (c : I32) (last : Bool)
    (h : c = 61#i32 ∨ (0 ≤ c.val ∧ c.val ≤ 8) ∨ (10 ≤ c.val ∧ c.val ≤ 31) ∨ c.val ≥ 127) :
    qp_encode_is_literal c last = ok false := by
  unfold qp_encode_is_literal
  cases last
  · rcases h with rfl | ⟨h0, h8⟩ | ⟨h10, h31⟩ | h127
    · simp
    · have hne32 : (c == 32#i32) = false := beq_false_of_ne (by intro h; subst h; have : (32#i32 : I32).val = 32 := rfl; omega)
      have hne9 : (c == 9#i32) = false := beq_false_of_ne (by intro h; subst h; have : (9#i32 : I32).val = 9 := rfl; omega)
      have hlt33 : ¬((33#i32 : I32) ≤ c) := by change ¬(33 ≤ c.val); omega
      simp [hne32, hne9, hlt33]
    · have hne32 : (c == 32#i32) = false := beq_false_of_ne (by intro h; subst h; have : (32#i32 : I32).val = 32 := rfl; omega)
      have hne9 : (c == 9#i32) = false := beq_false_of_ne (by intro h; subst h; have : (9#i32 : I32).val = 9 := rfl; omega)
      have hlt33 : ¬((33#i32 : I32) ≤ c) := by change ¬(33 ≤ c.val); omega
      simp [hne32, hne9, hlt33]
    · have hne32 : (c == 32#i32) = false := beq_false_of_ne (by intro h; subst h; have : (32#i32 : I32).val = 32 := rfl; omega)
      have hne9 : (c == 9#i32) = false := beq_false_of_ne (by intro h; subst h; have : (9#i32 : I32).val = 9 := rfl; omega)
      have hgt126 : ¬(c ≤ (126#i32 : I32)) := by change ¬(c.val ≤ 126); omega
      simp [hne32, hne9, hgt126]
  · simp

/-- Theorem 10: RFC 2045 §6.7 Quoted-Printable decoder rejects NUL, C0 controls (except HTAB/CR), and DEL. -/
theorem qp_decode_rejects_nul_and_c0 (c : I32)
    (h : (0 ≤ c.val ∧ c.val ≤ 8) ∨ (10 ≤ c.val ∧ c.val ≤ 12) ∨ (14 ≤ c.val ∧ c.val ≤ 31) ∨ c.val = 127) :
    qp_decode_allowed_literal c = ok false := by
  unfold qp_decode_allowed_literal
  have hne9 : (c == 9#i32) = false := beq_false_of_ne (by intro heq; subst heq; have : (9#i32 : I32).val = 9 := rfl; omega)
  have hne13 : (c == 13#i32) = false := beq_false_of_ne (by intro heq; subst heq; have : (13#i32 : I32).val = 13 := rfl; omega)
  have hlt128 : ¬((128#i32 : I32) ≤ c) := by change ¬(128 ≤ c.val); omega
  rcases h with ⟨h0, h8⟩ | ⟨h10, h12⟩ | ⟨h14, h31⟩ | h127
  · have hlt32 : ¬((32#i32 : I32) ≤ c) := by change ¬(32 ≤ c.val); omega
    simp [hne9, hne13, hlt32, hlt128]
  · have hlt32 : ¬((32#i32 : I32) ≤ c) := by change ¬(32 ≤ c.val); omega
    simp [hne9, hne13, hlt32, hlt128]
  · have hlt32 : ¬((32#i32 : I32) ≤ c) := by change ¬(32 ≤ c.val); omega
    simp [hne9, hne13, hlt32, hlt128]
  · have hgt126 : ¬(c ≤ (126#i32 : I32)) := by change ¬(c.val ≤ 126); omega
    simp [hne9, hne13, hgt126, hlt128]

/-- Theorem 11: RFC 2045 §6.7 76-column soft-wrap guard ensures every emitted token stays within column 75 (leaving room for soft `=`). -/
theorem qp_soft_wrap_76_col_bound (col width : I32)
    (hc0 : 0 ≤ col.val) (hc75 : col.val ≤ 75) (hw0 : 1 ≤ width.val) (hw3 : width.val ≤ 3) :
    qp_needs_soft_wrap col width = ok false → col.val + width.val ≤ 75 := by
  unfold qp_needs_soft_wrap
  intro h
  have hf := result_ok_inj h
  rw [decide_eq_false_iff_not] at hf
  have hadd := i32_add_val_of_bounds col width (by omega) (by omega)
  have hnot : ¬(75 < (Pion.I32.add col width).val) := hf
  omega

end MimeProofs
