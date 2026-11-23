import Aeneas
import PionLean
import Zip.Types
import Zip.Funs

open Aeneas Aeneas.Std Result Pion zip

namespace ZipProofs

@[simp]
theorem result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

theorem result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

theorem iscalar_eq_of_bv_eq {ty} {a b : IScalar ty} (h : a.bv = b.bv) : a = b := by
  cases a; cases b; congr

theorem iscalar_eq_of_val_eq {ty} {a b : IScalar ty} (h : a.val = b.val) : a = b :=
  iscalar_eq_of_bv_eq (BitVec.eq_of_toInt_eq h)

theorem i32_mk_bv (x : BitVec 32) : (⟨x⟩ : I32).bv = x := rfl

theorem u32_mk_bv (x : BitVec 32) : (⟨x⟩ : U32).bv = x := rfl

theorem i32_band_bv (a b : I32) : (Pion.I32.band a b).bv = a.bv &&& b.bv := rfl

theorem i32_bor_bv (a b : I32) : (Pion.I32.bor a b).bv = a.bv ||| b.bv := rfl

theorem u32_band_bv (a b : U32) : (Pion.U32.band a b).bv = a.bv &&& b.bv := rfl

theorem i32_shl_ok (x : I32) (s : I32) (hs0 : 0 ≤ s.val) (hs1 : s.val < 32) :
    Pion.I32.shl x s = ok (⟨x.bv <<< s.val.toNat⟩ : I32) := by
  unfold Pion.I32.shl
  simp [hs0, hs1]

theorem i32_shr_ok (x : I32) (s : I32) (hs0 : 0 ≤ s.val) (hs1 : s.val < 32) :
    Pion.I32.shr x s = ok (⟨x.bv.sshiftRight s.val.toNat⟩ : I32) := by
  unfold Pion.I32.shr
  simp [hs0, hs1]

theorem u32_shr_ok (x : U32) (s : U32) (hs : s.val < 32) :
    Pion.U32.shr x s = ok (⟨x.bv >>> s.val⟩ : U32) := by
  unfold Pion.U32.shr
  simp [hs]

theorem i32_val_nonneg_toNat (x : I32) (hx : 0 ≤ x.val) :
    x.bv.toNat = x.val.toNat := by
  have h1 : x.val = x.bv.toInt := rfl
  have h2 : x.bv.toInt = if 2 * x.bv.toNat < 2 ^ 32 then (x.bv.toNat : Int) else (x.bv.toNat : Int) - 2 ^ 32 := by
    rw [BitVec.toInt_eq_toNat_cond]; rfl
  have hlt : x.bv.toNat < 2 ^ 32 := x.bv.isLt
  omega

theorem i32_add_val_of_bounds (a b : I32)
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

theorem i32_sub_val_of_bounds (a b : I32)
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

theorem i64_sub_val_of_bounds (a b : I64)
    (hlo : -9223372036854775808 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 9223372036854775807) :
    (Pion.I64.sub a b).val = a.val - b.val := by
  have h1 : (Pion.I64.sub a b).val = (a.bv - b.bv).toInt := rfl
  rw [h1, BitVec.toInt_sub]
  have ha : a.bv.toInt = a.val := rfl
  have hb : b.bv.toInt = b.val := rfl
  rw [ha, hb]
  by_cases h0 : 0 ≤ a.val - b.val
  · have hm : (a.val - b.val) % ((2 ^ 64 : Nat) : Int) = a.val - b.val :=
      Int.emod_eq_of_lt h0 (by omega)
    simp only [Int.bmod, hm]; split <;> omega
  · have hm : (a.val - b.val) % ((2 ^ 64 : Nat) : Int) = a.val - b.val + ((2 ^ 64 : Nat) : Int) := by
      have h' : (a.val - b.val + ((2 ^ 64 : Nat) : Int)) % ((2 ^ 64 : Nat) : Int) =
          a.val - b.val + ((2 ^ 64 : Nat) : Int) :=
        Int.emod_eq_of_lt (by omega) (by omega)
      simpa [Int.add_emod_right] using h'
    simp only [Int.bmod, hm]; split <;> omega

theorem bv32_getElem_high_false (x : I32) (hx0 : 0 ≤ x.val) {k : Nat} (hx : x.val < ((2 ^ k : Nat) : Int))
    (i : Nat) (hi : i < 32) (hki : k ≤ i) : x.bv[i] = false := by
  rw [BitVec.getElem_eq_testBit_toNat, i32_val_nonneg_toNat x hx0]
  apply Nat.testBit_lt_two_pow
  have hlt : x.val.toNat < 2 ^ k := by omega
  exact Nat.lt_of_lt_of_le hlt (Nat.pow_le_pow_right (by omega) hki)

/-- Theorem 1: `in_range64` is exact overflow-free mathematical range inclusion `0 ≤ off, size, limit ∧ off + size ≤ limit`. -/
theorem in_range64_iff (off size limit : I64) :
    in_range64 off size limit = ok true ↔
      0 ≤ off.val ∧ 0 ≤ size.val ∧ 0 ≤ limit.val ∧ off.val + size.val ≤ limit.val := by
  unfold in_range64
  have hlim_hi : limit.val ≤ 9223372036854775807 := by
    have h := limit.hBounds.2; change limit.val < 2 ^ 63 at h; omega
  constructor
  · intro h
    have ht := result_ok_inj h
    simp only [Bool.and_eq_true, decide_eq_true_eq] at ht
    rcases ht with ⟨⟨⟨⟨hoff, hsize⟩, hlim⟩, hle⟩, hoff_le⟩
    have hoff' : 0 ≤ off.val := hoff
    have hsize' : 0 ≤ size.val := hsize
    have hlim' : 0 ≤ limit.val := hlim
    have hle' : size.val ≤ limit.val := hle
    have hsub := i64_sub_val_of_bounds limit size (by omega) (by omega)
    have hoff_le' : off.val ≤ (Pion.I64.sub limit size).val := hoff_le
    omega
  · intro ⟨hoff, hsize, hlim, hsum⟩
    have h1 : (0#i64 : I64) ≤ off := hoff
    have h2 : (0#i64 : I64) ≤ size := hsize
    have h3 : (0#i64 : I64) ≤ limit := hlim
    have h4 : size ≤ limit := by change size.val ≤ limit.val; omega
    have hsub := i64_sub_val_of_bounds limit size (by omega) (by omega)
    have h5 : off ≤ Pion.I64.sub limit size := show off.val ≤ (Pion.I64.sub limit size).val by omega
    simp only [h1, h2, h3, h4, h5, decide_true, Bool.and_self]

/-- Theorem 2: `in_range64` rejects any negative offset, size, or limit. -/
theorem in_range64_rejects_negative (off size limit : I64)
    (h : off.val < 0 ∨ size.val < 0 ∨ limit.val < 0) :
    in_range64 off size limit = ok false := by
  unfold in_range64
  rcases h with h1 | h2 | h3
  · have hf : ¬((0#i64 : I64) ≤ off) := by change ¬(0 ≤ off.val); omega
    simp [hf]
  · have hf : ¬((0#i64 : I64) ≤ size) := by change ¬(0 ≤ size.val); omega
    simp [hf]
  · have hf : ¬((0#i64 : I64) ≤ limit) := by change ¬(0 ≤ limit.val); omega
    simp [hf]

/-- Theorem 3: `in_range64` is immune to `Int64::MAX + 1` wrap-around attacks. -/
theorem in_range64_rejects_int64_max_wrap :
    in_range64 9223372036854775807#i64 1#i64 100#i64 = ok false ∧
    in_range64 1#i64 9223372036854775807#i64 100#i64 = ok false := by
  constructor <;> (unfold in_range64; congr 1)

/-- Theorem 4: `ascii_upper` is idempotent on all bytes `0..255`. -/
theorem ascii_upper_idempotent (c : I32) (hlo : 0 ≤ c.val) (hhi : c.val ≤ 255) :
    (do let y ← ascii_upper c; ascii_upper y) = ascii_upper c := by
  unfold ascii_upper
  have c32 : (32#i32 : I32).val = 32 := rfl
  by_cases hl : 97 ≤ c.val ∧ c.val ≤ 122
  · have h1 : (97#i32 : I32) ≤ c := hl.1
    have h2 : c ≤ (122#i32 : I32) := hl.2
    simp only [h1, h2, decide_true, Bool.and_self, ↓reduceIte, result_bind_ok]
    have hs := i32_sub_val_of_bounds c 32#i32 (by omega) (by omega)
    have hnot : ¬((97#i32 : I32) ≤ Pion.I32.sub c 32#i32) := show ¬((97 : Int) ≤ (Pion.I32.sub c 32#i32).val) by omega
    simp only [hnot, decide_false, Bool.false_and, Bool.false_eq_true, ↓reduceIte]
  · have hfl : (decide (c ≥ 97#i32) && decide (c ≤ 122#i32)) = false := by
      rw [Bool.and_eq_false_iff]; by_cases ha : 97 ≤ c.val
      · right; rw [decide_eq_false_iff_not]; change ¬(c.val ≤ 122); omega
      · left; rw [decide_eq_false_iff_not]; change ¬(97 ≤ c.val); omega
    simp only [hfl, Bool.false_eq_true, ↓reduceIte, result_bind_ok]

/-- Theorem 5: `ascii_upper` never produces a lowercase ASCII letter `a..z`. -/
theorem ascii_upper_no_lowercase (c : I32) (hlo : 0 ≤ c.val) (hhi : c.val ≤ 255) :
    ∃ y, ascii_upper c = ok y ∧ ¬(97 ≤ y.val ∧ y.val ≤ 122) := by
  unfold ascii_upper
  have c32 : (32#i32 : I32).val = 32 := rfl
  by_cases hl : 97 ≤ c.val ∧ c.val ≤ 122
  · have h1 : (97#i32 : I32) ≤ c := hl.1
    have h2 : c ≤ (122#i32 : I32) := hl.2
    simp only [h1, h2, decide_true, Bool.and_self, ↓reduceIte]
    have hs := i32_sub_val_of_bounds c 32#i32 (by omega) (by omega)
    exact ⟨Pion.I32.sub c 32#i32, rfl, by omega⟩
  · have hfl : (decide (c ≥ 97#i32) && decide (c ≤ 122#i32)) = false := by
      rw [Bool.and_eq_false_iff]; by_cases ha : 97 ≤ c.val
      · right; rw [decide_eq_false_iff_not]; change ¬(c.val ≤ 122); omega
      · left; rw [decide_eq_false_iff_not]; change ¬(97 ≤ c.val); omega
    simp only [hfl, Bool.false_eq_true, ↓reduceIte]
    exact ⟨c, rfl, hl⟩

/-- Theorem 6: `is_zip_path_sep` characterizes Unix `/` (47) and Windows `\` (92). -/
theorem zip_path_sep_iff (c : I32) :
    is_zip_path_sep c = ok true ↔ c = 47#i32 ∨ c = 92#i32 := by
  unfold is_zip_path_sep
  constructor
  · intro h; have ht := result_ok_inj h; simp only [Bool.or_eq_true, beq_iff_eq] at ht; exact ht
  · intro h; rcases h with rfl | rfl <;> simp

/-- Theorem 7: `is_zip_forbidden_byte` rejects all C0 controls (`< 32`), DEL (`127`), and drive/ADS colon `:` (`58`). -/
theorem zip_forbidden_byte_iff (c : I32) :
    is_zip_forbidden_byte c = ok true ↔ c.val < 32 ∨ c.val = 127 ∨ c.val = 58 := by
  unfold is_zip_forbidden_byte
  constructor
  · intro h
    have ht := result_ok_inj h
    simp only [Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq] at ht
    rcases ht with (hlt | rfl) | rfl
    · exact Or.inl hlt
    · exact Or.inr (Or.inl rfl)
    · exact Or.inr (Or.inr rfl)
  · intro h
    rcases h with hlt | h127 | h58
    · have h1 : c < (32#i32 : I32) := hlt; simp [h1]
    · have h2 : c = 127#i32 := iscalar_eq_of_val_eq h127; subst h2; simp
    · have h3 : c = 58#i32 := iscalar_eq_of_val_eq h58; subst h3; simp

/-- Theorem 8: `is_zip_forbidden_seg_tail` rejects trailing `.` (46) and space (32). -/
theorem zip_forbidden_seg_tail_iff (c : I32) :
    is_zip_forbidden_seg_tail c = ok true ↔ c = 46#i32 ∨ c = 32#i32 := by
  unfold is_zip_forbidden_seg_tail
  constructor
  · intro h; have ht := result_ok_inj h; simp only [Bool.or_eq_true, beq_iff_eq] at ht; exact ht
  · intro h; rcases h with rfl | rfl <;> simp

/-- Theorem 9: `is_win_reserved_3` catches `CON`, `PRN`, `AUX`, `NUL` in both uppercase and lowercase. -/
theorem win_reserved_3_catches_all_4_devices :
    is_win_reserved_3 67#i32 79#i32 78#i32 = ok true ∧
    is_win_reserved_3 99#i32 111#i32 110#i32 = ok true ∧
    is_win_reserved_3 80#i32 82#i32 78#i32 = ok true ∧
    is_win_reserved_3 112#i32 114#i32 110#i32 = ok true ∧
    is_win_reserved_3 65#i32 85#i32 88#i32 = ok true ∧
    is_win_reserved_3 97#i32 117#i32 120#i32 = ok true ∧
    is_win_reserved_3 78#i32 85#i32 76#i32 = ok true ∧
    is_win_reserved_3 110#i32 117#i32 108#i32 = ok true := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
    (unfold is_win_reserved_3 ascii_upper; simp only [result_bind_ok]; congr 1)

/-- Theorem 10: `is_win_reserved_4` catches `COM1..COM9` and `LPT1..LPT9` (case-insensitive). -/
theorem win_reserved_4_catches_com_lpt (d : I32) (hlo : 49 ≤ d.val) (hhi : d.val ≤ 57) :
    is_win_reserved_4 67#i32 79#i32 77#i32 d = ok true ∧
    is_win_reserved_4 99#i32 111#i32 109#i32 d = ok true ∧
    is_win_reserved_4 76#i32 80#i32 84#i32 d = ok true ∧
    is_win_reserved_4 108#i32 112#i32 116#i32 d = ok true := by
  have h1 : (49#i32 : I32) ≤ d := hlo
  have h2 : d ≤ (57#i32 : I32) := hhi
  refine ⟨?_, ?_, ?_, ?_⟩ <;>
    (unfold is_win_reserved_4 ascii_upper; simp [h1, h2]; try decide)

/-- Theorem 11: `is_win_reserved_4` does not false-positive on `COM0` or `LPT0`. -/
theorem win_reserved_4_rejects_zero_digit :
    is_win_reserved_4 67#i32 79#i32 77#i32 48#i32 = ok false ∧
    is_win_reserved_4 76#i32 80#i32 84#i32 48#i32 = ok false := by
  constructor <;> (unfold is_win_reserved_4 ascii_upper; simp only [result_bind_ok]; congr 1)

/-- Theorem 12: `is_win_reserved_4` returns `false` whenever the 4th byte is outside `'1'..'9'` (`49..57`). -/
theorem win_reserved_4_requires_digit_1_to_9 (b0 b1 b2 b3 : I32)
    (h : b3.val < 49 ∨ b3.val > 57) :
    is_win_reserved_4 b0 b1 b2 b3 = ok false := by
  unfold is_win_reserved_4 ascii_upper
  simp only [result_bind_ok]
  rcases h with hlt | hgt
  · have hf : ¬((49#i32 : I32) ≤ b3) := by change ¬(49 ≤ b3.val); omega
    simp [hf]
  · have hf : ¬(b3 ≤ (57#i32 : I32)) := by change ¬(b3.val ≤ 57); omega
    simp [hf]

end ZipProofs
